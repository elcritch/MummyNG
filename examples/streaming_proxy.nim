import mummy
import mummy/requestbody
import std/[net, strutils]

## Streams POST /upload request bodies to a loopback HTTP service without
## buffering the complete body in Mummy. Start an upstream service on port 9000,
## then send a file with:
##
## curl --data-binary @large-file.bin http://localhost:8080/upload

const
  listenPort = Port(8080)
  upstreamPort = Port(9000)
  requestTimeoutMs = 30_000
  maxUploadBytes = 100 * 1024 * 1024
  maxResponseBytes = 1024 * 1024
  maxResponseHeaderBytes = 64 * 1024

type
  ProxyUpload = ref object
    socket: Socket

  ProxyResponse = object
    statusCode: int
    contentType, body: string

var uploads = newRequestBodyRegistry[ProxyUpload]()

proc close(upload: ProxyUpload) =
  if upload != nil and upload.socket != nil:
    upload.socket.close()
    upload.socket = nil

func compactHex(value: int): string =
  result = value.toHex()
  let first = result.find({'1'..'9', 'A'..'F'})
  result = if first >= 0: result[first .. ^1] else: "0"

proc parseBoundedDecimal(value: string, maximum: Natural): int =
  if value.len == 0:
    raise newException(IOError, "Invalid upstream response number")
  for character in value:
    if character notin {'0'..'9'}:
      raise newException(IOError, "Invalid upstream response number")
    let digit = ord(character) - ord('0')
    if result > (maximum - digit) div 10:
      raise newException(IOError, "Invalid upstream response number")
    result = result * 10 + digit

proc responseLine(upload: ProxyUpload): string =
  result = upload.socket.recvLine(
    timeout = requestTimeoutMs,
    maxLength = 8 * 1024
  )
  if result.len == 0 or result.len > 8 * 1024:
    raise newException(IOError, "Invalid upstream response line")

proc startUpload(contentType: string): ProxyUpload =
  if {'\r', '\n'} in contentType:
    raise newException(ValueError, "Invalid Content-Type header")
  result = ProxyUpload(socket: newSocket(buffered = true))
  try:
    result.socket.connect("127.0.0.1", upstreamPort, timeout = requestTimeoutMs)
    var headers =
      "POST /upload HTTP/1.1\r\n" &
      "Host: 127.0.0.1:" & $upstreamPort.int & "\r\n" &
      "Transfer-Encoding: chunked\r\n" &
      "Connection: close\r\n"
    if contentType.len > 0:
      headers.add("Content-Type: " & contentType & "\r\n")
    result.socket.send(headers & "\r\n")
  except CatchableError:
    result.close()
    raise

proc write(upload: ProxyUpload, data: string) =
  if data.len > 0:
    upload.socket.send(data.len.compactHex() & "\r\n")
    upload.socket.send(data)
    upload.socket.send("\r\n")

proc finish(upload: ProxyUpload): ProxyResponse =
  upload.socket.send("0\r\n\r\n")
  let status = upload.responseLine().splitWhitespace(maxSplit = 2)
  if status.len < 2 or status[0] notin ["HTTP/1.0", "HTTP/1.1"] or
      status[1].len != 3:
    raise newException(IOError, "Invalid upstream response")
  result.statusCode = parseBoundedDecimal(status[1], 599)
  if result.statusCode < 100:
    raise newException(IOError, "Invalid upstream response status")

  var contentLength = -1
  var headerBytes = 0
  while true:
    let line = upload.responseLine()
    if line == "\r\n":
      break
    headerBytes += line.len + 2
    if headerBytes > maxResponseHeaderBytes:
      raise newException(IOError, "Upstream response headers are too large")
    let separator = line.find(':')
    if separator <= 0:
      raise newException(IOError, "Invalid upstream response header")
    let name = line[0 ..< separator]
    let value = line[separator + 1 .. ^1].strip()
    if cmpIgnoreCase(name, "Content-Length") == 0:
      if contentLength >= 0:
        raise newException(IOError, "Duplicate upstream Content-Length")
      contentLength = parseBoundedDecimal(value, maxResponseBytes)
    elif cmpIgnoreCase(name, "Content-Type") == 0:
      result.contentType = value

  if contentLength < 0 or contentLength > maxResponseBytes:
    raise newException(IOError, "Invalid upstream response length")
  result.body = upload.socket.recv(contentLength, timeout = requestTimeoutMs)
  if result.body.len != contentLength:
    raise newException(IOError, "Upstream response ended early")

proc takeUpload(stream: RequestBodyStream): ProxyUpload =
  discard uploads.take(stream, result)

proc discardUpload(stream: RequestBodyStream) =
  stream.takeUpload().close()

proc handler(request: Request) =
  request.respond(404)

proc requestBodyHandler(
  request: Request,
  stream: RequestBodyStream,
  event: RequestBodyEvent
) {.gcsafe.} =
  case event.kind
  of RequestBodyOpen:
    if request.httpMethod != "POST" or request.path != "/upload":
      discard stream.buffer()
      return
    try:
      uploads[stream] = startUpload(request.headers["Content-Type"])
      if not stream.accept():
        stream.discardUpload()
        discard stream.reject(statusCode = 500)
    except CatchableError:
      stream.discardUpload()
      discard stream.reject(statusCode = 502, body = "Could not connect upstream")

  of RequestBodyChunk:
    if event.bytesReceived > maxUploadBytes:
      stream.discardUpload()
      discard stream.reject(statusCode = 413, body = "Upload is too large")
      return
    var upload: ProxyUpload
    if not uploads.get(stream, upload):
      discard stream.reject(statusCode = 500)
      return
    try:
      upload.write(event.data)
    except CatchableError:
      stream.discardUpload()
      discard stream.reject(statusCode = 502, body = "Upstream write failed")

  of RequestBodyEnd:
    let upload = stream.takeUpload()
    if upload == nil:
      request.respond(500)
      return
    try:
      let response = upload.finish()
      var headers: HttpHeaders
      if response.contentType.len > 0:
        headers["Content-Type"] = response.contentType
      request.respond(response.statusCode, headers, response.body)
    except CatchableError:
      request.respond(502, body = "Invalid upstream response")
    finally:
      upload.close()

  of RequestBodyError:
    stream.discardUpload()

let server = newServer(
  handler,
  maxBodyLen = 1024 * 1024 * 1024,
  requestBodyHandler = requestBodyHandler,
  requestBodyChunkSize = 64 * 1024
)

echo "Streaming proxy listening on http://localhost:", listenPort.int
server.serve(listenPort)
uploads.close()
