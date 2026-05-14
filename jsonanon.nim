# jsonanon.nim
# Portable JSON anonymizer in Nim.
#
# Build:
#   nim c -d:release --opt:size --threads:on -d:useMalloc --passL:-static -o:jsonanon jsonanon.nim
#
# If your platform/libc does not support fully static linking, use:
#   nim c -d:release --opt:size --threads:on -d:useMalloc -o:jsonanon jsonanon.nim
#
# Usage:
#   ./jsonanon --in:input.json --out:anonymized.json
#   cat input.json | ./jsonanon > anonymized.json
#   ./jsonanon --in:input.json --seed-text:project-a

import std/[json, parseopt, os, strutils, random, times, strformat, math, cpuinfo]

type
  Options = object
    inputPath: string
    outputPath: string
    pretty: bool
    preserveNull: bool
    seed: int64
    seedText: string

  Anonymizer = ref object
    rng: Rand
    preserveNull: bool
    consistent: JsonNode

  WorkerArgs = object
    jsonStr: string
    seed: int64
    preserveNull: bool
    pretty: bool
    output: string  # written by worker proc

const
  firstNames = ["Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Avery", "Jamie", "Quinn", "Sam", "Maya", "Nora", "Lena", "Iris", "Victor", "Dylan"]
  lastNames = ["Smith", "Johnson", "Brown", "Miller", "Davis", "Wilson", "Taylor", "Anderson", "Clark", "Moore", "Walker", "Hall"]
  cities = ["Springfield", "Riverton", "Fairview", "Oakwood", "Franklin", "Georgetown", "Arlington", "Milton"]
  states = ["CA", "NY", "TX", "WA", "OR", "IL", "MA", "CO"]
  countries = ["United States", "Netherlands", "Germany", "France", "Canada", "United Kingdom", "Australia"]
  jobTitles = ["Engineer", "Manager", "Analyst", "Designer", "Consultant", "Director", "Coordinator", "Specialist"]
  statusValues = ["active", "pending", "inactive", "complete", "failed"]
  currencies = ["USD", "EUR", "GBP", "CHF", "CAD", "AUD"]

proc usage() =
  echo """
jsonanon - anonymize arbitrary JSON while preserving keys, structure, and JSON value types

Options:
  --in:<file>             Input JSON file. Defaults to stdin.
  --out:<file>            Output JSON file. Defaults to stdout.
  --pretty:on|off         Pretty-print output. Default: on.
  --seed:<integer>        Deterministic numeric seed. Default: current time.
  --seed-text:<text>      Deterministic text seed.
  --preserve-null:on|off  Keep null values as null. Default: on.
  --help                  Show help.

Examples:
  jsonanon --in:input.json --out:anon.json
  jsonanon --in:input.json --out:anon.json --seed-text:project-a
  cat input.json | jsonanon --pretty:off > anon.json
"""

proc parseBoolOption(s: string): bool =
  let v = s.toLowerAscii()
  if v in ["1", "true", "yes", "y", "on"]: return true
  if v in ["0", "false", "no", "n", "off"]: return false
  raise newException(ValueError, "invalid boolean option: " & s)

proc parseOptions(): Options =
  result.pretty = true
  result.preserveNull = true
  result.seed = 0

  var parser = initOptParser(commandLineParams())
  for kind, key, val in parser.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "in", "i": result.inputPath = val
      of "out", "o": result.outputPath = val
      of "pretty": result.pretty = parseBoolOption(val)
      of "preserve-null": result.preserveNull = parseBoolOption(val)
      of "seed": result.seed = parseInt(val).int64
      of "seed-text": result.seedText = val
      of "help", "h":
        usage()
        quit(0)
      else:
        raise newException(ValueError, "unknown option: " & key)
    of cmdArgument:
      raise newException(ValueError, "unexpected argument: " & key)
    of cmdEnd:
      discard

proc seedFromText(s: string): int64 =
  ## Stable enough deterministic seed for repeatable anonymization.
  ## Uses FNV-1a 64-bit rather than Nim's randomized hash().
  var h = 0xcbf29ce484222325'u64
  for ch in s:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  result = cast[int64](h)

proc normalizeKey(s: string): string =
  result = s.toLowerAscii()
  for ch in ['_', '-', ' ']:
    result = result.replace($ch, "")

proc containsAny(s: string; parts: varargs[string]): bool =
  for p in parts:
    if s.contains(p): return true
  false

proc maxInt(a, b: int): int =
  if a > b: a else: b

proc pick(a: Anonymizer; xs: openArray[string]): string =
  xs[a.rng.rand(xs.len - 1)]

proc fakeName(a: Anonymizer): string =
  a.pick(firstNames) & " " & a.pick(lastNames)

proc fakeEmail(a: Anonymizer): string =
  (a.pick(firstNames) & "." & a.pick(lastNames) & $(10 + a.rng.rand(89))).toLowerAscii() & "@example.test"

proc fakePhone(a: Anonymizer): string =
  fmt"+1-555-{a.rng.rand(999):03}-{a.rng.rand(9999):04}"

proc fakeUUID(a: Anonymizer): string =
  var bytes: array[16, uint8]
  for i in 0 ..< 16:
    bytes[i] = uint8(a.rng.rand(255))
  bytes[6] = (bytes[6] and 0x0f'u8) or 0x40'u8
  bytes[8] = (bytes[8] and 0x3f'u8) or 0x80'u8
  result = fmt"{bytes[0]:02x}{bytes[1]:02x}{bytes[2]:02x}{bytes[3]:02x}-{bytes[4]:02x}{bytes[5]:02x}-{bytes[6]:02x}{bytes[7]:02x}-{bytes[8]:02x}{bytes[9]:02x}-{bytes[10]:02x}{bytes[11]:02x}{bytes[12]:02x}{bytes[13]:02x}{bytes[14]:02x}{bytes[15]:02x}"

proc fakeStreetAddress(a: Anonymizer): string =
  let suffix = a.pick(["Street", "Avenue", "Road", "Lane", "Boulevard"])
  fmt"{100 + a.rng.rand(9898)} {a.pick(lastNames)} {suffix}"

proc fakeCompany(a: Anonymizer): string =
  a.pick(["Northstar", "Bluebird", "Oakridge", "Summit", "Evergreen", "Redwood"]) & " " &
    a.pick(["Systems", "Labs", "Group", "Holdings", "Partners"])

proc fakeCompanySlug(a: Anonymizer): string =
  a.fakeCompany().toLowerAscii().replace(" ", "-")

proc fakeURL(a: Anonymizer): string =
  "https://" & a.fakeCompanySlug() & ".example.test/" & a.pick(["profile", "orders", "account", "docs"])

proc fakeIBAN(a: Anonymizer): string =
  fmt"NL{10 + a.rng.rand(88):02}TEST{a.rng.rand(9_999_999_999):010}"

proc fakeIPv4(a: Anonymizer): string =
  fmt"10.{a.rng.rand(255)}.{a.rng.rand(255)}.{a.rng.rand(255)}"

proc looksLikeEmail(s: string): bool =
  let at = s.find('@')
  if at <= 0 or at == s.len - 1: return false
  if s.find(' ') >= 0: return false
  let domain = s[at + 1 .. ^1]
  domain.find('.') > 0

proc looksLikeUUID(s: string): bool =
  if s.len != 36: return false
  for i, ch in s:
    if i in [8, 13, 18, 23]:
      if ch != '-': return false
    else:
      if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  true

proc looksLikePhone(s: string): bool =
  if s.len < 7: return false
  var i = 0
  if s[i] == '+': inc i
  if i >= s.len or s[i] notin {'0'..'9'}: return false
  inc i
  var digits = 0
  while i < s.len:
    if s[i] in {'0'..'9'}: inc digits
    elif s[i] notin {' ', '.', '(', ')', '-'}: return false
    inc i
  digits >= 6

proc looksLikeURL(s: string): bool =
  s.startsWith("http://") or s.startsWith("https://")

proc looksLikeIPv4(s: string): bool =
  let parts = s.split('.')
  if parts.len != 4: return false
  for p in parts:
    if p.len == 0 or p.len > 3: return false
    for ch in p:
      if ch notin {'0'..'9'}: return false
  true

proc allDigits(s: string): bool =
  for ch in s:
    if ch notin {'0'..'9'}: return false
  s.len > 0

proc matchesDateYMD(s: string): bool =
  ## yyyy-MM-dd
  s.len >= 10 and s[4] == '-' and s[7] == '-' and
    allDigits(s[0..3]) and allDigits(s[5..6]) and allDigits(s[8..9])

proc matchesDateSlashYMD(s: string): bool =
  ## yyyy/MM/dd
  s.len == 10 and s[4] == '/' and s[7] == '/' and
    allDigits(s[0..3]) and allDigits(s[5..6]) and allDigits(s[8..9])

proc matchesDateSlashDMY(s: string): bool =
  ## dd/MM/yyyy
  s.len == 10 and s[2] == '/' and s[5] == '/' and
    allDigits(s[0..1]) and allDigits(s[3..4]) and allDigits(s[6..9])

proc looksLikeDate(s: string): bool =
  matchesDateYMD(s) or matchesDateSlashDMY(s)

proc fakeDateLike(a: Anonymizer; original: string): string =
  let base = dateTime(1990, mJan, 1, 0, 0, 0, zone = utc())
  let d = base + initDuration(days = a.rng.rand(365 * 40))

  if original.len >= 11 and matchesDateYMD(original) and original[10] == 'T':
    return d.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  if matchesDateSlashYMD(original):
    return d.format("yyyy/MM/dd")
  if matchesDateSlashDMY(original):
    return d.format("dd/MM/yyyy")
  if original.len == 19 and matchesDateYMD(original) and original[10] == ' ':
    return d.format("yyyy-MM-dd HH:mm:ss")
  d.format("yyyy-MM-dd")

proc fakeSameShapeString(a: Anonymizer; s: string): string =
  for ch in s:
    case ch
    of 'A'..'Z': result.add(char(ord('A') + a.rng.rand(25)))
    of 'a'..'z': result.add(char(ord('a') + a.rng.rand(25)))
    of '0'..'9': result.add(char(ord('0') + a.rng.rand(9)))
    else: result.add(ch)

proc inferDecimalPlaces(s: string): int =
  let dot = s.find('.')
  if dot < 0: return 2
  var e = s.find('e')
  if e < 0: e = s.find('E')
  let stop = if e >= 0: e else: s.len
  result = stop - dot - 1
  if result < 1: result = 1
  if result > 8: result = 8

proc pow10Int(n: int): int64 =
  result = 1
  for _ in 0 ..< n:
    result *= 10

proc fakeIntForKey(a: Anonymizer; key: string; orig: int64): int64 =
  var absVal = abs(orig)
  let digits = ($absVal).len

  if containsAny(key, "age"):
    return int64(18 + a.rng.rand(71))
  if containsAny(key, "year"):
    return int64(1970 + a.rng.rand(59))
  if containsAny(key, "month"):
    return int64(1 + a.rng.rand(11))
  if containsAny(key, "day"):
    return int64(1 + a.rng.rand(27))
  if containsAny(key, "count", "quantity", "qty", "items"):
    return int64(a.rng.rand(999))

  var minVal = pow10Int(maxInt(0, digits - 1))
  let maxVal = pow10Int(digits) - 1
  if digits == 1: minVal = 0

  var fake = minVal + a.rng.rand(maxVal - minVal)
  if orig < 0: fake = -fake
  fake

proc fakeFloatForKey(a: Anonymizer; key: string; orig: float): float =
  if containsAny(key, "lat", "latitude"):
    return -90.0 + a.rng.rand(1.0) * 180.0
  if containsAny(key, "lon", "lng", "longitude"):
    return -180.0 + a.rng.rand(1.0) * 360.0

  var magnitude = abs(orig)
  if magnitude == 0: magnitude = 100.0
  let minVal = magnitude * 0.25
  let maxVal = magnitude * 1.75
  result = minVal + a.rng.rand(1.0) * (maxVal - minVal)
  if orig < 0: result = -result

proc formatFloatFixed(x: float; places: int): string =
  result = formatFloat(x, ffDecimal, places)

proc cacheKey(path: seq[string]; value: string): string =
  path.join(".") & "=" & value

proc fakeString(a: Anonymizer; key, value: string; path: seq[string]): string =
  let trimmed = value.strip()
  if trimmed.len == 0: return value

  let ck = cacheKey(path, value)
  if a.consistent.hasKey(ck):
    return a.consistent[ck].getStr()

  let nk = normalizeKey(key)

  if looksLikeEmail(trimmed) or containsAny(nk, "email", "mail"):
    result = a.fakeEmail()
  elif looksLikeURL(trimmed) or containsAny(nk, "url", "uri", "website", "link"):
    result = a.fakeURL()
  elif looksLikeUUID(trimmed) or containsAny(nk, "uuid", "guid"):
    result = a.fakeUUID()
  elif looksLikeIPv4(trimmed) or containsAny(nk, "ip", "ipaddress"):
    result = a.fakeIPv4()
  elif containsAny(nk, "date", "dob", "birth", "createdat", "updatedat", "timestamp") or looksLikeDate(trimmed):
    result = a.fakeDateLike(trimmed)
  elif looksLikePhone(trimmed) or containsAny(nk, "phone", "mobile", "telephone", "fax"):
    result = a.fakePhone()
  elif containsAny(nk, "firstname", "givenname"):
    result = a.pick(firstNames)
  elif containsAny(nk, "lastname", "surname", "familyname"):
    result = a.pick(lastNames)
  elif containsAny(nk, "fullname", "name", "contactperson", "customername", "username"):
    result = a.fakeName()
  elif containsAny(nk, "address", "street", "addr"):
    result = a.fakeStreetAddress()
  elif containsAny(nk, "city", "town"):
    result = a.pick(cities)
  elif containsAny(nk, "state", "province", "region"):
    result = a.pick(states)
  elif containsAny(nk, "country"):
    result = a.pick(countries)
  elif containsAny(nk, "postcode", "zipcode", "zip", "postal"):
    result = fmt"{10000 + a.rng.rand(89998):05}"
  elif containsAny(nk, "company", "organization", "organisation", "employer", "vendor"):
    result = a.fakeCompany()
  elif containsAny(nk, "currency") and trimmed.len == 3:
    result = a.pick(currencies)
  elif containsAny(nk, "status"):
    result = a.pick(statusValues)
  elif containsAny(nk, "role", "title", "position"):
    result = a.pick(jobTitles)
  elif containsAny(nk, "iban"):
    result = a.fakeIBAN()
  else:
    result = a.fakeSameShapeString(trimmed)

  a.consistent[ck] = %result

proc anonymizeAt(a: Anonymizer; node: JsonNode; path: seq[string]; key: string): JsonNode =
  case node.kind
  of JObject:
    result = newJObject()
    for k, v in node:
      result[k] = a.anonymizeAt(v, path & @[k], k)
  of JArray:
    result = newJArray()
    for i, v in node.elems:
      result.add(a.anonymizeAt(v, path & @[$i], key))
  of JString:
    result = %a.fakeString(key, node.getStr(), path)
  of JInt:
    let nk = normalizeKey(key)
    result = %a.fakeIntForKey(nk, node.getBiggestInt())
  of JFloat:
    let nk = normalizeKey(key)
    result = %a.fakeFloatForKey(nk, node.getFloat())
  of JBool:
    result = %bool(a.rng.rand(1) == 0)
  of JNull:
    result = newJNull()

proc computeSeed(opts: Options): int64 =
  if opts.seedText.len > 0:
    return seedFromText(opts.seedText)
  if opts.seed != 0:
    return opts.seed
  let t = getTime()
  t.toUnix() * 1_000_000_000'i64 + t.nanosecond

proc newAnonymizer(opts: Options): Anonymizer =
  Anonymizer(
    rng: initRand(computeSeed(opts)),
    preserveNull: opts.preserveNull,
    consistent: newJObject()
  )

proc readInput(path: string): string =
  if path.len > 0:
    readFile(path)
  else:
    stdin.readAll()

proc writeOutput(path, content: string) =
  if path.len > 0:
    let f = open(path, fmWrite)
    f.write(content)
    f.write('\n')
    f.close()
  else:
    stdout.write(content)
    stdout.write('\n')

# --- Parallel processing ---

const
  parallelMinElems = 32
  ## Cap workers to avoid glibc malloc contention with Nim's useMalloc mode.
  parallelMaxWorkers = 8

proc indentElement(s: string): string =
  ## Indent every line of a pretty-printed JSON element by 2 spaces.
  var res = newStringOfCap(s.len + s.count('\n') * 2 + 2)
  res.add("  ")
  for ch in s:
    res.add(ch)
    if ch == '\n':
      res.add("  ")
  # Trim any trailing whitespace added after the final newline.
  while res.len > 0 and res[^1] == ' ':
    res.setLen(res.len - 1)
  res

proc processChunk(state: ptr WorkerArgs) {.thread.} =
  ## Worker: parse → anonymize → write serialized output to state.output.
  let chunk = parseJson(state.jsonStr)
  let a = Anonymizer(
    rng: initRand(state.seed),
    preserveNull: state.preserveNull,
    consistent: newJObject()
  )
  let anon = a.anonymizeAt(chunk, @[], "")
  if state.pretty:
    var buf = newStringOfCap(state.jsonStr.len * 2)
    for i, elem in anon.elems:
      if i > 0: buf.add(",\n")
      buf.add(indentElement(elem.pretty()))
    state.output = buf
  else:
    # Write each element directly into buf (avoids $elem's tiny pre-allocation).
    var buf = newStringOfCap(state.jsonStr.len * 2)
    for i, elem in anon.elems:
      if i > 0: buf.add(',')
      toUgly(buf, elem)
    state.output = buf

proc anonymizeParallel(root: JsonNode; opts: Options; seed: int64): string =
  ## Split root JArray across CPU cores, anonymize in parallel, reassemble.
  let n = root.len
  let nWorkers = max(1, min(parallelMaxWorkers, min(countProcessors(), n)))
  let chunkSize = (n + nWorkers - 1) div nWorkers

  # Pre-allocate all worker state slots before spawning (stable addresses).
  var states: seq[WorkerArgs]
  var nChunks = 0
  var i = 0
  while i < n:
    let endIdx = min(i + chunkSize, n)
    var chunk = newJArray()
    for j in i ..< endIdx:
      chunk.add(root.elems[j])
    let w = int64(nChunks + 1)
    let workerSeed = seed xor w xor (w shl 32)
    states.add(WorkerArgs(
      jsonStr: $chunk,
      seed: workerSeed,
      preserveNull: opts.preserveNull,
      pretty: opts.pretty
    ))
    i = endIdx
    inc nChunks

  var threads = newSeq[Thread[ptr WorkerArgs]](nChunks)
  for idx in 0 ..< nChunks:
    createThread(threads[idx], processChunk, addr states[idx])
  for idx in 0 ..< nChunks:
    joinThread(threads[idx])

  var parts = newSeqOfCap[string](nChunks)
  for idx in 0 ..< nChunks:
    if states[idx].output.len > 0:
      parts.add(states[idx].output)

  if opts.pretty:
    "[\n" & parts.join(",\n") & "\n]"
  else:
    "[" & parts.join(",") & "]"

when isMainModule:
  try:
    let opts = parseOptions()
    let input = readInput(opts.inputPath)
    let root = parseJson(input)
    let seed = computeSeed(opts)

    let output =
      if root.kind == JArray and root.len >= parallelMinElems and countProcessors() > 1:
        anonymizeParallel(root, opts, seed)
      else:
        let a = Anonymizer(rng: initRand(seed), preserveNull: opts.preserveNull,
                           consistent: newJObject())
        let anon = a.anonymizeAt(root, @[], "")
        if opts.pretty: anon.pretty() else: $anon

    writeOutput(opts.outputPath, output)
  except CatchableError as e:
    stderr.writeLine("error: " & e.msg)
    quit(1)

