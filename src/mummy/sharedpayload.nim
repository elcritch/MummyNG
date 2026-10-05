# Immutable bytes shared by WebSocket queues and snapshot history. The last
# owner may be released on a different thread from the allocating publisher.
import std/atomics

type
  PayloadStorage = object
    owners: Atomic[int]
    size: int

  SharedPayload* = object
    ## Immutable owned bytes. Copies share storage using an atomic reference
    ## count, so independent owners may be released on different threads.
    storage: ptr PayloadStorage

proc `=destroy`(payload: SharedPayload) =
  if payload.storage != nil and
     payload.storage.owners.fetchSub(1, moAcquireRelease) == 1:
    deallocShared(payload.storage)

proc `=copy`(dest: var SharedPayload; source: SharedPayload) =
  if dest.storage == source.storage:
    return
  if source.storage != nil:
    discard source.storage.owners.fetchAdd(1, moRelaxed)
  `=destroy`(dest)
  dest.storage = source.storage

proc len*(payload: SharedPayload): int {.inline.} =
  ## Number of payload bytes; a default-initialized owner is empty.
  if payload.storage == nil: 0 else: payload.storage.size

proc dataAt*(payload: SharedPayload; offset: int): pointer {.inline.} =
  ## Transport-only borrowed pointer. Never mutate it or retain it past the
  ## owner's lifetime. offset may equal len for an empty payload.
  assert offset >= 0 and offset <= payload.len
  if payload.storage != nil:
    cast[pointer](cast[uint](payload.storage) + uint(sizeof(PayloadStorage) + offset))
  else:
    nil

proc newSharedPayload*(data: string): SharedPayload =
  ## Copy once into shared allocation; later copies retain only this owner.
  result.storage = cast[ptr PayloadStorage](
    allocShared(sizeof(PayloadStorage) + data.len))
  result.storage.owners.store(1, moRelaxed)
  result.storage.size = data.len
  if data.len > 0:
    copyMem(result.dataAt(0), unsafeAddr data[0], data.len)
