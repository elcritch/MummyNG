import mummy/sse
import std/[unittest, options]

suite "server-sent events":
  test "encodes basic data":
    check SseEvent(data: "hello").encode() == "data: hello\n\n"
    check SseEvent().encode() == "data: \n\n"

  test "normalizes multiline data":
    check SseEvent(data: "one\r\ntwo\rthree\nfour").encode() ==
      "data: one\ndata: two\ndata: three\ndata: four\n\n"

  test "encodes event fields":
    check SseEvent(
      data: "x",
      event: "update",
      id: "42",
      retry: some(0.Natural)
    ).encode() == "id: 42\nevent: update\nretry: 0\ndata: x\n\n"

  test "rejects invalid fields":
    check SseEvent(data: "x", event: "update\nno").encode() == ""
    check SseEvent(data: "x", id: "42\r\nno").encode() == ""
    check SseEvent(data: "x", id: "bad\0id").encode() == ""

  test "encodes comments":
    check SseEvent(comment: "ping\nagain").encode() ==
      ": ping\n: again\n\n"
