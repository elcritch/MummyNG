include ../src/mummy

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
