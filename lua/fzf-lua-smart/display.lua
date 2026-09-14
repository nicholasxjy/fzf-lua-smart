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
local function highlight(display, item, matcher, opts)
  if opts._fmt and opts._fmt.to then
    return display
  end
  local u = require("fzf-lua.utils")
  local plain = u.strip_ansi_coloring(display)
  local file = item.file or item.text
  local shown = file
  local at = plain:find(shown, 1, true)
  local offset = 0
  if not at then
    shown = vim.fs.basename(file)
    at = plain:find(shown, 1, true)
    offset = #file - #shown
  end
  if not at or plain:find(shown, at + 1, true) then
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
        local index = p - shift - offset
        if index >= 1 and index <= #shown then
          wanted[at + index - 1] = true
        end
      end
    end
  end
  local _, color = u.ansi_from_hl((opts.hls or {}).search or "FzfLuaSearch", "")
  color = color and color ~= "" and color or "\27[1m"
  local out, i, byte = {}, 1, 1
  while i <= #display do
    local ansi = display:sub(i):match("^\27%[[%d;]*m")
    if ansi then
      out[#out + 1] = ansi
      i = i + #ansi
    else
      -- Color complete UTF-8 characters, not individual continuation bytes.
      local lead = display:byte(i)
      local len = lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or 4
      local hit = false
      for p = byte, byte + len - 1 do
        hit = hit or wanted[p]
      end
      local char = display:sub(i, i + len - 1)
      out[#out + 1] = hit and color .. char .. "\27[0m" or char
      i, byte = i + len, byte + len
    end
  end
  return table.concat(out)
end
function M.entry(item, matcher, opts)
  local file = util.path(item) or item.text
  local pos = item.pos or { 0, 0 }
  local canonical = (item.buf and ("[" .. item.buf .. "]" .. require("fzf-lua.utils").nbsp) or "")
    .. file
    .. ":"
    .. pos[1]
    .. ":"
    .. (pos[2] + 1)
    .. ":"
  local display = require("fzf-lua.make_entry").file(file, opts) or file
  -- Control bytes cannot be allowed to introduce transport fields or terminal commands.
  display = display
    :gsub("%z", "\\x00")
    :gsub("[\1-\8\11\12\14-\26\28-\31]", function(c)
      return ("\\x%02x"):format(c:byte())
    end)
    :gsub("\n", "␊")
    :gsub("\r", "␍")
  display = highlight(display, item, matcher, opts)
  return require("fzf-lua.lib.base64").encode(canonical) .. sep .. display
end
return M
