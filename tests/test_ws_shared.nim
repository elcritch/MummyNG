# nim c -r -d:release --path:src tests/test_ws_shared.nim
import std/[deques, importutils, nativesockets, strutils, unittest]
import mummy

privateAccess(WebSocket)
privateAccess(Server)

proc handler(request: Request) {.gcsafe.} = discard

proc matches(payload: SharedPayload; expected: string): bool =
  payload.len == expected.len and (expected.len == 0 or
    equalMem(payload.dataAt(0), unsafeAddr expected[0], expected.len))

proc copyOnThread(payload: SharedPayload) {.thread.} =
  for _ in 0 ..< 10_000:
    var copies = @[payload, payload]
    copies[0] = SharedPayload()
    doAssert copies[1].matches("thread-owned bytes")

suite "shared WebSocket payloads":
  test "owns input independently, copies only owners and survives replacement":
    var input = "snapshot".repeat(1024)
    var first = newSharedPayload(input)
    var second = first
    check first.dataAt(0) == second.dataAt(0)
    input[0] = '!'
    check first.matches("snapshot".repeat(1024))
    first = newSharedPayload("replacement")
    check second.matches("snapshot".repeat(1024))
    second = second
    check second.matches("snapshot".repeat(1024))
    second = move first
    check second.matches("replacement")

  test "empty values can be copied, moved and destroyed":
    var payload = newSharedPayload("")
    var copy = payload
    payload = SharedPayload()
    check copy.len == 0
    copy = move payload
    check copy.len == 0

  test "independent owners may be copied and released on multiple threads":
    var payload = newSharedPayload("thread-owned bytes")
    var threads: array[4, Thread[SharedPayload]]
    for thread in threads.mitems:
      createThread(thread, copyOnThread, payload)
    payload = SharedPayload()
    joinThreads(threads)

  test "1024 queued clients share one payload, including history ownership":
    let server = newServer(handler, workerThreads = 0)
    defer: server.close()
    let expected = "snapshot".repeat(32 * 1024)
    var history = @[newSharedPayload(expected)]
    let address = history[0].dataAt(0)
    for i in 0 ..< 1024:
      let ws = WebSocket(server: server, clientSocket: SocketHandle(i + 1),
                         clientId: uint64(i + 1))
      ws.sendShared(history[0])
    check server.sendQueue.len == 1024
    history.setLen(0)
    while server.sendQueue.len > 0:
      let frame = server.sendQueue.popFirst()
      privateAccess(typeof(frame[]))
      check frame.buffer2.len == 0
      check frame.sharedPayload.dataAt(0) == address
      check frame.sharedPayload.matches(expected)

  when not defined(useMalloc):
    test "server shutdown releases undrained queues":
      let expected = "x".repeat(1024 * 1024)
      let before = getOccupiedMem()
      block:
        let server = newServer(handler, workerThreads = 0)
        let ws = WebSocket(server: server, clientSocket: SocketHandle(1), clientId: 1)
        ws.sendShared(newSharedPayload(expected))
        server.close()
      check getOccupiedMem() - before < 64 * 1024

    test "repeated queue teardown releases payload storage":
      let server = newServer(handler, workerThreads = 0)
      defer: server.close()
      let ws = WebSocket(server: server, clientSocket: SocketHandle(1), clientId: 1)
      let expected = "x".repeat(1024 * 1024)
      # Warm up the queue capacity, then check that payloads are not retained.
      ws.sendShared(newSharedPayload(expected))
      server.sendQueue.clear()
      let before = getOccupiedMem()
      for _ in 0 ..< 32:
        ws.sendShared(newSharedPayload(expected))
        server.sendQueue.clear()
      check getOccupiedMem() - before < 64 * 1024
