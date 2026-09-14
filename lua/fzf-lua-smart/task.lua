-- Scheduled coroutines keep all Neovim API calls on the main loop.
local M = {}
local Task = {}
Task.__index = Task
function M.nop()
  return setmetatable({ done = true }, Task)
end
function Task:running()
  return not self.done
end
function Task:abort()
  if self.done then
    return
  end
  self.done, self.cancelled = true, true
  for _, fn in ipairs(self.cleanup) do
    pcall(fn)
  end
  self.cleanup = {}
end
function Task:on_cancel(fn)
  self.cleanup[#self.cleanup + 1] = fn
end
function Task:resume()
  if self.done or self.pending then
    return
  end
  self.pending = true
  -- A scheduled-callback chain can starve libuv timers/input while Neovim
  -- drains its queue. A timer boundary lets terminal IO and cancellation run.
  vim.defer_fn(function()
    self.pending = false
    if self.done then
      return
    end
    local ok, suspend = coroutine.resume(self.co)
    if not ok then
      self:abort()
      if self.on_error then
        self.on_error(suspend)
      else
        vim.notify(suspend, vim.log.levels.ERROR)
      end
    elseif coroutine.status(self.co) == "dead" then
      self.done, self.cleanup = true, {}
    elseif not suspend then
      self:resume()
    end
  end, 1)
end
function M.new(fn, on_error)
  local self = setmetatable({ cleanup = {}, on_error = on_error }, Task)
  self.co = coroutine.create(function()
    fn(self)
  end)
  self:resume()
  return self
end
function M.yield()
  coroutine.yield(false)
end
function M.suspend()
  coroutine.yield(true)
end
function M.yielder(ms)
  local start, n = vim.uv.hrtime(), 0
  return function()
    n = n + 1
    if n % 100 == 0 and vim.uv.hrtime() - start >= (ms or 2) * 1e6 then
      M.yield()
      start = vim.uv.hrtime()
    end
  end
end
-- Stable, yielding merge sort. Never concatenate independently sorted chunks.
function M.sort(items, less, yield)
  local n, width, tmp = #items, 1, {}
  while width < n do
    for first = 1, n, 2 * width do
      local mid, last = math.min(first + width - 1, n), math.min(first + 2 * width - 1, n)
      local a, b = first, mid + 1
      for out = first, last do
        if a <= mid and (b > last or not less(items[b], items[a])) then
          tmp[out], a = items[a], a + 1
        else
          tmp[out], b = items[b], b + 1
        end
        yield()
      end
      for out = first, last do
        items[out] = tmp[out]
        yield()
      end
    end
    width = width * 2
  end
  return items
end
return M
