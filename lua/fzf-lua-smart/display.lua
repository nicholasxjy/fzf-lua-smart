local M = {}
local sep = string.char(31)
local util = require("fzf-lua-smart.util")

-- The first, hidden field carries the complete native file/buffer record. It is
-- not derived from visible (possibly shortened or non-injective) formatting.
function M.decode(entry)
  local token = entry:match("^([^" .. string.char(31) .. "]+)" .. string.char(31))
  if not token then
    return entry
  end
  return require("fzf-lua.lib.base64").decode(token)
end
function M.setup(opts)
  local format = opts._fmt
  local render = vim.tbl_extend("force", {}, opts, {
    _fmt = format,
    file_ignore_patterns = false,
    cwd_only = false,
    ignore_current_file = false,
  })
  opts._fmt = { from = M.decode }
  -- Identity decoding returns the full path; never lengthen a shortened guess.
  opts.path_shorten = false
  opts.fzf_opts["--delimiter"] = sep
  opts.fzf_opts["--with-nth"] = "2.."
  opts.fzf_opts["--nth"] = nil
  opts.fzf_opts["--read0"] = true
  opts.fzf_opts["--print0"] = true
  opts.field_index_expr = "{}"
  return render
end
local function match_color(opts)
  local u = require("fzf-lua.utils")
  local hl = ((opts.hls or {}).fzf or {}).match or "FzfLuaFzfMatch"
  -- Resolve the same foreground and optional styles as fzf-lua's --color=hl.
  local spec = require("fzf-lua.core").create_fzf_colors({
    __FZF_VERSION = opts.__FZF_VERSION,
    fzf_colors = { hl = (opts.fzf_colors or {}).hl or { "fg", hl } },
  })
  local styles =
    { bold = 1, dim = 2, italic = 3, underline = 4, blink = 5, reverse = 7, strikethrough = 9, regular = 22 }
  local color = {}
  for part in (spec or ""):gmatch("[^:]+") do
    if part:match("^#%x%x%x%x%x%x$") or tonumber(part) and tonumber(part) >= 0 then
      color[#color + 1] = u.ansi_from_rgb(part, ""):gsub("\27%[0m$", "")
    elseif styles[part] then
      color[#color + 1] = ("\27[%dm"):format(styles[part])
    end
  end
  return #color > 0 and table.concat(color) or "\27[1m"
end

-- Non-empty path components and their byte offsets, as gmatch("()([^/]+)").
local function components(file)
  local ats, texts, at, size = {}, {}, 1, #file
  while at <= size do
    local slash = file:find("/", at, true) or size + 1
    if slash > at then
      ats[#ats + 1], texts[#texts + 1] = at, file:sub(at, slash - 1)
    end
    at = slash + 1
  end
  return ats, texts
end

local function highlight(display, shown, item, matcher, opts)
  local file = item.file or item.text
  local path = require("fzf-lua.path")
  local source_at, source = components(file)
  local visible_at, visible = components(shown)
  local mapped = {}
  -- Align from the filename so cwd removal and shortened directories retain
  -- their source byte positions, including repeated directory names.
  for n = 0, math.min(#source, #visible) - 1 do
    local a, b = source[#source - n], visible[#visible - n]
    if
      a ~= b and not (n > 0 and opts.path_shorten and path.shorten(a .. "/", tonumber(opts.path_shorten)) == b .. "/")
    then
      break
    end
    local a_at, b_at = source_at[#source - n], visible_at[#visible - n]
    for p = 0, #b - 1 do
      mapped[b_at + p] = a_at + p
    end
    if a_at > 1 and b_at > 1 then
      mapped[b_at - 1] = a_at - 1
    end
  end

  -- Only escape sequences (ESC or 8-bit CSI) can make the plain text differ.
  local plain = display:find("[\27\155]") and require("fzf-lua.utils").strip_ansi_coloring(display) or display
  if opts.formatter == "path.filename_first" then
    local tail, parent = path.tail(shown), path.parent(shown)
    if parent then
      parent = path.remove_trailing(parent)
      if plain ~= tail .. "\t" .. parent then
        return display
      end
      local reordered = {}
      for p = 1, #tail do
        reordered[p] = mapped[#shown - #tail + p]
      end
      for p = 1, #parent do
        reordered[#tail + 1 + p] = mapped[p]
      end
      mapped = reordered
    elseif plain ~= shown then
      return display
    end
  elseif plain ~= shown then
    return display
  end

  local wanted = {}
  local positions = matcher:positions(item)
  for field, points in pairs(positions) do
    local shift
    if field == "file" then
      shift = 0
    elseif field == "text" then
      local start = item.text:find(file, 1, true)
      if start and not item.text:find(file, start + 1, true) then
        shift = start - 1
      end
    end
    if shift then
      for _, p in ipairs(points) do
        wanted[p - shift] = true
      end
    end
  end
  local color = opts.__smart_match_color or match_color(opts)
  -- Copy unmatched text and ANSI sequences in runs; only matches are rebuilt.
  local out, i, byte, from, size = {}, 1, 1, 1, #display
  local active = ""
  while i <= size do
    local lead = display:byte(i)
    local ansi = lead == 27 and display:match("^\27%[[%d;]*m", i)
    if ansi then
      -- Replay the formatter's active style after a match resets ANSI state.
      active = (ansi == "\27[0m" or ansi == "\27[m") and "" or active .. ansi
      i = i + #ansi
    else
      -- Color complete UTF-8 characters, not individual continuation bytes.
      local len = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
      local hit = false
      for p = byte, byte + len - 1 do
        hit = hit or wanted[mapped[p]]
      end
      if hit then
        out[#out + 1] = display:sub(from, i - 1)
        out[#out + 1] = color .. display:sub(i, i + len - 1) .. "\27[0m" .. active
        from = i + len
      end
      i, byte = i + len, byte + len
    end
  end
  out[#out + 1] = display:sub(from)
  return table.concat(out)
end

-- make_entry.file is synchronous: one reusable render table reads the entry
-- being rendered from these upvalues instead of a per-item table and closure.
local active_item, active_matcher
local function new_highlighter(opts, format)
  local render = setmetatable({
    _fmt = {
      to = function(shown, _, modules)
        local text, postfix = shown, nil
        if format and format.to then
          text, postfix = format.to(shown, opts, modules)
        end
        return highlight(text, shown, active_item, active_matcher, opts), postfix
      end,
    },
  }, { __index = opts })
  opts.__smart_highlighter = { format = format, render = render }
  return render
end
-- Kept free of closures: closing captured locals on return aborts LuaJIT traces.
local function highlighter(opts, format)
  local cached = opts.__smart_highlighter
  if cached and cached.format == format then
    return cached.render
  end
  return new_highlighter(opts, format)
end

local make_file, encode, nbsp
local function escape(c)
  return ("\\x%02x"):format(c:byte())
end
function M.entry(item, matcher, opts)
  if not make_file then
    make_file = require("fzf-lua.make_entry").file
    encode = require("fzf-lua.lib.base64").encode
    nbsp = require("fzf-lua.utils").nbsp
  end
  local file = util.path(item) or item.text
  local pos = item.pos
  local canonical = (item.buf and ("[" .. item.buf .. "]" .. nbsp) or "")
    .. file
    .. ":"
    .. (pos and pos[1] or 0)
    .. ":"
    .. (pos and pos[2] + 1 or 1)
    .. ":"
  local render, format = opts, opts._fmt
  if
    not matcher:empty()
    and (
      not format
      or not format.to
      or opts.formatter == "path.filename_first"
      or opts.formatter == "path.dirname_first"
    )
  then
    opts.__smart_match_color = opts.__smart_match_color or match_color(opts)
    -- Intercept the native path after cwd/shortening transformations and before
    -- icons are attached. Custom formatter output has no source-position map.
    render = highlighter(opts, format)
    active_item, active_matcher = item, matcher
  end
  local display = make_file(file, render) or file
  active_item, active_matcher = nil, nil
  -- Control bytes cannot be allowed to introduce transport fields or terminal
  -- commands. Tab and ANSI escapes are formatter output; most lines have none.
  if display:find("[%z\1-\8\10-\26\28-\31]") then
    display =
      display:gsub("%z", "\\x00"):gsub("[\1-\8\11\12\14-\26\28-\31]", escape):gsub("\n", "␊"):gsub("\r", "␍")
  end
  return encode(canonical) .. sep .. display
end
return M
