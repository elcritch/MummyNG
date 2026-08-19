## Thread-safe state helpers for streaming request body handlers.

import std/[locks, tables]

import ../mummy

type
  RequestBodyRegistryObj[T] = object
    lock: Lock
    values: Table[RequestBodyStream, T]

  RequestBodyRegistry*[T] = ptr RequestBodyRegistryObj[T]
    ## Associates application state with active request body streams.
    ##
    ## Request body callbacks can run concurrently for different streams. Registry
    ## operations synchronize access without holding the lock while callers use a
    ## retrieved value. Stored values must be safe to transfer between worker
    ## threads. Call `close` after the server and its handlers have stopped.

proc newRequestBodyRegistry*[T](): RequestBodyRegistry[T] =
  ## Creates an empty request body registry.
  result = cast[RequestBodyRegistry[T]](allocShared0(sizeof(result[])))
  initLock(result.lock)
  result.values = initTable[RequestBodyStream, T]()

proc close*[T](registry: var RequestBodyRegistry[T]) =
  ## Releases an inactive registry and its synchronization resources.
  ##
  ## No handler may access the registry during or after this call.
  if registry != nil:
    deinitLock(registry.lock)
    `=destroy`(registry[])
    deallocShared(registry)
    registry = nil

proc len*[T](registry: RequestBodyRegistry[T]): int {.gcsafe.} =
  ## Returns the number of registered streams.
  {.gcsafe.}:
    withLock registry.lock:
      result = registry.values.len

proc contains*[T](
  registry: RequestBodyRegistry[T],
  stream: RequestBodyStream
): bool {.gcsafe.} =
  ## Returns whether state is registered for `stream`.
  {.gcsafe.}:
    withLock registry.lock:
      result = stream in registry.values

proc `[]=`*[T](
  registry: RequestBodyRegistry[T],
  stream: RequestBodyStream,
  value: sink T
) {.gcsafe.} =
  ## Adds or replaces the state associated with `stream`.
  {.gcsafe.}:
    withLock registry.lock:
      registry.values[stream] = move value

proc get*[T](
  registry: RequestBodyRegistry[T],
  stream: RequestBodyStream,
  value: var T
): bool {.gcsafe.} =
  ## Copies the state associated with `stream` into `value` when present.
  {.gcsafe.}:
    withLock registry.lock:
      if stream in registry.values:
        value = registry.values[stream]
        result = true

proc take*[T](
  registry: RequestBodyRegistry[T],
  stream: RequestBodyStream,
  value: var T
): bool {.gcsafe.} =
  ## Removes the state associated with `stream` and moves it into `value`.
  {.gcsafe.}:
    withLock registry.lock:
      result = registry.values.pop(stream, value)

proc del*[T](
  registry: RequestBodyRegistry[T],
  stream: RequestBodyStream
) {.gcsafe.} =
  ## Removes any state associated with `stream`.
  {.gcsafe.}:
    withLock registry.lock:
      registry.values.del(stream)

proc clear*[T](registry: RequestBodyRegistry[T]) {.gcsafe.} =
  ## Removes all registered stream state.
  {.gcsafe.}:
    withLock registry.lock:
      registry.values.clear()
