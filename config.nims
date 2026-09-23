when (NimMajor, NimMinor, NimPatch) < (2, 0, 0):
  --threads:on
  --mm:orc

when defined(features.mummy.testing) and
    not defined(chroniclers.logBackendChronicles) and
    not defined(chroniclers.logBackendStd) and
    not defined(chroniclers.logBackendCustom) and
    not defined(chroniclers.logBackendNone) and
    not defined(features.chroniclers.chronicles) and
    not defined(features.chroniclers.std):
  switch("define", "chroniclers.logBackendChronicles")
