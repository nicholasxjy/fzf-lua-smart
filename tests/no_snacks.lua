-- This process never adds Snacks to runtimepath, including during history setup.
local done = false
local _, _, opts = require("fzf-lua-smart").smart({
  _start = false,
  file_icons = false,
  multi = { "files" },
  raw_cmd = "echo one.lua",
  matcher = { frecency = true },
})
assert(opts and not package.loaded.snacks and not _G.Snacks)
local resolved = require("fzf-lua-smart.config").resolve({
  multi = { "files" },
  file_icons = false,
  raw_cmd = "echo one.lua",
  matcher = { frecency = true },
})
local engine = require("fzf-lua-smart.engine").new(resolved)
engine:request("one", function(s)
  if not s then
    done = true
  end
end)
assert(vim.wait(10000, function()
  return done
end))
assert(#engine.results == 1)
assert(not package.loaded.snacks and not _G.Snacks)
engine:close()
print("PASS runtime without Snacks installed")
vim.cmd("qa!")
