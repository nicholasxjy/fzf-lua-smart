local tests, passed = {}, 0
_G.test = function(name, fn)
  tests[#tests + 1] = { name, fn }
end
_G.eq = function(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    (message or "not equal") .. "\nactual: " .. vim.inspect(actual) .. "\nexpected: " .. vim.inspect(expected)
  )
end
_G.wait = function(fn, ms)
  assert(vim.wait(ms or 10000, fn, 10), "timed out")
end
_G.fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/sub", "p")
-- Neovim resolves macOS /var symlinks in buffer names and frecency keys.
_G.fixture = assert(vim.uv.fs_realpath(fixture))
for _, file in ipairs({ "alpha.lua", "beta.txt", "sub/init.lua", ".hidden" }) do
  vim.fn.writefile({ "one", "two", "three" }, fixture .. "/" .. file)
end
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/.deps/snacks.nvim")
require("snacks")
for _, name in ipairs({ "matcher", "sources", "config", "history", "engine", "display", "integration" }) do
  dofile("tests/" .. name .. ".lua")
end
local errors = {}
for _, t in ipairs(tests) do
  local ok, err = xpcall(t[2], debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. t[1])
  else
    errors[#errors + 1] = t[1] .. ": " .. err
    print("FAIL " .. errors[#errors])
  end
end
print(("%d/%d tests passed"):format(passed, #tests))
vim.fn.delete(fixture, "rf")
if #errors > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
