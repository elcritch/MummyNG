# Broadcast one immutable payload to every connected WebSocket.
# nim c --threads:on --mm:orc --path:src -r examples/shared_websockets.nim
import mummy
import std/locks

var clients: seq[WebSocket]
var clientsLock: Lock
initLock(clientsLock)

proc handler(request: Request) =
  if request.path == "/ws":
    discard request.upgradeToWebSocket()
  else:
    request.respond(404)

proc websocketHandler(ws: WebSocket; event: WebSocketEvent; message: Message) =
  {.gcsafe.}:
    withLock clientsLock:
      case event
      of OpenEvent:
        clients.add(ws)
      of MessageEvent:
        if message.kind in {TextMessage, BinaryMessage}:
          let payload = newSharedPayload(message.data)
          for client in clients:
            client.sendShared(payload, message.kind)
          # Queues retain their own owners after this local value is released.
      of CloseEvent:
        for i, client in clients:
          if client == ws:
            clients.delete(i)
            break
      of ErrorEvent:
        discard

let server = newServer(handler, websocketHandler)
server.serve(Port(8080))
deinitLock(clientsLock)
