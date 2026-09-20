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
  "cC123",
  "cc123",
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
  "camelCase123.lua",
  "camel_case123.lua",
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
  }
  local generic = require("snacks.picker.config.defaults").defaults.matcher
  local smart = vim.tbl_deep_extend("force", {}, generic, require("snacks.picker.config.sources").smart.matcher)
  combinations[#combinations + 1] = generic
  combinations[#combinations + 1] = smart
  for _, key in ipairs(vim.fn.sort(vim.tbl_keys(smart))) do
    -- file_pos=false intentionally fixes an upstream no-op; tested separately below.
    if key ~= "file_pos" then
      combinations[#combinations + 1] = vim.tbl_extend("force", {}, smart, { [key] = not smart[key] })
    end
  end
  local history = {
    get = function(_, item)
      return item.idx % 23 / 7
    end,
  }
  local count = 0
  for _, options in ipairs(combinations) do
    -- Freeze history for score comparisons; real decay/storage is tested separately.
    local config = vim.tbl_extend("force", {}, options, { frecency = false })
    local a, b = port.new(config), upstream.new(config)
    if options.frecency then
      a.frecency, b.frecency = history, history
    end
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
          match_topk = i % 5 == 0 and 9 or nil,
        }
        for _, is_file in ipairs({ true, false }) do
          item.file = is_file and text or nil
          local ia, ib = vim.deepcopy(item), vim.deepcopy(item)
          local label = query .. " / " .. text .. " / " .. vim.inspect(options) .. " / file=" .. tostring(is_file)
          eq(a:update({}, ia), b:update({}, ib), label)
          eq(ia, ib, label .. " item")
          eq(a:positions(ia), b:positions(ib), label .. " positions")
          count = count + 1
        end
      end
    end
  end
  print("  exact differential comparisons: " .. count)
end)
test("fuzzy differential covers repeated bytes, gaps, boundaries and first-best ties", function()
  local seed = 19283
  local function random(n)
    seed = seed * 48271 % 2147483647
    return seed % n + 1
  end
  local alphabet = { "a", "a", "b", "c", "A", "B", "1", "2", "_", "-", "/", "\\", " ", "é", "文" }
  for _, options in ipairs({
    { filename_bonus = true },
    { filename_bonus = false },
    { filename_bonus = true, history_bonus = true },
    { filename_bonus = true, smartcase = false, ignorecase = false },
  }) do
    local a, b = port.new(options), upstream.new(options)
    for i = 1, 500 do
      local chars, query = {}, {}
      for j = 1, random(80) do
        chars[j] = alphabet[random(#alphabet)]
        if random(5) == 1 then
          query[#query + 1] = chars[j]
        end
      end
      local text = table.concat(chars)
      local item = { text = text, file = i % 2 == 0 and text or nil }
      a:init(table.concat(query))
      b:init(table.concat(query))
      eq(a:match(item), b:match(item), text .. " / " .. a.pattern)
      eq(a:positions(item), b:positions(item), text .. " / " .. a.pattern)
    end
    for _, text in ipairs({ ("a"):rep(256) .. "/b", "aababaaba/b", "a/aab/bab", "aaaAAAaaaab" }) do
      for _, query in ipairs({ "ab", "aaab", "aba", "aab", "aaaaac", "b" }) do
        a:init(query)
        b:init(query)
        local item = { text = text, file = text }
        eq(a:match(item), b:match(item), text .. " / " .. query)
        eq(a:positions(item), b:positions(item), text .. " / " .. query)
      end
    end
  end
end)

test("repeated matching clears heap metadata without inserting absent nil fields", function()
  local nil_writes = 0
  local item = setmetatable({ text = "alpha.lua" }, {
    __newindex = function(t, key, value)
      if key == "match_topk" and value == nil then
        nil_writes = nil_writes + 1
      end
      rawset(t, key, value)
    end,
  })
  local m = port.new()
  for _, query in ipairs({ "", "alpha", "missing", "" }) do
    m:init(query)
    m:update({}, item)
  end
  eq(nil_writes, 0)
  item.match_topk = 42
  m:update({}, item)
  eq(item.match_topk, nil)
end)

test("filename-boundary cache preserves scores across strings, directions and file flags", function()
  local a = require("fzf-lua-smart.vendor.score").new({ filename_bonus = true })
  local b = require("snacks.picker.core.score").new({ filename_bonus = true })
  for _, text in ipairs({ "a/b/c", "plain", "x/y/", "a\\b/c", "a/b/c", "a/b\nc" }) do
    for _, is_file in ipairs({ true, false, true }) do
      a.is_file, b.is_file = is_file, is_file
      for _, direction in ipairs({ 1, -1, 1 }) do
        for i = 1, #text do
          local first = direction == 1 and i or #text - i + 1
          eq(a:get(text, first, #text), b:get(text, first, #text))
        end
      end
    end
  end
end)

test("regex is compiled once per pattern, including invalid patterns", function()
  local regex, calls = vim.regex, 0
  vim.regex = function(pattern)
    calls = calls + 1
    return regex(pattern)
  end
  local ok, err = xpcall(function()
    local m = port.new({ regex = true })
    for index, query in ipairs({ "a.*b", "\\(", "b$" }) do
      m:init(query)
      for _ = 1, 20 do
        local item = { text = "aa/b", file = "aa/b" }
        m:match(item)
        m:positions(item)
      end
      eq(calls, index)
    end
  end, debug.traceback)
  vim.regex = regex
  assert(ok, err)
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
test("matcher pinned quirk: cwd bonus uses a raw path prefix", function()
  local m = port.new({ frecency = false, cwd_bonus = true })
  m.cwd = "/work"
  local item = { text = "/work-other/x", file = "/work-other/x" }
  m:update({}, item)
  eq(item.score, 1010)
end)
test("file_pos=false disables location syntax but preserves literal and field matching", function()
  for _, opts in ipairs({ {}, { file_pos = true }, { file_pos = false } }) do
    local m = port.new(opts)
    for _, query in ipairs({ "init.lua:3", "src/init.lua:3:2" }) do
      m:init(query)
      if opts.file_pos == false then
        eq(m.file, nil)
        eq(m:match({ text = "src/init.lua", file = "src/init.lua" }), 0)
        assert(m:match({ text = query, file = query }) > 0)
      else
        assert(m.file and m:match({ text = "src/init.lua", file = "src/init.lua" }) > 0)
      end
    end
    m:init("file:lua")
    assert(m:match({ text = "other", file = "init.lua" }) > 0)
  end
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
