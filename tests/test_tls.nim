## Wire tests over real sockets, for plain HTTP/WS and for HTTPS/WSS. One binary is both sides:
## `test_tls serve <port> [<cert> <key>]` runs the fixture server, and without arguments the
## test starts that server as a child process for each mode and drives it as a client.
##
##   nim c -r -d:ssl -d:sslVersion=3 tests/test_tls.nim
##
## The certificates under tests/tls are test-only fixtures (see tests/tls/README.md).

when not defined(ssl):
  {.error: "test_tls needs -d:ssl -d:sslVersion=3".}
when not defined(posix):
  {.error: "test_tls runs on POSIX systems".}

import std/[base64, locks, net, openssl, os, osproc, random, strutils, tables, times]
from std/nativesockets import setSockOptInt, close
from std/posix import TLinger, SOL_SOCKET, SO_LINGER, SO_RCVBUF, setsockopt, SockLen
import mummy

const
  streamedChunks = 16
  floodPairs = 64
  timeoutMs = 10_000

# ----- The fixture server

var
  server: Server
  stop: Channel[bool]
  streamsLock: Lock
  streamsSent: Table[ResponseBodyStream, int]

proc streamedChunk(index: int): string =
  ## Chunk `index` of `/stream-out`: distinct bytes and lengths, so loss or reordering shows.
  repeat(char(ord('a') + index), 64 * 1024 + index)

proc floodFrame(index: int): string =
  ## Small enough to be joined with its neighbours into one queued write.
  repeat(char(ord('A') + index mod 26), 48 * 1024 + index)

proc handler(request: Request) {.gcsafe.} =
  case request.path
  of "/healthz": request.respond(200, body = "ok")
  of "/echo": request.respond(200, body = request.body)
  of "/ws": discard request.upgradeToWebSocket()
  of "/stream-out": discard request.respondStream()
  of "/stop":
    request.respond(200, body = "stopping")
    stop.send(true)
  else: request.respond(404)

proc requestBodyHandler(request: Request, stream: RequestBodyStream, event: RequestBodyEvent) {.gcsafe.} =
  ## `/stream-in` reads its body in 1 KiB chunks, and socket reads pause until each one is
  ## handled. A body sent in one TLS record is then mostly decrypted inside OpenSSL already,
  ## so it must be delivered when reading resumes even though the socket reports nothing new.
  case event.kind
  of RequestBodyOpen:
    if request.path == "/stream-in": discard stream.accept()
  of RequestBodyChunk:
    request.body.add(event.data)
  of RequestBodyEnd:
    request.respond(200, body = request.body)
  of RequestBodyError: discard

proc responseBodyHandler(stream: ResponseBodyStream, event: ResponseBodyEventKind) {.gcsafe.} =
  case event
  of ResponseBodyOpen, ResponseBodyWritable:
    var index: int
    {.gcsafe.}:
      withLock streamsLock:
        index = streamsSent.getOrDefault(stream)
        streamsSent[stream] = index + 1
    if index < streamedChunks: discard stream.write(streamedChunk(index))
    else: stream.close()
  of ResponseBodyError, ResponseBodyClosed:
    {.gcsafe.}:
      withLock streamsLock:
        streamsSent.del(stream)

proc socketHandler(ws: WebSocket, event: WebSocketEvent, message: Message) {.gcsafe.} =
  if event != MessageEvent: return
  if message.kind == TextMessage and message.data.startsWith("shared:"):
    # One immutable payload queued twice: each send keeps its own offset.
    let payload = newSharedPayload(repeat('s', parseInt(message.data[7 .. ^1])))
    ws.sendShared(payload)
    ws.sendShared(payload)
  elif message.kind == TextMessage and message.data.startsWith("flood:"):
    # Frames queued faster than a stalled reader takes them.
    for i in 0 ..< parseInt(message.data[6 .. ^1]):
      ws.send("small-" & $i)
      ws.send(floodFrame(i), BinaryMessage)
  elif message.kind in {TextMessage, BinaryMessage}:
    ws.send(message.data, message.kind)
  elif message.kind == Ping:
    ws.send(message.data, Pong)

proc stopper() {.thread.} =
  discard stop.recv()
  sleep(100)
  server.close()

proc serveFixture() =
  stop.open()
  initLock(streamsLock)
  let tls =
    if paramCount() > 2:
      TlsConfig(certificateFile: paramStr(3), privateKeyFile: paramStr(4),
                handshakeTimeoutMs: 300, shutdownTimeoutMs: 100, maxPendingHandshakes: 2)
    else: nil
  server = newServer(handler, socketHandler, workerThreads = 2,
                     maxMessageLen = 8 * 1024 * 1024, maxBodyLen = 8 * 1024 * 1024,
                     requestBodyHandler = requestBodyHandler, requestBodyChunkSize = 1024,
                     responseBodyHandler = responseBodyHandler, tls = tls)
  var thread: Thread[void]
  createThread(thread, stopper)
  server.serve(Port(parseInt(paramStr(2))), "127.0.0.1")
  joinThread(thread)

# ----- The client

proc SSL_get_version(ssl: SslPtr): cstring {.cdecl, dynlib: DLLSSLName, importc.}

proc freePort(): Port =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = socket.getLocalAddr()[1]
  socket.close()

proc dial(port: Port, ctx: SslContext = nil): Socket =
  result = newSocket(buffered = false)
  result.connect("127.0.0.1", port, timeoutMs)
  if ctx != nil:
    try:
      ctx.wrapConnectedSocket(result, handshakeAsClient, "localhost")
    except CatchableError:
      result.getFd.close()
      raise

proc quietClose(socket: Socket) =
  try: socket.close()
  except CatchableError: discard

proc exact(socket: Socket, size: int): string =
  while result.len < size:
    let part = socket.recv(size - result.len, timeoutMs)
    doAssert part.len > 0, "unexpected EOF"
    result.add part

proc readHead(socket: Socket): string =
  while not result.endsWith("\r\n\r\n"): result.add socket.exact(1)

proc request(socket: Socket, httpMethod, path: string, body = ""): (int, string) =
  ## One keep-alive HTTP/1.1 exchange, with a Content-Length or chunked answer.
  socket.send(httpMethod & " " & path & " HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
              $body.len & "\r\n\r\n" & body)
  let head = socket.readHead()
  var contentLength = 0
  var chunked = false
  for line in head.split("\r\n")[1 .. ^1]:
    let colon = line.find(':')
    if colon < 0: continue
    let name = line[0 ..< colon].strip.toLowerAscii
    let value = line[colon + 1 .. ^1].strip
    if name == "content-length": contentLength = parseInt(value)
    elif name == "transfer-encoding": chunked = value.toLowerAscii == "chunked"
  var payload = ""
  if chunked:
    while true:
      var sizeLine = ""
      while not sizeLine.endsWith("\r\n"): sizeLine.add socket.exact(1)
      let size = parseHexInt(sizeLine.strip.split(';')[0])
      if size > 0: payload.add socket.exact(size)
      discard socket.exact(2)
      if size == 0: break
  else:
    payload = socket.exact(contentLength)
  (parseInt(head[9 .. 11]), payload)

proc get(port: Port, ctx: SslContext, path: string): string =
  let socket = dial(port, ctx)
  let (status, body) = socket.request("GET", path)
  socket.quietClose()
  doAssert status == 200, path & " answered " & $status
  body

proc websocket(port: Port, ctx: SslContext): Socket =
  result = dial(port, ctx)
  var key = newString(16)
  for c in key.mitems: c = char(rand(255))
  result.send("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" &
              "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" &
              "Sec-WebSocket-Key: " & encode(key) & "\r\n\r\n")
  let head = result.readHead()
  doAssert head.startsWith("HTTP/1.1 101"), head

proc frame(payload: string, opcode = 2): string =
  ## A masked client frame.
  result.add char(0x80 or opcode)
  if payload.len < 126:
    result.add char(0x80 or payload.len)
  elif payload.len <= 65_535:
    result.add char(0xFE)
    result.add char(payload.len shr 8)
    result.add char(payload.len and 0xFF)
  else:
    result.add char(0xFF)
    for shift in countdown(56, 0, 8): result.add char((payload.len shr shift) and 0xFF)
  const mask = "abcd"
  result.add mask
  for i, c in payload: result.add char(ord(c) xor ord(mask[i mod 4]))

proc receive(socket: Socket): (int, string) =
  let head = socket.exact(2)
  doAssert (ord(head[1]) and 0x80) == 0, "masked server frame"
  var size = ord(head[1]) and 127
  if size == 126:
    let bytes = socket.exact(2)
    size = (ord(bytes[0]) shl 8) or ord(bytes[1])
  elif size == 127:
    size = 0
    for c in socket.exact(8): size = (size shl 8) or ord(c)
  (ord(head[0]) and 15, socket.exact(size))

proc reset(socket: Socket) =
  ## Closes with a TCP reset, skipping any TLS close_notify.
  var linger = TLinger(l_onoff: 1, l_linger: 0)
  discard setsockopt(socket.getFd, SOL_SOCKET, SO_LINGER, addr linger, SockLen(sizeof(linger)))
  socket.getFd.close()

proc closedByPeer(socket: Socket): bool =
  try: socket.recv(1, 1000).len == 0
  except TimeoutError: false
  except OSError: true

proc exercise(port: Port, ctx: SslContext) =
  block:
    let socket = dial(port, ctx)
    for _ in 0 ..< 3: doAssert socket.request("GET", "/healthz") == (200, "ok")
    var body = ""
    for _ in 0 ..< 1024:
      for b in 0 .. 255: body.add char(b)
    doAssert socket.request("POST", "/echo", body) == (200, body)
    # A backpressured response stream, chunk by chunk.
    var streamed = ""
    for i in 0 ..< streamedChunks: streamed.add streamedChunk(i)
    doAssert socket.request("GET", "/stream-out") == (200, streamed), "corrupt streamed response"
    # Request bodies read with pauses between chunks: one that fits in a single TLS record,
    # and a large one.
    let small = body[0 ..< 12 * 1024]
    doAssert socket.request("POST", "/stream-in", small) == (200, small),
      "corrupt single-record streamed request body"
    let upload = body.repeat(4)
    doAssert socket.request("POST", "/stream-in", upload) == (200, upload),
      "corrupt streamed request body"
    doAssert socket.request("GET", "/healthz") == (200, "ok")
    socket.quietClose()

  block:
    let socket = websocket(port, ctx)
    var batch = ""
    for i in 0 ..< 128: batch.add frame("sequence-" & $i)
    socket.send(batch)
    for i in 0 ..< 128: doAssert socket.receive() == (2, "sequence-" & $i)
    # Ciphertext records of 3 bytes each.
    let split = frame("fragmented ciphertext input")
    for i in countup(0, split.high, 3): socket.send(split[i .. min(i + 2, split.high)])
    doAssert socket.receive() == (2, "fragmented ciphertext input")
    socket.send(frame("ping", 9))
    doAssert socket.receive() == (10, "ping")
    # A shared payload larger than one TLS write, queued twice between ordinary frames.
    socket.send(frame("before") & frame("shared:300000", 1) & frame("after"))
    doAssert socket.receive() == (2, "before")
    for _ in 0 ..< 2:
      doAssert socket.receive() == (2, repeat('s', 300_000)), "corrupt shared payload"
    doAssert socket.receive() == (2, "after")
    socket.send(frame("", 8))
    doAssert socket.receive()[0] == 8
    socket.quietClose()

  block:
    # A stalled reader: frames keep queueing behind a blocked write, which must not change
    # under it, and other clients are still served.
    let slow = websocket(port, ctx)
    slow.getFd.setSockOptInt(SOL_SOCKET.int, SO_RCVBUF.int, 8192)
    slow.send(frame("flood:" & $floodPairs, 1))
    sleep(200)
    doAssert get(port, ctx, "/healthz") == "ok", "a stalled reader blocked another client"
    slow.getFd.setSockOptInt(SOL_SOCKET.int, SO_RCVBUF.int, 512 * 1024)
    for i in 0 ..< floodPairs:
      doAssert slow.receive() == (1, "small-" & $i), "reordered backpressured frame"
      doAssert slow.receive() == (2, floodFrame(i)), "corrupt backpressured frame"
    slow.quietClose()

  # Abrupt peers must not kill the server, including during TLS writes.
  for _ in 0 ..< 12:
    let socket = websocket(port, ctx)
    socket.send(frame(repeat("reset", 20_000)))
    socket.reset()
  sleep(100)
  doAssert get(port, ctx, "/healthz") == "ok"

proc versionContext(caFile: string, version: int, legacy = false): SslContext =
  result = newContext(verifyMode = (if legacy: CVerifyNone else: CVerifyPeer), caFile = caFile)
  discard SSL_CTX_ctrl(result.context, 123, version.clong, nil) # SSL_CTX_set_min_proto_version
  discard SSL_CTX_ctrl(result.context, 124, version.clong, nil) # SSL_CTX_set_max_proto_version
  if legacy: discard SSL_CTX_set_cipher_list(result.context, "ALL:@SECLEVEL=0")

proc tlsLimits(port: Port, ctx: SslContext, caFile: string) =
  for (version, name) in [(0x0303, "TLSv1.2"), (0x0304, "TLSv1.3")]:
    let socket = dial(port, versionContext(caFile, version))
    doAssert $SSL_get_version(socket.sslHandle) == name
    socket.quietClose()
  var refused = false
  try: dial(port, versionContext(caFile, 0x0302, legacy = true)).quietClose()
  except CatchableError: refused = true
  doAssert refused, "TLS 1.1 accepted"

  # A connection that never starts its handshake is closed at the deadline.
  let stalled = dial(port)
  sleep(500)
  doAssert stalled.closedByPeer(), "handshake did not expire"
  stalled.close()

  # Connections beyond the unfinished-handshake limit are closed when accepted.
  let held = [dial(port), dial(port)]
  sleep(30)
  var rejected = false
  try: dial(port, ctx).quietClose()
  except CatchableError: rejected = true
  for socket in held: socket.close()
  doAssert rejected, "handshake admission limit ignored"
  sleep(100)

proc waitUntilListening(port: Port) =
  let deadline = epochTime() + 10
  while true:
    try:
      dial(port).close()
      return
    except OSError:
      doAssert epochTime() < deadline, "fixture server did not start"
      sleep(30)

proc runMode(name: string, port: Port, credentials: seq[string], ctx: SslContext, caFile = "") =
  let process = startProcess(getAppFilename(), args = @["serve", $port.int] & credentials,
                             options = {poParentStreams})
  try:
    waitUntilListening(port)
    exercise(port, ctx)
    if ctx != nil: tlsLimits(port, ctx, caFile)
    doAssert get(port, ctx, "/stop") == "stopping"
    doAssert process.waitForExit(timeoutMs) == 0, "fixture failed during shutdown"
    doAssert not process.running
    echo "PASS ", name
  finally:
    if process.running:
      process.kill()
      discard process.waitForExit()
    process.close()

proc main() =
  randomize()
  let
    fixtures = currentSourcePath().parentDir / "tls"
    caFile = fixtures / "rsa-cert.pem"
    ctx = newContext(verifyMode = CVerifyPeer, caFile = caFile)
  runMode("HTTP/WS", freePort(), @[], nil)
  runMode("HTTPS/WSS", freePort(), @[caFile, fixtures / "rsa-key.pem"], ctx, caFile)
  runMode("HTTPS/WSS ECDSA certificate chain", freePort(),
          @[fixtures / "ec-chain.pem", fixtures / "ec-key.pem"], ctx, caFile)
  # A certificate given as the key, and a missing key, fail at startup.
  for credentials in [@[caFile, caFile], @[caFile, fixtures / "missing-key.pem"]]:
    let process = startProcess(getAppFilename(), args = @["serve", $freePort().int] & credentials,
                               options = {poStdErrToStdOut})
    let code = process.waitForExit(5000)
    doAssert not process.running and code != 0, "invalid TLS configuration accepted"
    process.close()
  echo "PASS invalid TLS configurations"

if paramCount() > 0 and paramStr(1) == "serve":
  serveFixture()
else:
  main()
