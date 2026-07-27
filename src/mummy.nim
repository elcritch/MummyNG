when not defined(nimdoc):
  when not defined(gcArc) and not defined(gcOrc) and not defined(gcAtomicArc):
    {.error: "Using --mm:arc, --mm:orc or --mm:atomicArc is required by Mummy.".}

when not compileOption("threads"):
  {.error: "Using --threads:on is required by Mummy.".}

import mummy/common, mummy/internal, std/atomics, std/base64,
    std/cpuinfo, std/deques, std/hashes, std/nativesockets, std/os,
    std/monotimes, std/net, std/parseutils, std/selectors, std/sets, crunchy,
    std/tables, std/times, webby/httpheaders, webby/queryparams, webby/urls,
    zippy, std/options

from std/strutils import find, cmpIgnoreCase, toLowerAscii

when defined(linux):
  when defined(nimdoc):
    # Why am I doing this?
    from std/posix import write, TPollfd, POLLIN, poll, close, EAGAIN, O_CLOEXEC, O_NONBLOCK
  else:
    import std/posix

  let SOCK_NONBLOCK
    {.importc: "SOCK_NONBLOCK", header: "<sys/socket.h>".}: cint

when defined(windows):
  const ipv6OnlyOption = 27 # IPV6_V6ONLY from Winsock2.
elif defined(posix):
  from std/posix import ECONNABORTED, IPV6_V6ONLY

import std/locks

export Port, common, httpheaders, queryparams

const
  whitespace = {' ', '\t'}
  listenBacklogLen = 128
  maxEventsPerSelectLoop = 64
  initialRecvBufLen = (4 * 1024) - 9 # 8 byte cap field + null terminator

let
  http10 = "HTTP/1.0"
  http11 = "HTTP/1.1"

type
  ConnectionId = uint64

  RequestObj* = object
    httpVersion*: HttpVersion ## HTTP version from the request line.
    httpMethod*: string ## HTTP method from the request line.
    uri*: string ## Raw URI from the HTTP request line.
    path*: string ## Decoded request URI path.
    queryParams*: QueryParams ## Decoded request query parameter key-value pairs.
    pathParams*: PathParams ## Router named path parameter key-value pairs.
    headers*: HttpHeaders ## HTTP headers key-value pairs.
    body*: string ## Request body.
    remoteAddress*: string ## Network address of the request sender.
    server: Server
    connectionId: ConnectionId
    responded: bool

  Request* = ptr RequestObj

  WebSocket* = object
    server: Server
    connectionId: ConnectionId

  Message* = object
    kind*: MessageKind
    data*: string

  WebSocketEvent* = enum
    OpenEvent, MessageEvent, ErrorEvent, CloseEvent

  MessageKind* = enum
    TextMessage, BinaryMessage, Ping, Pong

  RequestHandler* = proc(request: Request) {.gcsafe.}

  WebSocketHandler* = proc(
    websocket: WebSocket,
    event: WebSocketEvent,
    message: Message
  ) {.gcsafe.}

  ServerObj = object
    handler: RequestHandler
    websocketHandler: WebSocketHandler
    logHandler: LogHandler
    maxHeadersLen, maxBodyLen, maxMessageLen: int
    tcpNoDelay: bool
    workerThreads: seq[Thread[Server]]
    serving: Atomic[bool]
    destroyCalled: bool
    listeningSockets: seq[Socket]
    selector: Selector[SelectorEntry]
    responseQueued, sendQueued, shutdown: SelectEvent
    connections: Table[ConnectionId, SelectorEntry] # Selector thread only.
    lastConnectionId: ConnectionId
    taskQueueLock: Lock
    taskQueueCond: Cond
    taskQueue: Deque[WorkerTask]
    responseQueue: Deque[OutgoingBuffer]
    responseQueueLock: Lock
    sendQueue: Deque[OutgoingBuffer]
    sendQueueLock: Lock
    websocketClaimed: Table[WebSocket, bool]
    websocketQueues: Table[WebSocket, Deque[WebSocketUpdate]]
    websocketQueuesLock: Lock

  Server* = ptr ServerObj

  WorkerTask = object
    request: Request
    websocket: WebSocket

  SelectorEntryKind = enum
    ListenerEntry, ClientEntry, EventEntry

  SelectorEntry {.acyclic.} = ref object
    socket: Socket
    case kind: SelectorEntryKind:
    of ListenerEntry:
      discard
    of EventEntry:
      event: SelectEvent
    of ClientEntry:
      connectionId: ConnectionId
      remoteAddress: string
      recvBuf: string
      bytesReceived: int
      requestState: IncomingRequestState
      frameState: IncomingFrameState
      outgoingBuffers: Deque[OutgoingBuffer]
      closeFrameQueuedAt: float64
      upgradedToWebSocket, closeFrameSent: bool
      sendsWaitingForUpgrade: seq[OutgoingBuffer]
      requestCounter: int # Incoming request incs, outgoing response decs

  IncomingRequestState = object
    headersParsed: bool
    chunked: bool
    loggedUnexpectedData: bool
    contentLength: int
    httpVersion: HttpVersion
    httpMethod: string
    uri: string
    path: string
    queryParams: QueryParams
    headers: HttpHeaders
    body: string

  IncomingFrameState = object
    opcode: uint8
    buffer: string
    frameLen: int

  OutgoingBuffer {.acyclic.} = ref object
    connectionId: ConnectionId
    closeConnection, isWebSocketUpgrade, isCloseFrame: bool
    buffer1, buffer2: string
    bytesSent: int

  WebSocketUpdate = object
    event: WebSocketEvent
    message: Message

proc `$`*(request: Request): string {.gcsafe.} =
  result = request.httpMethod & " " & request.uri & " "
  {.gcsafe.}:
    case request.httpVersion:
    of Http10:
      result &= http10
    else:
      result &= http11
  result &= " (" & $cast[uint](request) & ")"

proc `$`*(websocket: WebSocket): string =
  "WebSocket " & $cast[uint](hash(websocket))

proc log(server: Server, level: LogLevel, args: varargs[string]) =
  if server.logHandler == nil:
    return
  try:
    server.logHandler(level, args)
  except Exception as e:
    discard # ???

proc headerContainsToken(headers: var HttpHeaders, key, token: string): bool =
  # If a header looks like `Accept-Encoding: gzip,deflate` then we may want to
  # check if the value contains a specific token (in this case gzip or deflate)
  # This proc does a case-insensitive check while avoiding allocations
  for (k, v) in headers:
    if cmpIgnoreCase(k, key) == 0:
      var first = 0
      while first < v.len:
        var comma = v.find(',', start = first)
        if comma == -1:
          comma = v.len
        var len = comma - first
        while len > 0 and v[first] in whitespace:
          inc first
          dec len
        while len > 0 and v[first + len - 1] in whitespace:
          dec len
        if len > 0 and len == token.len:
          var matches = true
          for i in 0 ..< len:
            if ord(toLowerAscii(v[first + i])) != ord(toLowerAscii(token[i])):
              matches = false
              break
          if matches:
            return true
        first = comma + 1

proc registerHandle2(
  selector: Selector[SelectorEntry],
  socket: SocketHandle,
  events: set[Event],
  data: SelectorEntry
) {.raises: [IOSelectorsException].} =
  try:
    selector.registerHandle(socket, events, data)
  except ValueError: # Why ValueError?
    raise newException(IOSelectorsException, getCurrentExceptionMsg())

proc updateHandle2(
  selector: Selector[SelectorEntry],
  socket: SocketHandle,
  events: set[Event]
) {.raises: [IOSelectorsException].} =
  try:
    selector.updateHandle(socket, events)
  except ValueError: # Why ValueError?
    raise newException(IOSelectorsException, getCurrentExceptionMsg())

proc trigger(
  server: Server,
  event: SelectEvent
) {.raises: [].} =
  try:
    event.trigger()
  except Exception as e:
    let err = osLastError()
    server.log(
      ErrorLevel,
      "Error triggering event ", $err, " ", osErrorMsg(err)
    )

proc setNoDelay(
  server: Server,
  socket: Socket
) {.raises: [].} =
  try:
    socket.setSockOpt(
      OptNoDelay,
      true,
      level = Protocol.IPPROTO_TCP.cint
    )
  except Exception as e:
    server.log(
      ErrorLevel,
      "Error setting TCP_NODELAY: ", e.msg
    )

proc allocateConnectionId(server: Server): ConnectionId =
  while true:
    inc server.lastConnectionId
    if server.lastConnectionId notin server.connections:
      return server.lastConnectionId

proc send*(
  websocket: WebSocket,
  data: sink string,
  kind = TextMessage,
) {.raises: [], gcsafe.} =
  ## Enqueues the message to be sent over the WebSocket connection.

  var encodedFrame = OutgoingBuffer()
  encodedFrame.connectionId = websocket.connectionId

  case kind:
  of TextMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x1, data.len)
  of BinaryMessage:
    encodedFrame.buffer1 = encodeFrameHeader(0x2, data.len)
  of Ping:
    encodedFrame.buffer1 = encodeFrameHeader(0x9, data.len)
  of Pong:
    encodedFrame.buffer1 = encodeFrameHeader(0xA, data.len)

  encodedFrame.buffer2 = move data

  var queueWasEmpty: bool
  withLock websocket.server.sendQueueLock:
    queueWasEmpty = websocket.server.sendQueue.len == 0
    websocket.server.sendQueue.addLast(move encodedFrame)

  if queueWasEmpty:
    websocket.server.trigger(websocket.server.sendQueued)

proc close*(websocket: WebSocket) {.raises: [], gcsafe.} =
  ## Begins the WebSocket closing handshake.
  ## This does not discard previously queued messages before starting the
  ## closing handshake.
  ## The handshake will only begin after the queued messages are sent.

  var encodedFrame = OutgoingBuffer()
  encodedFrame.connectionId = websocket.connectionId
  encodedFrame.buffer1 = encodeFrameHeader(0x8, 0)
  encodedFrame.isCloseFrame = true

  var queueWasEmpty: bool
  withLock websocket.server.sendQueueLock:
    queueWasEmpty = websocket.server.sendQueue.len == 0
    websocket.server.sendQueue.addLast(move encodedFrame)

  if queueWasEmpty:
    websocket.server.trigger(websocket.server.sendQueued)

proc respond*(
  request: Request,
  statusCode: int,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  body: sink string = ""
) {.raises: [], gcsafe.} =
  ## Sends the response for the request.
  ## This should usually only be called once per request.

  if request.responded:
    request.server.log(
      InfoLevel,
      "Responding to a request that has already received a non-1xx response"
    )

  var encodedResponse = OutgoingBuffer()
  encodedResponse.connectionId = request.connectionId
  encodedResponse.closeConnection =
    request.httpVersion == Http10 # Default behavior

  # Override default behavior based on request Connection header
  if request.headers.headerContainsToken("Connection", "close"):
    encodedResponse.closeConnection = true
  elif request.headers.headerContainsToken("Connection", "keep-alive"):
    encodedResponse.closeConnection = false

  # If we are not already going to close the connection based on the request
  # headers, check if we should based on the response headers
  if not encodedResponse.closeConnection:
    encodedResponse.closeConnection = headers.headerContainsToken(
      "Connection", "close"
    )

  if encodedResponse.closeConnection:
    headers["Connection"] = "close"
  elif request.httpVersion == Http10:
    headers["Connection"] = "keep-alive"

  # If the body is big enough to justify compressing and not already compressed
  if body.len > 860 and "Content-Encoding" notin headers:
    if request.headers.headerContainsToken("Accept-Encoding", "gzip"):
      try:
        body = compress(body.cstring, body.len, BestSpeed, dfGzip)
        headers["Content-Encoding"] = "gzip"
      except Exception as e:
        # This should never happen since exceptions are only thrown if
        # the data format is invalid or the level is invalid
        request.server.log(
          DebugLevel,
          "Unexpected gzip error: " & e.msg
        )
    elif request.headers.headerContainsToken("Accept-Encoding", "deflate"):
      try:
        body = compress(body.cstring, body.len, BestSpeed, dfDeflate)
        headers["Content-Encoding"] = "deflate"
      except Exception as e:
        # See gzip
        request.server.log(
          DebugLevel,
          "Unexpected deflate error: " & e.msg
        )
    else:
      discard

  # This is usually not set by the caller, however it needs to be for HEAD
  # responses where there is a Content-Length but no body
  if "Content-Length" notin headers:
    let shouldAddContentLengthHeader =
      statusCode != 204 and (statusCode < 100 or statusCode >= 200)
    # Do not add a Content-Length header for a 204 or 1xx response
    # See RFC 7230 3.3.2
    if shouldAddContentLengthHeader or body.len > 0:
      headers["Content-Length"] = $body.len

  encodedResponse.buffer1 = encodeHeaders(statusCode, headers)
  if encodedResponse.buffer1.len + body.len < 32 * 1024:
    # There seems to be a harsh penalty on multiple send() calls on Linux
    # so just use 1 buffer if the body is small enough
    encodedResponse.buffer1 &= body
  else:
    encodedResponse.buffer2 = move body
  encodedResponse.isWebSocketUpgrade = headers.headerContainsToken(
    "Upgrade",
    "websocket"
  )

  if statusCode < 100 or statusCode >= 200:
    # Mark if this request has received a non-informational (1xx) response
    request.responded = true

  var queueWasEmpty: bool
  withLock request.server.responseQueueLock:
    queueWasEmpty = request.server.responseQueue.len == 0
    request.server.responseQueue.addLast(move encodedResponse)

  if queueWasEmpty:
    request.server.trigger(request.server.responseQueued)

proc upgradeToWebSocket*(
  request: Request
): WebSocket {.raises: [MummyError], gcsafe.} =
  ## Upgrades the request to a WebSocket connection. You can immediately start
  ## calling send().
  ## Future updates for this WebSocket will be calls to the websocketHandler
  ## provided to `newServer`. The first event will be onOpen.
  ## Note: if the client disconnects before receiving this upgrade response,
  ## no onOpen event will be received.
  if not request.headers.headerContainsToken("Connection", "Upgrade"):
    raise newException(
      MummyError,
      "Invalid request to upgade, missing 'Connection: upgrade' header"
    )

  if not request.headers.headerContainsToken("Upgrade", "websocket"):
    raise newException(
      MummyError,
      "Invalid request to upgade, missing 'Upgrade: websocket' header"
    )

  let websocketKey = request.headers["Sec-WebSocket-Key"]
  if websocketKey == "":
    raise newException(
      MummyError,
      "Invalid request to upgade, missing Sec-WebSocket-Key header"
    )

  let websocketVersion = request.headers["Sec-WebSocket-Version"]
  if websocketVersion != "13":
    raise newException(
      MummyError,
      "Invalid request to upgade, missing Sec-WebSocket-Version header"
    )

  # Looks good to upgrade

  result = WebSocket(
    server: request.server,
    connectionId: request.connectionId
  )

  let hash = sha1(websocketKey & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

  var headers: HttpHeaders
  headers["Connection"] = "Upgrade"
  headers["Upgrade"] = "websocket"
  headers["Sec-WebSocket-Accept"] = base64.encode(hash)

  request.respond(101, headers)

proc workerProc(server: Server) {.raises: [].} =
  # The worker threads run the task queue here
  let server = server

  proc runTask(task: WorkerTask) =
    if task.request != nil:
      try:
        server.handler(task.request)
      except Exception as e:
        server.log(
          ErrorLevel,
          "Handler exception: " & e.msg & " " & e.getStackTrace()
        )
        if not task.request.responded:
          task.request.respond(500)
      `=destroy`(task.request[])
      deallocShared(task.request)
    else: # WebSocket
      withLock server.websocketQueuesLock:
        if server.websocketClaimed.getOrDefault(task.websocket, true):
          # If this websocket has been claimed or if it is not present in
          # the table (which indicates it has been closed), skip this task
          return
        # Claim this websocket
        server.websocketClaimed[task.websocket] = true

      while true: # Process the entire websocket queue
        var update: Option[WebSocketUpdate]
        withLock server.websocketQueuesLock:
          try:
            if server.websocketQueues[task.websocket].len > 0:
              update = some(server.websocketQueues[task.websocket].popFirst())
              if update.get.event == CloseEvent:
                server.websocketQueues.del(task.websocket)
                server.websocketClaimed.del(task.websocket)
            else:
              server.websocketClaimed[task.websocket] = false
          except KeyError:
            discard # Not possible

        if not update.isSome:
          break

        try:
          server.websocketHandler(
            task.websocket,
            update.get.event,
            move update.get.message
          )
        except Exception as e:
          server.log(
            ErrorLevel,
            "WebSocket exception: " & e.msg & " " & e.getStackTrace()
          )

        if update.get.event == CloseEvent:
          break

  when defined(mummyCheck22398):
    var loggedExceptionLeak: bool

  while true:
    acquire(server.taskQueueLock)

    while server.taskQueue.len == 0 and not server.destroyCalled:
      wait(server.taskQueueCond, server.taskQueueLock)

    if server.destroyCalled:
      release(server.taskQueueLock)
      return

    let task = server.taskQueue.popFirst()
    release(server.taskQueueLock)

    runTask(task)

    when defined(mummyCheck22398):
      # https://github.com/nim-lang/Nim/issues/22398
      if not loggedExceptionLeak and getCurrentExceptionMsg() != "":
        echo "Detected leaked exception: ", getCurrentExceptionMsg()
        loggedExceptionLeak = true

proc postTask(server: Server, task: WorkerTask) {.raises: [].} =
  withLock server.taskQueueLock:
    server.taskQueue.addLast(task)
  signal(server.taskQueueCond)

proc postWebSocketUpdate(
  websocket: WebSocket,
  update: sink WebSocketUpdate
) {.raises: [].} =
  if websocket.server.websocketHandler == nil:
    websocket.server.log(DebugLevel, "WebSocket event but no WebSocket handler")
    return

  var needsTask: bool

  withLock websocket.server.websocketQueuesLock:
    if websocket notin websocket.server.websocketQueues:
      return

    try:
      websocket.server.websocketQueues[websocket].addLast(move update)
      if not websocket.server.websocketClaimed[websocket]:
        needsTask = true
    except KeyError:
      discard # Not possible

  if needsTask:
    websocket.server.postTask(WorkerTask(websocket: websocket))

proc sendCloseFrame(
  server: Server,
  dataEntry: SelectorEntry,
  closeConnection: bool
) {.raises: [IOSelectorsException].} =
  let outgoingBuffer = OutgoingBuffer()
  outgoingBuffer.connectionId = dataEntry.connectionId
  outgoingBuffer.buffer1 = encodeFrameHeader(0x8, 0)
  outgoingBuffer.isCloseFrame = true
  outgoingBuffer.closeConnection = closeConnection
  dataEntry.outgoingBuffers.addLast(outgoingBuffer)
  dataEntry.closeFrameQueuedAt = epochTime()
  server.selector.updateHandle2(dataEntry.socket.getFd(), {Read, Write})

proc afterRecvWebSocket(
  server: Server,
  dataEntry: SelectorEntry
): bool {.raises: [IOSelectorsException].} =
  if dataEntry.closeFrameQueuedAt > 0 and
    epochTime() - dataEntry.closeFrameQueuedAt > 10:
    # The Close frame dance didn't work out, just close the connection
    return true

  # Try to parse entire frames out of the receive buffer
  while true:
    if dataEntry.bytesReceived < 2:
      return false # Need to receive more bytes

    let
      b0 = dataEntry.recvBuf[0].uint8
      b1 = dataEntry.recvBuf[1].uint8
      fin = (b0 and 0b10000000) != 0
      rsv1 = b0 and 0b01000000
      rsv2 = b0 and 0b00100000
      rsv3 = b0 and 0b00010000
      opcode = b0 and 0b00001111

    if rsv1 != 0 or rsv2 != 0 or rsv3 != 0:
      return true # Per spec this must fail, close the connection

    # Masking bit should be set
    if (b1 and 0b10000000) == 0:
      return true # Per spec, close the connection

    if opcode == 0 and dataEntry.frameState.opcode == 0:
      # Per spec, the first frame must have an opcode > 0
      return true # Close the connection

    if dataEntry.frameState.opcode != 0 and opcode != 0:
      # Per spec, if we have buffered fragments the opcode must be 0
      return true # Close the connection

    var pos = 2

    var payloadLen = (b1 and 0b01111111).int
    if payloadLen <= 125:
      discard
    elif payloadLen == 126:
      if dataEntry.bytesReceived < 4:
        return false # Need to receive more bytes
      var l: uint16
      copyMem(l.addr, dataEntry.recvBuf[pos].addr, 2)
      payloadLen = nativesockets.htons(l).int
      pos += 2
    else:
      if dataEntry.bytesReceived < 10:
        return false # Need to receive more bytes
      var l: uint32
      copyMem(l.addr, dataEntry.recvBuf[pos + 4].addr, 4)
      payloadLen = nativesockets.htonl(l).int
      pos += 8

    let isControlFrame = opcode in [0x8.uint8, 0x9, 0xA]
    if isControlFrame and not fin:
      # Per spec, control frames must not be fragmented
      return true # Close the connection
    if payloadLen > 125 and isControlFrame:
      # Per spec, control frames are only allowed payloads up to 125 bytes
      return true # Close the connection

    if dataEntry.frameState.frameLen + payloadLen > server.maxMessageLen:
      server.log(DebugLevel, "Dropped WebSocket, message too long")
      return true # Message is too large, close the connection

    if dataEntry.bytesReceived < pos + 4:
      return false # Need to receive more bytes

    var mask: array[4, uint8]
    copyMem(mask.addr, dataEntry.recvBuf[pos].addr, 4)

    pos += 4

    if dataEntry.bytesReceived < pos + payloadLen:
      return false # Need to receive more bytes

    # Unmask the payload
    for i in 0 ..< payloadLen:
      let j = i mod 4
      dataEntry.recvBuf[pos + i] =
        (dataEntry.recvBuf[pos + i].uint8 xor mask[j]).char

    if dataEntry.frameState.opcode == 0:
      # This is the first fragment
      dataEntry.frameState.opcode = opcode

    # Make room in the message buffer for this fragment
    let newFrameLen = dataEntry.frameState.frameLen + payloadLen
    if dataEntry.frameState.buffer.len < newFrameLen:
      let newBufferLen = max(dataEntry.frameState.buffer.len * 2, newFrameLen)
      dataEntry.frameState.buffer.setLen(newBufferLen)

    if payloadLen > 0:
      # Copy the fragment into the message buffer
      copyMem(
        dataEntry.frameState.buffer[dataEntry.frameState.frameLen].addr,
        dataEntry.recvBuf[pos].addr,
        payloadLen
      )
      dataEntry.frameState.frameLen += payloadLen

    # Remove this frame from the receive buffer
    let frameLen = pos + payloadLen
    if dataEntry.bytesReceived == frameLen:
      dataEntry.bytesReceived = 0
    else:
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[frameLen].addr,
        dataEntry.bytesReceived - frameLen
      )
      dataEntry.bytesReceived -= frameLen

    if fin:
      let frameOpcode = dataEntry.frameState.opcode

      # We have a full message

      var message: Message
      message.data = move dataEntry.frameState.buffer
      message.data.setLen(dataEntry.frameState.frameLen)

      dataEntry.frameState = IncomingFrameState()

      case frameOpcode:
      of 0x1: # Text
        message.kind = TextMessage
      of 0x2: # Binary
        message.kind = BinaryMessage
      of 0x8: # Close
        # If we already queued a close, just close the connection
        # This is not quite perfect
        if dataEntry.closeFrameQueuedAt > 0:
          return true # Close the connection
        # Otherwise send a Close in response then close the connection
        server.sendCloseFrame(dataEntry, true)
        continue
      of 0x9: # Ping
        message.kind = Ping
      of 0xA: # Pong
        message.kind = Pong
      else:
        server.log(DebugLevel, "Dropped WebSocket, received invalid opcode")
        return true # Invalid opcode, close the connection

      let
        websocket = WebSocket(
          server: server,
          connectionId: dataEntry.connectionId
        )
        update = WebSocketUpdate(
          event: MessageEvent,
          message: move message
        )
      websocket.postWebSocketUpdate(update)

proc popRequest(
  server: Server,
  dataEntry: SelectorEntry
): Request {.raises: [].} =
  ## Pops the completed HttpRequest from the socket and resets the parse state.
  result = cast[Request](allocShared0(sizeof(RequestObj)))
  result.server = server
  result.connectionId = dataEntry.connectionId
  result.remoteAddress = dataEntry.remoteAddress
  result.httpVersion = dataEntry.requestState.httpVersion
  result.httpMethod = move dataEntry.requestState.httpMethod
  result.uri = move dataEntry.requestState.uri
  result.path = move dataEntry.requestState.path
  result.queryParams = move dataEntry.requestState.queryParams
  result.headers = move dataEntry.requestState.headers
  result.body = move dataEntry.requestState.body
  result.body.setLen(dataEntry.requestState.contentLength)
  dataEntry.requestState = IncomingRequestState()
  inc dataEntry.requestCounter
  if dataEntry.bytesReceived > 0:
    server.log(DebugLevel, "Receive buffer not empty after request")

proc afterRecvHttp(
  server: Server,
  dataEntry: SelectorEntry
): bool {.raises: [].} =
  # We do not expect pipelined requests so log if any new data is received
  # while a request is outstanding
  if dataEntry.requestCounter > 0 and
    not dataEntry.requestState.loggedUnexpectedData:
    server.log(
      DebugLevel,
      "Received data before the previous request has been responded to"
    )
    dataEntry.requestState.loggedUnexpectedData = true

  # Have we completed parsing the headers?
  if not dataEntry.requestState.headersParsed:
    # Not done with headers yet, look for the end of the headers
    let headersEnd = dataEntry.recvBuf.find(
      "\r\n\r\n",
      0,
      min(dataEntry.bytesReceived, server.maxHeadersLen) - 1 # Inclusive
    )
    if headersEnd < 0: # Headers end not found
      if dataEntry.bytesReceived > server.maxHeadersLen:
        server.log(DebugLevel, "Dropped connection, headers too long")
        return true # Headers too long or malformed, close the connection
      return false # Try again after receiving more bytes

    # We have the headers, now to parse them (avoiding excess allocations)

    var lineNum, lineStart: int
    while lineStart < headersEnd:
      var lineEnd = dataEntry.recvBuf.find(
        "\r\n",
        lineStart,
        headersEnd
      )
      if lineEnd == -1:
        lineEnd = headersEnd

      var lineLen = lineEnd - lineStart
      while lineLen > 0 and dataEntry.recvBuf[lineStart] in whitespace:
        inc lineStart
        dec lineLen
      while lineLen > 0 and
        dataEntry.recvBuf[lineStart + lineLen - 1] in whitespace:
        dec lineLen

      if lineNum == 0: # This is the request line
        let space1 = dataEntry.recvBuf.find(
          ' ',
          lineStart,
          lineStart + lineLen - 1
        )
        if space1 == -1:
          return true # Invalid request line, close the connection
        dataEntry.requestState.httpMethod = dataEntry.recvBuf[lineStart ..< space1]
        let
          remainingLen = lineLen - (space1 + 1 - lineStart)
          space2 = dataEntry.recvBuf.find(
            ' ',
            space1 + 1,
            space1 + 1 + remainingLen - 1
          )
        if space2 == -1:
          return true # Invalid request line, close the connection
        dataEntry.requestState.uri = dataEntry.recvBuf[space1 + 1 ..< space2]
        try:
          var url = parseUrl(dataEntry.requestState.uri)
          dataEntry.requestState.path = move url.path
          dataEntry.requestState.queryParams = move url.query
        except Exception as e:
          server.log(
            DebugLevel,
            "Dropped connection, invalid request URI: " &
            dataEntry.requestState.uri
          )
          return true # Invalid request URI, close the connection
        if dataEntry.recvBuf.find(
          ' ',
          space2 + 1,
          lineStart + lineLen - 1
        ) != -1:
          return true # Invalid request line, close the connection
        let httpVersionLen = lineLen - (space2 + 1 - lineStart)
        if httpVersionLen != 8:
          return true # Invalid request line, close the connection
        {.gcsafe.}:
          if equalMem(
            dataEntry.recvBuf[space2 + 1].addr,
            http11[0].unsafeAddr,
            8
          ):
            dataEntry.requestState.httpVersion = Http11
          elif equalMem(
            dataEntry.recvBuf[space2 + 1].addr,
            http10[0].unsafeAddr,
            8
          ):
            dataEntry.requestState.httpVersion = Http10
          else:
            return true # Unsupported HTTP version, close the connection
      else: # This is a header
        let splitAt = dataEntry.recvBuf.find(
          ':',
          lineStart,
          lineStart + lineLen - 1
        )
        if splitAt == -1:
          # Malformed header, include it for debugging purposes
          var line = dataEntry.recvBuf[lineStart ..< lineStart + lineLen]
          dataEntry.requestState.headers.add((move line, ""))
        else:
          var
            leftStart = lineStart
            leftLen = splitAt - leftStart
            rightStart = splitAt + 1
            rightLen = lineStart + lineLen - rightStart

          while leftLen > 0 and
            dataEntry.recvBuf[leftStart] in whitespace:
            inc leftStart
            dec leftLen
          while leftLen > 0 and
            dataEntry.recvBuf[leftStart + leftLen - 1] in whitespace:
            dec leftLen
          while rightLen > 0 and
            dataEntry.recvBuf[rightStart] in whitespace:
            inc rightStart
            dec rightLen
          while leftLen > 0 and
            dataEntry.recvBuf[rightStart + rightLen - 1] in whitespace:
            dec rightLen

          # TODO: Headers must not contain control characters (0-31, 127)

          dataEntry.requestState.headers.add((
            dataEntry.recvBuf[leftStart ..< leftStart + leftLen],
            dataEntry.recvBuf[rightStart ..< rightStart + rightLen]
          ))

      lineStart = lineEnd + 2
      inc lineNum

    dataEntry.requestState.chunked =
      dataEntry.requestState.headers.headerContainsToken(
        "Transfer-Encoding", "chunked"
      )

    var foundContentLength, foundTransferEncoding: bool
    for (k, v) in dataEntry.requestState.headers:
      if cmpIgnoreCase(k, "Content-Length") == 0:
        if foundContentLength:
          # This is a second Content-Length header, not valid
          return true # Close the connection
        foundContentLength = true
        if dataEntry.requestState.chunked:
          # Found both Transfer-Encoding: chunked and Content-Length headers
          return true # Close the connection
        try:
          dataEntry.requestState.contentLength = strictParseInt(v)
        except Exception as e:
          return true # Parsing Content-Length failed, close the connection
      elif cmpIgnoreCase(k, "Transfer-Encoding") == 0:
        if foundTransferEncoding:
          # This is a second Transfer-Encoding header, not valid
          return true # Close the connection
        foundTransferEncoding = true

    if dataEntry.requestState.contentLength < 0:
      return true # Invalid Content-Length, close the connection

    # Remove the headers from the receive buffer
    # We do this so we can hopefully just move the receive buffer at the end
    # instead of always copying a potentially huge body
    let bodyStart = headersEnd + 4
    if dataEntry.bytesReceived == bodyStart:
      dataEntry.bytesReceived = 0
    else:
      # This could be optimized away by having [0] be [head] where head can move
      # without having to copy the headers out
      # Preferring to copy the headers out to avoid the worst case of copying
      # huge bodies
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[bodyStart].addr,
        dataEntry.bytesReceived - bodyStart
      )
      dataEntry.bytesReceived -= bodyStart

    # One of three possible states for request body:
    # 1) We received a Content-Length header, so we know the content length
    # 2) We received a Transfer-Encoding: chunked header
    # 3) Neither, so we assume a content length of 0

    # Mark that headers have been parsed, must end this block
    dataEntry.requestState.headersParsed = true

  # Headers have been parsed, now for the body

  if dataEntry.requestState.chunked: # Chunked request
    # Process as many chunks as we have
    while true:
      if dataEntry.bytesReceived < 3:
        return false # Need to receive more bytes

      # Look for the end of the chunk length
      let chunkLenEnd = dataEntry.recvBuf.find(
        "\r\n",
        0,
        min(dataEntry.bytesReceived - 1, 19) # Inclusive with a reasonable max
      )
      if chunkLenEnd < 0: # Chunk length end not found
        if dataEntry.bytesReceived > 19:
          return true # We should have found it, close the connection
        return false # Try again after receiving more bytes

      # After we know we've seen the end of the chunk length, parse it
      var chunkLen: int
      try:
        chunkLen =
          strictParseHex(dataEntry.recvBuf.toOpenArray(0, chunkLenEnd - 1))
      except Exception as e:
        return true # Parsing chunk length failed, close the connection

      if dataEntry.requestState.contentLength + chunkLen > server.maxBodyLen:
        server.log(DebugLevel, "Dropped connection, body too long")
        return true # Body is too large, close the connection

      let chunkStart = chunkLenEnd + 2
      if dataEntry.bytesReceived < chunkStart + chunkLen + 2:
        return false # Need to receive more bytes

      # Make room in the body buffer for this chunk
      let newContentLength = dataEntry.requestState.contentLength + chunkLen
      if dataEntry.requestState.body.len < newContentLength:
        let newLen = max(dataEntry.requestState.body.len * 2, newContentLength)
        dataEntry.requestState.body.setLen(newLen)

      if chunkLen > 0:
        copyMem(
          dataEntry.requestState.body[dataEntry.requestState.contentLength].addr,
          dataEntry.recvBuf[chunkStart].addr,
          chunkLen
        )
        dataEntry.requestState.contentLength += chunkLen

      # Remove this chunk from the receive buffer
      let
        nextChunkStart = chunkLenEnd + 2 + chunkLen + 2
        bytesRemaining = dataEntry.bytesReceived - nextChunkStart
      copyMem(
        dataEntry.recvBuf[0].addr,
        dataEntry.recvBuf[nextChunkStart].addr,
        bytesRemaining
      )
      dataEntry.bytesReceived = bytesRemaining

      if chunkLen == 0: # A chunk of len 0 marks the end of the request body
        let request = server.popRequest(dataEntry)
        server.postTask(WorkerTask(request: request))
  else:
    if dataEntry.requestState.contentLength > server.maxBodyLen:
      server.log(DebugLevel, "Dropped connection, body too long")
      return true # Body is too large, close the connection

    if dataEntry.bytesReceived < dataEntry.requestState.contentLength:
      return false # Need to receive more bytes

    # We have the entire request body

    # If this request has a body
    if dataEntry.requestState.contentLength > 0:
      # If the receive buffer only has the body in it, just move it and reset
      # the receive buffer
      if dataEntry.requestState.contentLength == dataEntry.bytesReceived:
        dataEntry.requestState.body = move dataEntry.recvBuf
        dataEntry.recvBuf.setLen(initialRecvBufLen)
        dataEntry.bytesReceived = 0
      else:
        # Copy the body out of the buffer
        dataEntry.requestState.body.setLen(dataEntry.requestState.contentLength)
        copyMem(
          dataEntry.requestState.body[0].addr,
          dataEntry.recvBuf[0].addr,
          dataEntry.requestState.contentLength
        )
        # Remove this request from the receive buffer
        let bytesRemaining =
          dataEntry.bytesReceived - dataEntry.requestState.contentLength
        copyMem(
          dataEntry.recvBuf[0].addr,
          dataEntry.recvBuf[dataEntry.requestState.contentLength].addr,
          bytesRemaining
        )
        dataEntry.bytesReceived = bytesRemaining

    let request = server.popRequest(dataEntry)
    server.postTask(WorkerTask(request: request))

proc afterRecv(
  server: Server,
  dataEntry: SelectorEntry
): bool {.raises: [IOSelectorsException].} =
  # Have we upgraded this connection to a websocket?
  # If not, treat incoming bytes as part of HTTP requests.
  if dataEntry.upgradedToWebSocket:
    server.afterRecvWebSocket(dataEntry)
  else:
    server.afterRecvHttp(dataEntry)

proc afterSend(
  server: Server,
  dataEntry: SelectorEntry
): bool {.raises: [IOSelectorsException].} =
  let
    outgoingBuffer = dataEntry.outgoingBuffers.peekFirst()
    totalBytes = outgoingBuffer.buffer1.len + outgoingBuffer.buffer2.len
  if outgoingBuffer.bytesSent == totalBytes:
    # The current outgoing buffer for this socket has been fully sent
    # Remove it from the outgoing buffer queue
    dataEntry.outgoingBuffers.shrink(fromFirst = 1)
    if outgoingBuffer.isCloseFrame:
      dataEntry.closeFrameSent = true
    if outgoingBuffer.closeConnection:
      return true
  # If we don't have any more outgoing buffers, update the selector
  if dataEntry.outgoingBuffers.len == 0:
    server.selector.updateHandle2(dataEntry.socket.getFd(), {Read})

proc acceptClient(
  listeningSocket: Socket
): (Socket, string) {.raises: [OSError].} =
  # std/net.acceptAddr uses an IPv4-sized address buffer in supported Nim
  # versions. Keep this raw accept so IPv6 peers are handled correctly.
  var
    peerAddress: Sockaddr_storage
    peerAddressLen = sizeof(peerAddress).SockLen

  let clientFd =
    when defined(linux) and not defined(nimdoc):
      accept4(
        listeningSocket.getFd(),
        cast[ptr SockAddr](addr peerAddress),
        addr peerAddressLen,
        SOCK_CLOEXEC or SOCK_NONBLOCK
      )
    else:
      nativesockets.accept(
        listeningSocket.getFd(),
        cast[ptr SockAddr](addr peerAddress),
        addr peerAddressLen
      )

  if clientFd == osInvalidSocket:
    return (nil, "")

  when not defined(linux):
    when declared(setInheritable):
      if not clientFd.setInheritable(false):
        let error = osLastError()
        clientFd.close()
        raiseOSError(error)

  try:
    let clientDomain =
      if peerAddress.ss_family.cint == nativesockets.toInt(Domain.AF_INET6):
        Domain.AF_INET6
      else:
        Domain.AF_INET
    let clientSocket = newSocket(
      clientFd,
      clientDomain,
      buffered = false
    )
    let remoteAddress =
      try:
        clientSocket.getPeerAddr()[0]
      except Exception:
        ""
    (clientSocket, remoteAddress)
  except OSError as e:
    clientFd.close()
    raise e

proc isTransientAcceptError(error: OSErrorCode): bool =
  when defined(windows):
    error.int32 in [WSAEWOULDBLOCK, WSAECONNRESET, WSAECONNABORTED]
  else:
    error.int32 in [EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED]

proc destroy(server: Server, joinThreads: bool) {.raises: [].} =
  withLock server.taskQueueLock:
    server.destroyCalled = true
  if server.selector != nil:
    try:
      server.selector.close()
    except Exception as e:
      discard # Ignore
  for listeningSocket in server.listeningSockets:
    listeningSocket.close()
  for connection in server.connections.values:
    connection.socket.close()
  broadcast(server.taskQueueCond)
  if joinThreads:
    joinThreads(server.workerThreads)
    deinitLock(server.taskQueueLock)
    deinitCond(server.taskQueueCond)
    deinitLock(server.responseQueueLock)
    deinitLock(server.sendQueueLock)
    deinitLock(server.websocketQueuesLock)
    try:
      server.responseQueued.close()
    except Exception as e:
      discard # Ignore
    try:
      server.sendQueued.close()
    except Exception as e:
      discard # Ignore
    try:
      server.shutdown.close()
    except Exception as e:
      discard # Ignore
    `=destroy`(server[])
    deallocShared(server)
  else:
    # This is not a clean exit, leak to avoid potential segfaults for now
    # The process is likely going to be exiting anyway
    discard

proc drainResponseQueue(
  server: Server,
  responses: var seq[OutgoingBuffer]
) {.raises: [IOSelectorsException].} =
  responses.setLen(0)
  withLock server.responseQueueLock:
    while server.responseQueue.len > 0:
      responses.add(server.responseQueue.popFirst())

  for response in responses:
    let client = server.connections.getOrDefault(response.connectionId)
    if client == nil:
      server.log(DebugLevel, "Dropped response to disconnected client")
    else:
      client.outgoingBuffers.addLast(response)
      server.selector.updateHandle2(client.socket.getFd(), {Read, Write})
      client.requestCounter = max(client.requestCounter - 1, 0)

      if response.isWebSocketUpgrade:
        client.upgradedToWebSocket = true
        let websocket = WebSocket(
          server: server,
          connectionId: response.connectionId
        )
        withLock server.websocketQueuesLock:
          server.websocketQueues[websocket] = initDeque[WebSocketUpdate]()
          server.websocketClaimed[websocket] = false
        websocket.postWebSocketUpdate(WebSocketUpdate(event: OpenEvent))

        for frame in client.sendsWaitingForUpgrade:
          if client.closeFrameQueuedAt > 0:
            server.log(DebugLevel, "Dropped message after WebSocket close")
          else:
            client.outgoingBuffers.addLast(frame)
            if frame.isCloseFrame:
              client.closeFrameQueuedAt = epochTime()
        client.sendsWaitingForUpgrade.setLen(0)

proc drainSendQueue(
  server: Server,
  frames: var seq[OutgoingBuffer]
) {.raises: [IOSelectorsException].} =
  frames.setLen(0)
  withLock server.sendQueueLock:
    while server.sendQueue.len > 0:
      frames.add(server.sendQueue.popFirst())

  for frame in frames:
    let client = server.connections.getOrDefault(frame.connectionId)
    if client == nil:
      server.log(DebugLevel, "Dropped message to disconnected client")
    elif client.upgradedToWebSocket:
      if client.closeFrameQueuedAt > 0:
        server.log(DebugLevel, "Dropped message after WebSocket close")
      else:
        client.outgoingBuffers.addLast(frame)
        if frame.isCloseFrame:
          client.closeFrameQueuedAt = epochTime()
        server.selector.updateHandle2(client.socket.getFd(), {Read, Write})
    else:
      client.sendsWaitingForUpgrade.add(frame)

proc acceptConnection(
  server: Server,
  listener: SelectorEntry
) {.raises: [OSError, IOSelectorsException].} =
  let (clientSocket, remoteAddress) = acceptClient(listener.socket)
  if clientSocket.isNil:
    let error = osLastError()
    if not isTransientAcceptError(error):
      raiseOSError(error)
  else:
    when not defined(linux):
      try:
        clientSocket.getFd().setBlocking(false)
      except OSError as e:
        clientSocket.close()
        raise e

    if server.tcpNoDelay:
      server.setNoDelay(clientSocket)

    let client = SelectorEntry(kind: ClientEntry, socket: clientSocket)
    client.connectionId = server.allocateConnectionId()
    client.remoteAddress = remoteAddress
    client.recvBuf.setLen(initialRecvBufLen)
    server.connections[client.connectionId] = client
    server.selector.registerHandle2(clientSocket.getFd(), {Read}, client)

proc receiveFromClient(client: SelectorEntry): bool =
  if client.bytesReceived == client.recvBuf.len:
    client.recvBuf.setLen(client.recvBuf.len * 2)

  let bytesReceived = client.socket.recv(
    client.recvBuf[client.bytesReceived].addr,
    client.recvBuf.len - client.bytesReceived
  )
  if bytesReceived > 0:
    client.bytesReceived += bytesReceived
    result = true

proc sendToClient(client: SelectorEntry): bool =
  let outgoingBuffer = client.outgoingBuffers.peekFirst()
  let bytesSent =
    if outgoingBuffer.bytesSent < outgoingBuffer.buffer1.len:
      client.socket.send(
        outgoingBuffer.buffer1[outgoingBuffer.bytesSent].addr,
        outgoingBuffer.buffer1.len - outgoingBuffer.bytesSent
      )
    else:
      let buffer2Pos = outgoingBuffer.bytesSent - outgoingBuffer.buffer1.len
      client.socket.send(
        outgoingBuffer.buffer2[buffer2Pos].addr,
        outgoingBuffer.buffer2.len - buffer2Pos
      )
  if bytesSent > 0:
    outgoingBuffer.bytesSent += bytesSent
    result = true

proc closeConnection(server: Server, client: SelectorEntry) {.raises: [].} =
  let clientFd = client.socket.getFd()
  try:
    server.selector.unregister(clientFd)
  except Exception:
    server.log(DebugLevel, "Error unregistering client socket")
  finally:
    client.socket.close()
    server.connections.del(client.connectionId)

  if client.upgradedToWebSocket:
    let websocket = WebSocket(
      server: server,
      connectionId: client.connectionId
    )
    if not client.closeFrameSent:
      websocket.postWebSocketUpdate(WebSocketUpdate(event: ErrorEvent))
    websocket.postWebSocketUpdate(WebSocketUpdate(event: CloseEvent))

proc loopForever(server: Server) {.raises: [OSError, IOSelectorsException].} =
  var
    readyKeys: array[maxEventsPerSelectLoop, ReadyKey]
    receivedFrom, sentTo: seq[SelectorEntry]
    needClosing: HashSet[ConnectionId]
    encodedResponses: seq[OutgoingBuffer]
    encodedFrames: seq[OutgoingBuffer]
  while true:
    receivedFrom.setLen(0)
    sentTo.setLen(0)
    needClosing.clear()

    let readyCount = server.selector.selectInto(-1, readyKeys)

    # Collapse these events into simple flags
    var responseQueuedTriggered, sendQueuedTriggered, shutdownTriggered: bool
    for i in 0 ..< readyCount:
      let readyKey = readyKeys[i]
      if User in readyKey.events:
        let eventEntry = server.selector.getData(readyKey.fd)
        if eventEntry.event == server.responseQueued:
          responseQueuedTriggered = true
        if eventEntry.event == server.sendQueued:
          sendQueuedTriggered = true
        elif eventEntry.event == server.shutdown:
          shutdownTriggered = true
        else:
          discard

    if responseQueuedTriggered:
      server.drainResponseQueue(encodedResponses)

    if sendQueuedTriggered:
      server.drainSendQueue(encodedFrames)

    if shutdownTriggered:
      server.destroy(true)
      return

    # This is the main client socket select loop
    for i in 0 ..< readyCount:
      let readyKey = readyKeys[i]

      # echo "Socket ready: ", readyKey.fd, " ", readyKey.events

      let entry = server.selector.getData(readyKey.fd)
      if entry.kind == ListenerEntry:
        if Read in readyKey.events:
          server.acceptConnection(entry)
      elif entry.kind == ClientEntry:
        if Error in readyKey.events:
          needClosing.incl(entry.connectionId)
        else:
          if Read in readyKey.events:
            if entry.receiveFromClient():
              receivedFrom.add(entry)
            else:
              needClosing.incl(entry.connectionId)

          if Write in readyKey.events and
              entry.connectionId notin needClosing:
            if entry.sendToClient():
              sentTo.add(entry)
            else:
              needClosing.incl(entry.connectionId)

    for client in receivedFrom:
      if client.connectionId notin needClosing:
        let needsClosing = server.afterRecv(client)
        if needsClosing:
          needClosing.incl(client.connectionId)

    for client in sentTo:
      if client.connectionId notin needClosing:
        let needsClosing = server.afterSend(client)
        if needsClosing:
          needClosing.incl(client.connectionId)

    for connectionId in needClosing:
      let client = server.connections.getOrDefault(connectionId)
      if client != nil:
        server.closeConnection(client)

proc close*(server: Server) {.raises: [], gcsafe.} =
  ## Cleanly stops and deallocates the server.
  ## In-flight request handler calls will be allowed to finish.
  ## No additional handler calls will be dispatched even if they are queued.
  if server.listeningSockets.len > 0:
    server.trigger(server.shutdown)
  else:
    server.destroy(true)

proc createListeningSocket(
  address: string,
  port: Port,
  domain: Domain,
  ipv6Only: bool
): Socket =
  let aiList = getAddrInfo(
    address,
    port,
    domain,
    SockType.SOCK_STREAM,
    Protocol.IPPROTO_TCP,
  )
  try:
    var
      ai = aiList
      lastError = default(OSErrorCode)
    while ai != nil:
      let listeningSocket = newSocket(
        ai.ai_family,
        ai.ai_socktype,
        ai.ai_protocol,
        buffered = false,
        inheritable = false
      )

      try:
        listeningSocket.getFd().setBlocking(false)
        listeningSocket.setSockOpt(OptReuseAddr, true)
        if ipv6Only and ai.ai_family == nativesockets.toInt(Domain.AF_INET6):
          listeningSocket.getFd().setSockOptInt(
            nativesockets.toInt(Protocol.IPPROTO_IPV6).int,
            when defined(windows): ipv6OnlyOption else: IPV6_V6ONLY.int,
            1
          )

        # std/net.bindAddr resolves the address again. Bind this addrinfo
        # candidate directly so later candidates remain available as fallbacks.
        if bindAddr(
          listeningSocket.getFd(),
          ai.ai_addr,
          ai.ai_addrlen.SockLen
        ) < 0:
          raiseOSError(osLastError())
        listeningSocket.listen(listenBacklogLen)
        return listeningSocket
      except OSError as e:
        lastError = e.errorCode.OSErrorCode
        listeningSocket.close()

      ai = ai.ai_next

    if lastError != default(OSErrorCode):
      raiseOSError(lastError)
    raise newException(IOError, "Could not resolve address: " & address)
  finally:
    freeAddrInfo(aiList)

proc serveBindings(
  server: Server,
  bindings: openArray[(string, Port)],
  domain: Domain,
  ipv6Only: bool
) {.raises: [MummyError].} =
  if server.listeningSockets.len > 0:
    raise newException(MummyError, "Server already has a socket")
  if bindings.len == 0:
    raise newException(MummyError, "At least one address and port is required")

  try:
    for (address, port) in bindings:
      let listeningSocket = createListeningSocket(
        address,
        port,
        domain,
        ipv6Only
      )
      server.listeningSockets.add(listeningSocket)
      let listener = SelectorEntry(
        kind: ListenerEntry,
        socket: listeningSocket
      )
      server.selector.registerHandle2(
        listeningSocket.getFd(),
        {Read},
        listener
      )
  except Exception as e:
    server.destroy(true)
    raise currentExceptionAsMummyError()

  server.serving.store(true, moRelaxed)

  try:
    server.loopForever()
  except Exception as e:
    server.log(ErrorLevel, e.msg & "\n" & e.getStackTrace())
    server.destroy(false)
    raise currentExceptionAsMummyError()

proc serve*(
  server: Server,
  port: Port,
  address = "localhost"
) {.raises: [MummyError].} =
  ## The server will serve on the address and port. The default address is
  ## localhost. Use "0.0.0.0" to make the server externally accessible (with
  ## caution).
  ## This call does not return unless server.close() is called from another
  ## thread.
  server.serveBindings([(address, port)], Domain.AF_INET, false)

proc serve*(
  server: Server,
  bindings: openArray[(string, Port)]
) {.raises: [MummyError].} =
  ## The server will serve on every `(address, port)` binding. IPv4 and IPv6
  ## addresses and different ports can be used together.
  ## This call does not return unless server.close() is called from another
  ## thread.
  server.serveBindings(bindings, Domain.AF_UNSPEC, true)

proc newServer*(
  handler: RequestHandler,
  websocketHandler: WebSocketHandler = nil,
  logHandler: LogHandler = nil,
  workerThreads = max(countProcessors() * 10, 1),
  maxHeadersLen = 8 * 1024, # 8 KB
  maxBodyLen = 1024 * 1024, # 1 MB
  maxMessageLen = 64 * 1024, # 64 KB
  tcpNoDelay = true
): Server {.raises: [MummyError].} =
  ## Creates a new HTTP server. The request handler will be called for incoming
  ## HTTP requests. The WebSocket handler will be called for WebSocket events.
  ## Calls to the HTTP, WebSocket and log handlers are made from worker threads.
  ## WebSocket events are dispatched serially per connection. This means your
  ## WebSocket handler must return from a call before the next call will be
  ## dispatched for the same connection.

  if handler == nil:
    raise newException(MummyError, "The request handler must not be nil")

  var workerThreads = workerThreads
  when defined(mummyNoWorkers): # For testing, fuzzing etc
    workerThreads = 0

  result = cast[Server](allocShared0(sizeof(ServerObj)))
  result.handler = handler
  result.websocketHandler = websocketHandler
  result.logHandler = if logHandler != nil: logHandler else: echoLogger
  result.maxHeadersLen = maxHeadersLen
  result.maxBodyLen = maxBodyLen
  result.maxMessageLen = maxMessageLen
  result.tcpNoDelay = tcpNoDelay
  result.workerThreads.setLen(workerThreads)

  # Stuff that can fail
  try:
    result.responseQueued = newSelectEvent()
    result.sendQueued = newSelectEvent()
    result.shutdown = newSelectEvent()

    result.selector = newSelector[SelectorEntry]()

    let responseQueuedData = SelectorEntry(kind: EventEntry)
    responseQueuedData.event = result.responseQueued
    result.selector.registerEvent(result.responseQueued, responseQueuedData)

    let sendQueuedData = SelectorEntry(kind: EventEntry)
    sendQueuedData.event = result.sendQueued
    result.selector.registerEvent(result.sendQueued, sendQueuedData)

    let shutdownData = SelectorEntry(kind: EventEntry)
    shutdownData.event = result.shutdown
    result.selector.registerEvent(result.shutdown, shutdownData)

    initLock(result.taskQueueLock)
    initCond(result.taskQueueCond)
    initLock(result.responseQueueLock)
    initLock(result.sendQueueLock)
    initLock(result.websocketQueuesLock)

    for i in 0 ..< workerThreads:
      createThread(result.workerThreads[i], workerProc, result)
  except Exception as e:
    result.destroy(true)
    raise currentExceptionAsMummyError()

proc responded*(request: Request): bool =
  ## Check if this request has been responded.
  ## Informational responses (1xx status codes) do not mark a request responded.
  # This is only safe to call on the request handler thread right now, improve?
  request.responded

proc waitUntilReady*(server: Server, timeout: float = 10) =
  ## This proc blocks until the server is ready to receive requests or
  ## the timeout has passed. The timeout is in floating point seconds.
  ## This is useful when writing tests, where you need to know
  ## the server is ready before you begin sending requests.
  ## If the server is already ready this returns immediately.
  let start = getMonoTime()
  while true:
    if server.serving.load(moRelaxed):
      return
    let elapsed = getMonoTime() - start
    if elapsed.inMilliseconds.float > timeout * 1000:
      raise newException(MummyError, "Timeout while waiting for server")
    sleep(100)
