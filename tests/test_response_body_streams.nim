import mummy, mummy/sse
import std/unittest
import std/[atomics, httpclient, nativesockets, options, os, strutils, times]

const port = Port(8097)

var
  mode: Atomic[int]
  openMode: Atomic[int]
  errorMode: Atomic[int]
  closedMode: Atomic[int]
  writeStep: Atomic[int]
  sseStep: Atomic[int]

proc handler(request: Request) {.gcsafe.} =
  case request.path
  of "/stream":
    mode.store(1, moRelaxed)
    var headers: mummy.HttpHeaders
    headers["Content-Type"] = "text/plain"
    discard request.respondStream(headers = headers)
  of "/head":
    let stream = request.respondStream()
    check not stream.write("not sent")
  of "/http10":
    mode.store(2, moRelaxed)
    discard request.respondStream()
  of "/throw":
    mode.store(3, moRelaxed)
    discard request.respondStream()
  of "/disconnect":
    mode.store(4, moRelaxed)
    discard request.respondStream()
  of "/sse":
    mode.store(5, moRelaxed)
    discard request.respondSse()
  of "/close-before-open":
    mode.store(6, moRelaxed)
    let stream = request.respondStream(start = false)
    stream.close()
    stream.start()
  of "/shutdown":
    mode.store(7, moRelaxed)
    discard request.respondStream()
  else:
    request.respond(404)

proc streamHandler(
  stream: ResponseBodyStream,
  event: ResponseBodyEventKind
) {.gcsafe.} =
  let currentMode = mode.load(moRelaxed)
  case event
  of ResponseBodyOpen:
    openMode.store(currentMode, moRelaxed)
    case currentMode
    of 1:
      check writeStep.load(moRelaxed) == 0
      writeStep.store(1, moRelaxed)
      check stream.write("hello, ")
      check not stream.write("too early")
    of 2:
      check stream.write("http10")
    of 3:
      raise newException(ValueError, "expected response body handler failure")
    of 5:
      check sseStep.load(moRelaxed) == 0
      sseStep.store(1, moRelaxed)
      check stream.send(SseEvent(
        data: "hello",
        event: "ready",
        id: "1",
        retry: some(0.Natural)
      ))
    of 6:
      check not stream.write("too late")
    of 4, 7:
      discard
    else:
      checkpoint "unexpected response stream mode"
      check false
  of ResponseBodyWritable:
    case currentMode
    of 1:
      check writeStep.load(moRelaxed) == 1
      writeStep.store(2, moRelaxed)
      check stream.write("stream")
      stream.close()
    of 2:
      stream.close()
    of 5:
      if sseStep.load(moRelaxed) == 1:
        sseStep.store(2, moRelaxed)
        check stream.heartbeat("ping")
      else:
        check sseStep.load(moRelaxed) == 2
        sseStep.store(3, moRelaxed)
        stream.close()
    else:
      checkpoint "unexpected Writable event"
      check false
  of ResponseBodyError:
    check currentMode in {3, 4, 7}
    check errorMode.load(moRelaxed) < currentMode
    errorMode.store(currentMode, moRelaxed)
  of ResponseBodyClosed:
    if currentMode in {3, 4, 7}:
      check errorMode.load(moRelaxed) == currentMode
    check not stream.write("too late")
    stream.close()
    closedMode.store(currentMode, moRelaxed)

test "supports legacy server constructor calls":
  # Keep the original Mummy positional call shape source compatible.
  check compiles(newServer(handler, nil, 1, 8192, 1024, 65536, true))
  # Keep the request-body streaming call shape source compatible too.
  check compiles(newServer(
    handler, nil, 1, 8192, 1024, 65536, true, nil, 65536
  ))

let server = newServer(
  handler,
  workerThreads = 2,
  responseBodyHandler = streamHandler
)
var requester: Thread[void]

proc openTcpSocket(): SocketHandle =
  result = createNativeSocket(
    Domain.AF_INET,
    SockType.SOCK_STREAM,
    Protocol.IPPROTO_TCP,
    false
  )
  if result == osInvalidSocket:
    raiseOSError(osLastError())
  let ai = getAddrInfo(
    "localhost",
    port,
    Domain.AF_INET,
    SockType.SOCK_STREAM,
    Protocol.IPPROTO_TCP
  )
  try:
    if result.connect(ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
      raiseOSError(osLastError())
  finally:
    freeAddrInfo(ai)

proc sendAll(socket: SocketHandle, data: string) =
  var sent: int
  while sent < data.len:
    let count = socket.send(data[sent].unsafeAddr, (data.len - sent).cint, 0)
    if count <= 0:
      raiseOSError(osLastError())
    sent += count

proc readAll(socket: SocketHandle): string =
  var buffer = newString(1024)
  while true:
    let count = socket.recv(buffer[0].addr, buffer.len.cint, 0)
    if count <= 0:
      return
    result.add(buffer[0 ..< count])

proc waitFor(value: var Atomic[int], expected: int) =
  let started = epochTime()
  while value.load(moRelaxed) != expected:
    check epochTime() - started < 5
    sleep(10)

proc requestRaw(
  path: string,
  version = "HTTP/1.1",
  extraHeaders = ""
): string =
  let socket = openTcpSocket()
  socket.sendAll(
    "GET " & path & " " & version & "\r\n" &
    "Host: localhost\r\n" & extraHeaders & "Connection: close\r\n\r\n"
  )
  result = socket.readAll()
  socket.close()

proc requesterProc() {.thread, gcsafe.} =
  server.waitUntilReady()

  block chunked:
    let response = requestRaw("/stream")
    check response.startsWith("HTTP/1.1 200")
    check "Transfer-Encoding: chunked" in response
    check "Content-Length" notin response
    if not response.endsWith("7\r\nhello, \r\n6\r\nstream\r\n0\r\n\r\n"):
      checkpoint response
    check response.endsWith("7\r\nhello, \r\n6\r\nstream\r\n0\r\n\r\n")
    waitFor(closedMode, 1)
    check writeStep.load(moRelaxed) == 2

  block head:
    let client = newHttpClient()
    let response = client.request(
      "http://localhost:" & $port.int & "/head",
      httpMethod = HttpHead
    )
    check response.status.startsWith("200")
    client.close()

  block http10:
    let response = requestRaw("/http10", "HTTP/1.0")
    check response.startsWith("HTTP/1.1 200")
    check "Transfer-Encoding" notin response
    if not response.endsWith("http10"):
      checkpoint response
    check response.endsWith("http10")
    waitFor(closedMode, 2)

  block handlerException:
    discard requestRaw("/throw")
    waitFor(closedMode, 3)

  block disconnect:
    let socket = openTcpSocket()
    socket.sendAll("GET /disconnect HTTP/1.1\r\nHost: localhost\r\n\r\n")
    waitFor(openMode, 4)
    socket.close()
    waitFor(closedMode, 4)

  block sse:
    let response = requestRaw("/sse", extraHeaders = "Accept-Encoding: gzip\r\n")
    check "Content-Type: text/event-stream" in response
    check "Cache-Control: no-cache" in response
    check "X-Accel-Buffering: no" in response
    check "Content-Encoding" notin response
    check "id: 1\nevent: ready\nretry: 0\ndata: hello\n\n" in response
    check ": ping\n\n" in response
    waitFor(closedMode, 5)
    check sseStep.load(moRelaxed) == 3

  block closeBeforeOpen:
    let response = requestRaw("/close-before-open")
    if not response.endsWith("0\r\n\r\n"):
      checkpoint response
    check response.endsWith("0\r\n\r\n")
    waitFor(closedMode, 6)

  block shutdown:
    let socket = openTcpSocket()
    socket.sendAll("GET /shutdown HTTP/1.1\r\nHost: localhost\r\n\r\n")
    waitFor(openMode, 7)
    server.close()
    discard socket.readAll()
    socket.close()

suite "response body streams":
  test "streams responses and server-sent events":
    createThread(requester, requesterProc)
    server.serve(port)
    check closedMode.load(moRelaxed) == 7
    check errorMode.load(moRelaxed) == 7
