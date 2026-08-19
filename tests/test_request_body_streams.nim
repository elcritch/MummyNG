import mummy
import std/[atomics, httpclient, nativesockets, os, strutils, times]

const
  port = Port(8086)
  streamedBody = "abcdefghijklmnop"

var
  openedStreams: Atomic[int]
  failedStreams: Atomic[int]
  sinkCleanups: Atomic[int]

proc writeFailingSink(data: string) =
  doAssert data.len > 0
  raise newException(IOError, "expected sink write failure")

proc handler(request: Request) =
  case request.path
  of "/buffer", "/default", "/chunked-default", "/empty":
    request.respond(200, body = request.body)
  else:
    request.respond(500, body = "unexpected ordinary request")

proc requestBodyHandler(
  request: Request,
  stream: RequestBodyStream,
  event: RequestBodyEvent
) =
  case event.kind
  of RequestBodyOpen:
    discard openedStreams.fetchAdd(1, moRelaxed)
    case request.path
    of "/buffer":
      doAssert stream.buffer()
    of "/default", "/chunked-default":
      discard
    of "/reject":
      doAssert stream.reject(statusCode = 422, body = "rejected")
    else:
      doAssert stream.accept()
  of RequestBodyChunk:
    doAssert event.data.len <= 4
    doAssert event.bytesReceived == request.body.len + event.data.len
    if request.path == "/reject-chunk":
      doAssert stream.reject(statusCode = 422, body = "chunk rejected")
      return
    if request.path == "/handler-exception":
      raise newException(ValueError, "expected request body handler failure")
    if request.path == "/sink-failure":
      try:
        writeFailingSink(event.data)
      except IOError:
        discard sinkCleanups.fetchAdd(1, moRelaxed)
        doAssert stream.reject(
          statusCode = 507,
          body = "sink write failed"
        )
      return
    request.body.add(event.data)
  of RequestBodyEnd:
    doAssert not stream.accept()
    doAssert event.bytesReceived == request.body.len
    request.respond(200, body = request.body)
  of RequestBodyError:
    doAssert event.bytesReceived == request.body.len
    discard failedStreams.fetchAdd(1, moRelaxed)

static:
  # The original positional newServer call remains source-compatible.
  doAssert compiles(newServer(handler, nil, 1, 8192, 1024, 65536, true))

let server = newServer(
  handler,
  workerThreads = 2,
  maxBodyLen = 1024,
  requestBodyHandler = requestBodyHandler,
  requestBodyChunkSize = 4
)

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
  var sent = 0
  while sent < data.len:
    let count = socket.send(
      data[sent].unsafeAddr,
      (data.len - sent).cint,
      0
    )
    if count <= 0:
      raiseOSError(osLastError())
    sent += count

proc requestRaw(request: string): string =
  let socket = openTcpSocket()
  defer:
    socket.close()
  socket.sendAll(request)

  var buffer = newString(4096)
  while true:
    let count = socket.recv(buffer[0].addr, buffer.len.cint, 0)
    if count < 0:
      raiseOSError(osLastError())
    if count == 0:
      break
    result.add(buffer[0 ..< count])

proc waitFor(value: var Atomic[int], minimum: int) =
  let started = epochTime()
  while value.load(moRelaxed) < minimum:
    doAssert epochTime() - started < 5
    sleep(10)

var requesterThread: Thread[void]

proc requesterProc() =
  server.waitUntilReady()

  block:
    let client = newHttpClient()
    doAssert client.postContent(
      "http://localhost:" & $port.int & "/stream",
      streamedBody
    ) == streamedBody

  block:
    let client = newHttpClient()
    doAssert client.postContent(
      "http://localhost:" & $port.int & "/buffer",
      streamedBody
    ) == streamedBody

  block:
    let client = newHttpClient()
    doAssert client.postContent(
      "http://localhost:" & $port.int & "/default",
      streamedBody
    ) == streamedBody

  block:
    let client = newHttpClient()
    let response = client.post(
      "http://localhost:" & $port.int & "/reject",
      streamedBody
    )
    doAssert response.status == "422"
    doAssert response.body == "rejected"

  block:
    let client = newHttpClient()
    let response = client.post(
      "http://localhost:" & $port.int & "/reject-chunk",
      streamedBody
    )
    doAssert response.status == "422"
    doAssert response.body == "chunk rejected"

  block handler_exception:
    let client = newHttpClient()
    let response = client.post(
      "http://localhost:" & $port.int & "/handler-exception",
      streamedBody
    )
    doAssert response.status == "500"

  block sink_write_failure:
    let cleanupsBefore = sinkCleanups.load(moRelaxed)
    let client = newHttpClient()
    let response = client.post(
      "http://localhost:" & $port.int & "/sink-failure",
      streamedBody
    )
    doAssert response.status == "507"
    doAssert response.body == "sink write failed"
    doAssert sinkCleanups.load(moRelaxed) == cleanupsBefore + 1

  block:
    let response = requestRaw(
      "POST /chunked HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Connection: close\r\n\r\n" &
      "3\r\nabc\r\n5\r\ndefgh\r\n0\r\n\r\n"
    )
    doAssert response.startsWith("HTTP/1.1 200")
    doAssert response.endsWith("abcdefgh")

  block:
    let response = requestRaw(
      "POST /chunked-default HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Connection: close\r\n\r\n" &
      "3\r\nabc\r\n5\r\ndefgh\r\n0\r\n\r\n"
    )
    doAssert response.startsWith("HTTP/1.1 200")
    doAssert response.endsWith("abcdefgh")

  block:
    let openedBefore = openedStreams.load(moRelaxed)
    let client = newHttpClient()
    doAssert client.postContent(
      "http://localhost:" & $port.int & "/empty",
      ""
    ) == ""
    doAssert openedStreams.load(moRelaxed) == openedBefore

  block:
    let
      openedBefore = openedStreams.load(moRelaxed)
      failuresBefore = failedStreams.load(moRelaxed)
    let socket = openTcpSocket()
    socket.sendAll(
      "POST /too-large-chunked HTTP/1.1\r\n" &
      "Host: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" &
      "401\r\n"
    )
    waitFor(openedStreams, openedBefore + 1)
    waitFor(failedStreams, failuresBefore + 1)
    socket.close()

  block:
    let
      openedBefore = openedStreams.load(moRelaxed)
      failuresBefore = failedStreams.load(moRelaxed)
    let socket = openTcpSocket()
    socket.sendAll(
      "POST /disconnect HTTP/1.1\r\n" &
      "Host: localhost\r\nContent-Length: 10\r\n\r\nabc"
    )
    waitFor(openedStreams, openedBefore + 1)
    socket.close()
    waitFor(failedStreams, failuresBefore + 1)

  block:
    let
      openedBefore = openedStreams.load(moRelaxed)
      failuresBefore = failedStreams.load(moRelaxed)
    let socket = openTcpSocket()
    socket.sendAll(
      "POST /shutdown HTTP/1.1\r\n" &
      "Host: localhost\r\nContent-Length: 10\r\n\r\nabc"
    )
    waitFor(openedStreams, openedBefore + 1)
    server.close()
    waitFor(failedStreams, failuresBefore + 1)
    socket.close()

createThread(requesterThread, requesterProc)
server.serve(port)
joinThread(requesterThread)
