import std/os, mummy, std/atomics, std/httpclient
import std/unittest

var
  requestCounter: Atomic[int]
  doneCounter: Atomic[int]

proc handler(request: Request) =
  discard requestCounter.fetchAdd(1, moRelaxed)
  request.respond(200)
  sleep(10_000)
  discard doneCounter.fetchAdd(1, moRelaxed)

let server = newServer(handler, workerThreads = 10)

var serverThread: Thread[void]

proc serverProc() =
  {.gcsafe.}:
    server.serve(Port(8080))

suite "worker sleep":
  test "responds before slow handlers finish":
    createThread(serverThread, serverProc)
    server.waitUntilReady()

    for i in 0 ..< 10:
      let client = newHttpClient()
      discard client.getContent("http://localhost:8080/")

    check requestCounter.exchange(0, moRelaxed) == 10
    check doneCounter.exchange(0, moRelaxed) == 0

    echo "Done, shut down the server"
    server.close()
