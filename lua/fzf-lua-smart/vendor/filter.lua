-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names and search-only host integration.
---@class fzf_lua_smart.Filter
---@field pattern string Pattern used to filter items by the matcher
---@field search string Initial search string used by finders
---@field buf? number
---@field file? string
---@field cwd string
---@field all boolean
---@field paths {path:string, want:boolean}[]
---@field opts fzf_lua_smart.FilterConfig
---@field current_buf number
---@field current_win number
---@field source_id? number
---@field meta table<string, any>
local M = {}
M.__index = M

---@param picker fzf_lua_smart.Search
function M.new(picker)
  local opts = picker.opts ---@type fzf-lua-smart.Config|{filter?:fzf-lua-smart.filter.Config}
  local self = setmetatable({}, M)
  self.current_buf = vim.api.nvim_get_current_buf()
  self.current_win = vim.api.nvim_get_current_win()
  self.meta = {}
  local function gets(v)
    return type(v) == "function" and v(picker) or v or "" --[[@as string]]
  end
  self.pattern = gets(opts.pattern)
  self.search = gets(opts.search)
  self:init(opts)
  return self
end

---@param opts fzf_lua_smart.Config|{filter?:fzf_lua_smart.FilterConfig}
function M:init(opts)
  self.opts = opts.filter or {}
  self.all = not self.opts or not (self.opts.cwd or self.opts.buf or self.opts.paths or self.opts.filter)
  self.paths = {}
  local cwd = self.opts and self.opts.cwd
  self.cwd = type(cwd) == "string" and cwd or opts.cwd or vim.fn.getcwd(0)
  self.cwd = vim.fs.normalize(self.cwd --[[@as string]], { _fast = true })
  if not self.all and self.opts then
    self.buf = self.opts.buf == true and 0 or self.opts.buf --[[@as number?]]
    self.buf = self.buf == 0 and M.current_buf or self.buf
    self.file = self.buf and vim.fs.normalize(vim.api.nvim_buf_get_name(self.buf), { _fast = true }) or nil
    for path, want in pairs(self.opts.paths or {}) do
      table.insert(self.paths, { path = vim.fs.normalize(path), want = want })
    end
  end
  return self
end

function M:is_empty()
  return vim.trim(self.pattern) == "" and vim.trim(self.search) == ""
end

---@param cwd string
function M:set_cwd(cwd)
  self.cwd = cwd
  self.cwd = vim.fs.normalize(self.cwd --[[@as string]], { _fast = true })
end

---@param opts? {trim?:boolean}
---@return fzf_lua_smart.Filter
function M:clone(opts)
  local ret = setmetatable({}, {
    __index = self,
    __call = M.filter,
  })
  if opts and opts.trim then
    ret.pattern = vim.trim(self.pattern)
    ret.search = vim.trim(self.search)
  else
    ret.pattern = self.pattern
    ret.search = self.search
  end
  return ret
end

---@param item fzf_lua_smart.Item):boolean
function M:match(item)
  if self.all then
    return true
  end
  if self.opts.filter and not self.opts.filter(item, self) then
    return false
  end
  if self.buf and (item.buf ~= self.buf) and (item.file ~= self.file) then
    return false
  end
  if not (self.opts.cwd or self.opts.paths) then
    return true
  end
  local path = require("fzf-lua-smart.util").path(item)
  if not path then
    return false
  end
  if self.opts.cwd and path ~= self.cwd and not path:find(self.cwd .. "/", 1, true) then
    return false
  end
  if self.opts.paths then
    for _, p in ipairs(self.paths) do
      if (path:sub(1, #p.path) == p.path) ~= p.want then
        return false
      end
    end
  end
  return true
end

---@param items fzf_lua_smart.Item[]
function M:filter(items)
  if self.all then
    return items
  end
  local ret = {} ---@type fzf-lua-smart.finder.Item[]
  for _, item in ipairs(items) do
    if self:match(item) then
      table.insert(ret, item)
    end
  end
  return ret
end

M.__call = M.filter

return M
