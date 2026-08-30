import mummy {.all.}, mummy/internal
import std/unittest

suite "Mummy internals":
  test "matches header tokens":
    var headers: HttpHeaders
    headers["0"] = "a"
    headers["1"] = "a,b"
    headers["2"] = "a, bbbb,cc  ,     dd   ,,"

    check headers.headerContainsToken("0", "a")
    check headers.headerContainsToken("0", "A")
    check not headers.headerContainsToken("0", "b")

    check headers.headerContainsToken("1", "a")
    check headers.headerContainsToken("1", "A")
    check headers.headerContainsToken("1", "b")
    check headers.headerContainsToken("1", "B")
    check not headers.headerContainsToken("1", "c")
    check not headers.headerContainsToken("1", "C")

    check headers.headerContainsToken("2", "a")
    check headers.headerContainsToken("2", "bbbb")
    check headers.headerContainsToken("2", "BbBB")
    check headers.headerContainsToken("2", "cc")
    check headers.headerContainsToken("2", "dd")
    check headers.headerContainsToken("2", "DD")
    check not headers.headerContainsToken("2", "d")

  test "parses strict decimal integers":
    for i in 0 ..< 10_000:
      check strictParseInt($i) == i

    check strictParseInt("-1") == -1

    check strictParseInt("9223372036854775807") == 9223372036854775807
    check strictParseInt("-9223372036854775808") == -9223372036854775808

    expect ValueError:
      discard strictParseInt("")

    expect ValueError:
      discard strictParseInt("+")

    expect ValueError:
      discard strictParseInt("-")

    expect ValueError:
      discard strictParseInt("-0")

    expect ValueError:
      discard strictParseInt("+1")

    expect ValueError:
      discard strictParseInt("010")

    expect ValueError:
      discard strictParseInt("10a")

    expect ValueError:
      discard strictParseInt("9223372036854775808")

    expect ValueError:
      discard strictParseInt("-9223372036854775809")

  test "parses strict hexadecimal integers":
    expect ValueError:
      discard strictParseHex("")

    expect ValueError:
      discard strictParseHex("00")

    expect ValueError:
      discard strictParseHex("0f")

    expect ValueError:
      discard strictParseHex("0x1")

    for i in 0 ..< 10_000:
      check strictParseHex(toHexWithoutLeadingZeroes(i)) == i

    check strictParseHex("7FFFFFFFFFFFFFFF") == 9223372036854775807

    expect ValueError:
      discard strictParseHex("8FFFFFFFFFFFFFFF")

    discard strictParseHex("1111111111111111")
    expect ValueError:
      discard strictParseHex("11111111111111111")
