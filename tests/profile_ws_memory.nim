# Offline queue-only comparison; no sockets, packs or upstream requests.
# nim c -d:release tests/profile_ws_memory.nim
# ./tests/profile_ws_memory [shared|copied]
import std/[deques, importutils, nativesockets, os, strformat, strutils]
import mummy

privateAccess(WebSocket)
privateAccess(Server)

proc report(stage: string) =
  var rss = "unavailable"
  when defined(linux):
    for line in lines("/proc/self/status"):
      if line.startsWith("VmRSS:"): rss = line.splitWhitespace()[1] & " KiB"
  echo &"{stage}: heap={getOccupiedMem() div 1024} KiB rss={rss}"

proc handler(request: Request) {.gcsafe.} = discard

proc main() =
  let mode = if paramCount() == 0: "shared" else: paramStr(1)
  if mode notin ["shared", "copied"]:
    quit "usage: profile_ws_memory [shared|copied]"
  let server = newServer(handler, workerThreads = 0)
  defer: server.close()
  let payload = "snapshot".repeat(32 * 1024)
  var shared = newSharedPayload(payload)
  report(mode & " baseline (256 KiB snapshot)")
  for i in 0 ..< 1024:
    let ws = WebSocket(server: server, clientSocket: SocketHandle(i + 1),
                       clientId: uint64(i + 1))
    if mode == "shared": ws.sendShared(shared)
    else: ws.send(payload, BinaryMessage)
    if i + 1 in [1, 128, 512, 1024]: report($(i + 1) & " queued clients")
  server.sendQueue.clear()
  shared = SharedPayload()
  report("queue cleared")

main()
