-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names and search-only host integration.
local M = {}

local uv = vim.uv or vim.loop

---@param filter fzf_lua_smart.Filter
---@param extra? string[]
local function oldfiles(filter, extra)
  local done = {} ---@type table<string, boolean>
  local files = {} ---@type string[]
  vim.list_extend(files, extra or {})
  vim.list_extend(files, vim.v.oldfiles)
  local i = 0
  return function()
    for f = i + 1, #files do
      i = f
      local file = files[f]
      file = vim.fn.fnamemodify(file, ":p")
      file = vim.fs.normalize(file, { _fast = true, expand_env = false })
      local want = not done[file] and filter:match({ file = file, text = "" })
      done[file] = true
      if want and uv.fs_stat(file) then
        return file
      end
    end
  end
end

--- Get the most recent files, optionally filtered by the
--- current working directory or a custom directory.
---@param opts fzf_lua_smart.SourceConfig
---@type fzf_lua_smart.finder
function M.files(opts, ctx)
  local current_file = vim.fs.normalize(vim.api.nvim_buf_get_name(0), { _fast = true })
  ---@type number[]
  local bufs = vim.tbl_filter(function(b)
    return vim.api.nvim_buf_get_name(b) ~= "" and vim.bo[b].buftype == ""
  end, vim.api.nvim_list_bufs())
  table.sort(bufs, function(a, b)
    return vim.fn.getbufinfo(a)[1].lastused > vim.fn.getbufinfo(b)[1].lastused
  end)
  local extra = vim.tbl_map(function(b)
    return vim.api.nvim_buf_get_name(b)
  end, bufs)
  ---@async
  ---@param cb async fun(item: fzf-lua-smart.finder.Item)
  return function(cb)
    for file in oldfiles(ctx.filter, extra) do
      if file ~= current_file then
        cb({ file = file, text = file, recent = true })
      end
    end
  end
end

M.recent = M.files

return M
