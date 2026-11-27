# Optional native TLS

Mummy can serve HTTPS and WSS itself, through nonblocking OpenSSL 3 on the selector thread.
Without a TLS configuration it serves plain HTTP and WebSockets exactly as before.

```nim
import mummy

proc handler(request: Request) =
  request.respond(200, body = "hello")

let server = newServer(handler, tls = TlsConfig(
  certificateFile: "/run/certs/chain.pem",
  privateKeyFile: "/run/certs/key.pem"))
server.serve(Port(8443), "0.0.0.0")
```

Build with `--threads:on --mm:orc -d:ssl -d:sslVersion=3` (`-d:useOpenssl3` as well on Nim versions
that need it). `sslVersion=3` makes the program load the OpenSSL 3 shared library (`libssl3` on
Debian and Ubuntu), which must be installed where it runs. A build without `-d:ssl` rejects a
supplied TLS configuration with `MummyError`.

## Configuration

The configuration requires an unencrypted PEM private key and a PEM certificate chain with the leaf
first. Invalid credentials fail in `newServer`, before any worker starts. TLS 1.2 is the minimum,
TLS 1.3 is supported, early data, compression and renegotiation are disabled, and HTTP/2 is not
advertised. Client certificate authentication and certificate hot reload are not implemented:
replace the files and restart to rotate a certificate.

| Field | Default | Meaning |
|---|---|---|
| `handshakeTimeoutMs` | 10,000 | A connection that has not finished its handshake by then is closed. |
| `maxPendingHandshakes` | 256 | Connections accepted beyond this many unfinished handshakes are closed at once. |
| `shutdownTimeoutMs` | 1,000 | How long a closing connection may take to send its `close_notify`. |

All three must be positive. Deadlines use monotonic time and a heap, so established idle
connections are never scanned. On a normal close Mummy sends `close_notify` but does not wait for
the peer's reply; fatal errors close at once.

## Behaviour

TLS objects and all their I/O belong to the selector thread, like every other socket operation.
Each selector turn handles at most 32 KiB of reads and 32 KiB of writes per connection. Plain
responses, WebSocket frames, shared WebSocket payloads (`sendShared`) and streamed response bodies
(`respondStream`, SSE) are written from their own buffers, with the same completion events as
plain connections. A pending `SSL_write` pins its bytes, address and length; later WebSocket frames
batch only into the buffers after it.

Streamed request bodies keep their backpressure: while Mummy has paused reading a request body,
it does not read from the TLS connection either, except to finish an operation OpenSSL asked to
retry (those bytes wait in the receive buffer). Records OpenSSL already decrypted are delivered when
reading resumes, even if the socket reports nothing new.

The existing message and body limits apply unchanged. TLS adds no outgoing queue limit:
applications must still bound how much they enqueue to slow clients.

## Tests

```sh
nim c -r tests/test_batching.nim
nim c -r tests/test_tls_state.nim
nim c -r -d:ssl -d:sslVersion=3 -d:mummyTlsTest tests/test_tls_retry.nim
nim c -r -d:ssl -d:sslVersion=3 tests/test_tls.nim
```

`test_tls.nim` needs nothing beyond Nim's standard library and OpenSSL 3. It starts itself as a
fixture server in a child process and drives it over real sockets, with the same checks over plain
HTTP/WS, over HTTPS/WSS, and over an ECDSA leaf in a full PEM chain: keep-alive, WebSocket framing
including records split into 3-byte writes, shared payloads, streamed responses, paused streamed
request bodies, frames queued behind a stalled reader while other clients are served, abrupt
resets, TLS 1.2 and 1.3 (and a refused TLS 1.1), handshake deadlines and admission limits,
credential errors and shutdown. Its certificates are committed fixtures (`tests/tls`).
`test_tls_retry.nim` injects deterministic OpenSSL results under `mummyTlsTest`; those hooks do
not exist in other builds. CI runs the TLS tests on Linux.
