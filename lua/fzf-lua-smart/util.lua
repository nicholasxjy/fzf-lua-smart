-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names, search-only host integration and a
-- normalize fast path.
local M = {}
local normalize_opts = { _fast = true, expand_env = false }
function M.path(item)
  if not (item and item.file) then
    return
  end
  local path = item._path
  if not path then
    path = item.cwd and item.cwd .. "/" .. item.file or item.file
    -- Fast, non-env POSIX normalization only expands a leading "~" (and keeps
    -- ""); skip the call for every other candidate. Windows is unsupported.
    if path:byte(1) == 126 then
      path = vim.fs.normalize(path, normalize_opts)
    end
    item._path = path
  end
  return path
end

function M.text(item, keys)
  local buffer = require("string.buffer").new()
  for _, key in ipairs(keys) do
    if item[key] then
      if #buffer > 0 then
        buffer:put(" ")
      end
      if key == "pos" or key == "end_pos" then
        buffer:putf("%d:%d", item[key][1], item[key][2])
      else
        buffer:put(tostring(item[key]))
      end
    end
  end
  return buffer:get()
end

function M.rtp()
  local ret = {} ---@type string[]
  vim.list_extend(ret, vim.api.nvim_get_runtime_file("", true))
  if package.loaded.lazy then
    local extra = require("lazy.core.util").get_unloaded_rtp("")
    vim.list_extend(ret, extra)
  end
  return ret
end

---@param str string
---@return string text, string[] args
function M.parse(str)
  -- Format: this is a test -- -g=hello
  local t, a = str:match("^(.-)%s+%-%-%s*(.*)$")
  if not t then
    return str, {}
  end
  t, a = vim.trim(t), vim.trim(a:gsub("%s+", " "))
  local args = {} ---@type string[]
  -- tokenize the args, keeping quoted strings together
  local in_quote = nil ---@type string?
  local c = 1
  for i = 1, #a do
    local char = a:sub(i, i)
    if char == "'" or char == '"' then
      if in_quote == char then
        in_quote = nil
      else
        in_quote = char
      end
    elseif char == " " and not in_quote then
      args[#args + 1] = a:sub(c, i - 1)
      c = i + 1
    end
  end
  if c <= #a then
    args[#args + 1] = a:sub(c)
  end
  return t, args
end

return M
