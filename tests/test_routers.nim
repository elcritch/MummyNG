import mummy, mummy/routers, webby/urls
import std/unittest

proc handler(request: Request) =
  discard

proc unexpectedHandler(request: Request) =
  raise newException(AssertionDefect, "unexpected route handler invocation")

proc unexpectedErrorHandler(request: Request, e: ref Exception) =
  raise newException(AssertionDefect, "unexpected route error handler invocation")

test "matches literal and single-segment wildcard routes":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/", handler)
  router.get("/page.html", handler)
  router.get("/*.js", handler)
  router.get("/*/index.html", handler)
  router.get("/styles/*.css", handler)
  router.get("/partial/*", handler)
  router.get("/literal*", handler)
  router.get("/*double*", handler)
  router.get("/質問/日本語のURLはどうする", handler)

  expect MummyError:
    router.get("/**/*", handler)

  expect MummyError:
    router.get("/**/**", handler)

  expect MummyError:
    router.get("/**/bad/**/**", handler)

  expect MummyError:
    let s = ""
    router.get(s, handler)

  expect MummyError:
    let s = "abc"
    router.get(s, handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = ""
  expect AssertionDefect:
    routerHandler(request)

  request.path = "page.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/"
  routerHandler(request)

  request.path = "/a"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/page.html"
  routerHandler(request)

  request.path = "/script.js"
  routerHandler(request)

  request.path = "/.js"
  routerHandler(request)

  request.path = "/script.j"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/script.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/script"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/min.js"
  routerHandler(request)

  request.path = "/index.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/index.html"
  routerHandler(request)

  request.path = "/b/index.html"
  routerHandler(request)

  request.path = "/a/b/index.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/styles/index.css"
  routerHandler(request)

  request.path = "/styles/2/index.css"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/styles/script.js"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/partial"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/partial/something"
  routerHandler(request)

  request.path = "/partial/more/here"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/literal*"
  routerHandler(request)

  request.path = "/literal*asdf&asdf"
  routerHandler(request)

  request.path = "/literalasdf"
  routerHandler(request)

  request.path = "/adoubleb"
  routerHandler(request)

  request.path = "/longerdoubleevenmore"
  routerHandler(request)

  request.path = "/doubleb"
  routerHandler(request)

  request.path = "/adouble"
  routerHandler(request)

  request.path = "/double"
  routerHandler(request)

  request.path = "/doubl"
  expect AssertionDefect:
    routerHandler(request)

  block:
    let url = parseUrl("/%E8%B3%AA%E5%95%8F/%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%81%AEURL%E3%81%AF%E3%81%A9%E3%81%86%E3%81%99%E3%82%8B")
    request.path = url.path
    routerHandler(request)

  deallocShared(request)

test "matches catch-all routes":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  proc badHandler(request: Request) =
    raise newException(AssertionDefect, "unexpected fallback handler invocation")

  router.get("/**", handler)
  router.get("/**", badHandler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/"
  routerHandler(request)

  request.path = "/index.html"
  routerHandler(request)

  request.path = "/path"
  routerHandler(request)

  request.path = "/path/to/thing.html"
  routerHandler(request)

  request.path = "/a/b/c/d/e/f/g/h.txt"
  routerHandler(request)

test "matches a catch-all between literal segments":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/**/TEST/**", handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/TEST/page.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/TEST/a/b/c/d.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/TEST/b.html"
  routerHandler(request)

test "matches multiple catch-alls between literal segments":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/**/TEST/**/TEST2/**", handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/index.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/path"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/path/to/thing.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/b/c/d/e/f/g/h.txt"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/b/TEST/d/f/g.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/TEST/page.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/b/TEST/d/f/g/TEST2/page.html"
  routerHandler(request)

  request.path = "/a/TEST/b/TEST2/page.html"
  routerHandler(request)

  request.path = "/TEST/page.html&3"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/TEST/TEST2/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/TEST/TEST2/page.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/TEST/TEST2/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a/TEST/TEST2/page.html"
  expect AssertionDefect:
    routerHandler(request)

test "matches mixed segment and catch-all wildcards":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/*page/**/*.html", handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/page/thing/do.html"
  routerHandler(request)

  request.path = "/2page/thing/do.html"
  routerHandler(request)

  request.path = "/wowpage/do.html"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/wowpage/a/do.htm"
  expect AssertionDefect:
    routerHandler(request)

test "matches suffix wildcards":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/*a", handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/a"
  routerHandler(request)

  request.path = "/aa"
  routerHandler(request)

  request.path = "/somethinga"
  routerHandler(request)

  request.path = "/a/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/something"
  expect AssertionDefect:
    routerHandler(request)

test "matches contains wildcards":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/*something*", handler)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/something"
  routerHandler(request)

  request.path = "/asomething"
  routerHandler(request)

  request.path = "/somethingb"
  routerHandler(request)

  request.path = "/asomethingb"
  routerHandler(request)

  request.path = "/something/"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/something/else"
  expect AssertionDefect:
    routerHandler(request)

test "treats embedded single stars literally":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/a*b", handler) # Not a wildcard here

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/a"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/ab"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/asomethingb"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a*b"
  routerHandler(request)

test "treats embedded double stars literally":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  router.get("/**z", handler) # Not a wildcard here
  router.get("/a**b", handler) # Not a wildcard here

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/a"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/ab"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/asomethingb"
  expect AssertionDefect:
    routerHandler(request)

  request.path = "/a**b"
  routerHandler(request)

test "stores path parameters":
  var pathParams: PathParams
  check "foo" notin pathParams
  pathParams["foo"] = "bar"
  check "foo" in pathParams
  check pathParams.len == 1
  check pathParams["foo"] == "bar"

test "matches parameterized routes":
  var router: Router
  router.notFoundHandler = unexpectedHandler
  router.methodNotAllowedHandler = unexpectedHandler
  router.errorHandler = unexpectedErrorHandler

  proc routeHandler1(request: Request) =
    check "id" in request.pathParams
    check request.pathParams.len == 1
    check request.pathParams["id"] == "123"

  router.get("/@id", routeHandler1)

  proc routeHandler2(request: Request) =
    check "name" in request.pathParams
    check "id" in request.pathParams
    check request.pathParams.len == 2
    check request.pathParams["name"] == "abc"
    check request.pathParams["id"] == "123"

  router.get("/@name/@id", routeHandler2)

  proc routeHandler3(request: Request) =
    check "first" in request.pathParams
    check "second" in request.pathParams
    check request.pathParams.len == 2
    check request.pathParams["first"] == "a"
    check request.pathParams["second"] == "b"

  router.get("/@first/zzz/@second", routeHandler3)

  proc routeHandler4(request: Request) =
    check "first" in request.pathParams
    check "second" in request.pathParams
    check request.pathParams.len == 2
    check request.pathParams["first"] == "a"
    check request.pathParams["second"] == "b"

  router.get("/@first/*/@second", routeHandler4)

  proc routeHandler5(request: Request) =
    check "name" in request.pathParams
    check request.pathParams.len == 1
    check request.pathParams["name"] == "bob"

  router.get("/a/**/literal/@name", routeHandler5)

  let routerHandler = router.toHandler()

  let request = cast[Request](allocShared0(sizeof(RequestObj)))
  request.httpMethod = "GET"

  request.path = "/123"
  routerHandler(request)

  request.path = "/abc/123"
  routerHandler(request)

  request.path = "/a/zzz/b"
  routerHandler(request)

  request.path = "/a/wild/b"
  routerHandler(request)

  request.path = "/a/b/c/d/literal/bob"
  routerHandler(request)
