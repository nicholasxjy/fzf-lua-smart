local M = {}
function M.check()
  local h = vim.health
  h.start("fzf-lua-smart")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim >= 0.11")
  else
    h.error("Neovim >= 0.11 required")
  end
  if jit.os == "Linux" or jit.os == "OSX" then
    h.ok(jit.os)
  else
    h.error("Only Linux/macOS supported")
  end
  local ok = pcall(require, "fzf-lua")
  if ok then
    h.ok("fzf-lua found")
  else
    h.error("fzf-lua is the required plugin dependency")
  end
  local opts = ok and require("fzf-lua.config").globals or {}
  local bin = vim.fn.expand(opts.fzf_bin or "fzf")
  local ran, output = false, ""
  if vim.fn.executable(bin) == 1 then
    ran, output = pcall(vim.fn.system, { bin, "--version" })
  end
  local version = ran and vim.v.shell_error == 0 and output:match("(%d+%.%d+%.%d+)")
  if version and vim.version.ge(version, "0.59.0") and not bin:match("sk$") then
    h.ok("fzf " .. version)
  else
    h.error("fzf >= 0.59 required; skim not supported")
  end
  local tools = {}
  for _, tool in ipairs({ "fdfind", "fd", "rg", "find" }) do
    if vim.fn.executable(tool) == 1 then
      tools[#tools + 1] = tool
    end
  end
  if #tools > 0 then
    h.ok("Finders: " .. table.concat(tools, ", "))
  else
    h.error("No file finder installed")
  end
  local db = require("fzf-lua-smart.config").defaults.db or {}
  local loaded, lib = pcall(require, "fzf-lua-smart.sqlite")
  local sqlite = loaded and pcall(lib.library, db.sqlite3_path)
  if sqlite then
    h.ok("SQLite library available (integer deadlines)")
  else
    h.info("SQLite unavailable; KV fallback (double deadlines)")
  end
  local dir = require("fzf-lua-smart.store").directory()
  local existing = dir
  while not vim.uv.fs_stat(existing) and existing ~= "/" do
    existing = vim.fs.dirname(existing)
  end
  if vim.fn.filewritable(existing) == 2 then
    h.ok("Independent history directory: " .. dir)
  else
    h.warn("History directory not writable: " .. dir .. "; session-memory fallback")
  end
end
return M
