-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names, search-only host integration and a
-- loop-free comparator chain.
---@class fzf_lua_smart.sorters
local M = {}

---@alias fzf_lua_smart.sort.Field { name: string, desc: boolean, len?: boolean }

---@class fzf_lua_smart.sort.Config
---@field fields? (fzf_lua_smart.sort.Field|string)[]

---@param opts? fzf_lua_smart.sort.Config
function M.default(opts)
  local fields = {} ---@type fzf-lua-smart.sort.Field[]
  for _, f in ipairs(opts and opts.fields or { { name = "score", desc = true }, "idx" }) do
    if type(f) == "string" then
      local desc, len = false, nil
      if f:sub(1, 1) == "#" then
        f, len = f:sub(2), true
      end
      if f:sub(-5) == ":desc" then
        f, desc = f:sub(1, -6), true
      elseif f:sub(-4) == ":asc" then
        f = f:sub(1, -5)
      end
      table.insert(fields, { name = f, desc = desc, len = len })
    else
      table.insert(fields, f)
    end
  end

  -- Chain one loop-free comparator per field. A field loop inside the
  -- comparator aborts LuaJIT traces of every sorting loop that calls it.
  local less = function()
    return false
  end
  for i = #fields, 1, -1 do
    local name, desc, len, next_less = fields[i].name, fields[i].desc, fields[i].len, less
    ---@param a fzf-lua-smart.Item
    ---@param b fzf-lua-smart.Item
    less = function(a, b)
      local av, bv = a[name], b[name]
      if av ~= nil and bv ~= nil then
        if len then
          av, bv = #av, #bv
        end
        if av ~= bv then
          if type(av) == "boolean" then
            av, bv = av and 0 or 1, bv and 0 or 1
          end
          if desc then
            return av > bv
          else
            return av < bv
          end
        end
      end
      return next_less(a, b)
    end
  end
  return less
end

function M.idx()
  ---@param a fzf-lua-smart.Item
  ---@param b fzf-lua-smart.Item
  return function(a, b)
    return a.idx < b.idx
  end
end

return M
