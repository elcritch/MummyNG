import mummy/sse as mummySse
import std/[assertions, options]
import sse/parser as sseParser
import sse/types as sseTypes

block basic:
  doAssert mummySse.SseEvent(data: "hello").encode() == "data: hello\n\n"
  doAssert mummySse.SseEvent().encode() == "data: \n\n"

block multiline:
  doAssert mummySse.SseEvent(data: "one\r\ntwo\rthree\nfour").encode() ==
    "data: one\ndata: two\ndata: three\ndata: four\n\n"

block fields:
  doAssert mummySse.SseEvent(
    data: "x",
    event: "update",
    id: "42",
    retry: some(0.Natural)
  ).encode() == "retry: 0\nevent: update\nid: 42\ndata: x\n\n"

block fieldOnly:
  doAssert mummySse.SseEvent(event: "update").encode() ==
    "event: update\ndata: \n\n"

block defaultMessage:
  doAssert mummySse.SseEvent(data: "x", event: "message").encode() ==
    "data: x\n\n"

block invalidFields:
  doAssert mummySse.SseEvent(data: "x", event: "update\nno").encode() == ""
  doAssert mummySse.SseEvent(data: "x", id: "42\r\nno").encode() == ""
  doAssert mummySse.SseEvent(data: "x", id: "bad\0id").encode() == ""

block comment:
  doAssert mummySse.SseEvent(comment: "ping\nagain").encode() ==
    ": ping\n: again\n\n"

block parsesWithSse:
  let encoded = mummySse.SseEvent(
    data: "payload",
    event: "update",
    id: "42",
    retry: some(3000.Natural),
    comment: "ready"
  ).encode()
  var events: seq[sseTypes.SseEvent]
  var parser = sseParser.initSseParser(
    proc (event: sseTypes.SseEvent) {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        events.add(event)
  )
  parser.feed(encoded)
  parser.complete()
  doAssert events.len == 1
  doAssert events[0].eventType == "update"
  doAssert events[0].data == "payload"
  doAssert events[0].lastEventId == "42"
  doAssert parser.reconnectionTime == 3000
