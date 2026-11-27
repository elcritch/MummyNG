import std/selectors
import mummy/tls

var connection: TlsConnection
connection.phase = tlsHandshake
connection.wait = tlsRead
doAssert tlsInterests(connection, true) == {Read}
connection.wait = tlsWrite
doAssert tlsInterests(connection, false) == {Write}
connection.phase = tlsOpen
connection.wait = tlsReady
doAssert tlsInterests(connection, false) == {Read}
doAssert tlsInterests(connection, true) == {Read, Write}
# Paused request reads leave only the output, or nothing.
doAssert tlsInterests(connection, true, readable = false) == {Write}
doAssert tlsInterests(connection, false, readable = false) == {}
connection.writeWait = tlsRead
# A write retry waiting to read keeps Read while reads are paused.
doAssert tlsInterests(connection, true, readable = false) == {Read}
doAssert tlsInterests(connection, true) == {Read}
doAssert not satisfied(connection.writeWait, {Write})
connection.writeWait = tlsWrite
doAssert tlsInterests(connection, true) == {Write}
doAssert not satisfied(connection.writeWait, {Read})
connection.writeWait = tlsReady
connection.readWait = tlsWrite
doAssert tlsInterests(connection, true) == {Write}
connection.phase = tlsClosing
connection.wait = tlsRead
doAssert tlsInterests(connection, true) == {Read}

when not defined(ssl):
  import mummy/common
  doAssertRaises MummyError:
    discard newTlsContext(TlsConfig(certificateFile: "cert", privateKeyFile: "key"))
