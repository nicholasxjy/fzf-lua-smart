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
local root = vim.fn.getcwd()
local STARTUP = "fzf_lua_smart_frecency_startup"
local function startup_autocmds()
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = STARTUP })
  return ok and #list or 0
end
local function reset_history(opts)
  F.untrack()
  if F.store then
    F.store:close()
    F.store = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, "fzf_lua_smart_frecency")
  vim.fn.delete(require("fzf-lua-smart.store").directory(), "rf")
  F.opts = opts
end
local function listed(file)
  local buf = vim.fn.bufadd(file)
  vim.bo[buf].buflisted = true
  return buf
end
test("startup tracking queues visits before first use and replays them at their own times", function()
  local now, old_time, oldU = 1700000000, os.time, U.store
  os.time = function()
    return now
  end
  reset_history({ sqlite3_path = "/no/such/library" })
  F.track()
  F.track()
  eq(#vim.api.nvim_get_autocmds({ group = STARTUP, event = "BufWinEnter" }), 1)
  local file = fixture .. "/beta.txt"
  local buf = listed(file)
  local expected = {}
  U.store = memory(expected)
  local item = { file = file, text = "", idx = 1, score = 0 }
  for _, t in ipairs({ now, now + 3 * 86400, now + 40 * 86400 }) do
    now = t
    vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf })
    U.new():visit(item)
  end
  eq(F.store, nil, "visits before first use must not open the store")
  now = now + 86400
  local frecency = F.new()
  eq(F.pending, nil)
  eq(startup_autocmds(), 0)
  eq(F.store:get(file), expected[file])
  eq(frecency:get(item), U.new():get(item))
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf })
  U.new():visit(item)
  eq(F.store:get(file), expected[file], "visits after first use are live")
  U.store, os.time = oldU, old_time
  vim.api.nvim_buf_delete(buf, { force = true })
end)
test("startup tracking writes queued visits on exit and honors setup opt-outs", function()
  local C = require("fzf-lua-smart.config")
  local kv = { sqlite3_path = "/no/such/library" }
  reset_history(kv)
  C.setup({ db = { track_on_startup = false } })
  eq({ F.pending, startup_autocmds() }, { nil, 0 })
  C.setup({ ["matcher.frecency"] = false })
  eq({ F.pending, startup_autocmds() }, { nil, 0 })
  C.setup({ db = kv })
  assert(F.pending, "setup re-enables startup tracking")
  local file = fixture .. "/sub/init.lua"
  local buf = listed(file)
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = buf })
  eq(F.store, nil)
  vim.api.nvim_exec_autocmds("ExitPre", { group = STARTUP })
  eq(F.store, nil)
  local store = require("fzf-lua-smart.store").open(kv)
  assert(store:get(file), "queued visit must be written on exit")
  store:close()
  C.setup()
  F.untrack()
  vim.api.nvim_buf_delete(buf, { force = true })
end)
test("plugin script records startup buffers once and writes them on exit without a picker", function()
  local env = { XDG_DATA_HOME = vim.fn.tempname() }
  local file = fixture .. "/alpha.lua"
  local function nvim(args)
    local cmd = { "nvim", "--headless", "-u", "tests/minimal.lua", "-i", "NONE" }
    vim.list_extend(cmd, args)
    vim.list_extend(cmd, { "+qa!" })
    local r = vim.system(cmd, { cwd = root, env = env, text = true }):wait()
    eq(r.code, 0, r.stderr)
    return r.stdout
  end
  local probe = "+lua local F = require('fzf-lua-smart.vendor.frecency') local n = 0 "
    .. "for _, v in ipairs(F.pending or {}) do n = n + (v.file == %q and 1 or 0) end "
    .. "io.stdout:write(vim.json.encode({ store = F.store ~= nil, visits = n }))"
  eq(vim.json.decode(nvim({ file, probe:format(file) })), { store = false, visits = 1 })
  local read = "+lua io.stdout:write(tostring(require('fzf-lua-smart.store').open({}):get(%q) ~= nil))"
  eq(nvim({ read:format(file) }), "true")
  vim.fn.delete(env.XDG_DATA_HOME, "rf")
end)
