local M = {}
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/lua/fzf%-lua%-smart/process.lua$")
-- Pure-data snapshots: callbacks, Neovim handles, history writes and lifecycle
-- stay in the main instance. No session closure is string.dump'ed by fzf-lua.
function M.match(engine, task, yield)
  local matcher, items = engine.matcher, {}
  for i, item in ipairs(engine.items) do
    if item.file and matcher.frecency then
      item.frecency = item.frecency or matcher.frecency:get(item)
    end
    local out = {}
    for k, v in pairs(item) do
      if type(k) == "string" then
        if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
          out[k] = v
        elseif k == "pos" then
          out[k] = { v[1], v[2] }
        else
          out[k] = tostring(v)
        end
      end
    end
    items[i] = out
    yield()
  end
  local opts = {}
  for k, v in pairs(matcher.opts) do
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
      opts[k] = v
    end
  end
  opts.frecency, opts.keep_parents = false, false
  local snapshot = {
    items = items,
    matcher = opts,
    pattern = matcher.pattern,
    cwd = matcher.cwd,
    tick = matcher.tick,
    frecency = matcher.frecency ~= nil,
  }
  local result
  local proc = vim.system(
    { vim.v.progpath, "-u", "NONE", "-l", root .. "/lua/fzf-lua-smart/process_worker.lua", root },
    {
      stdin = vim.mpack.encode(snapshot),
      text = false,
    },
    function(res)
      result = res
      task:resume()
    end
  )
  task:on_cancel(function()
    if not result then
      pcall(proc.kill, proc, 15)
    end
  end)
  while not result do
    require("fzf-lua-smart.task").suspend()
  end
  assert(result.code == 0, "matching worker failed: " .. (result.stderr or ""))
  return vim.mpack.decode(result.stdout)
end
return M
