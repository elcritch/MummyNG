## Deterministic retries, including cross-direction waits rarely induced on real sockets.
import std/[openssl, selectors]
import mummy/tls

var step, successes, originalLength: int
var original: pointer
var connection: TlsConnection
var storage = "the original write"
original = addr storage[0]
originalLength = storage.len

tlsTestIo = proc(operation: TlsTestOperation, buffer: pointer, size: int): cint {.gcsafe, raises: [].} =
  inc step
  case operation
  of testWrite:
    doAssert buffer == original
    doAssert size == originalLength
    if step == 1:
      tlsTestError = SSL_ERROR_WANT_WRITE
      return -1
    if step == 2:
      tlsTestError = SSL_ERROR_WANT_READ
      return -1
    inc successes
    return 5 # positive partial progress
  of testRead:
    tlsTestError = SSL_ERROR_WANT_WRITE
    return -1
  of testAccept:
    tlsTestError = SSL_ERROR_WANT_WRITE
    return -1
  of testShutdown:
    return 0

doAssert connection.writeTls(original, storage.len) == 0
doAssert connection.writeWait == tlsWrite
doAssert tlsInterests(connection, true) == {Read} # handshake still owns readiness
connection.phase = tlsOpen
doAssert tlsInterests(connection, true) == {Write}
# A different offered buffer/length must never replace an outstanding SSL_write retry.
doAssert connection.writeTls(nil, 999) == 0
doAssert connection.writeWait == tlsRead
doAssert tlsInterests(connection, true) == {Read}
doAssert connection.writeTls(nil, 999) == 5
doAssert successes == 1
doAssert connection.writeWait == tlsReady
doAssert connection.readTls(original, storage.len) == 0
doAssert connection.readWait == tlsWrite
doAssert tlsInterests(connection, true) == {Write}
doAssert connection.handshakeTls() == tlsWrite
doAssert connection.shutdownTls() == tlsClosed
