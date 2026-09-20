-- Deterministic hot-path benchmarks, independent of scanner/fzf startup and IO.
-- Run: nvim --headless -u tests/minimal.lua -l scripts/benchmark_core.lua
local Matcher = require("fzf-lua-smart.vendor.matcher")
local Task = require("fzf-lua-smart.task")
local less = require("fzf-lua-smart.vendor.sort").default({ fields = { "score:desc", "#text", "idx" } })
local function noop() end

local function measure(name, count, prepare, run)
  local times, allocations, checksum = {}, {}, nil
  for iteration = 0, 3 do
    local input = prepare()
    collectgarbage("collect")
    collectgarbage("stop")
    local memory, start = collectgarbage("count"), vim.uv.hrtime()
    local ok, value = pcall(run, input)
    local elapsed = (vim.uv.hrtime() - start) / 1e6
    local allocated = collectgarbage("count") - memory
    collectgarbage("restart")
    assert(ok, value)
    assert(checksum == nil or checksum == value, "nondeterministic benchmark")
    checksum = value
    if iteration > 0 then
      times[#times + 1], allocations[#allocations + 1] = elapsed, allocated
    end
  end
  table.sort(times)
  table.sort(allocations)
  print(vim.json.encode({
    benchmark = name,
    candidates = count,
    median_ms = times[2],
    allocated_kib = allocations[2],
    checksum = checksum,
  }))
end

for _, count in ipairs({ 10000, 100000 }) do
  local items = {}
  for i = 1, count do
    local file = ("src/group%d/file%06d.lua"):format(i % 100, i)
    items[i] = { text = file, file = file, score = 1000, idx = i }
  end
  for _, case in ipairs({ { "fuzzy", "flua" }, { "regex", "file.*lua", regex = true } }) do
    local matcher = Matcher.new({ filename_bonus = true, regex = case.regex })
    matcher:init(case[2])
    measure(case[1], count, function()
      return items
    end, function(input)
      local score = 0
      for _, item in ipairs(input) do
        score = score + matcher:match(item)
      end
      return score
    end)
  end
  for _, order in ipairs({ "sorted", "reverse", "mixed" }) do
    measure("sort_" .. order, count, function()
      local input = vim.deepcopy(items)
      if order == "sorted" then
        table.sort(input, less)
      elseif order == "reverse" then
        table.sort(input, function(a, b)
          return less(b, a)
        end)
      else
        for i, item in ipairs(input) do
          item.score = (i * 7919) % count
        end
      end
      return input
    end, function(input)
      Task.sort(input, less, noop)
      local sum = 0
      for i, item in ipairs(input) do
        assert(i == 1 or not less(item, input[i - 1]), "unsorted benchmark result")
        sum = sum + i * item.idx
      end
      return sum
    end)
  end
end

for _, size in ipairs({ 128, 512, 2048 }) do
  local matcher = Matcher.new({ filename_bonus = true })
  matcher:init("ab")
  local item = { text = ("a"):rep(size) .. "/b", file = "repeated" }
  measure("fuzzy_repeated_" .. size, 1000, function()
    return item
  end, function(input)
    local score = 0
    for _ = 1, 1000 do
      score = score + matcher:match(input)
    end
    return score
  end)
end
vim.cmd("qa!")
