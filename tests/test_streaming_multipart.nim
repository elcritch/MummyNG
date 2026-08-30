import mummy
import mummy/multipart
import std/[unittest, options, strutils]

const
  boundary = "AaB03x"
  contentType = "multipart/form-data; boundary=" & boundary
  multipartBody =
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=field\r\n\r\n" &
    "value\r\n--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=upload; filename=\"a.txt\"\r\n" &
    "Content-Type: text/plain\r\n\r\n" &
    "abc\r\n--" & boundary & "--\r\n"

type CollectedPart = object
  metadata: MultipartPart
  body: string
  ended: bool

proc collect(
  events: sink seq[MultipartEvent],
  parts: var seq[CollectedPart],
  ended: var bool
) =
  for event in events:
    case event.kind
    of MultipartPartBegin:
      parts.add(CollectedPart(metadata: event.part))
    of MultipartPartData:
      check parts.len > 0
      parts[^1].body.add(event.data)
    of MultipartPartEnd:
      check parts.len > 0
      parts[^1].ended = true
    of MultipartMessageEnd:
      ended = true

proc decode(chunkSize: Positive): tuple[parts: seq[CollectedPart], ended: bool] =
  var decoder = initMultipartDecoder(contentType)
  var offset = 0

  while offset < multipartBody.len:
    let ending = min(offset + chunkSize, multipartBody.len)
    collect(
      decoder.feed(multipartBody[offset ..< ending]),
      result.parts,
      result.ended
    )
    offset = ending
  collect(decoder.finish(), result.parts, result.ended)

test "decodes every chunk size":
  for chunkSize in 1 .. multipartBody.len:
    let decoded = decode(chunkSize)
    check decoded.ended
    check decoded.parts.len == 2
    check decoded.parts[0].metadata.name == "field"
    check decoded.parts[0].metadata.filename.isNone
    check decoded.parts[0].body == "value"
    check decoded.parts[0].ended
    check decoded.parts[1].metadata.name == "upload"
    check decoded.parts[1].metadata.filename == some("a.txt")
    check decoded.parts[1].metadata.headers["Content-Type"] == "text/plain"
    check decoded.parts[1].body == "abc"
    check decoded.parts[1].ended

test "preserves boundary lookalikes in part data":
  let body =
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=data\r\n\r\n" &
    "before\r\n--" & boundary & "XXafter\r\n--" & boundary & "--"
  var decoder = initMultipartDecoder(contentType)
  var decodedData = ""
  for event in decoder.feed(body):
    if event.kind == MultipartPartData:
      decodedData.add(event.data)
  for event in decoder.finish():
    if event.kind == MultipartPartData:
      decodedData.add(event.data)
  check decodedData == "before\r\n--" & boundary & "XXafter"

test "accepts empty messages and parts":
  var emptyMessage = initMultipartDecoder(contentType)
  check emptyMessage.feed("--" & boundary & "--").len == 0
  let ending = emptyMessage.finish()
  check ending.len == 1
  check ending[0].kind == MultipartMessageEnd

  var emptyPart = initMultipartDecoder(contentType)
  let events = emptyPart.feed(
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=empty\r\n\r\n" &
    "\r\n--" & boundary & "--"
  )
  check events.len == 2
  check events[0].kind == MultipartPartBegin
  check events[1].kind == MultipartPartEnd
  discard emptyPart.finish()

test "rejects invalid configuration":
  expect MummyError:
    discard initMultipartDecoder("text/plain")
  expect MummyError:
    discard initMultipartDecoder("multipart/form-data; boundary=")
  expect MummyError:
    discard initMultipartDecoder(
      "multipart/form-data; boundary=; boundary=" & boundary
    )
  expect MummyError:
    discard initMultipartDecoder(
      "multipart/form-data; boundary=" & "a".repeat(71)
    )
  expect MummyError:
    discard initMultipartDecoder("multipart/form-data; boundary=bad@boundary")

test "rejects large or invalid part headers":
  var oversized = initMultipartDecoder(contentType, maxHeaderBytes = 8)
  expect MummyError:
    discard oversized.feed(multipartBody)

  var missingName = initMultipartDecoder(contentType)
  expect MummyError:
    discard missingName.feed(
      "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; filename=a.txt\r\n\r\n"
    )
  expect MummyError:
    discard missingName.feed("more data")

test "accepts extreme header limit without overflow":
  var decoder = initMultipartDecoder(contentType, maxHeaderBytes = high(int))
  discard decoder.feed("--" & boundary & "--")
  discard decoder.finish()

test "rejects incomplete and reused decoders":
  var incomplete = initMultipartDecoder(contentType)
  discard incomplete.feed("--" & boundary & "\r\n")
  expect MummyError:
    discard incomplete.finish()

  var complete = initMultipartDecoder(contentType)
  discard complete.feed("--" & boundary & "--")
  discard complete.finish()
  expect MummyError:
    discard complete.feed("")
  expect MummyError:
    discard complete.finish()
