include ../src/mummy

block:
  # Both transports use the same cursor for headers, owned bodies and shared
  # payloads. Exercise every partial-write offset and the completed boundary.
  for output in [OutgoingBuffer(),
                 OutgoingBuffer(buffer1: "header"),
                 OutgoingBuffer(buffer2: "body"),
                 OutgoingBuffer(sharedPayload: newSharedPayload("shared")),
                 OutgoingBuffer(buffer1: "header", buffer2: "body"),
                 OutgoingBuffer(buffer1: "header", sharedPayload: newSharedPayload("shared"))]:
    var unsent = output.buffer1
    if output.sharedPayload.len > 0: unsent.add "shared"
    unsent.add output.buffer2
    while unsent.len > 0:
      let segment = output.nextSegment()
      doAssert segment.isSome
      let (buffer, length) = segment.get
      doAssert length > 0 and length <= unsent.len
      doAssert cast[ptr UncheckedArray[char]](buffer)[0] == unsent[0]
      # A one-byte write must advance within a segment without skipping bytes.
      inc output.bytesSent
      unsent = unsent[1 .. ^1]
    doAssert output.nextSegment().isNone

block:
  var queue = initDeque[OutgoingBuffer]()
  let first = OutgoingBuffer(buffer1: "first", bytesSent: 2)
  queue.addLast(first)
  doAssert joinFrame(queue, OutgoingBuffer(buffer1: "second"))
  doAssert queue.len == 1
  doAssert first.buffer1 == "firstsecond"
  doAssert first.bytesSent == 2
  for boundary in [OutgoingBuffer(isCloseFrame: true),
                   OutgoingBuffer(closeConnection: true),
                   OutgoingBuffer(buffer2: "large")]:
    doAssert not joinFrame(queue, boundary)
  first.isWebSocketUpgrade = true
  doAssert not joinFrame(queue, OutgoingBuffer(buffer1: "later"))

block:
  # A shared payload is sent after its own header, so neither side of it joins.
  var queue = initDeque[OutgoingBuffer]()
  queue.addLast(OutgoingBuffer(buffer1: "head"))
  doAssert not joinFrame(queue, OutgoingBuffer(buffer1: "h", sharedPayload: newSharedPayload("shared")))
  queue.addLast(OutgoingBuffer(buffer1: "h", sharedPayload: newSharedPayload("shared")))
  doAssert not joinFrame(queue, OutgoingBuffer(buffer1: "after"))
  doAssert queue.peekFirst().buffer1 == "head"
  doAssert queue.peekLast().buffer1 == "h"

block:
  let server = newServer(proc(request: Request) = discard, workerThreads = 1)
  let ws = WebSocket(server: server)
  ws.send("hello")
  let frame = server.sendQueue.popFirst()
  doAssert frame.buffer2.len == 0
  doAssert frame.buffer1.len == 7
  doAssert frame.buffer1[2 .. ^1] == "hello"
  server.close()
