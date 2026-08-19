import mummy/sse
import std/[assertions, options]

block basic:
  doAssert SseEvent(data: "hello").encode() == "data: hello\n\n"
  doAssert SseEvent().encode() == "data: \n\n"

block multiline:
  doAssert SseEvent(data: "one\r\ntwo\rthree\nfour").encode() ==
    "data: one\ndata: two\ndata: three\ndata: four\n\n"

block fields:
  doAssert SseEvent(
    data: "x",
    event: "update",
    id: "42",
    retry: some(0.Natural)
  ).encode() == "id: 42\nevent: update\nretry: 0\ndata: x\n\n"

block invalidFields:
  doAssert SseEvent(data: "x", event: "update\nno").encode() == ""
  doAssert SseEvent(data: "x", id: "42\r\nno").encode() == ""
  doAssert SseEvent(data: "x", id: "bad\0id").encode() == ""

block comment:
  doAssert SseEvent(comment: "ping\nagain").encode() ==
    ": ping\n: again\n\n"
