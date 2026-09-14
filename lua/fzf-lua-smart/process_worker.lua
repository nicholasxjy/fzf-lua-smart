-- Headless, one-shot matching bridge. All input/output is MessagePack data.
vim.opt.runtimepath:prepend(assert(arg[1]))
local snapshot = vim.mpack.decode(io.stdin:read("*a"))
local matcher = require("fzf-lua-smart.vendor.matcher").new(snapshot.matcher)
matcher:init(snapshot.pattern)
matcher.cwd, matcher.tick = snapshot.cwd, snapshot.tick
if snapshot.frecency then
  matcher.frecency = {
    get = function(_, item)
      return item.frecency
    end,
  }
end
local result = {}
for i, item in ipairs(snapshot.items) do
  local matched = matcher:update({}, item)
  result[i] = {
    matched = matched,
    score = item.score,
    pos = item.pos,
    match_pos = item.match_pos,
    match_tick = item.match_tick,
    frecency = item.frecency,
  }
end
io.stdout:write(vim.mpack.encode(result))
io.stdout:flush()
