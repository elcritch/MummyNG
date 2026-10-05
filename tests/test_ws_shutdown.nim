# A live selector and worker must release shared frames that slow peers never drain.
import std/[assertions, atomics, importutils, monotimes, nativesockets, net, os,
            strutils, times]

import mummy

when defined(posix):
  from std/posix import SO_SNDBUF, SO_RCVBUF
else:
  let
    SO_SNDBUF {.importc, header: "winsock2.h".}: cint
    SO_RCVBUF {.importc, header: "winsock2.h".}: cint

privateAccess(WebSocket)
privateAccess(Server)
privateAccess(SharedPayload)

const
  timeoutMs = 10_000
  payloadSize = 8 * 1024 * 1024
  payloadCount = 4

var
  peers: array[2, WebSocket]
  opened: Atomic[int]
  stopped: Atomic[bool]
  transportErrors: Atomic[int]

proc liveAllocations(): int =
  for name, value in fieldPairs(getAllocStats()):
    when name == "allocCount":
      result += value
    elif name == "deallocCount":
      result -= value

template waitFor(condition: untyped; message: string) =
  block:
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while not condition:
      doAssert getMonoTime() < deadline, message
      sleep(1)

proc handler(request: Request) {.gcsafe.} =
  discard request.upgradeToWebSocket()

proc wsEvent(ws: WebSocket; event: WebSocketEvent; message: Message) {.gcsafe.} =
  if event == OpenEvent:
    ws.clientSocket.setSockOptInt(SOL_SOCKET, SO_SNDBUF, 4096)
    # One worker publishes each handle before the release/acquire barrier.
    let index = opened.load(moRelaxed)
    doAssert index < peers.len
    peers[index] = ws
    opened.store(index + 1, moRelease)
  elif event == ErrorEvent:
    discard transportErrors.fetchAdd(1, moRelease)

proc serve(server: Server) {.thread.} =
  server.serve(Port(0), "127.0.0.1")
  stopped.store(true, moRelease)

proc connectSlowPeer(port: Port): Socket =
  result = newSocket(buffered = false)
  try:
    result.getFd().setSockOptInt(SOL_SOCKET, SO_RCVBUF, 4096)
    result.connect("127.0.0.1", port, timeout = timeoutMs)
    result.send("GET /ws HTTP/1.1\r\nHost: localhost\r\n" &
      "Connection: Upgrade\r\nUpgrade: websocket\r\n" &
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
      "Sec-WebSocket-Version: 13\r\n\r\n")
    doAssert result.recvLine(timeout = timeoutMs).startsWith("HTTP/1.1 101 ")
    var headersComplete = false
    for _ in 0 ..< 16:
      let line = result.recvLine(timeout = timeoutMs)
      doAssert line.len > 0, "connection closed during WebSocket upgrade"
      if line == "\r\n":
        headersComplete = true
        break
    doAssert headersComplete, "WebSocket upgrade headers did not end"
  except:
    result.close()
    raise

proc runShutdown() =
  opened.store(0, moRelaxed)
  stopped.store(false, moRelaxed)
  transportErrors.store(0, moRelaxed)
  let server = newServer(handler, wsEvent, workerThreads = 1)
  var servingThread: Thread[Server]
  createThread(servingThread, serve, server)
  server.waitUntilReady()
  var closed = false
  defer:
    if not closed:
      server.close()
    waitFor(stopped.load(moAcquire), "server shutdown did not complete")
    joinThread(servingThread)
    reset(peers)

  let port = server.listeningSockets[0].getSockName()
  let first = connectSlowPeer(port)
  defer: first.close()
  let second = connectSlowPeer(port)
  defer: second.close()
  waitFor(opened.load(moAcquire) == peers.len, "WebSocket workers did not open peers")

  block:
    let data = "x".repeat(payloadSize)
    var history: seq[SharedPayload]
    for _ in 0 ..< payloadCount:
      history.add(newSharedPayload(data))
      for peer in peers:
        peer.sendShared(history[^1])
    for index, payload in history:
      privateAccess(typeof(payload.storage[]))
      echo "payload ", index, " owners = ", payload.storage.owners.load(moAcquire),
        ", transport errors = ", transportErrors.load(moAcquire)
      doAssert payload.storage.owners.load(moAcquire) >= peers.len + 1,
        "each peer must retain a queued owner"
    # Drop every publisher/history owner before stopping the selector.
    history.setLen(0)

  # Reading the frame header and one payload byte proves both socket queues
  # reached partial payload writes. No peer drains the remaining 8 MiB frame
  # (or the three frames behind it); both TCP buffers are limited to 4 KiB.
  for socket in [first, second]:
    let prefix = socket.recv(11, timeout = timeoutMs)
    doAssert prefix.len == 11
    doAssert prefix[0] == '\x82' and prefix[1] == '\x7f'
    doAssert prefix[10] == 'x'

  server.close()
  closed = true
  waitFor(stopped.load(moAcquire), "server shutdown did not release pending sends")
  # Keep both peers open until after the server has stopped: disconnect cleanup
  # must not accidentally substitute for the shutdown path under test.

block allocationAccountingIsActive:
  let before = liveAllocations()
  var payload = newSharedPayload("allocation counter control")
  doAssert liveAllocations() == before + 1
  payload = SharedPayload()
  doAssert liveAllocations() == before

# Initialize lazy runtime, socket and logging state before measuring whole runs.
runShutdown()
let baseline = liveAllocations()
for iteration in 1 .. 4:
  runShutdown()
  let retained = liveAllocations() - baseline
  echo "live slow-client shutdown ", iteration, ": retained allocations = ", retained
  doAssert retained <= 0, "shutdown retained shared payload or server allocations"
