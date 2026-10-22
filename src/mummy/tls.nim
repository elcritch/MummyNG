## Nonblocking TLS primitives. A connection is owned exclusively by the selector thread.
import std/[nativesockets, selectors]
import ./common

type
  TlsConfig* = ref object ## HTTPS/WSS settings passed to `newServer`; `nil` disables TLS.
    certificateFile*: string ## PEM certificate chain, leaf first.
    privateKeyFile*: string ## Matching unencrypted PEM private key.
    handshakeTimeoutMs*: int = 10_000 ## Handshake deadline in milliseconds; must be positive.
    shutdownTimeoutMs*: int = 1_000 ## TLS shutdown deadline in milliseconds; must be positive.
    maxPendingHandshakes*: int = 256 ## Maximum concurrent handshakes; must be positive.
  TlsWait* = enum
    tlsReady, tlsRead, tlsWrite, tlsClosed, tlsFailed
  TlsPhase* = enum
    tlsHandshake, tlsOpen, tlsClosing

when defined(ssl):
  import std/openssl
  type
    TlsContext* = SslCtx
    TlsConnection* = object
      handle*: SslPtr
      phase*: TlsPhase
      wait*: TlsWait
      readWait*, writeWait*: TlsWait
      writeBuffer: pointer
      writeLength: int

  when defined(mummyTlsTest):
    type TlsTestOperation* = enum
      testAccept, testRead, testWrite, testShutdown
    var tlsTestError*: cint
    var tlsTestIo*: proc(operation: TlsTestOperation, buffer: pointer, size: int): cint {.gcsafe, raises: [].}

  template callIo(operation: untyped, buffer: pointer, size: int, actual: untyped): cint =
    when defined(mummyTlsTest):
      if tlsTestIo != nil: tlsTestIo(operation, buffer, size) else: actual
    else:
      actual

  proc setOptions(ctx: SslCtx, options: uint64): uint64
    {.cdecl, dynlib: DLLSSLName, importc: "SSL_CTX_set_options".}

  proc newTlsContext*(config: TlsConfig): TlsContext {.raises: [MummyError].} =
    if config == nil: return nil
    if config.certificateFile.len == 0 or config.privateKeyFile.len == 0 or
        config.handshakeTimeoutMs <= 0 or config.shutdownTimeoutMs <= 0 or
        config.maxPendingHandshakes <= 0:
      raise newException(MummyError, "TLS requires a certificate, private key and positive limits")
    try:
      if getOpenSSLVersion() < 0x30000000'u64:
        raise newException(MummyError, "TLS requires OpenSSL 3 or newer")
      result = SSL_CTX_new(TLS_server_method())
      if result == nil: raise newException(MummyError, "Cannot create TLS context")
      # SSL_CTX_set_min_proto_version is a macro over SSL_CTX_ctrl.
      if SSL_CTX_ctrl(result, 123, 0x0303, nil) != 1:
        raise newException(MummyError, "Cannot require TLS 1.2")
      discard setOptions(result, (1'u64 shl 30) or (1'u64 shl 17)) # no renegotiation/compression
      discard SSLCTXSetMode(result, SSL_MODE_ENABLE_PARTIAL_WRITE or 16) # release idle buffers
      if SSL_CTX_use_certificate_chain_file(result, config.certificateFile.cstring) != 1 or
          SSL_CTX_use_PrivateKey_file(result, config.privateKeyFile.cstring, SSL_FILETYPE_PEM) != 1 or
          SSL_CTX_check_private_key(result) != 1:
        raise newException(MummyError, "Cannot load TLS certificate/private key (PEM), or keys do not match")
      # Early data remains disabled (OpenSSL's default). No h2 ALPN is advertised.
    except Exception as e:
      if result != nil:
        SSL_CTX_free(result)
        result = nil
      raise newException(MummyError, e.msg)

  proc freeTlsContext*(ctx: var TlsContext) {.raises: [].} =
    if ctx != nil:
      SSL_CTX_free(ctx)
      ctx = nil

  proc initTls*(ctx: TlsContext, socket: SocketHandle): TlsConnection {.raises: [].} =
    result.handle = SSL_new(ctx)
    result.wait = tlsRead
    if result.handle == nil: return
    if SSL_set_fd(result.handle, socket) != 1:
      SSL_free(result.handle)
      result.handle = nil
    else:
      sslSetAcceptState(result.handle)

  proc freeTls*(connection: var TlsConnection) {.raises: [].} =
    if connection.handle != nil:
      SSL_free(connection.handle)
      connection.handle = nil
    connection.writeBuffer = nil
    connection.writeLength = 0

  proc classify(connection: TlsConnection, count: cint): TlsWait {.raises: [].} =
    if count > 0: return tlsReady
    let error = block:
      when defined(mummyTlsTest):
        if tlsTestIo != nil: tlsTestError else: SSL_get_error(connection.handle, count)
      else:
        SSL_get_error(connection.handle, count)
    case error
    of SSL_ERROR_WANT_READ: tlsRead
    of SSL_ERROR_WANT_WRITE: tlsWrite
    of SSL_ERROR_ZERO_RETURN: tlsClosed
    else: tlsFailed

  proc handshakeTls*(connection: var TlsConnection): TlsWait {.raises: [].} =
    ErrClearError()
    result = connection.classify(callIo(testAccept, nil, 0, SSL_accept(connection.handle)))
    connection.wait = result
    if result == tlsReady: connection.phase = tlsOpen

  proc readTls*(connection: var TlsConnection, buffer: pointer, size: int): int {.raises: [].} =
    ErrClearError()
    let count = callIo(testRead, buffer, size, SSL_read(connection.handle, buffer, size))
    connection.readWait = connection.classify(count)
    if count > 0: result = count

  proc writeTls*(connection: var TlsConnection, buffer: pointer, size: int): int {.raises: [].} =
    if connection.writeBuffer == nil:
      connection.writeBuffer = buffer
      connection.writeLength = size
    ErrClearError()
    let count = callIo(testWrite, connection.writeBuffer, connection.writeLength,
                      SSL_write(connection.handle, cast[cstring](connection.writeBuffer), connection.writeLength))
    connection.writeWait = connection.classify(count)
    if count > 0:
      connection.writeBuffer = nil
      connection.writeLength = 0
      result = count

  proc shutdownTls*(connection: var TlsConnection): TlsWait {.raises: [].} =
    connection.phase = tlsClosing
    ErrClearError()
    let count = callIo(testShutdown, nil, 0, SSL_shutdown(connection.handle))
    # A zero return means our close_notify was sent. Do not wait for the peer's reply.
    result = if count >= 0: tlsClosed else: connection.classify(count)
    connection.wait = result

  proc pendingTls*(connection: TlsConnection): bool {.raises: [].} =
    connection.handle != nil and SSL_pending(connection.handle) > 0

else:
  type
    TlsContext* = pointer
    TlsConnection* = object
      handle*: pointer
      phase*: TlsPhase
      wait*, readWait*, writeWait*: TlsWait
  proc newTlsContext*(config: TlsConfig): TlsContext {.raises: [MummyError].} =
    if config != nil: raise newException(MummyError, "TLS requires compilation with -d:ssl -d:useOpenssl3")
  proc freeTlsContext*(ctx: var TlsContext) {.raises: [].} = discard
  proc freeTls*(connection: var TlsConnection) {.raises: [].} = discard
  proc pendingTls*(connection: TlsConnection): bool {.raises: [].} = false

proc satisfied*(wait: TlsWait, events: set[Event]): bool {.raises: [].} =
  case wait
  of tlsReady: true
  of tlsRead: Read in events
  of tlsWrite: Write in events
  else: false

proc tlsInterests*(connection: TlsConnection, hasOutput: bool, readable = true): set[Event] {.raises: [].} =
  ## The selector events a TLS connection waits for. `readable` is false while the server has
  ## paused reading request bytes; pending retries still wait for the event OpenSSL asked for.
  if connection.phase != tlsOpen:
    return if connection.wait == tlsWrite: {Write} else: {Read}
  # A write blocked on writing must be retried before any other TLS I/O.
  if connection.writeWait == tlsWrite: return {Write}
  if connection.writeWait == tlsRead: return {Read}
  if connection.readWait == tlsWrite: return {Write}
  if readable: result.incl(Read)
  if hasOutput: result.incl(Write)
