import mummy
import mummy/multipart
import std/[assertions, options, strutils]

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
      doAssert parts.len > 0
      parts[^1].body.add(event.data)
    of MultipartPartEnd:
      doAssert parts.len > 0
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

block decodes_across_every_chunk_size:
  for chunkSize in 1 .. multipartBody.len:
    let decoded = decode(chunkSize)
    doAssert decoded.ended
    doAssert decoded.parts.len == 2
    doAssert decoded.parts[0].metadata.name == "field"
    doAssert decoded.parts[0].metadata.filename.isNone
    doAssert decoded.parts[0].body == "value"
    doAssert decoded.parts[0].ended
    doAssert decoded.parts[1].metadata.name == "upload"
    doAssert decoded.parts[1].metadata.filename == some("a.txt")
    doAssert decoded.parts[1].metadata.headers["Content-Type"] == "text/plain"
    doAssert decoded.parts[1].body == "abc"
    doAssert decoded.parts[1].ended

block preserves_boundary_lookalikes_in_part_data:
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
  doAssert decodedData == "before\r\n--" & boundary & "XXafter"

block accepts_empty_messages_and_parts:
  var emptyMessage = initMultipartDecoder(contentType)
  doAssert emptyMessage.feed("--" & boundary & "--").len == 0
  let ending = emptyMessage.finish()
  doAssert ending.len == 1
  doAssert ending[0].kind == MultipartMessageEnd

  var emptyPart = initMultipartDecoder(contentType)
  let events = emptyPart.feed(
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=empty\r\n\r\n" &
    "\r\n--" & boundary & "--"
  )
  doAssert events.len == 2
  doAssert events[0].kind == MultipartPartBegin
  doAssert events[1].kind == MultipartPartEnd
  discard emptyPart.finish()

block rejects_invalid_configuration:
  doAssertRaises MummyError:
    discard initMultipartDecoder("text/plain")
  doAssertRaises MummyError:
    discard initMultipartDecoder("multipart/form-data; boundary=")
  doAssertRaises MummyError:
    discard initMultipartDecoder(
      "multipart/form-data; boundary=; boundary=" & boundary
    )
  doAssertRaises MummyError:
    discard initMultipartDecoder(
      "multipart/form-data; boundary=" & "a".repeat(71)
    )
  doAssertRaises MummyError:
    discard initMultipartDecoder("multipart/form-data; boundary=bad@boundary")

block rejects_large_or_invalid_part_headers:
  var oversized = initMultipartDecoder(contentType, maxHeaderBytes = 8)
  doAssertRaises MummyError:
    discard oversized.feed(multipartBody)

  var missingName = initMultipartDecoder(contentType)
  doAssertRaises MummyError:
    discard missingName.feed(
      "--" & boundary & "\r\n" &
      "Content-Disposition: form-data; filename=a.txt\r\n\r\n"
    )
  doAssertRaises MummyError:
    discard missingName.feed("more data")

block accepts_extreme_header_limit_without_overflow:
  var decoder = initMultipartDecoder(contentType, maxHeaderBytes = high(int))
  discard decoder.feed("--" & boundary & "--")
  discard decoder.finish()

block rejects_incomplete_and_reused_decoders:
  var incomplete = initMultipartDecoder(contentType)
  discard incomplete.feed("--" & boundary & "\r\n")
  doAssertRaises MummyError:
    discard incomplete.finish()

  var complete = initMultipartDecoder(contentType)
  discard complete.feed("--" & boundary & "--")
  discard complete.finish()
  doAssertRaises MummyError:
    discard complete.feed("")
  doAssertRaises MummyError:
    discard complete.finish()
