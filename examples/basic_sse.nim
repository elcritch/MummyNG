import mummy, mummy/sse

proc handler(request: Request) =
  if request.path == "/events":
    discard request.respondSse()
  else:
    request.respond(404)

proc responseBodyHandler(stream: ResponseBodyStream, event: ResponseBodyEventKind) =
  case event
  of ResponseBodyOpen:
    discard stream.send(SseEvent(
      event: "hello",
      data: "connected",
      retry: some(3000.Natural)
    ))
  of ResponseBodyWritable:
    discard stream.heartbeat()
    stream.close()
  of ResponseBodyError, ResponseBodyClosed:
    discard

let server = newServer(handler, responseBodyHandler = responseBodyHandler)
echo "Serving SSE at http://localhost:8080/events"
server.serve(Port(8080))
