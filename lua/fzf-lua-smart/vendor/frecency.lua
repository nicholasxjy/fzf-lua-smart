-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone module names, search-only host integration, live
-- single-entry reads for visits and optional visit tracking from startup.
-- Frecency based on exponential decay. Roughly based on:
-- https://wiki.mozilla.org/User:Jesse/NewFrecency?title=User:Jesse/NewFrecency
---@class fzf_lua_smart.Frecency
---@field now number
---@field cache table<string, number>
local M = {}
M.__index = M

local uv = vim.uv or vim.loop
local util = require("fzf-lua-smart.util")

local HALF_LIFE = 30 * 24 * 3600 -- Half-life = 30 days (in seconds)
local LAMBDA = math.log(2) / HALF_LIFE -- λ = ln(2) / half_life
local SEED_VALUE = 1
local DEFAULT_VALUE = 1
local MAX_STORE_SIZE = 10000

---@class fzf_lua_smart.frecency.Store
---@field set fun(self:fzf_lua_smart.frecency.Store, key:string, value:number)
---@field get fun(self:fzf_lua_smart.frecency.Store, key:string):number
---@field close fun(self:fzf_lua_smart.frecency.Store)
---@field get_all fun(self:fzf_lua_smart.frecency.Store):table<string, number>

-- Global store of frecency deadlinesl
---@type fzf_lua_smart.frecency.Store?
M.store = nil

-- Visits recorded by startup tracking before the store is opened.
---@type {file:string, buf:number, time:number, value?:number}[]?
M.pending = nil
local STARTUP_GROUP = "fzf_lua_smart_frecency_startup"

local function on_win_enter(ev)
  if vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative == "" then
    M.visit_buf(ev.buf)
  end
end

function M.setup()
  M.store = require("fzf-lua-smart.store").open(M.opts or {})
  local pending = M.pending
  M.untrack()
  local group = vim.api.nvim_create_augroup("fzf_lua_smart_frecency", { clear = true })
  vim.api.nvim_create_autocmd("ExitPre", {
    group = group,
    callback = function()
      if M.store then
        M.store:close()
        M.store = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = on_win_enter })
  local queued = M.replay(pending)
  -- Existing buffers get one visit, unless startup tracking already queued one.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not queued[vim.api.nvim_buf_get_name(buf)] then
      M.visit_buf(buf)
    end
  end
end

--- Record visits from startup without opening the store. They are queued and
--- replayed at their own times when the store is first opened: by the first
--- picker, or on exit when no picker was opened.
function M.track()
  if M.store or M.pending then
    return
  end
  M.pending = {}
  local group = vim.api.nvim_create_augroup(STARTUP_GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = on_win_enter })
  vim.api.nvim_create_autocmd("ExitPre", {
    group = group,
    callback = function()
      local pending = M.pending
      M.untrack()
      if pending and #pending > 0 and not M.store then
        M.store = require("fzf-lua-smart.store").open(M.opts or {})
        M.replay(pending)
        M.store:close()
        M.store = nil
      end
    end,
  })
end

--- Stop startup tracking and discard visits that were not written yet.
function M.untrack()
  if M.pending then
    M.pending = nil
    pcall(vim.api.nvim_del_augroup_by_name, STARTUP_GROUP)
  end
end

function M.new()
  local self = setmetatable({}, M)
  self.now = os.time()
  if not M.store then
    M.setup()
  end
  self.cache = M.store:get_all()
  return self
end

--- A visit reads and updates one entry. Read it from the live store instead of
--- copying a whole SQLite history snapshot on every BufWinEnter.
local function live()
  if not M.store then
    M.setup()
  end
  local store = M.store
  if not store.get then
    return M.new()
  end
  local self = setmetatable({}, M)
  self.now = os.time()
  self.cache = setmetatable({}, {
    __index = function(_, key)
      return store:get(key)
    end,
  })
  return self
end

--- Convert from a current score s into a "deadline date"
--- t = now() + (ln(s) / λ)
---@param score number
function M:to_deadline(score)
  return self.now + (math.log(score) / LAMBDA)
end

--- Convert from a "deadline date" back into a current score
--- s = e^(λ * (deadline - now))
function M:to_score(deadline)
  return math.exp(LAMBDA * (deadline - self.now))
end

--- Get the current frecency score for an item.
--- If the item is not tracked yet, it will seed it
--- based on the last used time or last modified time.
---@param item fzf_lua_smart.Item
---@param opts? {seed?: boolean}
function M:get(item, opts)
  opts = opts or {}
  local path = util.path(item)
  if not path then
    return 0
  end
  if item.dir then
    -- frecency of a directory is the sum of frecencies of all files in it
    local score = 0
    local prefix = path .. "/"
    for k, v in pairs(self.cache) do
      if k:find(prefix, 1, true) == 1 then
        score = score + self:to_score(v)
      end
    end
    return score
  end
  local deadline = self.cache[path]
  if not deadline then
    return opts.seed ~= false and self:seed(item) or 0
  end
  return self:to_score(deadline)
end

---@param item fzf_lua_smart.Item
---@param value? number
function M:seed(item, value)
  -- only seed recent files or items with buffer info
  if not (item.info or item.recent) then
    return 0
  end
  local last_used = type(item.info) == "table" and item.info.lastused or nil
  local path = util.path(item)
  if not path then
    return 0
  end
  if not last_used then
    local stat = uv.fs_stat(path)
    last_used = stat and stat.mtime.sec
  end
  if not last_used then
    return 0
  end
  -- Calculate decayed single-visit score
  local dt = self.now - last_used -- in seconds
  return (value or SEED_VALUE) * math.exp(-LAMBDA * dt)
end

--- Add a "visit" to the item.
--- If the item doesn't exist, it is created with initial score = `visit_value`.
--- Otherwise, the new score is old_score + visit_value.
---@param item fzf_lua_smart.Item
---@param value? number @the "points" to add (e.g. typed=2, clicked=1, etc.)
function M:visit(item, value)
  local path = util.path(item)
  if not path then
    return
  end
  local score = self:get(item, { seed = false }) + (value or DEFAULT_VALUE)
  self.store:set(path, self:to_deadline(score))
end

---@param buf number
---@param value? number
function M.visit_buf(buf, value)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or not vim.bo[buf].buflisted then
    return
  end
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" or not vim.uv.fs_stat(file) then
    return
  end
  if M.pending then
    M.pending[#M.pending + 1] = { file = file, buf = buf, time = os.time(), value = value }
    return true
  end
  local frecency = live()
  frecency:visit({
    text = "",
    idx = 1,
    score = 0,
    file = file,
    buf = buf,
    info = vim.fn.getbufinfo(buf)[1],
  }, value)
  return true
end

--- Apply queued visits as if each had been recorded live at its own time.
---@param pending? {file:string, buf:number, time:number, value?:number}[]
---@return table<string, boolean> files
function M.replay(pending)
  local files = {} ---@type table<string, boolean>
  for _, visit in ipairs(pending or {}) do
    local frecency = live()
    frecency.now = visit.time
    frecency:visit({ text = "", idx = 1, score = 0, file = visit.file, buf = visit.buf }, visit.value)
    files[visit.file] = true
  end
  return files
end

return M
