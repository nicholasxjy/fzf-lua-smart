local Task = require("fzf-lua-smart.task")

test("stable sort agrees with total ordering across sizes and input distributions", function()
  for _, count in ipairs({ 0, 1, 2, 3, 7, 16, 31, 100, 1025 }) do
    for _, order in ipairs({ "sorted", "reverse", "mixed", "ties" }) do
      local items = {}
      for i = 1, count do
        items[i] = {
          idx = i,
          score = order == "sorted" and i or order == "reverse" and -i or order == "mixed" and i * 7919 % 17 or 0,
        }
      end
      local expected = vim.deepcopy(items)
      table.sort(expected, function(a, b)
        return a.score < b.score or a.score == b.score and a.idx < b.idx
      end)
      local yields = 0
      local sorted = Task.sort(items, function(a, b)
        return a.score < b.score
      end, function()
        yields = yields + 1
      end)
      eq(sorted, expected, count .. " " .. order)
      assert(sorted == items, "sort must mutate the caller's array")
      assert(count < 2 or yields > 0, "sorting must remain interruptible")
    end
  end
end)

test("stable sort takes linear comparisons for already ordered candidates", function()
  local items, comparisons = {}, 0
  for i = 1, 4096 do
    items[i] = i
  end
  Task.sort(items, function(a, b)
    comparisons = comparisons + 1
    return a < b
  end, function() end)
  assert(comparisons <= #items, "ordered runs must not be merged again")
end)

test("cancelled tasks release suspended coroutine data and run cleanup once", function()
  local refs = setmetatable({}, { __mode = "v" })
  local ready, cleaned = false, 0
  local task = Task.new(function(t)
    local data = { ("payload"):rep(1024) }
    refs[1] = data
    t:on_cancel(function()
      cleaned = cleaned + 1
    end)
    ready = true
    Task.suspend()
    assert(data[1]) -- keep the data live across suspension
  end)
  wait(function()
    return ready
  end)
  collectgarbage("collect")
  assert(refs[1])
  task:abort()
  task:abort()
  collectgarbage("collect")
  eq(cleaned, 1)
  assert(refs[1] == nil, "cancelled coroutine still retains its suspended data")
  eq(task:running(), false)
end)

test("tasks can abort themselves and report errors without retaining their coroutine", function()
  local cleaned, failure = 0, nil
  local task = Task.new(function(t)
    t:on_cancel(function()
      cleaned = cleaned + 1
    end)
    t:abort()
  end)
  wait(function()
    return not task:running()
  end)
  eq(cleaned, 1)
  eq(task.co, nil)
  local failed = Task.new(function()
    error("expected task failure")
  end, function(err)
    failure = err
  end)
  wait(function()
    return failure ~= nil
  end)
  assert(failure:find("expected task failure", 1, true))
  eq(failed.co, nil)
  eq(failed:running(), false)
end)
