import mummy, mummy/multipart
import std/unittest

suite "multipart fuzzing":
  test "accepts and rejects fragmented multipart bodies safely":
    let valid = "--123\r\nContent-Disposition: form-data; name=\"abc\";filename=\"file.txt\";\r\nContent-Type: text/plain\r\n\r\ndef\r\n--123\r\nContent-Disposition: form-data; name=\"ghi\"\r\nDummy-Header-1: 1\r\nDummy-Header-2: 2\r\nBroken-Header\r\n\r\njkl\r\n--123--"

    let request = cast[Request](allocShared0(sizeof(RequestObj)))
    request.headers["Content-Type"] = "multipart/form-data; boundary=123"

    for i in 0 ..< valid.len:
      request.body = valid[0 .. i]
      try:
        discard request.decodeMultipart()
      except:
        discard

    for i in 0 ..< valid.len:
      request.body = valid[i .. ^1]
      try:
        discard request.decodeMultipart()
      except:
        discard

    proc tryStreaming(body: string, chunkSize: Positive) =
      var decoder = initMultipartDecoder(request)
      var offset = 0
      try:
        while offset < body.len:
          let ending = min(offset + chunkSize, body.len)
          discard decoder.feed(body[offset ..< ending])
          offset = ending
        discard decoder.finish()
      except MummyError:
        discard

    for chunkSize in 1 .. 16:
      tryStreaming(valid, chunkSize)

    for i in 0 ..< valid.len:
      tryStreaming(valid[0 .. i], 7)
      tryStreaming(valid[i .. ^1], 7)
