# Real sockets: partial writes, a delayed reader and an abruptly closed reader.
# nim c -r -d:release tests/test_ws_transport.nim
import std/[httpclient, importutils, locks, nativesockets, options]
import mummy
import whisky
when defined(posix):
  from std/posix import SO_SNDBUF
else:
  # winlean does not expose this Winsock constant.
  let SO_SNDBUF {.importc, header: "winsock2.h".}: cint

privateAccess(mummy.WebSocket)
privateAccess(Server)

var clients: seq[mummy.WebSocket]
var clientsLock: Lock
initLock(clientsLock)

proc snapshot(sequence: int): string =
  result = newString(256 * 1024 + sequence)
  for i in 0 ..< result.len:
    result[i] = char((i + sequence) mod 251)

proc handler(request: Request) {.gcsafe.} =
  if request.path == "/ws":
    discard request.upgradeToWebSocket()
  else:
    request.respond(200, body = "HTTP still works")

proc wsEvent(ws: mummy.WebSocket; event: WebSocketEvent;
             message: mummy.Message) {.gcsafe.} =
  {.gcsafe.}:
    withLock clientsLock:
      case event
      of OpenEvent:
        # Smaller than the payload to exercise independent partial writes.
        ws.clientSocket.setSockOptInt(SOL_SOCKET, SO_SNDBUF, 4096)
        clients.add ws
        ws.send("ready")
      of MessageEvent:
        if message.kind == mummy.TextMessage and message.data == "broadcast":
          for sequence in 1 .. 3:
            let payload = newSharedPayload(snapshot(sequence))
            for client in clients:
              client.sendShared(payload)
              client.send("flow-" & $sequence)
          # Empty frames must also preserve the following marker's boundary.
          for client in clients:
            client.sendShared(newSharedPayload(""))
            client.send("done")
        elif message.kind == mummy.TextMessage and message.data == "finish":
          ws.sendShared(newSharedPayload("last"), mummy.TextMessage)
          ws.close()
        elif message.kind == mummy.TextMessage and message.data == "stale":
          # Simulate a delayed publisher holding an old connection identity
          # after the same socket handle has been reused.
          var stale = ws
          stale.clientId = ws.clientId xor 1'u64
          stale.sendShared(newSharedPayload("must not arrive"))
          ws.send("fresh")
      of CloseEvent:
        for i, client in clients:
          if client == ws:
            clients.delete(i)
            break
      of ErrorEvent:
        discard

proc expectMessage(ws: whisky.WebSocket; kind: whisky.MessageKind; data: string) =
  let message = ws.receiveMessage(timeout = 10_000)
  doAssert message.isSome, "timed out waiting for " & $kind
  doAssert message.get.kind == kind
  doAssert message.get.data == data

let server = newServer(handler, wsEvent, workerThreads = 2)

proc requester() {.thread.} =
  server.waitUntilReady()
  defer: server.close()
  let authority = "127.0.0.1:" & $server.listeningSockets[0].getSockName().uint16
  let fast = newWebSocket("ws://" & authority & "/ws")
  defer: fast.close()
  fast.expectMessage(whisky.TextMessage, "ready")
  let slow = newWebSocket("ws://" & authority & "/ws")
  defer: slow.close()
  slow.expectMessage(whisky.TextMessage, "ready")
  let abandoned = newWebSocket("ws://" & authority & "/ws")
  defer: abandoned.close()
  abandoned.expectMessage(whisky.TextMessage, "ready")
  fast.send("broadcast")
  # A full first frame proves the broadcast was queued before disconnect.
  fast.expectMessage(whisky.BinaryMessage, snapshot(1))
  abandoned.close()
  fast.expectMessage(whisky.TextMessage, "flow-1")
  for sequence in 2 .. 3:
    fast.expectMessage(whisky.BinaryMessage, snapshot(sequence))
    fast.expectMessage(whisky.TextMessage, "flow-" & $sequence)
  fast.expectMessage(whisky.BinaryMessage, "")
  fast.expectMessage(whisky.TextMessage, "done")
  let reconnected = newWebSocket("ws://" & authority & "/ws")
  defer: reconnected.close()
  reconnected.expectMessage(whisky.TextMessage, "ready")
  reconnected.send("stale")
  reconnected.expectMessage(whisky.TextMessage, "fresh")
  # The delayed reader begins after the first reader has drained every frame.
  for sequence in 1 .. 3:
    slow.expectMessage(whisky.BinaryMessage, snapshot(sequence))
    slow.expectMessage(whisky.TextMessage, "flow-" & $sequence)
  slow.expectMessage(whisky.BinaryMessage, "")
  slow.expectMessage(whisky.TextMessage, "done")
  let http = newHttpClient(timeout = 10_000)
  defer: http.close()
  doAssert http.getContent("http://" & authority & "/") == "HTTP still works"
  fast.send("finish")
  fast.expectMessage(whisky.TextMessage, "last")
  var closed = false
  try:
    discard fast.receiveMessage(timeout = 10_000)
  except CatchableError:
    closed = true
  doAssert closed, "close frame must follow the final shared message"
  echo "[OK] shared frames, partial writes, slow/disconnected peers, ordering, HTTP and close"

var requesterThread: Thread[void]
createThread(requesterThread, requester)
server.serve(Port(0), "127.0.0.1")
joinThread(requesterThread)
deinitLock(clientsLock)
