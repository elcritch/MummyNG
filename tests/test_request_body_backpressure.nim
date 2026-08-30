import mummy
import std/unittest
import std/[atomics, nativesockets, os, strutils, times]

when defined(windows):
  const socketSendBufferOption = 0x1001 # SO_SNDBUF from Winsock2.h.
else:
  from std/posix import SO_SNDBUF
  template socketSendBufferOption: int = SO_SNDBUF.int

const
  port = Port(8087)
  bodyLen = 8 * 1024 * 1024
  bodyChunkLen = 64 * 1024

var
  firstChunkEntered: Atomic[bool]
  releaseFirstChunk: Atomic[bool]
  senderFinished: Atomic[bool]
  senderSucceeded: Atomic[bool]
  bytesHandled: Atomic[int]

proc handler(request: Request) =
  request.respond(500, body = "unexpected ordinary request")

proc requestBodyHandler(
  request: Request,
  stream: RequestBodyStream,
  event: RequestBodyEvent
) =
  case event.kind
  of RequestBodyOpen:
    check request.path == "/backpressure"
    check stream.accept()
  of RequestBodyChunk:
    let previous = bytesHandled.fetchAdd(event.data.len, moRelaxed)
    if previous == 0:
      firstChunkEntered.store(true, moRelease)
      while not releaseFirstChunk.load(moAcquire):
        sleep(1)
  of RequestBodyEnd:
    check bytesHandled.load(moRelaxed) == bodyLen
    request.respond(200, body = "upload complete")
  of RequestBodyError:
    discard

let server = newServer(
  handler,
  maxBodyLen = bodyLen,
  requestBodyHandler = requestBodyHandler,
  requestBodyChunkSize = bodyChunkLen
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

  # Keep the client-side buffer much smaller than the body so its send cannot
  # finish while Mummy has paused reads for the blocked handler.
  result.setSockOptInt(SOL_SOCKET, socketSendBufferOption, 4 * 1024)
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

proc sendBody(socket: SocketHandle) {.thread.} =
  let bodyChunk = 'x'.repeat(bodyChunkLen)
  var sent = 0
  try:
    while sent < bodyLen:
      let count = min(bodyChunk.len, bodyLen - sent)
      socket.sendAll(bodyChunk[0 ..< count])
      sent += count
    senderSucceeded.store(true, moRelease)
  except OSError:
    discard
  finally:
    senderFinished.store(true, moRelease)

proc waitFor(value: var Atomic[bool], timeoutSeconds: float): bool =
  let started = epochTime()
  while not value.load(moAcquire):
    if epochTime() - started >= timeoutSeconds:
      return false
    sleep(10)
  true

proc readResponse(socket: SocketHandle): string =
  var buffer = newString(4096)
  while true:
    let count = socket.recv(buffer[0].addr, buffer.len.cint, 0)
    if count < 0:
      raiseOSError(osLastError())
    if count == 0:
      break
    result.add(buffer[0 ..< count])

var requesterThread: Thread[void]

proc requesterProc() =
  server.waitUntilReady()
  defer:
    server.close()

  let socket = openTcpSocket()
  var socketOpen = true
  var senderThread: Thread[SocketHandle]
  try:
    socket.sendAll(
      "POST /backpressure HTTP/1.1\r\n" &
      "Host: localhost\r\n" &
      "Content-Length: " & $bodyLen & "\r\n" &
      "Connection: close\r\n\r\n"
    )
    createThread(senderThread, sendBody, socket)

    let firstChunkReceived = firstChunkEntered.waitFor(5)
    if not firstChunkReceived:
      checkpoint "request body handler did not receive the first chunk"
    check firstChunkReceived
    sleep(250)
    if senderFinished.load(moAcquire):
      checkpoint "sender completed while the first chunk handler was blocked"
    check not senderFinished.load(moAcquire)

    releaseFirstChunk.store(true, moRelease)
    if not senderFinished.waitFor(10):
      socket.close()
      socketOpen = false
      joinThread(senderThread)
      checkpoint "sender did not resume after the handler returned"
      check false

    joinThread(senderThread)
    if not senderSucceeded.load(moAcquire):
      checkpoint "sender failed before completing the upload"
    check senderSucceeded.load(moAcquire)
    let response = socket.readResponse()
    check response.startsWith("HTTP/1.1 200")
    check response.endsWith("upload complete")
  finally:
    releaseFirstChunk.store(true, moRelease)
    if socketOpen:
      socket.close()

suite "request body backpressure":
  test "pauses socket reads while a chunk is handled":
    createThread(requesterThread, requesterProc)
    server.serve(port)
    joinThread(requesterThread)
