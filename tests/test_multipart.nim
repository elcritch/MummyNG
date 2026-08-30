import mummy, mummy/multipart
import std/unittest

test "requires multipart content type":
  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  expect MummyError:
    discard request.decodeMultipart()

test "validates multipart content types and boundaries":
  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.body = "--123--"

  request.headers["Content-Type"] = "multipart/form-data; boundary=123"
  discard request.decodeMultipart()

  expect MummyError:
    request.headers["Content-Type"] = "asdf; boundary=123"
    discard request.decodeMultipart()

  expect MummyError:
    request.headers["Content-Type"] = "multipart/form-data; boundary="
    discard request.decodeMultipart()

  expect MummyError:
    request.headers["Content-Type"] = "multipart/form-data; boundary=456"
    discard request.decodeMultipart()

  request.headers["Content-Type"] = "MULTIPART/FoRm-DaTa; boundary=123"
  discard request.decodeMultipart()

  request.headers["Content-Type"] = "multipart/form-data;boundary=123"
  discard request.decodeMultipart()

  request.headers["Content-Type"] = "multipart/form-data; boundary=\"123\""
  discard request.decodeMultipart()

  request.body = "--123--\r\n"
  discard request.decodeMultipart()

test "decodes multipart fields and files":
  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.headers["Content-Type"] = "multipart/form-data; boundary=123"

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=\"abc\"\r\n\r\n\r\n--123--"
    let entries = request.decodeMultipart()
    check entries.len == 1
    check entries[0].name == "abc"
    check not entries[0].data.isSome
    check entries[0].headers == @[("Content-Disposition", "form-data; name=\"abc\"")]

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=abc\r\n\r\n\r\n--123--"
    let entries = request.decodeMultipart()
    check entries.len == 1
    check entries[0].name == "abc"
    check not entries[0].data.isSome

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=abc;zzz\r\n\r\n\r\n--123--"
    let entries = request.decodeMultipart()
    check entries.len == 1
    check entries[0].name == "abc"
    check not entries[0].data.isSome

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=abc\r\n--123--"
    expect MummyError:
      discard request.decodeMultipart()

  block:
    request.body = "--123\r\nContent-Disposition: name=\"abc\"\r\n\r\n\r\n--123--"
    expect MummyError:
      discard request.decodeMultipart()

  block:
    request.body = "--123\r\n\r\n--123--"
    expect MummyError:
      discard request.decodeMultipart()

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=abc\r\n\r\n--123--"
    expect MummyError:
      echo request.decodeMultipart()

  block:
    request.body = "--123\r\nContent-Disposition: form-data; \r\n\r\n--123--"
    expect MummyError:
      echo request.decodeMultipart()

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=\"abc\"\r\n\r\ndef\r\n--123--"
    let entries = request.decodeMultipart()
    check entries.len == 1
    check entries[0].name == "abc"
    check not entries[0].filename.isSome
    check entries[0].data.isSome
    let (start, last) = entries[0].data.get
    check request.body[start .. last] == "def"

  block:
    request.body = "--123\r\nContent-Disposition: form-data; name=\"abc\";filename=\"file.txt\";\r\nContent-Type: text/plain\r\n\r\ndef\r\n--123\r\nContent-Disposition: form-data; name=\"ghi\"\r\nDummy-Header-1: 1\r\nDummy-Header-2: 2\r\nBroken-Header\r\n\r\njkl\r\n--123--"
    let entries = request.decodeMultipart()

    check entries.len == 2
    check entries[0].name == "abc"
    check entries[0].filename == some("file.txt")
    check entries[0].headers.len == 2
    check entries[0].headers["Content-Type"] == "text/plain"
    check entries[0].data.isSome
    block:
      let (start, last) = entries[0].data.get
      check request.body[start .. last] == "def"

    check entries[1].name == "ghi"
    check entries[1].data.isSome
    block:
      let (start, last) = entries[1].data.get
      check request.body[start .. last] == "jkl"
    check entries[1].headers == @[
      ("Content-Disposition", "form-data; name=\"ghi\""),
      ("Dummy-Header-1", "1"),
      ("Dummy-Header-2", "2"),
      ("Broken-Header", "")
    ]
