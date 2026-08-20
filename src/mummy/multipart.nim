import ../mummy, std/strutils, std/options

export options

type MultipartEntry* = object
  name*: string
  filename*: Option[string]
  data*: Option[(int, int)] ## The (start, last) of this entry's data in the request body.
  headers*: HttpHeaders

type
  MultipartPart* = object
    ## Metadata announced before an incrementally decoded part's data.
    name*: string
    filename*: Option[string]
    headers*: HttpHeaders

  MultipartEventKind* = enum
    ## Incremental multipart decoder event kinds.
    MultipartPartBegin,
    MultipartPartData,
    MultipartPartEnd,
    MultipartMessageEnd

  MultipartEvent* = object
    ## One event emitted by an incremental multipart decoder.
    kind*: MultipartEventKind
    part*: MultipartPart ## Populated for `MultipartPartBegin`.
    data*: string ## Populated for `MultipartPartData`.

  MultipartDecoderState = enum
    MultipartFirstBoundary,
    MultipartHeaders,
    MultipartBody,
    MultipartClosing,
    MultipartComplete,
    MultipartFailed

  MultipartDecoder* = object
    ## Incrementally decodes a multipart/form-data request body.
    boundary, bodyBoundary, buffer: string
    state: MultipartDecoderState
    maxHeaderBytes: int
    finished: bool

const defaultMultipartHeaderBytes* = 64 * 1024

proc raiseInvalidMultipart(extra = "") {.noreturn.} =
  var message = "Invalid multipart body"
  if extra.len > 0:
    message.add(", " & extra)
  raise newException(MummyError, move message)

proc parseStreamingBoundary(contentType: string): string =
  let parts = contentType.split(';')
  if parts.len < 2 or cmpIgnoreCase(parts[0].strip(), "multipart/form-data") != 0:
    raise newException(MummyError, "Invalid Content-Type header for multipart")

  var found: bool
  for i in 1 ..< parts.len:
    let separator = parts[i].find('=')
    if separator <= 0 or
        cmpIgnoreCase(parts[i][0 ..< separator].strip(), "boundary") != 0:
      continue
    if found:
      raise newException(MummyError, "Duplicate multipart boundary")
    found = true
    result = parts[i][separator + 1 .. ^1].strip()
    if result.len >= 2 and result[0] == '"' and result[^1] == '"':
      result = result[1 ..< ^1]

  if not found or result.len == 0 or result.len > 70:
    raise newException(MummyError, "Invalid multipart boundary")
  for i, character in result:
    if character in {'a'..'z', 'A'..'Z', '0'..'9', '\'', '(', ')', '+', '_',
        ',', '-', '.', '/', ':', '=', '?'}:
      continue
    if character == ' ' and i < result.high:
      continue
    raise newException(MummyError, "Invalid multipart boundary")

proc dispositionValue(value, wantedName: string): Option[string] =
  let firstSeparator = value.find(';')
  let disposition =
    if firstSeparator >= 0: value[0 ..< firstSeparator].strip()
    else: value.strip()
  if cmpIgnoreCase(disposition, "form-data") != 0:
    raise newException(MummyError, "Invalid Content-Disposition header")

  var cursor = if firstSeparator >= 0: firstSeparator + 1 else: value.len
  while cursor < value.len:
    while cursor < value.len and value[cursor] in {' ', '\t', ';'}:
      inc cursor
    if cursor == value.len:
      break

    let nameStart = cursor
    while cursor < value.len and value[cursor] notin {'=', ';'}:
      inc cursor
    if cursor == value.len or value[cursor] != '=':
      while cursor < value.len and value[cursor] != ';':
        inc cursor
      continue
    let name = value[nameStart ..< cursor].strip()
    inc cursor
    while cursor < value.len and value[cursor] in {' ', '\t'}:
      inc cursor

    var parameterValue = ""
    if cursor < value.len and value[cursor] == '"':
      inc cursor
      var closed: bool
      while cursor < value.len:
        case value[cursor]
        of '\\':
          inc cursor
          if cursor == value.len:
            raise newException(MummyError, "Invalid Content-Disposition header")
          parameterValue.add(value[cursor])
          inc cursor
        of '"':
          inc cursor
          closed = true
          break
        else:
          parameterValue.add(value[cursor])
          inc cursor
      if not closed:
        raise newException(MummyError, "Invalid Content-Disposition header")
      while cursor < value.len and value[cursor] in {' ', '\t'}:
        inc cursor
      if cursor < value.len and value[cursor] != ';':
        raise newException(MummyError, "Invalid Content-Disposition header")
    else:
      let valueStart = cursor
      while cursor < value.len and value[cursor] != ';':
        inc cursor
      parameterValue = value[valueStart ..< cursor].strip()

    if cmpIgnoreCase(name, wantedName) == 0:
      return some(move parameterValue)

proc parseStreamingPart(headerBlock: string): MultipartPart =
  var cursor = 0
  while cursor < headerBlock.len:
    let lineEnd = headerBlock.find("\r\n", start = cursor)
    let ending = if lineEnd >= 0: lineEnd else: headerBlock.len
    let line = headerBlock[cursor ..< ending]
    let separator = line.find(':')
    if separator > 0:
      result.headers.add((line[0 ..< separator].strip(), line[separator + 1 .. ^1].strip()))
    else:
      result.headers.add((line, ""))
    cursor = ending + 2

  let contentDisposition = result.headers["Content-Disposition"]
  let name = contentDisposition.dispositionValue("name")
  if name.isNone:
    raise newException(MummyError, "Invalid Content-Disposition header")
  result.name = name.get()
  result.filename = contentDisposition.dispositionValue("filename")

proc initMultipartDecoder*(
  contentType: string,
  maxHeaderBytes: Positive = defaultMultipartHeaderBytes
): MultipartDecoder =
  ## Creates a bounded incremental multipart/form-data decoder.
  ##
  ## Feed decoded request body chunks with `feed`, then call `finish` once at
  ## `RequestBodyEnd`. A malformed or incomplete body raises `MummyError`.
  result.boundary = contentType.parseStreamingBoundary()
  result.bodyBoundary = "\r\n--" & result.boundary
  result.state = MultipartFirstBoundary
  result.maxHeaderBytes = maxHeaderBytes

proc initMultipartDecoder*(
  request: Request,
  maxHeaderBytes: Positive = defaultMultipartHeaderBytes
): MultipartDecoder =
  ## Creates an incremental decoder from a request's Content-Type header.
  if request == nil:
    raise newException(MummyError, "Invalid request for multipart")
  var contentType = request.headers["Content-Type"]
  if request.headers["User-Agent"].startsWith("Wolfram HTTPClient"):
    contentType = contentType.replace("multipart/form-data,", "multipart/form-data;")
  initMultipartDecoder(contentType, maxHeaderBytes)

proc consume(decoder: var MultipartDecoder, count: int) =
  if count == decoder.buffer.len:
    decoder.buffer.setLen(0)
  else:
    decoder.buffer = decoder.buffer[count .. ^1]

proc addPartData(events: var seq[MultipartEvent], data: sink string) =
  if data.len > 0:
    events.add(MultipartEvent(kind: MultipartPartData, data: move data))

proc process(decoder: var MultipartDecoder, events: var seq[MultipartEvent]) =
  while true:
    case decoder.state
    of MultipartFirstBoundary:
      let marker = "--" & decoder.boundary
      if decoder.buffer.len < marker.len:
        if not marker.startsWith(decoder.buffer):
          decoder.state = MultipartFailed
          raiseInvalidMultipart("body does not start with boundary")
        return
      if not decoder.buffer.startsWith(marker):
        decoder.state = MultipartFailed
        raiseInvalidMultipart("body does not start with boundary")
      if decoder.buffer.len < marker.len + 2:
        return
      let suffix = decoder.buffer[marker.len ..< marker.len + 2]
      decoder.consume(marker.len + 2)
      case suffix
      of "\r\n": decoder.state = MultipartHeaders
      of "--": decoder.state = MultipartClosing
      else:
        decoder.state = MultipartFailed
        raiseInvalidMultipart("invalid first boundary")

    of MultipartHeaders:
      var headerLength, terminatorLength: int
      if decoder.buffer.startsWith("\r\n"):
        terminatorLength = 2
      else:
        headerLength = decoder.buffer.find("\r\n\r\n")
        if headerLength < 0:
          if decoder.buffer.len > 3 and
              decoder.buffer.len - 3 > decoder.maxHeaderBytes:
            decoder.state = MultipartFailed
            raiseInvalidMultipart("part headers are too large")
          return
        terminatorLength = 4
      if headerLength > decoder.maxHeaderBytes:
        decoder.state = MultipartFailed
        raiseInvalidMultipart("part headers are too large")
      var part = parseStreamingPart(decoder.buffer[0 ..< headerLength])
      decoder.consume(headerLength + terminatorLength)
      events.add(MultipartEvent(kind: MultipartPartBegin, part: move part))
      decoder.state = MultipartBody

    of MultipartBody:
      var searchStart = 0
      var boundaryAt = -1
      while true:
        let candidate = decoder.buffer.find(decoder.bodyBoundary, start = searchStart)
        if candidate < 0:
          break
        let suffixStart = candidate + decoder.bodyBoundary.len
        if decoder.buffer.len < suffixStart + 2:
          if candidate > 0:
            events.addPartData(decoder.buffer[0 ..< candidate])
            decoder.consume(candidate)
          return
        let suffix = decoder.buffer[suffixStart ..< suffixStart + 2]
        if suffix in ["\r\n", "--"]:
          boundaryAt = candidate
          break
        searchStart = candidate + 1

      if boundaryAt < 0:
        let retained = min(decoder.buffer.len, decoder.bodyBoundary.len + 1)
        let dataLength = decoder.buffer.len - retained
        if dataLength > 0:
          events.addPartData(decoder.buffer[0 ..< dataLength])
          decoder.consume(dataLength)
        return

      let suffixStart = boundaryAt + decoder.bodyBoundary.len
      let suffix = decoder.buffer[suffixStart ..< suffixStart + 2]
      if boundaryAt > 0:
        events.addPartData(decoder.buffer[0 ..< boundaryAt])
      decoder.consume(suffixStart + 2)
      events.add(MultipartEvent(kind: MultipartPartEnd))
      decoder.state = if suffix == "\r\n": MultipartHeaders else: MultipartClosing

    of MultipartClosing:
      if decoder.buffer.len == 0:
        return
      if decoder.buffer.len == 1 and decoder.buffer[0] == '\r':
        return
      if decoder.buffer.startsWith("\r\n"):
        decoder.consume(2)
        decoder.state = MultipartComplete
      else:
        decoder.state = MultipartFailed
        raiseInvalidMultipart("invalid data after closing boundary")

    of MultipartComplete:
      if decoder.buffer.len > 0:
        decoder.state = MultipartFailed
        raiseInvalidMultipart("data follows closing boundary")
      return

    of MultipartFailed:
      raiseInvalidMultipart("decoder has failed")

proc feed*(decoder: var MultipartDecoder, data: sink string): seq[MultipartEvent] =
  ## Decodes another body chunk and returns all complete multipart events.
  if decoder.finished:
    raiseInvalidMultipart("decoder is already finished")
  if decoder.state == MultipartFailed:
    raiseInvalidMultipart("decoder has failed")
  if decoder.buffer.len == 0:
    decoder.buffer = move data
  else:
    decoder.buffer.add(data)
  try:
    decoder.process(result)
  except MummyError:
    decoder.state = MultipartFailed
    raise

proc finish*(decoder: var MultipartDecoder): seq[MultipartEvent] =
  ## Completes decoding and returns the terminal `MultipartMessageEnd` event.
  if decoder.finished:
    raiseInvalidMultipart("decoder is already finished")
  if decoder.state == MultipartFailed:
    raiseInvalidMultipart("decoder has failed")
  try:
    decoder.process(result)
  except MummyError:
    decoder.state = MultipartFailed
    raise
  if decoder.state == MultipartClosing and decoder.buffer.len == 0:
    decoder.state = MultipartComplete
  if decoder.state != MultipartComplete:
    decoder.state = MultipartFailed
    raiseInvalidMultipart("multipart body ended early")
  decoder.finished = true
  result.add(MultipartEvent(kind: MultipartMessageEnd))

proc decodeMultipart*(request: Request): seq[MultipartEntry] {.raises: [MummyError].} =

  template raiseInvalidContentType() =
    raise newException(MummyError, "Invalid Content-Type header for multipart")

  template raiseInvalidBody(extra = "") =
    var msg = "Invalid multipart body"
    if extra != "":
      msg &= ", " & extra
    raise newException(MummyError, move msg)

  var contentType = request.headers["Content-Type"]

  # Wolfram HTTPClient in Wolfram Language uses a comma instead of
  # a semicolon: multipart/form-data, boundary=vTd41rxm1e7O
  if request.headers["User-Agent"].startsWith("Wolfram HTTPClient"):
    contentType = contentType.replace(
      "multipart/form-data,",
      "multipart/form-data;"
    )

  let first = contentType.split(';', maxsplit = 1)

  if cmpIgnoreCase(first[0], "multipart/form-data") != 0 or first.len != 2:
    raiseInvalidContentType()

  let second = first[1].split("boundary=", maxsplit = 1)

  if second.len != 2:
    raiseInvalidContentType()

  var boundary = second[1]
  if boundary.len >= 2:
    # Remove quotes from around boundary if present
    # https://www.rfc-editor.org/rfc/rfc2046.html#section-5.1.1
    if boundary[0] == '"' and boundary[^1] == '"':
      boundary = boundary[1 ..< ^1]

  if boundary.len == 0:
    raiseInvalidContentType()

  let realBoundary = "--" & boundary

  var i: int
  while true:
    # Decodes one entry per iteration
    var entry: MultipartEntry

    # Ensure we have room for a boundary line
    if i + realBoundary.len + 2 > request.body.len:
      raiseInvalidBody("no room for boundary line")

    # Each entry must start with a boundary
    if not equalMem(
      request.body[i].addr,
      realBoundary.cstring,
      realBoundary.len
    ):
      raiseInvalidBody("entry does not start with boundary")

    i += realBoundary.len

    # Is this the multipart end marker?
    if request.body[i] == '-' and request.body[i + 1] == '-':
      i += 2
      # We should be at the end of the request body
      if i == request.body.len:
        break
      # If we are not, allow \r\n at the end of the request body
      if request.body.len == i + 2:
        if request.body[i] == '\r' and request.body[i + 1] == '\n':
          break
      # Something is wrong
      raiseInvalidBody("error with multipart body end marker")

    # This is a multipart entry

    # Ensure the boundary line ends with \r\n
    if request.body[i] != '\r' or request.body[i + 1] != '\n':
      raiseInvalidBody("boundary line does not end with \\r\\n")

    i += 2

    block: # Entry headers
      while true:
        let lineEnd = request.body.find("\r\n", start = i)
        if lineEnd == -1:
          raiseInvalidBody("header line does not end with \\r\\n")

        if lineEnd == i:
          # No more headers
          i += 2
          break

        # A header line
        let
          header = request.body[i ..< lineEnd]
          parts = header.split(':', maxsplit = 1)
        if parts.len == 2:
          entry.headers.add((parts[0].strip(), parts[1].strip()))
        else:
          # Malformed header, include it for debugging purposes
          entry.headers.add((header, ""))

        i = lineEnd + 2

    # Entry data here

    let nextBoundary = request.body.find(realBoundary, start = i)
    if nextBoundary == -1:
      raiseInvalidBody("entry missing next boundary")

    let
      start = i
      last = nextBoundary - 3

    if start <= last:
      entry.data = some((start, last))
    elif start - last == 1:
      # No data for this entry
      discard
    else:
      # Something wrong here
      raiseInvalidBody("entry data multipart end error")

    # Verify the \r\n after the entry data
    if request.body[last + 1] != '\r' or request.body[last + 2] != '\n':
      raiseInvalidBody("entry data does not end with \\r\\n")

    i = nextBoundary

    result.add(move entry)

  template raiseInvalidContentDisposition() =
    raise newException(MummyError, "Invalid Content-Disposition header")

  proc formDataValue(contentDisposition, name: string): Option[string] =
    var nameStart = contentDisposition.find(name & "=")
    if nameStart == -1:
      return none(string)
    nameStart += name.len + 1 # Move past name=
    if nameStart + 1 > contentDisposition.len:
      return none(string)
    # Is the name value quoted? name="abc" vs name=abc
    if contentDisposition[nameStart] == '"':
      let closeQuote = contentDisposition.find('"', start = nameStart + 1)
      if closeQuote == -1:
        raiseInvalidContentDisposition()
      result = some(contentDisposition[nameStart + 1 ..< closeQuote])
    else:
      let endingSemicolon = contentDisposition.find(';', start = nameStart)
      if endingSemicolon == -1:
        result = some(contentDisposition[nameStart .. ^1])
      else:
        result = some(contentDisposition[nameStart ..< endingSemicolon])

  for entry in result.mitems:
    let contentDisposition = entry.headers["Content-Disposition"]
    if contentDisposition.len < 10:
      raiseInvalidContentDisposition()
    if cmpIgnoreCase(contentDisposition[0 ..< 10], "form-data;") != 0:
      raiseInvalidContentDisposition()
    var entryName = contentDisposition.formDataValue("name")
    if not entryName.isSome:
      raiseInvalidContentDisposition() # A name is required
    entry.name = move entryName.get
    entry.filename = contentDisposition.formDataValue("filename")
