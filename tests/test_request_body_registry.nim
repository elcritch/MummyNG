import mummy
import mummy/requestbody
import std/unittest

type UploadState = ref object
  body: string

var registry = newRequestBodyRegistry[UploadState]()
var stream: RequestBodyStream
var concurrentRegistry = newRequestBodyRegistry[int]()

proc exerciseRegistry(worker: int) {.thread.} =
  for iteration in 0 ..< 10_000:
    concurrentRegistry[stream] = worker
    var retrieved: int
    check concurrentRegistry.get(stream, retrieved)
    check retrieved in 0 ..< 4

test "starts empty":
  check registry.len == 0
  check stream notin registry
  var state: UploadState
  check not registry.get(stream, state)
  check state == nil

test "stores and retrieves state":
  let state = UploadState(body: "chunk")
  registry[stream] = state
  check registry.len == 1
  check stream in registry

  var retrieved: UploadState
  check registry.get(stream, retrieved)
  check retrieved == state
  check retrieved.body == "chunk"

test "replaces and takes state":
  let replacement = UploadState(body: "replacement")
  registry[stream] = replacement

  var taken: UploadState
  check registry.take(stream, taken)
  check taken == replacement
  check registry.len == 0
  check not registry.take(stream, taken)

test "deletion and clear are idempotent":
  registry.del(stream)
  registry[stream] = UploadState(body: "one")
  registry.clear()
  check registry.len == 0

test "synchronizes concurrent callers":
  var threads: array[4, Thread[int]]
  for worker in 0 ..< threads.len:
    createThread(threads[worker], exerciseRegistry, worker)
  joinThreads(threads)
  check concurrentRegistry.len == 1

test "closes registries":
  registry.close()
  concurrentRegistry.close()
  check registry == nil
  check concurrentRegistry == nil
