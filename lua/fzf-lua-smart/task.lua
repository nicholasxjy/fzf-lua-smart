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
  local cleanup = self.cleanup
  -- A suspended coroutine owns its whole stack, including candidate arrays and
  -- worker snapshots. Saved picker options may keep the Task alive after close.
  self.co, self.cleanup, self.on_error = nil, {}, nil
  for _, fn in ipairs(cleanup) do
    pcall(fn)
  end
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
    local co, on_error = self.co, self.on_error
    local ok, suspend = coroutine.resume(co)
    if not ok then
      self:abort()
      if on_error then
        on_error(suspend)
      else
        vim.notify(suspend, vim.log.levels.ERROR)
      end
    elseif self.done then
      return -- the running callback may have aborted its own task
    elseif coroutine.status(co) == "dead" then
      self.done, self.co, self.cleanup, self.on_error = true, nil, {}, nil
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
-- Stable, yielding merge sort. Already ordered runs need no copying; otherwise
-- buffer only the left run and merge into items, leaving the right tail in place.
function M.sort(items, less, yield)
  local n, width, tmp = #items, 1, {}
  while width < n do
    for first = 1, n - width, 2 * width do
      local mid, last = first + width - 1, math.min(first + 2 * width - 1, n)
      if less(items[mid + 1], items[mid]) then
        for i = 1, width do
          tmp[i] = items[first + i - 1]
          yield()
        end
        local a, b, out = 1, mid + 1, first
        while a <= width and b <= last do
          if not less(items[b], tmp[a]) then
            items[out], a = tmp[a], a + 1
          else
            items[out], b = items[b], b + 1
          end
          out = out + 1
          yield()
        end
        while a <= width do
          items[out], a, out = tmp[a], a + 1, out + 1
          yield()
        end
      end
      yield()
    end
    width = width * 2
  end
  return items
end
return M
