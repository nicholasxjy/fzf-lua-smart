-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names and search-only host integration.
---@class fzf_lua_smart.transformers
---@field [string] fzf_lua_smart.transform
local M = {}

function M.unique_file(item, ctx)
  ctx.meta.done = ctx.meta.done or {} ---@type table<string, boolean>
  local path = require("fzf-lua-smart.util").path(item)
  if not path or ctx.meta.done[path] then
    return false
  end
  ctx.meta.done[path] = true
end

function M.text_to_file(item, ctx)
  item.file = item.file or item.text
end

return M
