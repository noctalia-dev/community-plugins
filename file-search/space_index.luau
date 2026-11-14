--!nonstrict
--[[
  space_index.luau - pure logic of the Space tab: category table, entry lists,
  sorting, donut slices and node navigation. No host globals: a plain module
  (ends with `return idx`), unit-tested by tests/space_index_test.lua.

  Decoded index node:  { n = name, s = bytes, f = loose file bytes,
                         u = unreadable folders in the subtree,
                         nf = files (non-folder entries) in the subtree,
                         c = { 8 bytes per category }, d = { child nodes },
                         t = { { n, s, k = category } } top files, leaf = true? }
  t[i].n is a path relative to the node ("sub/dir/file.mkv"), not a bare name.

  EXT below is the ONE extension table. The jq program that builds the index
  is generated from it and is the only place that assigns a file its category
  (last extension, case-insensitive). Any extension not listed, no extension
  or a dotfile is category 8 (other).

  On disk the index is JSON Lines (see jqProgram); space.luau rebuilds this
  nested shape from it.

  Index build: jqProgram(6, 10, 1048576, 0.0005) = depth 6, top 10 files per
  category, a folder is folded when under 1 MiB or under 0.05% of its parent.
  The user sees these folders in "(files and small folders)". Fewer than N
  files in a list means the list is complete.
  Tested by tests/space_jq_test.sh on tests/fixtures/small.ncdu.json.

  Slice colour index: in folders mode it is the rank of the folder among the
  shown slices (biggest first), so two shown slices never share a colour; in
  types mode it is the category number. Loose and "other" slices have none
  (the panel paints them grey). A slice carries its node, so the list can
  give its row the same colour.
]]

local idx = {}

idx.CATEGORIES = { "video", "images", "audio", "archives", "documents", "code", "packages", "other" }

-- Same fixed palettes as usage.luau, so a category keeps its colour.
idx.COLORS_DARK = {
    "#7aa2f7", "#9ece6a", "#e0af68", "#f7768e",
    "#bb9af7", "#2ac3de", "#ff9e64", "#73daca",
}
idx.COLORS_LIGHT = {
    "#3b5fc0", "#4f8a2b", "#b07708", "#c2405a",
    "#7c4dbd", "#0e7490", "#c25a12", "#2f8f7a",
}

-- category number -> lower-case extensions (no dot)
idx.EXT = {
    { "mkv", "mp4", "avi", "mov", "webm", "m4v", "wmv", "flv" },
    { "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "raw" },
    { "mp3", "flac", "wav", "ogg", "opus", "m4a", "aac" },
    { "zip", "tar", "gz", "xz", "bz2", "zst", "7z", "rar", "tgz" },
    { "pdf", "doc", "docx", "odt", "xls", "xlsx", "ods", "ppt", "pptx", "txt", "md", "epub" },
    { "lua", "luau", "py", "js", "ts", "c", "h", "cpp", "hpp", "rs", "go", "java", "sh", "json", "toml", "yaml", "yml" },
    { "deb", "rpm", "pkg", "apk", "appimage", "iso", "img", "jar", "whl" },
}

function idx.child(node, name)
    for _, d in ipairs(node.d or {}) do
        if d.n == name then return d end
    end
    return nil
end

-- Folders view (also types view with no category selected): sub-folders plus
-- one "loose" row for files directly inside. With a category in types mode:
-- that category's top files only.
function idx.entries(node, mode, category)
    local out = {}
    if mode == "types" and category then
        for _, f in ipairs(node.t or {}) do
            if f.k == category then
                table.insert(out, { name = f.n, bytes = f.s, kind = "file", category = category })
            end
        end
    else
        for _, d in ipairs(node.d or {}) do
            table.insert(out, { name = d.n, bytes = d.s, kind = "dir", node = d, files = d.nf })
        end
        if (node.f or 0) > 0 then
            local kept = 0
            for _, d in ipairs(node.d or {}) do kept += d.nf or 0 end
            table.insert(out, { name = "", bytes = node.f, kind = "loose", files = (node.nf or 0) - kept })
        end
    end
    return idx.sort(out, "size", true)
end

-- The folder part ("a/b/", up to the last "/") shared by the names of
-- entries[1..count]; "" when they share none.
function idx.commonDir(entries, count)
    if count < 1 then return "" end
    local prefix = entries[1].name:match("^(.*/)") or ""
    for i = 2, count do
        local name = entries[i].name
        while prefix ~= "" and name:sub(1, #prefix) ~= prefix do
            prefix = prefix:sub(1, -2):match("^(.*/)") or ""
        end
    end
    return prefix
end

-- key: "size" (bytes), "name" (last path segment) or "path" (the whole
-- relative name); name and path ignore case. Ties: full name, then the
-- original position.
local function sortValue(e, key)
    if key == "name" then return (e.name:match("[^/]*$")):lower() end
    if key == "path" then return e.name:lower() end
    return e.bytes
end

function idx.sort(entries, key, descending)
    local pos, val = {}, {}
    for i, e in ipairs(entries) do pos[e], val[e] = i, sortValue(e, key) end
    local out = table.clone(entries)
    table.sort(out, function(a, b)
        local x, y = val[a], val[b]
        if x ~= y then
            if descending then return x > y end
            return x < y
        end
        if a.name ~= b.name then return a.name < b.name end
        return pos[a] < pos[b]
    end)
    return out
end

-- jq program: `ncdu -o` JSON in, JSON Lines out (run with jq -c): a header
-- `{"v":4,"root":<name>}`, then one record per kept folder in pre-order,
-- `{"id":"0/2/1",n,s,f,u,nf,c,t,leaf?}`. id is the child-index path from the root
-- ("0"), so a record's parent is its id minus the last segment and no d is
-- written; children follow in node.d order.
-- ncdu: a folder is an array whose first item is its info object, a file is
-- an object; "excluded" entries are skipped. c and t cover
-- the whole subtree (t names are paths relative to the node, top topN per
-- category, ties by name). A folder's own dsize counts as a loose "other" byte.
-- Folders deeper than depth, under minBytes, or under relMin (a fraction) of
-- their parent's s go into the parent's f; c, t and u still count them.
-- u counts folders ncdu could not read ("read_error") in the whole subtree.
-- nf counts the files of the whole subtree, folded folders included: one per
-- name (a hard link or symlink counts each time), 0 for an unreadable folder.
-- A hard link counts dsize/nlink per name.
function idx.jqProgram(depth, topN, minBytes, relMin)
    local ext = {}
    for cat, list in ipairs(idx.EXT) do
        for _, e in ipairs(list) do table.insert(ext, string.format('"%s":%d', e, cat)) end
    end
    return string.format([=[
{%s} as $E
| def cat: split(".") as $p
    | if ($p | length) < 2 or (($p | length) == 2 and $p[0] == "") then 8
      else ($E[$p[-1] | ascii_downcase] // 8) end;
  def size: (.dsize // 0) as $d | if .hlnkc and (.nlink // 1) > 1 then ($d / .nlink | floor) else $d end;
  def node($lvl):
    (.[0] | size) as $own
    | [.[1:][] | select(type == "array") | node($lvl + 1)] as $kids
    | [.[1:][] | select(type == "object" and (.excluded | not)) | {n: .name, s: size, k: (.name | cat)}] as $files
    | ($own + ([$files[].s, $kids[].s] | add // 0)) as $s
    | (if $lvl < %d then [$kids[] | select(.s >= ([%d, %.6f * $s] | max))] else [] end) as $keep
    | {n: .[0].name, s: $s, f: ($s - ([$keep[].s] | add // 0)), d: $keep,
       nf: (($files | length) + ([$kids[].nf] | add // 0)),
       u: ((if .[0].read_error == true then 1 else 0 end) + ([$kids[].u] | add // 0)),
       c: (reduce $kids[].c as $x (reduce $files[] as $x ([0, 0, 0, 0, 0, 0, 0, $own]; setpath([$x.k - 1]; .[$x.k - 1] + $x.s));
             [range(8) as $j | .[$j] + $x[$j]])),
       t: ([$files[] | select(.s > 0)] + [$kids[] | .n as $p | .t[] | .n = $p + "/" + .n]
           | group_by(.k) | map(sort_by(-.s, .n) | .[:%d]) | add // [])}
    | if $lvl == %d then .leaf = true else . end;
  def flat($id): ({id: $id} + del(.d)), (.d | to_entries[] | .key as $k | .value | flat($id + "/" + ($k | tostring)));
  .[3] | node(0) | ({v: 4, root: .n}, flat("0"))
]=], table.concat(ext, ","), math.floor(depth), math.floor(minBytes), relMin, math.floor(topN), math.floor(depth))
end

-- Donut rows. folders: one per entry, biggest first; idx.slices gives a folder
-- the colour of its rank among the shown slices. types: one per non-empty
-- category, colour index = category number.
local function sliceRows(node, mode)
    local rows = {}
    if mode == "types" then
        for i = 1, 8 do
            local b = (node.c or {})[i] or 0
            if b > 0 then
                table.insert(rows, { name = idx.CATEGORIES[i], bytes = b, kind = "category", index = i })
            end
        end
        return idx.sort(rows, "size", true)
    end
    return idx.entries(node, "folders")
end

-- Top maxSlices-1 rows plus one "other" holding the rest (bytes sum to node.s).
function idx.slices(node, mode, maxSlices)
    local out = {}
    if (node.s or 0) <= 0 then return out end
    local list = sliceRows(node, mode)
    local kept = #list > maxSlices and maxSlices - 1 or #list
    local sum = 0
    for i = 1, kept do
        local e = list[i]
        sum += e.bytes
        local index = e.index or (e.kind == "dir" and i or nil)
        table.insert(out, {
            label = e.name, bytes = e.bytes, kind = e.kind, index = index, node = e.node,
            color = index and idx.COLORS_DARK[(index - 1) % 8 + 1] or nil,
        })
    end
    if node.s > sum then
        table.insert(out, { label = "other", bytes = node.s - sum, kind = "other" })
    end
    return out
end

return idx
