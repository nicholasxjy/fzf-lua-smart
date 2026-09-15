local Display = require("fzf-lua-smart.display")
local Utils = require("fzf-lua.utils")
local match_color = "\27[38;2;17;34;51m"
local reset = "\27[0m"

local function render(file, query, options, text)
  vim.api.nvim_set_hl(0, "SmartTestMatch", { fg = "#112233", bg = "#abcdef" })
  vim.api.nvim_set_hl(0, "SmartTestSearch", { fg = "#ff0000" })
  vim.api.nvim_set_hl(0, "SmartTestDir", { fg = "#445566" })
  vim.api.nvim_set_hl(0, "SmartTestFile", { fg = "#778899" })
  local opts = require("fzf-lua-smart.config").resolve(vim.tbl_deep_extend("force", {
    cwd = fixture,
    file_icons = false,
    git_icons = false,
    hls = {
      fzf = { match = "SmartTestMatch" },
      search = "SmartTestSearch",
      dir_part = "SmartTestDir",
      file_part = "SmartTestFile",
    },
  }, options or {}))
  local matcher = require("fzf-lua-smart.vendor.matcher").new({ frecency = false })
  matcher:init(query)
  local entry = Display.entry(
    { file = file, text = text or file, cwd = file:sub(1, 1) ~= "/" and fixture or nil },
    matcher,
    Display.setup(opts)
  )
  local display = entry:match(string.char(31) .. "(.*)$")
  local matches = {}
  for char in display:gmatch("\27%[38;2;17;34;51m(.-)\27%[0m") do
    matches[#matches + 1] = char
  end
  return table.concat(matches), display, opts
end

test("display matches use the native fzf foreground, including field queries and UTF-8", function()
  for _, case in ipairs({
    { "sub/init.lua", "init", "init" },
    { "sub/init.lua", "file:^sub", "sub" },
    { fixture .. "/sub/init.lua", "file:sub", "sub" },
    { "sub/init.lua", "init.lua:2:1", "init.lua" },
    { "测试/文件.lua", "文件", "文件" },
    { "sub/init.lua", "!missing", "" },
    { "sub/init.lua", "", "" },
  }) do
    local matches, display = render(case[1], case[2])
    eq(matches, case[3])
    assert(not display:find("\27[48;", 1, true), "native fzf match uses only the group's foreground")
    eq(Utils.strip_ansi_coloring(display), (case[1]:gsub(vim.pesc(fixture .. "/"), "")))
  end
  eq(render("sub/init.lua", "init", nil, "buffer sub/init.lua"), "init")
end)

test("built-in path formatters map directory and filename matches after shortening", function()
  for _, formatter in ipairs({ "path.dirname_first", "path.filename_first", { "path.filename_first", 2 } }) do
    local matches, display = render("sub/init.lua", "sub init", { formatter = formatter })
    eq(matches, formatter == "path.dirname_first" and "subinit" or "initsub")
    assert(display:find("\27[38;2;119;136;153m.lua", 1, true), "file color must resume after a match")
    matches, display = render("sub/init.lua", "file:^s", { formatter = formatter })
    eq(matches, "s")
    assert(display:find(match_color .. "s" .. reset .. "\27[38;2;68;85;102mu", 1, true))
    eq(
      render("sub/sub/init.lua", "file:^sub/sub/init", { formatter = formatter, path_shorten = 1 }),
      formatter == "path.dirname_first" and "s/s/init" or "inits/s"
    )
    eq(render("sub/init.lua", "file:ub", { formatter = formatter, path_shorten = 1 }), "")
  end
end)

test("display respects fzf match color overrides and leaves custom formatter output intact", function()
  local _, display = render("alpha.lua", "alpha", { fzf_colors = { hl = "#123456:underline" } })
  assert(display:find("\27[38;2;18;52;86m\27[4ma", 1, true))
  _, display = render("alpha.lua", "alpha", { fzf_colors = { hl = { "fg", { "MissingSmartHl", "SmartTestSearch" } } } })
  assert(display:find("\27[38;2;255;0;0ma", 1, true))
  local matches
  matches, display =
    render("alpha.lua", "alpha", { _fmt = {
      to = function()
        return "custom alpha.lua"
      end,
    } })
  eq(matches, "")
  eq(display, "custom alpha.lua")
end)
