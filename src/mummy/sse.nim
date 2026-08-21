## Server-sent events built on Mummy's bounded response body streams.

import std/options

import sse/types as sseTypes
import sse/writer as sseWriter

import ../mummy

export options

type
  SseEvent* = object
    ## A semantic server-sent event.
    data*: string ## Event payload; an empty payload emits an empty `data` field.
    event*: string ## Optional event type; CR and LF are invalid.
    id*: string ## Optional last-event ID; CR, LF, and NUL are invalid.
    retry*: Option[Natural] ## Optional reconnection delay in milliseconds.
    comment*: string ## Optional comment text, useful for keep-alive messages.

proc isFieldValue(value: string, allowNull = true): bool {.raises: [].} =
  for ch in value:
    if ch in {'\r', '\n'} or (not allowNull and ch == '\0'):
      return false
  result = true

proc encode*(event: SseEvent): string {.raises: [].} =
  ## Encodes an event using the SSE wire format.
  ##
  ## Returns an empty string if an event name or ID could inject another field.
  if not event.event.isFieldValue() or not event.id.isFieldValue(allowNull = false):
    return
  if event.comment.len > 0:
    result.add(sseWriter.serializeComment(event.comment))
  if event.retry.isSome:
    result.add(sseWriter.serializeRetry(event.retry.get().int))
  if event.data.len > 0 or event.event.len > 0 or event.id.len > 0 or
      result.len == 0:
    result.add(sseWriter.serializeEvent(sseTypes.SseEvent(
      data: event.data,
      eventType: event.event,
      lastEventId: event.id
    )))
  else:
    result.add("\n")

proc respondSse*(
  request: Request,
  statusCode = 200,
  headers: sink HttpHeaders = emptyHttpHeaders(),
  start = true
): ResponseBodyStream {.raises: [], gcsafe.} =
  ## Starts an SSE response without overriding explicitly supplied headers.
  if "Content-Type" notin headers:
    headers["Content-Type"] = "text/event-stream"
  if "Cache-Control" notin headers:
    headers["Cache-Control"] = "no-cache"
  if "Connection" notin headers:
    headers["Connection"] = "keep-alive"
  if "X-Accel-Buffering" notin headers:
    headers["X-Accel-Buffering"] = "no"
  request.respondStream(statusCode, move headers, start)

proc send*(stream: ResponseBodyStream, event: SseEvent): bool {.raises: [], gcsafe.} =
  ## Attempts to send one encoded SSE event when the stream is writable.
  ## Returns false for an invalid event name or ID.
  var encoded = event.encode()
  encoded.len > 0 and stream.write(move encoded)

proc comment*(stream: ResponseBodyStream, text: string): bool {.raises: [], gcsafe.} =
  ## Attempts to send an SSE comment when the stream is writable.
  var encoded = sseWriter.serializeComment(text)
  encoded.add("\n")
  stream.write(move encoded)

proc heartbeat*(stream: ResponseBodyStream, comment = "keep-alive"): bool {.raises: [], gcsafe.} =
  ## Attempts to send an SSE comment heartbeat when the stream is writable.
  stream.comment(comment)
