-- Independent storage. SQLite intentionally stores integer deadlines (upstream
-- bind_int64 semantics); KV retains Lua doubles via string.buffer encoding.
local M = {}
local warned = false
function M.warn(err)
  if warned then
    return
  end
  warned = true
  vim.schedule(function()
    vim.notify("fzf-lua-smart: history unavailable; using session memory. " .. tostring(err), vim.log.levels.WARN)
  end)
end
local function valid(data)
  assert(type(data) == "table", "invalid history table")
  for k, v in pairs(data) do
    assert(type(k) == "string" and type(v) == "number" and v == v and math.abs(v) < math.huge, "invalid history entry")
  end
  return data
end
local function kv(path)
  local loaded, data = os.time(), {}
  local stat = vim.uv.fs_stat(path)
  if stat then
    local fd = assert(io.open(path, "rb"))
    local bytes = assert(fd:read("*a"))
    assert(fd:close())
    data = valid(require("string.buffer").decode(bytes))
  end
  return {
    data = data,
    close = function(self)
      local current = vim.uv.fs_stat(path)
      -- Upstream's last-writer guard, rather than merging visits twice.
      if current and current.mtime.sec > loaded then
        return
      end
      local entries = {}
      for key, value in pairs(self.data) do
        entries[#entries + 1] = { key, value }
      end
      table.sort(entries, function(a, b)
        return a[2] > b[2]
      end)
      local cleaned = {}
      for i = 1, math.min(#entries, 10000) do
        cleaned[entries[i][1]] = entries[i][2]
      end
      local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
      local fd = assert(io.open(tmp, "wb"))
      local ok, err = fd:write(require("string.buffer").encode(cleaned))
      local closed, cerr = fd:close()
      if not ok or not closed then
        os.remove(tmp)
        error(err or cerr)
      end
      local renamed, rerr = os.rename(tmp, path)
      if not renamed then
        os.remove(tmp)
        error(rerr)
      end
      self.data = cleaned
    end,
  }
end

function M.directory()
  return vim.fn.stdpath("data") .. "/fzf-lua-smart"
end
function M.open(opts)
  local dir = M.directory()
  local backend, data, kind
  local ok, err = pcall(function()
    vim.fn.mkdir(dir, "p")
    local available, sqlite = pcall(require, "fzf-lua-smart.sqlite")
    local lib_ok, lib = false, nil
    if available then
      lib_ok, lib = pcall(sqlite.library, opts.sqlite3_path)
    end
    if lib_ok then
      backend = sqlite.open(dir .. "/frecency.sqlite3", lib)
      data, kind = valid(backend:get_all()), "sqlite"
    else
      backend = kv(dir .. "/frecency.dat")
      data, kind = backend.data, "kv"
    end
  end)
  if not ok then
    if backend then
      pcall(backend.close, backend)
    end
    backend, data, kind = nil, {}, "memory"
    M.warn(err)
  end
  local self = { data = data, kind = kind }
  function self:set(key, value)
    if backend and kind == "sqlite" then
      local success, failure = pcall(backend.set, backend, key, value)
      if not success then
        pcall(backend.close, backend)
        backend = nil
        self.kind = "memory"
        M.warn(failure)
      else
        -- Mirrors sqlite bind_int64's truncation before the next snapshot.
        value = value < 0 and math.ceil(value) or math.floor(value)
      end
    end
    self.data[key] = value
  end
  function self:get(key)
    return self.data[key]
  end
  function self:get_all()
    -- KV shares its cache; SQLite get_all returns a fresh snapshot upstream.
    return self.kind == "sqlite" and vim.deepcopy(self.data) or self.data
  end
  function self:close()
    if not backend then
      return
    end
    backend.data = self.data
    local success, failure = pcall(backend.close, backend)
    backend = nil
    if not success then
      self.kind = "memory"
      M.warn(failure)
    end
  end
  return self
end
return M
