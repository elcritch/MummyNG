version     = "0.6.3"
author      = "Ryan Oldenburg / Jaremy Creechley"
description = "Multithreaded HTTP + WebSocket server"
license     = "MIT"

srcDir = "src"

requires "nim >= 2.0.0"
requires "zippy >= 0.10.9"
requires "webby >= 0.2.1"
requires "crunchy >= 0.1.11"
requires "chroniclers >= 0.7.0"
# Atlas otherwise selects the first 0.7.0 commit, before the backend flag changes.
requires "chroniclers #4fa640a2f44b784d71b356dc2086c42dc005a0c4"

feature "chronicles":
  requires "chroniclers >= 0.7.0[chronicles]"

feature "testing":
  requires "chronicles >= 0.12.3"
  requires "whisky"
  requires "jsony"
