local F = require("fzf-lua-smart.vendor.frecency")
local U = require("snacks.picker.core.frecency")
local function memory(data)
  return {
    get_all = function()
      return data
    end,
    set = function(_, k, v)
      data[k] = v
    end,
    close = function() end,
  }
end
test("frecency differential: frozen clock, seeds, snapshots, decay and visits", function()
  local now, old_time = 1700000000, os.time
  os.time = function()
    return now
  end
  local oldF, oldU = F.store, U.store
  local da, db = {}, {}
  F.store, U.store = memory(da), memory(db)
  local a, b = F.new(), U.new()
  local item = { file = fixture .. "/alpha.lua", info = { lastused = now - 86400 }, text = "", idx = 1, score = 0 }
  eq(a:get(vim.deepcopy(item)), b:get(vim.deepcopy(item)))
  eq(da, {}) -- seeding never writes
  for _, days in ipairs({ 0, 1, 30, 60, 100 }) do
    now = 1700000000 + days * 86400
    a, b = F.new(), U.new()
    eq(a:to_score(a:to_deadline(3.2)), b:to_score(b:to_deadline(3.2)))
    a:visit(item)
    b:visit(item)
    eq(da, db)
    eq(a:get(item), b:get(item))
  end
  F.store, U.store, os.time = oldF, oldU, old_time
end)
test("history SQLite/KV reopen, precision, pruning and independent location", function()
  local S = require("fzf-lua-smart.store")
  local dir = S.directory()
  assert(dir:find("/fzf-lua-smart", 1, true))
  assert(not dir:find("/snacks/", 1, true))
  vim.fn.delete(dir, "rf")
  local kv = S.open({ sqlite3_path = "/no/such/library" })
  eq(kv.kind, "kv")
  for i = 1, 10010 do
    kv:set("/test/" .. i, i + 0.25)
  end
  kv:close()
  kv = S.open({ sqlite3_path = "/no/such/library" })
  eq(vim.tbl_count(kv:get_all()), 10000)
  eq(kv:get("/test/10010"), 10010.25)
  eq(kv:get("/test/1"), nil)
  kv:close()
  local db = S.open({})
  if db.kind == "sqlite" then
    db:set("/number", 100.75)
    eq(db:get("/number"), 100)
    db:close()
    db = S.open({})
    eq(db:get("/number"), 100)
    db:close()
  else
    print("  SQLite library unavailable; KV verified")
  end
end)
test("history corruption is preserved, warns once and falls back to memory", function()
  local S = require("fzf-lua-smart.store")
  local path = S.directory() .. "/frecency.dat"
  vim.fn.writefile({ "CORRUPT" }, path)
  local store = S.open({ sqlite3_path = "/no/library" })
  eq(store.kind, "memory")
  store:set("/x", 123)
  store:close()
  eq(vim.fn.readfile(path), { "CORRUPT" })
  vim.fn.delete(path)
end)
test("history lazy initialization and BufWinEnter registration is idempotent", function()
  if F.store then
    F.store:close()
    F.store = nil
  end
  local before = vim.api.nvim_get_current_buf()
  local buf = vim.fn.bufadd(fixture .. "/alpha.lua")
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local opts = require("fzf-lua-smart.config").resolve({ matcher = { frecency = false } })
  local engine = require("fzf-lua-smart.engine").new(opts)
  eq(F.store, nil)
  engine:close()
  opts.matcher.frecency = true
  engine = require("fzf-lua-smart.engine").new(opts)
  local count = #vim.api.nvim_get_autocmds({ group = "fzf_lua_smart_frecency" })
  local more = require("fzf-lua-smart.engine").new(opts)
  eq(#vim.api.nvim_get_autocmds({ group = "fzf_lua_smart_frecency" }), count)
  assert(F.store:get(fixture .. "/alpha.lua"))
  engine:close()
  more:close()
  vim.api.nvim_set_current_buf(before)
  vim.api.nvim_buf_delete(buf, { force = true })
end)
