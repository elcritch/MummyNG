import mummy
import mummy/requestbody
import std/assertions

type UploadState = ref object
  body: string

var registry = newRequestBodyRegistry[UploadState]()
var stream: RequestBodyStream
var concurrentRegistry = newRequestBodyRegistry[int]()

proc exerciseRegistry(worker: int) {.thread.} =
  for iteration in 0 ..< 10_000:
    concurrentRegistry[stream] = worker
    var retrieved: int
    doAssert concurrentRegistry.get(stream, retrieved)
    doAssert retrieved in 0 ..< 4

block starts_empty:
  doAssert registry.len == 0
  doAssert stream notin registry
  var state: UploadState
  doAssert not registry.get(stream, state)
  doAssert state == nil

block stores_and_retrieves_state:
  let state = UploadState(body: "chunk")
  registry[stream] = state
  doAssert registry.len == 1
  doAssert stream in registry

  var retrieved: UploadState
  doAssert registry.get(stream, retrieved)
  doAssert retrieved == state
  doAssert retrieved.body == "chunk"

block replaces_and_takes_state:
  let replacement = UploadState(body: "replacement")
  registry[stream] = replacement

  var taken: UploadState
  doAssert registry.take(stream, taken)
  doAssert taken == replacement
  doAssert registry.len == 0
  doAssert not registry.take(stream, taken)

block deletion_and_clear_are_idempotent:
  registry.del(stream)
  registry[stream] = UploadState(body: "one")
  registry.clear()
  doAssert registry.len == 0

block synchronizes_concurrent_callers:
  var threads: array[4, Thread[int]]
  for worker in 0 ..< threads.len:
    createThread(threads[worker], exerciseRegistry, worker)
  joinThreads(threads)
  doAssert concurrentRegistry.len == 1

registry.close()
concurrentRegistry.close()
doAssert registry == nil
doAssert concurrentRegistry == nil
