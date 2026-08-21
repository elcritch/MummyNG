## Server-sent events built on Mummy's bounded response body streams.

import std/[options, strutils]

import ../mummy

export options

type
  SseEvent* = object
    ## A semantic server-sent event.
    data*: string ## Event payload; each input line becomes one `data` field.
    event*: string ## Optional event type; CR and LF are invalid.
    id*: string ## Optional last-event ID; CR, LF, and NUL are invalid.
    retry*: Option[Natural] ## Optional reconnection delay in milliseconds.
    comment*: string ## Optional comment text, useful for keep-alive messages.

proc isFieldValue(value: string, allowNull = true): bool {.raises: [].} =
  for ch in value:
    if ch in {'\r', '\n'} or (not allowNull and ch == '\0'):
      return false
  result = true

proc appendLines(result: var string, prefix, value: string) {.raises: [].} =
  var start: int
  while true:
    let ending = value.find('\n', start)
    if ending < 0:
      result.add(prefix)
      result.add(value[start..^1])
      result.add("\n")
      return
    result.add(prefix)
    result.add(value[start..<ending])
    result.add("\n")
    start = ending + 1

proc encode*(event: SseEvent): string {.raises: [].} =
  ## Encodes an event using the SSE wire format.
  ##
  ## Returns an empty string if an event name or ID could inject another field.
  if not event.event.isFieldValue() or not event.id.isFieldValue(allowNull = false):
    return
  if event.comment.len > 0:
    result.appendLines(": ", event.comment.replace("\r\n", "\n").replace('\r', '\n'))
  if event.id.len > 0:
    result.add("id: " & event.id & "\n")
  if event.event.len > 0:
    result.add("event: " & event.event & "\n")
  if event.retry.isSome:
    result.add("retry: " & $event.retry.get() & "\n")
  if event.data.len > 0 or result.len == 0:
    result.appendLines(
      "data: ",
      event.data.replace("\r\n", "\n").replace('\r', '\n')
    )
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
  var encoded: string
  encoded.appendLines(": ", text.replace("\r\n", "\n").replace('\r', '\n'))
  encoded.add("\n")
  stream.write(move encoded)

proc heartbeat*(stream: ResponseBodyStream, comment = "keep-alive"): bool {.raises: [], gcsafe.} =
  ## Attempts to send an SSE comment heartbeat when the stream is writable.
  stream.comment(comment)
