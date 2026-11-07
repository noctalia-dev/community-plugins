# Shares Noctalia's settings.toml between devices, one setting at a time. settings.sh runs it:
#   awk -f settings.awk -v mine=<file> -v theirs=<file> -v base=<file> -v out=<folder>
# <mine> is this device's settings.toml, <theirs> the other devices' shared settings and
# <base> the shared settings this device last agreed on; a missing file counts as empty.
# It writes <out>/shared, the new shared settings; <out>/local, the settings of <mine> that
# stay on this device; and <out>/settings, this device's new settings.toml, when it takes a
# setting from the others. It prints "taken <number>" and "count <number>".
#
# Each setting is a leaf: its path, the keys joined by dots, and its value as TOML text on
# one line, written the same way whatever file it came from. The reader knows the TOML that
# Noctalia writes: tables, lists of tables, strings, numbers, booleans, lists and inline
# tables. Anything else stops it, so a setting is never lost.

BEGIN {
  RESURRECT = "plugin_settings.\"omerfuyar/resurrect\""
  MONITOR = "^(eDP|DP|HDMI|DVI|VGA|LVDS|DSI|Virtual|HEADLESS|USB)(-[A-Z])?-[0-9]+$"
  NAMES_MONITOR = "(^|[@:_.-])(eDP|DP|HDMI|DVI|VGA|LVDS|DSI)(-[A-Z])?-[0-9]+($|[@:_.-])"
  FOLDER_SOURCE = "(^\\{ |, )kind = \"path\"(, | \\})"
  ESCAPE["b"] = "\\u0008"
  ESCAPE["t"] = "\\u0009"
  ESCAPE["n"] = "\\u000a"
  ESCAPE["f"] = "\\u000c"
  ESCAPE["r"] = "\\u000d"
  for (i = 1; i < 32; i++) CONTROL[sprintf("%c", i)] = sprintf("\\u%04x", i)
  CONTROL[sprintf("%c", 127)] = "\\u007f"

  parse("mine", slurp(mine))
  parse("theirs", slurp(theirs))
  parse("base", slurp(base))
  classify("mine")
  classify("theirs")
  classify("base")
  merge()

  shared = dump(MERGED, MERGED_LIST, merged_count)
  check(shared, MERGED, MERGED_LIST, merged_count)
  printf "%s", shared >(out "/shared")
  close(out "/shared")

  local_count = 0
  for (i = 1; i <= COUNT["mine"]; i++) {
    path = LEAVES["mine", i]
    if (("mine", path) in LOCAL) {
      LOCAL_VALUES[path] = LOCAL["mine", path]
      LOCAL_LIST[++local_count] = path
    }
  }
  text = dump(LOCAL_VALUES, LOCAL_LIST, local_count)
  check(text, LOCAL_VALUES, LOCAL_LIST, local_count)
  printf "%s", text >(out "/local")
  close(out "/local")

  if (taken > 0) {
    result()
    if (!same_leaves(RESULT, RESULT_LIST, result_count, "mine")) {
      text = dump(RESULT, RESULT_LIST, result_count)
      check(text, RESULT, RESULT_LIST, result_count)
      printf "%s", text >(out "/settings")
      close(out "/settings")
    }
  }
  print "taken " taken
  print "count " merged_count
}

function fail(message) {
  print "settings.awk: " message >"/dev/stderr"
  exit 1
}

function slurp(file,   text, line) {
  text = ""
  if (file == "") return text
  while ((getline line <file) > 0) text = text line "\n"
  close(file)
  return text
}

# Reading. The text is in TEXT, read from position AT to SIZE.

function where(   before) {
  before = substr(TEXT, 1, AT)
  return "line " (gsub(/\n/, "", before) + 1)
}

function expect(token) {
  if (substr(TEXT, AT, length(token)) != token) fail("expected " token " at " where())
  AT += length(token)
}

# Skips spaces and tabs.
function skip_space(   c) {
  while (AT <= SIZE) {
    c = substr(TEXT, AT, 1)
    if (c != " " && c != "\t") return
    AT++
  }
}

# Skips spaces, tabs, line ends and comments.
function skip_blank(   c) {
  while (AT <= SIZE) {
    c = substr(TEXT, AT, 1)
    if (c == "#") {
      while (AT <= SIZE && substr(TEXT, AT, 1) != "\n") AT++
    } else if (c == " " || c == "\t" || c == "\r" || c == "\n") {
      AT++
    } else {
      return
    }
  }
}

# Ends a line: only a comment may follow.
function line_end(   c) {
  skip_space()
  if (substr(TEXT, AT, 1) == "#") while (AT <= SIZE && substr(TEXT, AT, 1) != "\n") AT++
  if (substr(TEXT, AT, 1) == "\r") AT++
  if (AT <= SIZE && substr(TEXT, AT, 1) != "\n") fail("unexpected text at " where())
  AT++
}

# A key as it is written in the output: bare when it can be, else quoted.
function key_text(name) {
  return name ~ /^[A-Za-z0-9_-]+$/ ? name : "\"" name "\""
}

# Reads one key. Sets KEY_NAME to its name, escaped as in a quoted key, and returns it as
# the output writes it.
function read_key(   start) {
  if (substr(TEXT, AT, 1) == "\"") {
    KEY_NAME = read_basic()
  } else if (substr(TEXT, AT, 1) == "'") {
    KEY_NAME = read_literal()
  } else {
    start = AT
    while (AT <= SIZE && substr(TEXT, AT, 1) ~ /[A-Za-z0-9_-]/) AT++
    if (AT == start) fail("expected a key at " where())
    KEY_NAME = substr(TEXT, start, AT - start)
  }
  return key_text(KEY_NAME)
}

# Reads a dotted key and returns it, relative to table <table>. With <record>, each path
# it names is recorded with its parent, its key and its name.
function read_path(table, record,   relative, path, key, parent) {
  relative = ""
  path = table
  skip_space()
  while (1) {
    key = read_key()
    relative = relative == "" ? key : relative "." key
    if (record) {
      parent = path
      path = path == "" ? key : path "." key
      PARENT[path] = parent
      KEY[path] = key
      NAME[path] = KEY_NAME
      DEPTH[path] = DEPTH[parent] + 1
      FIRST[path] = parent == "" ? KEY_NAME : FIRST[parent]
    }
    skip_space()
    if (substr(TEXT, AT, 1) != ".") return relative
    AT++
    skip_space()
  }
}

# One character of a string, escaped as the output writes it.
function plain(c) {
  if (c in CONTROL) return CONTROL[c]
  if (c == "\\" || c == "\"") return "\\" c
  return c
}

# Reads an escape sequence in a basic string.
function read_escape(   e) {
  e = substr(TEXT, AT + 1, 1)
  if (e == "\"" || e == "\\") {
    AT += 2
    return "\\" e
  }
  if (e in ESCAPE) {
    AT += 2
    return ESCAPE[e]
  }
  if (e == "u") {
    AT += 6
    return "\\u" tolower(substr(TEXT, AT - 4, 4))
  }
  if (e == "U") {
    AT += 10
    return "\\U" tolower(substr(TEXT, AT - 8, 8))
  }
  fail("unknown escape at " where())
}

# Reads a basic string, one line or several; returns its text between the quotes.
function read_basic(   text, c, many) {
  many = (substr(TEXT, AT, 3) == "\"\"\"")
  if (many) {
    AT += 3
    if (substr(TEXT, AT, 1) == "\n") AT++
    else if (substr(TEXT, AT, 2) == "\r\n") AT += 2
  } else {
    AT++
  }
  text = ""
  while (1) {
    if (AT > SIZE) fail("a string does not end")
    if (many && substr(TEXT, AT, 3) == "\"\"\"") {
      AT += 3
      return text
    }
    c = substr(TEXT, AT, 1)
    if (!many && c == "\"") {
      AT++
      return text
    }
    if (c == "\\") {
      if (many && substr(TEXT, AT + 1, 1) ~ /[ \t\r\n]/) fail("a line-ending backslash at " where())
      text = text read_escape()
    } else if (c == "\n" && !many) {
      fail("a string does not end at " where())
    } else {
      text = text plain(c)
      AT++
    }
  }
}

# Reads a literal string, one line or several; returns its text as a basic string has it.
function read_literal(   text, c, many) {
  many = (substr(TEXT, AT, 3) == "'''")
  if (many) {
    AT += 3
    if (substr(TEXT, AT, 1) == "\n") AT++
    else if (substr(TEXT, AT, 2) == "\r\n") AT += 2
  } else {
    AT++
  }
  text = ""
  while (1) {
    if (AT > SIZE) fail("a string does not end")
    if (many && substr(TEXT, AT, 3) == "'''") {
      AT += 3
      return text
    }
    c = substr(TEXT, AT, 1)
    if (!many && c == "'") {
      AT++
      return text
    }
    if (c == "\n" && !many) fail("a string does not end at " where())
    text = text plain(c)
    AT++
  }
}

# Reads a value and returns it as the output writes it.
function read_value(   c, start, word) {
  skip_space()
  c = substr(TEXT, AT, 1)
  if (c == "\"") return "\"" read_basic() "\""
  if (c == "'") return "\"" read_literal() "\""
  if (c == "[") return read_list()
  if (c == "{") return read_inline()
  start = AT
  while (AT <= SIZE && substr(TEXT, AT, 1) ~ /[A-Za-z0-9_.:+-]/) AT++
  word = substr(TEXT, start, AT - start)
  if (word == "true" || word == "false" || is_number(word)) return word
  fail("unknown value " word " at " where())
}

function is_number(word) {
  return word ~ /^[-+]?(0|[1-9][0-9_]*)(\.[0-9][0-9_]*)?([eE][-+]?[0-9][0-9_]*)?$/ ||
    word ~ /^0x[0-9A-Fa-f_]+$/ || word ~ /^0o[0-7_]+$/ || word ~ /^0b[01_]+$/ ||
    word ~ /^[-+]?(inf|nan)$/
}

function is_float(word) {
  if (word ~ /^0[xob]/) return 0
  return word ~ /[.eE]/ || word ~ /^[-+]?(inf|nan)$/
}

function read_list(   text, c) {
  AT++
  text = ""
  while (1) {
    skip_blank()
    if (substr(TEXT, AT, 1) == "]") {
      AT++
      return "[" text "]"
    }
    text = text (text == "" ? "" : ", ") read_value()
    skip_blank()
    c = substr(TEXT, AT, 1)
    if (c == ",") {
      AT++
    } else if (c != "]") {
      fail("expected , or ] at " where())
    }
  }
}

function read_inline(   text, key, c) {
  AT++
  text = ""
  while (1) {
    skip_blank()
    if (substr(TEXT, AT, 1) == "}") {
      AT++
      return text == "" ? "{}" : "{ " text " }"
    }
    key = read_path("", 0)
    expect("=")
    text = text (text == "" ? "" : ", ") key " = " read_value()
    skip_blank()
    c = substr(TEXT, AT, 1)
    if (c == ",") {
      AT++
    } else if (c != "}") {
      fail("expected , or } at " where())
    }
  }
}

# Records leaf <path> of file <tag> with value <value>. An inline table is split into its
# leaves, as a table is.
function leaf(tag, path, value,   text) {
  if (substr(value, 1, 1) == "{") {
    split_inline(tag, path, value)
    return
  }
  if ((tag, path) in VALUE) fail("setting " path " is there twice")
  VALUE[tag, path] = value
  LEAVES[tag, ++COUNT[tag]] = path
  # A table with a monitor's name as a value belongs to this device.
  if (substr(value, 1, 1) == "\"") {
    text = substr(value, 2, length(value) - 2)
    if (text ~ MONITOR) HAS_MONITOR[tag, PARENT[path]] = 1
  }
}

function split_inline(tag, path, value,   text, at, size, key) {
  text = TEXT
  at = AT
  size = SIZE
  TEXT = value
  AT = 2
  SIZE = length(value)
  while (1) {
    skip_space()
    if (substr(TEXT, AT, 1) == "}") break
    key = read_path(path, 1)
    expect("=")
    leaf(tag, path "." key, read_value())
    skip_space()
    if (substr(TEXT, AT, 1) == ",") AT++
  }
  TEXT = text
  AT = at
  SIZE = size
}

# Reads TOML text <text> as file <tag>.
function parse(tag, text,   table, list, item, in_item, key, i, lists, list_count) {
  TEXT = text
  AT = 1
  SIZE = length(text)
  COUNT[tag] = 0
  table = ""
  in_item = 0
  while (1) {
    skip_blank()
    if (AT > SIZE) break
    if (substr(TEXT, AT, 2) == "[[") {
      if (in_item) ITEMS[tag, list] = ITEMS[tag, list] (ITEMS[tag, list] == "" ? "" : ", ") item_text(item)
      AT += 2
      list = read_path("", 1)
      expect("]]")
      line_end()
      if (!((tag, list) in ITEMS)) {
        ITEMS[tag, list] = ""
        lists = lists "\n" list
      }
      item = ""
      in_item = 1
    } else if (substr(TEXT, AT, 1) == "[") {
      if (in_item) ITEMS[tag, list] = ITEMS[tag, list] (ITEMS[tag, list] == "" ? "" : ", ") item_text(item)
      in_item = 0
      AT++
      table = read_path("", 1)
      expect("]")
      line_end()
    } else if (in_item) {
      key = read_path("", 0)
      expect("=")
      item = item (item == "" ? "" : ", ") key " = " read_value()
      line_end()
    } else {
      key = read_path(table, 1)
      expect("=")
      leaf(tag, table == "" ? key : table "." key, read_value())
      line_end()
    }
  }
  if (in_item) ITEMS[tag, list] = ITEMS[tag, list] (ITEMS[tag, list] == "" ? "" : ", ") item_text(item)
  # Each list of tables is one leaf, a list of inline tables.
  list_count = split(substr(lists, 2), LIST_NAMES, "\n")
  for (i = 1; i <= list_count; i++) leaf(tag, LIST_NAMES[i], "[" ITEMS[tag, LIST_NAMES[i]] "]")
}

function item_text(item) {
  return item == "" ? "{}" : "{ " item " }"
}

# Comparing.

# Splits value <text> into TOKENS; returns their number.
function tokens(text, TOKENS,   n, at, size, c, start) {
  n = 0
  at = 1
  size = length(text)
  while (at <= size) {
    c = substr(text, at, 1)
    if (c == " ") {
      at++
    } else if (c ~ /[][{},=]/) {
      TOKENS[++n] = c
      at++
    } else if (c == "\"") {
      start = at++
      while (at <= size && substr(text, at, 1) != "\"") at += substr(text, at, 1) == "\\" ? 2 : 1
      TOKENS[++n] = substr(text, start, ++at - start)
    } else {
      start = at
      while (at <= size && substr(text, at, 1) !~ /[][{},= ]/) at++
      TOKENS[++n] = substr(text, start, at - start)
    }
  }
  return n
}

function number(word) {
  gsub(/_/, "", word)
  return word + 0
}

# Two floats are the same when they are close: Noctalia stores widget positions as floats.
function close_floats(a, b,   x, y, d) {
  if (!is_number(a) || !is_number(b) || !is_float(a) || !is_float(b)) return 0
  if (a ~ /inf|nan/ || b ~ /inf|nan/) return 0
  x = number(a)
  y = number(b)
  d = x > y ? x - y : y - x
  if (x < 0) x = -x
  if (y < 0) y = -y
  return d <= 1e-6 * (x > y ? x : y)
}

function same(a, b,   na, nb, i) {
  if ((a "") == (b "")) return 1
  na = tokens(a, SAME_A)
  nb = tokens(b, SAME_B)
  if (na != nb) return 0
  for (i = 1; i <= na; i++) {
    if (SAME_A[i] != SAME_B[i] && !close_floats(SAME_A[i], SAME_B[i])) return 0
  }
  return 1
}

# Splits list <text> into its items, in LIST_ITEMS; returns their number.
function items(text, LIST_ITEMS,   n, at, size, c, depth, start, quoted) {
  split("", LIST_ITEMS)
  n = 0
  size = length(text) - 1
  if (substr(text, 1, 1) != "[" || size < 2) return 0
  depth = 0
  quoted = 0
  start = 2
  for (at = 2; at <= size; at++) {
    c = substr(text, at, 1)
    if (quoted) {
      if (c == "\\") at++
      else if (c == "\"") quoted = 0
    } else if (c == "\"") {
      quoted = 1
    } else if (c == "[" || c == "{") {
      depth++
    } else if (c == "]" || c == "}") {
      depth--
    } else if (c == "," && depth == 0) {
      LIST_ITEMS[++n] = trim(substr(text, start, at - start))
      start = at + 1
    }
  }
  LIST_ITEMS[++n] = trim(substr(text, start, size + 1 - start))
  return n
}

function trim(text) {
  sub(/^ +/, "", text)
  sub(/ +$/, "", text)
  return text
}

function join(LIST_ITEMS, n,   text, i) {
  text = ""
  for (i = 1; i <= n; i++) text = text (i > 1 ? ", " : "") LIST_ITEMS[i]
  return "[" text "]"
}

# Sharing.

# True for a table that holds settings of this device only, in file <tag>.
function is_local(tag, table,   r) {
  if ((tag, table) in LOCAL_TABLE) return LOCAL_TABLE[tag, table]
  if (table == "") r = ((tag, "") in HAS_MONITOR)
  else if (is_local(tag, PARENT[table])) r = 1
  else if (DEPTH[table] == 1 && (NAME[table] == "brightness" || NAME[table] == "battery")) r = 1
  else if (FIRST[table] == "wallpaper") r = 0
  else r = (NAME[table] ~ NAMES_MONITOR) || ((tag, table) in HAS_MONITOR)
  LOCAL_TABLE[tag, table] = r
  return r
}

# Puts each leaf of file <tag> in SHARED or in LOCAL.
function classify(tag,   i, path, value, n, k, shared, local) {
  for (i = 1; i <= COUNT[tag]; i++) {
    path = LEAVES[tag, i]
    value = VALUE[tag, path]
    if (is_local(tag, PARENT[path]) ||
      PARENT[path] == RESURRECT && (NAME[path] == "share" || NAME[path] == "device_files")) {
      LOCAL[tag, path] = value
    } else if (path == "plugins.source" && substr(value, 1, 1) == "[") {
      # Plugin sources that are folders on this device stay here.
      n = items(value, SOURCES)
      shared = local = ""
      for (k = 1; k <= n; k++) {
        if (SOURCES[k] ~ FOLDER_SOURCE) local = local (local == "" ? "" : ", ") SOURCES[k]
        else shared = shared (shared == "" ? "" : ", ") SOURCES[k]
      }
      SHARED[tag, path] = "[" shared "]"
      if (local != "") LOCAL[tag, path] = "[" local "]"
    } else {
      SHARED[tag, path] = value
    }
  }
}

# Whether setting <path> is the same in files <a> and <b>; missing in both counts as the same.
function agree(a, b, path,   in_a, in_b) {
  in_a = ((a, path) in SHARED)
  in_b = ((b, path) in SHARED)
  if (!in_a || !in_b) return !in_a && !in_b
  return same(SHARED[a, path], SHARED[b, path])
}

function shared_value(tag, path) {
  return (tag, path) in SHARED ? SHARED[tag, path] : ""
}

# Plugins enabled on either side are in, those turned off on either side are out.
function merge_list(path,   nm, nt, nb, i, n, removed) {
  nm = items(shared_value("mine", path), MINE_ITEMS)
  nt = items(shared_value("theirs", path), THEIR_ITEMS)
  nb = items(shared_value("base", path), BASE_ITEMS)
  split("", REMOVED)
  for (i = 1; i <= nb; i++) {
    if (!contains(MINE_ITEMS, nm, BASE_ITEMS[i]) || !contains(THEIR_ITEMS, nt, BASE_ITEMS[i])) {
      REMOVED[BASE_ITEMS[i]] = 1
    }
  }
  n = 0
  split("", OUT_ITEMS)
  for (i = 1; i <= nt; i++) if (!(THEIR_ITEMS[i] in REMOVED)) OUT_ITEMS[++n] = THEIR_ITEMS[i]
  for (i = 1; i <= nm; i++) {
    if (!(MINE_ITEMS[i] in REMOVED) && !contains(OUT_ITEMS, n, MINE_ITEMS[i])) OUT_ITEMS[++n] = MINE_ITEMS[i]
  }
  return join(OUT_ITEMS, n)
}

# Whether lists <a> and <b> hold the same items, in any order.
function same_items(a, b,   na, nb, i) {
  na = items(a, SAME_ITEMS_A)
  nb = items(b, SAME_ITEMS_B)
  if (na != nb) return 0
  for (i = 1; i <= na; i++) if (!contains(SAME_ITEMS_B, nb, SAME_ITEMS_A[i])) return 0
  for (i = 1; i <= nb; i++) if (!contains(SAME_ITEMS_A, na, SAME_ITEMS_B[i])) return 0
  return 1
}

function contains(LIST_ITEMS, n, item,   i) {
  for (i = 1; i <= n; i++) if (LIST_ITEMS[i] == item) return 1
  return 0
}

# Compares each shared setting in its three versions: this device's, theirs and the base.
# One that only another device changed is taken; otherwise this device's value stays.
function merge(   tags, t, i, path, has, value, seen) {
  taken = 0
  merged_count = 0
  split("mine theirs base", tags, " ")
  for (t = 1; t <= 3; t++) {
    for (i = 1; i <= COUNT[tags[t]]; i++) {
      path = LEAVES[tags[t], i]
      if (!((tags[t], path) in SHARED) || path in seen) continue
      seen[path] = 1
      if (path == "plugins.enabled") {
        value = merge_list(path)
        has = 1
        # The same plugins in another order are not a change: this device's order stays.
        if (("mine", path) in SHARED && same_items(value, SHARED["mine", path])) value = SHARED["mine", path]
        else taken++
      } else if (!(("base", path) in SHARED) && ("theirs", path) in SHARED && !agree("mine", "theirs", path)) {
        # Shared for the first time here: the value another device shared first wins.
        has = 1
        value = SHARED["theirs", path]
        taken++
      } else if (agree("mine", "theirs", path) || agree("theirs", "base", path) || !agree("mine", "base", path)) {
        has = (("mine", path) in SHARED)
        value = shared_value("mine", path)
      } else {
        has = (("theirs", path) in SHARED)
        value = shared_value("theirs", path)
        taken++
      }
      if (has) {
        MERGED[path] = value
        MERGED_LIST[++merged_count] = path
      }
    }
  }
}

# This device's new settings: the merged ones, and those that stay here.
function result(   i, path) {
  result_count = 0
  for (i = 1; i <= merged_count; i++) {
    path = MERGED_LIST[i]
    RESULT[path] = MERGED[path]
    RESULT_LIST[++result_count] = path
  }
  for (i = 1; i <= COUNT["mine"]; i++) {
    path = LEAVES["mine", i]
    if (!(("mine", path) in LOCAL)) continue
    if (!(path in RESULT)) RESULT_LIST[++result_count] = path
    if (path == "plugins.source" && path in MERGED) {
      RESULT[path] = join_lists(MERGED[path], LOCAL["mine", path])
    } else {
      RESULT[path] = LOCAL["mine", path]
    }
  }
}

function join_lists(a, b) {
  if (a == "[]") return b
  return substr(a, 1, length(a) - 1) ", " substr(b, 2)
}

# Whether leaves LIST in VALUES are exactly the leaves of file <tag>.
function same_leaves(VALUES, LIST, n, tag,   i) {
  if (n != COUNT[tag]) return 0
  for (i = 1; i <= n; i++) {
    if (!((tag, LIST[i]) in VALUE) || !same(VALUES[LIST[i]], VALUE[tag, LIST[i]])) return 0
  }
  return 1
}

# Writing.

# TOML text for leaves LIST in VALUES, each table's leaves under its header, in a fixed order.
function dump(VALUES, LIST, n,   i, path, text, table, started) {
  split("", ORDER)
  for (i = 1; i <= n; i++) ORDER[i] = LIST[i]
  sort(ORDER, 1, n)
  text = ""
  started = 0
  for (i = 1; i <= n; i++) {
    path = ORDER[i]
    if (!started || PARENT[path] != table) {
      started = 1
      table = PARENT[path]
      if (table != "") text = text (text == "" ? "" : "\n") "[" table "]\n"
    }
    text = text KEY[path] " = " VALUES[path] "\n"
  }
  return text
}

function sort(A, left, right,   i, last, middle) {
  if (left >= right) return
  middle = int((left + right) / 2)
  swap(A, left, middle)
  last = left
  for (i = left + 1; i <= right; i++) if (sorts_before(A[i], A[left])) swap(A, ++last, i)
  swap(A, left, last)
  sort(A, left, last - 1)
  sort(A, last + 1, right)
}

# Leaves sort by table, then by key, so each table's leaves stay together in any locale.
function sorts_before(a, b) {
  if (PARENT[a] != PARENT[b]) return PARENT[a] "" < PARENT[b] ""
  return KEY[a] "" < KEY[b] ""
}

function swap(A, i, j,   t) {
  t = A[i]
  A[i] = A[j]
  A[j] = t
}

# Reads <text> back and stops unless it holds exactly leaves LIST in VALUES.
function check(text, VALUES, LIST, n,   tag) {
  tag = "check" ++checks
  parse(tag, text)
  if (!same_leaves(VALUES, LIST, n, tag)) fail("the written settings do not read back the same")
}
