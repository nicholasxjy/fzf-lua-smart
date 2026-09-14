local port = require("fzf-lua-smart.vendor.matcher")
local upstream = require("snacks.picker.core.matcher")
local queries = {
  "",
  "a",
  "aa",
  "aba",
  "init",
  "Init",
  "FOO",
  "^foo",
  "foo$",
  "'foo",
  "'foo'",
  "!foo",
  "foo bar",
  "foo | bar",
  "foo | bar baz",
  "!foo | bar",
  "^foo$",
  "file:lua",
  "buf:12",
  "xx:!foo",
  "file:!lua",
  "src/init.lua:12:3",
  "init.lua:12",
  "init.lua:",
  "init.lua::",
  "测试",
  "é",
  ".",
  "\\",
  "a | | b",
  "  foo   bar  ",
  "!",
  "'",
  "foo | !bar baz",
  "a:1",
  "file:^src",
  "foo\\ bar",
}
local texts = {
  "",
  "foo",
  "Foo",
  "FOO",
  "fooBar",
  "foo bar",
  "foobar",
  "bar foo",
  "aabacaba",
  "alpha.lua",
  "src/init.lua",
  "src/Init.lua",
  "tests/foo_spec.lua",
  "a/foo",
  "测试/文件.lua",
  "café.lua",
  "foo\\bar",
  "a::1",
  "foo_bar",
  "foo-bar",
  "x foo bar x",
  "foo foo foo",
  "/work-other/foo.lua",
}
test("matcher differential: queries, scores, fields, file positions and byte highlights", function()
  local combinations = {
    {},
    { fuzzy = false },
    { smartcase = false, ignorecase = false },
    { smartcase = false },
    { filename_bonus = true },
    { filename_bonus = false, history_bonus = true },
    { cwd_bonus = true },
    { regex = true },
    { file_pos = false },
  }
  local count = 0
  for _, options in ipairs(combinations) do
    options.frecency = false
    local a, b = port.new(options), upstream.new(options)
    a.cwd, b.cwd = "/work", "/work"
    for _, query in ipairs(queries) do
      a:init(query)
      b:init(query)
      eq(a.mods, b.mods)
      eq(a.file, b.file)
      for i, text in ipairs(texts) do
        local item = {
          text = text,
          file = text,
          idx = i,
          score = 1000,
          buf = 12,
          score_add = i % 3 == 0 and 1.5 or nil,
          score_mul = i % 4 == 0 and 0.75 or nil,
        }
        local ia, ib = vim.deepcopy(item), vim.deepcopy(item)
        eq(a:update({}, ia), b:update({}, ib), query .. " / " .. text)
        eq(ia, ib, query .. " item / " .. text)
        eq(a:positions(ia), b:positions(ib), query .. " positions / " .. text)
        count = count + 1
      end
    end
  end
  print("  exact differential comparisons: " .. count)
end)
test("sort differential: complete order, booleans, missing fields and raw text length", function()
  local configs = {
    { fields = { "score:desc", "#text", "idx" } },
    { fields = { "recent", "idx:desc" } },
    { fields = { { name = "score", desc = true }, "#text:asc" } },
    { fields = {} },
  }
  for _, config in ipairs(configs) do
    local a, b = {}, {}
    for i = 1, 400 do
      a[i] = { idx = i, score = i % 7, text = texts[i % #texts + 1], recent = i % 2 == 0 }
    end
    b = vim.deepcopy(a)
    table.sort(a, require("fzf-lua-smart.vendor.sort").default(config))
    table.sort(b, require("snacks.picker.sort").default(config))
    eq(a, b)
  end
end)
test("matcher pinned quirks: cwd prefix and file_pos=false still parses locations", function()
  local m = port.new({ frecency = false, cwd_bonus = true, file_pos = false })
  m.cwd = "/work"
  local item = { text = "/work-other/x", file = "/work-other/x" }
  m:update({}, item)
  eq(item.score, 1010)
  m:init("x.lua:3:2")
  eq(m.file.pos, { 3, 2 })
end)
test("full logical sort differential with >1000 entries and frozen frecency", function()
  local a = port.new({ frecency = false, cwd_bonus = true, filename_bonus = true })
  local b = upstream.new({ frecency = false, cwd_bonus = true, filename_bonus = true })
  a.cwd, b.cwd = "/work", "/work"
  local history = {
    get = function(_, item)
      return item.idx % 23 / 7
    end,
  }
  a.frecency, b.frecency = history, history
  local ia, ib = {}, {}
  a:init("lua")
  b:init("lua")
  for i = 1, 3000 do
    local item = {
      text = ("src/file%04d.lua"):format(3001 - i),
      file = ("src/file%04d.lua"):format(3001 - i),
      cwd = "/work",
      idx = i,
      score = 1000,
    }
    local other = vim.deepcopy(item)
    assert(a:update({}, item))
    assert(b:update({}, other))
    ia[i], ib[i] = item, other
  end
  local fields = { fields = { "score:desc", "#text", "idx" } }
  require("fzf-lua-smart.task").sort(ia, require("fzf-lua-smart.vendor.sort").default(fields), function() end)
  table.sort(ib, require("snacks.picker.sort").default(fields))
  eq(ia, ib)
  -- Deliberate, user-approved difference from Snacks list UI's topk tail.
  local heap =
    require("snacks.picker.util.minheap").new({ capacity = 1000, cmp = require("snacks.picker.sort").default(fields) })
  for _, item in ipairs(ib) do
    heap:add(item)
  end
  eq(heap:get(1001), nil)
end)
test("full sorter deliberately preserves enumeration order for comparator ties", function()
  local items = { { idx = 1 }, { idx = 2 }, { idx = 3 } }
  require("fzf-lua-smart.task").sort(items, function()
    return false
  end, function() end)
  eq(
    vim.tbl_map(function(i)
      return i.idx
    end, items),
    { 1, 2, 3 }
  )
end)
