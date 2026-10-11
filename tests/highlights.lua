local C = require("fzf-lua-smart.config")
local Core = require("fzf-lua.core")

-- Read effective --color values in CLI order, including user raw overrides.
local function colors(opts)
  local ret = {}
  local cli = table.concat(Core.build_fzf_cli(opts), " ")
  for spec in cli:gmatch("%-%-color[= ]+['\"]?([%w#:,%%+%-]+)") do
    for flag, value in spec:gmatch("([^,:]+):([^,]+)") do
      ret[flag] = value
    end
  end
  return ret
end

local function options(extra)
  return vim.tbl_deep_extend("force", {
    cwd = fixture,
    _start = false,
    file_icons = false,
    git_icons = false,
    previewer = false,
    winopts = { treesitter = false },
    raw_cmd = "printf '%s\\n' alpha.lua sub/init.lua",
    multi = { "files" },
    matcher = { frecency = false },
  }, extra or {})
end

test("all files highlight groups and auto color mappings are inherited", function()
  local fzf = require("fzf-lua")
  fzf.setup({})
  local hls = vim.deepcopy(require("fzf-lua.config").defaults.__HLS)
  local index = 0
  local function define(groups)
    for key, value in pairs(groups) do
      if type(value) == "table" then
        define(value)
      else
        index = index + 1
        local name = "SmartParityHighlight" .. index
        vim.api.nvim_set_hl(0, name, { fg = 0x110000 + index, bg = 0x220000 + index })
        groups[key] = name
      end
    end
  end
  define(hls)
  for _, overrides in ipairs({ {}, { hls = hls } }) do
    local input = options(vim.tbl_extend("force", { fzf_colors = true }, overrides))
    local native = require("fzf-lua.config").normalize_opts(vim.deepcopy(input), "files")
    local smart = C.resolve(vim.deepcopy(input))
    eq(smart.hls, native.hls)
    eq(smart.fzf_colors, native.fzf_colors)
    eq(smart.fzf_colors.hl, smart.fzf_colors["hl+"])
    eq(colors(smart), colors(native))
  end
end)

test("live smart CLI retains the complete files palette and query override precedence", function()
  vim.api.nvim_set_hl(0, "SmartParityQuery", { fg = "#123456" })
  vim.api.nvim_set_hl(0, "SmartParityLive", { fg = "#abcdef" })
  vim.api.nvim_set_hl(0, "SmartParityNoFg", { bg = "#654321" })
  for _, case in ipairs({
    { fzf_colors = true },
    { fzf_colors = false },
    { fzf_colors = { true, query = false } },
    { fzf_colors = { query = "#334455:regular:underline" } },
    { fzf_colors = { query = { "fg", { "SmartParityNoFg", "SmartParityQuery" }, "italic", "regular" } } },
    { fzf_colors = { query = { "fg", "SmartParityNoFg" } } },
    { fzf_colors = { query = { "fg", "SmartParityNoFg", "underline" } } },
    { fzf_colors = true, fzf_args = "--color=query:#445566:bold" },
    { fzf_colors = true, fzf_args = { "--color=query:#445566:bold", "--color=query:#556677" } },
    { fzf_colors = true, fzf_raw_args = "--color=query:#667788" },
    { fzf_colors = true, fzf_cli_args = { "--color=query:#778899" } },
    { fzf_colors = true, fzf_opts = { ["--color"] = "query:#8899aa:regular" } },
  }) do
    local input = options(vim.tbl_deep_extend("force", {
      hls = { fzf = { query = "SmartParityQuery" }, live_prompt = "SmartParityLive" },
    }, case))
    local saved = vim.deepcopy(input)
    local _, _, native = require("fzf-lua").files(vim.deepcopy(input))
    local _, _, smart = require("fzf-lua-smart").smart(input)
    smart.__smart:close()
    eq(smart.is_live, true, "keep native reload and resume semantics")
    local expected = colors(native)
    eq(colors(smart), expected, vim.inspect(case))
    -- Keep the original palette when fzf-lua rebuilds the CLI on resume.
    eq(colors(smart), expected, "resume: " .. vim.inspect(case))
    eq(input, saved, "never mutate caller highlight configuration")
  end
end)
