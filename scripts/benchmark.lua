local function bench(count)
  local file = vim.fn.tempname()
  local fd = assert(io.open(file, "w"))
  for i = 1, count do
    fd:write(("src/group%d/file%06d.lua\n"):format(i % 100, i))
  end
  fd:close()
  local max_gap, last = 0, vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  timer:start(
    0,
    10,
    vim.schedule_wrap(function()
      local now = vim.uv.hrtime()
      max_gap = math.max(max_gap, (now - last) / 1e6)
      last = now
    end)
  )
  local start = vim.uv.hrtime()
  local _, _, opts = require("fzf-lua-smart").smart({
    multi = { "files" },
    raw_cmd = "cat " .. vim.fn.shellescape(file),
    file_icons = false,
    matcher = { frecency = false },
    cwd = vim.fn.getcwd(),
    previewer = false,
    fzf_opts = { ["--info"] = "inline" },
  })
  local e = opts.__smart
  assert(vim.wait(120000, function()
    return e.results and not e.sink
  end, 10))
  assert(#e.results == count and #e.items == count)
  local win = require("fzf-lua.win").__SELF()
  assert(
    vim.wait(120000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(win.fzf_bufnr, 0, -1, false), "\n")
      return text:find(count .. "/" .. count, 1, true) ~= nil
    end, 10),
    "fzf did not display the complete candidate count"
  )
  local total = (vim.uv.hrtime() - start) / 1e6
  print(vim.json.encode({
    candidates = count,
    scan_ms = e.scan_ms,
    match_ms = e.match_ms,
    sort_ms = e.sort_ms,
    total_to_fzf_count_ms = total,
    max_timer_gap_ms = max_gap,
    memory_kib = collectgarbage("count"),
  }))
  local scans = e.scans
  vim.api.nvim_chan_send(vim.bo[win.fzf_bufnr].channel, "file9")
  assert(vim.wait(120000, function()
    return e.query == "file9" and not e.sink
  end, 10))
  assert(e.scans == scans)
  vim.api.nvim_chan_send(vim.bo[win.fzf_bufnr].channel, "\3")
  assert(vim.wait(10000, function()
    return e.closed
  end))
  timer:stop()
  timer:close()
  vim.fn.delete(file)
end
bench(10000)
bench(100000)
vim.cmd("qa!")
