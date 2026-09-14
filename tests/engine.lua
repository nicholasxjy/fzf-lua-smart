local function run(options, query, remote)
  local o = require("fzf-lua-smart.config").resolve(vim.tbl_deep_extend("force", {
    cwd = fixture,
    multi = { "files" },
    file_icons = false,
    matcher = { frecency = false },
  }, options or {}))
  local e = require("fzf-lua-smart.engine").new(o)
  e.multiprocess = remote
  local done = false
  e:request(query or "", function(s)
    if not s then
      done = true
    end
  end)
  wait(function()
    return done
  end)
  assert(e.results, "no results published")
  return e
end
_G.run_engine = run
test("engine fixed candidate order, unique_file, empty-query ranking and no truncation", function()
  local e = run({ raw_cmd = "printf '%s\\n' beta.txt alpha.lua beta.txt sub/init.lua" })
  eq(#e.items, 3)
  eq(e.items[1].file, "beta.txt")
  eq(e.items[2].file, "alpha.lua")
  eq(e.results[1].file, "beta.txt")
  eq(e.results[3].file, "sub/init.lua")
  eq(e.scans, 1)
  local done = false
  e:request("alpha", function(s)
    if not s then
      done = true
    end
  end)
  wait(function()
    return done
  end)
  eq(e.scans, 1)
  eq(#e.results, 1)
  e:close()
end)
test("live query refreshes finder search but preserves independent matcher pattern", function()
  local e = run({ live = true, pattern = "lua" }, "alpha")
  eq(#e.results, 1)
  eq(e.matcher.pattern, "lua")
  local done = false
  e:request("beta", function(s)
    if not s then
      done = true
    end
  end)
  wait(function()
    return done
  end)
  eq(e.scans, 2)
  eq(#e.results, 0)
  e:close()
end)
test("filter.transform controls refresh/search state; transform sees search-only context", function()
  local calls = 0
  local e = run({
    filter = {
      transform = function(picker, filter)
        assert(picker.opts and picker.find and picker.count and not picker.win)
        calls = calls + 1
        filter.search = ""
        return false
      end,
    },
    transform = function(item, ctx)
      assert(ctx:cwd() == fixture)
      assert(ctx.async and ctx.async:running(), "transform must receive the active collection task")
      item.score_add = 4
    end,
  }, "alpha")
  eq(calls, 1)
  eq(e.results[1].score_add, 4)
  local entries = {}
  for item, index in e.ctx.picker:iter() do
    eq(item, e.results[index])
    entries[#entries + 1] = item
  end
  eq(entries, e.results)
  e:close()
end)
test("keep_parents retains a later unmatched parent exactly once in both execution modes", function()
  for _, remote in ipairs({ false, true }) do
    local child
    local e = run({
      raw_cmd = "printf '%s\\n' child.lua parent.lua",
      matcher = { keep_parents = true },
      transform = function(item)
        if item.file == "child.lua" then
          child = item
        else
          child.parent = item
        end
      end,
    }, "child", remote)
    for _ = 1, 2 do
      eq(#e.results, 2)
      eq(e.results[2].file, "parent.lua")
      eq(e.results[2].score, 1)
      eq(e.results[2].child_match_only, true)
      local done = false
      e:request("child", function(s)
        if not s then
          done = true
        end
      end)
      wait(function()
        return done
      end)
    end
    e:close()
  end
end)
test("multiprocess snapshot matches main process score/order/positions", function()
  local options = { raw_cmd = "printf '%s\\n' sub/init.lua alpha.lua beta.txt", matcher = { frecency = true } }
  local a, b = run(options, "lua", false), run(options, "lua", true)
  eq(a.results, b.results)
  a:close()
  b:close()
end)
test("generation cancels stale matches and close cancels scanning process", function()
  local e = run({ raw_cmd = "printf '%s\\n' alpha.lua beta.txt" })
  local old, done = 0, false
  e:request("alpha", function(s)
    if s then
      old = old + 1
    end
  end)
  e:request("beta", function(s)
    if not s then
      done = true
    end
  end)
  wait(function()
    return done
  end)
  eq(old, 0)
  eq(e.results[1].file, "beta.txt")
  e:close()
  local opts = require("fzf-lua-smart.config").resolve({
    cwd = fixture,
    multi = { "files" },
    raw_cmd = "sleep 10; echo stale",
    matcher = { frecency = false },
  })
  local pending = require("fzf-lua-smart.engine").new(opts)
  pending:request("", function() end)
  vim.wait(50)
  pending:close()
  assert(pending.scan.cancelled)
  vim.wait(250)
  eq(#pending.items, 0)
end)
test("display identity survives shortening/formatter and preserves buffer/location", function()
  local o = require("fzf-lua-smart.config").resolve({
    cwd = fixture,
    file_icons = false,
    path_shorten = 1,
    formatter = "path.filename_first",
    matcher = { frecency = false },
  })
  local render = require("fzf-lua-smart.display").setup(o)
  local m = require("fzf-lua-smart.vendor.matcher").new({ frecency = false })
  m:init("init")
  local item = { file = fixture .. "/sub/init.lua", text = fixture .. "/sub/init.lua", buf = 99, pos = { 3, 2 } }
  local line = require("fzf-lua-smart.display").entry(item, m, render)
  local decoded = require("fzf-lua.path").entry_to_file(line, o)
  eq(decoded.path, item.file)
  eq(decoded.bufnr, 99)
  eq(decoded.line, 3)
  eq(decoded.col, 3)
end)
test("line_query nil/false/true/function is handled once with native precedence", function()
  local base = { raw_cmd = "printf '%s\\n' alpha.lua sub/init.lua" }
  local a = run_engine(base, "alpha.lua:3:2")
  eq(a.results[1].pos, { 3, 2 })
  a:close()
  local b = run_engine(vim.tbl_extend("force", base, { line_query = false }), "alpha.lua:3")
  eq(#b.results, 0)
  b:close()
  local c = run_engine(vim.tbl_extend("force", base, { line_query = true }), "alpha.lua:3")
  eq(c.results[1].pos, { 3, 0 })
  c:close()
  local d = run_engine(
    vim.tbl_extend("force", base, {
      line_query = function(q)
        return 2, q:gsub("@2", "")
      end,
    }),
    "alpha@2"
  )
  eq(d.results[1].pos, { 2, 0 })
  d:close()
  local e = run_engine(
    vim.tbl_extend("force", base, {
      line_query = function()
        return nil, nil
      end,
    }),
    "alpha"
  )
  eq(#e.results, 1)
  eq(e.results[1].pos, nil)
  e:close()
end)
test("late reload after close is ignored rather than restarting cancelled work", function()
  local e = run_engine({ raw_cmd = "echo alpha.lua" })
  local scans = e.scans
  e:close()
  local eof = false
  e:request("late", function(s)
    assert(s == nil)
    eof = true
  end)
  eq(e.scans, scans)
  eq(eof, true)
  eq(e.closed, true)
end)
test("repeated queries clone the input filter, not an ever-growing transformed chain", function()
  local n = 0
  local e = run_engine({
    raw_cmd = "echo alpha.lua",
    filter = {
      transform = function(_, f)
        n = n + 1
        eq(f.search, "")
        f.search = "transformed"
      end,
    },
  })
  for i = 1, 250 do
    e:request("alpha" .. i, function() end)
  end
  eq(n, 251)
  eq(e.scans, 1)
  e:close()
end)
test("empty and failed finders publish EOF without fabricated candidates", function()
  local empty = run_engine({ raw_cmd = ":" })
  eq(#empty.results, 0)
  empty:close()
  local notify, errors = vim.notify, {}
  vim.notify = function(msg)
    errors[#errors + 1] = msg
  end
  local failed = run_engine({ raw_cmd = "echo finder-error >&2; exit 3" })
  vim.notify = notify
  eq(#failed.results, 0)
  eq(#errors, 1)
  assert(errors[1]:find("finder-error", 1, true))
  failed:close()
end)
test("explicit finder limit cancels the remaining shell pipeline", function()
  local start = vim.uv.hrtime()
  local e = run_engine({ raw_cmd = "printf '%s\n' a b c d; sleep 10", limit = 2 })
  eq(#e.items, 2)
  assert((vim.uv.hrtime() - start) / 1e6 < 3000)
  e:close()
end)
test("scheduled task yields return to libuv so input/timers can interrupt work", function()
  local ticks, done = 0, false
  local timer = vim.uv.new_timer()
  timer:start(
    0,
    2,
    vim.schedule_wrap(function()
      ticks = ticks + 1
    end)
  )
  local Task = require("fzf-lua-smart.task")
  Task.new(function()
    for _ = 1, 30 do
      Task.yield()
    end
    done = true
  end)
  wait(function()
    return done
  end)
  timer:stop()
  timer:close()
  assert(ticks >= 3)
end)
test("callback refresh requests do not recursively reuse a one-shot reload pipe", function()
  local calls = 0
  local e = run_engine({
    raw_cmd = "echo alpha.lua",
    filter = {
      transform = function(search)
        calls = calls + 1
        search:find()
      end,
    },
  })
  eq(calls, 1)
  eq(e.force, true)
  eq(#e.results, 1)
  e:close()
end)
