test("real fzf disabled matching/no-sort preserves published order and multi-selection", function()
  local selected
  local _, _, opts = require("fzf-lua-smart").smart({
    cwd = fixture,
    multi = { "files" },
    file_icons = false,
    raw_cmd = "printf '%s\\n' beta.txt alpha.lua sub/init.lua",
    matcher = { frecency = false },
    query = "file:lua",
    previewer = false,
    actions = {
      enter = function(lines, o)
        selected = {}
        for _, line in ipairs(lines) do
          selected[#selected + 1] = require("fzf-lua.path").entry_to_file(line, o).path
        end
      end,
    },
  })
  assert(opts and opts.__smart)
  wait(function()
    return opts.__smart.results and opts.__smart.sink == nil
  end)
  vim.wait(200)
  local win = require("fzf-lua.win").__SELF()
  assert(win and win.fzf_bufnr)
  local chan = vim.bo[win.fzf_bufnr].channel
  vim.api.nvim_chan_send(chan, "\t\t\r")
  wait(function()
    return selected ~= nil
  end)
  eq(selected, { fixture .. "/alpha.lua", fixture .. "/sub/init.lua" })
  assert(opts.__smart.closed)
end)
test("real fzf resumes smart query with independent files resume record", function()
  local C = require("fzf-lua.config")
  C.resume_set(nil, { query = "native-files" }, { __resume_key = "files" })
  local _, _, o = require("fzf-lua-smart").smart({ resume = true, previewer = false })
  eq(o.query, "file:lua")
  eq(o.__resume_key, "fzf-lua-smart")
  wait(function()
    return o.__smart.results and not o.__smart.sink
  end)
  vim.wait(100)
  local win = require("fzf-lua.win").__SELF()
  vim.api.nvim_chan_send(vim.bo[win.fzf_bufnr].channel, "\3")
  wait(function()
    return o.__smart.closed
  end)
  eq(C.resume_get(nil, { __resume_key = "files" }).query, "native-files")
end)
local function ready(o)
  wait(function()
    return o.__smart.results and not o.__smart.sink
  end)
  vim.wait(150)
  return require("fzf-lua.win").__SELF()
end
local function send(win, keys)
  vim.api.nvim_chan_send(vim.bo[win.fzf_bufnr].channel, keys)
end
test("real fzf native cat preview decodes shortened paths and normal file edit jumps", function()
  local before = vim.api.nvim_get_current_buf()
  local _, _, o = require("fzf-lua-smart").smart({
    cwd = fixture,
    multi = { "files" },
    file_icons = false,
    raw_cmd = "printf '%s\\n' alpha.lua sub/init.lua",
    matcher = { frecency = false },
    query = "sub/init.lua:2:1",
    previewer = "cat",
    path_shorten = 1,
    formatter = "path.filename_first",
    actions = { enter = require("fzf-lua.actions").file_edit },
  })
  local win = ready(o)
  vim.wait(350)
  send(win, "\r")
  wait(function()
    return o.__smart.closed
  end)
  eq(vim.api.nvim_buf_get_name(0), fixture .. "/sub/init.lua")
  eq(vim.api.nvim_win_get_cursor(0), { 2, 1 })
  if vim.api.nvim_buf_is_valid(before) then
    vim.api.nvim_set_current_buf(before)
  end
end)
test("real fzf builtin preview, buffer identity, quickfix/loclist and delete actions", function()
  local buf = vim.fn.bufadd(fixture .. "/beta.txt")
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local captured
  local _, _, o = require("fzf-lua-smart").smart({
    cwd = fixture,
    multi = { "buffers" },
    hidden = false,
    matcher = { frecency = false },
    query = "beta.txt",
    file_icons = false,
    previewer = "builtin",
    copen = false,
    lopen = false,
    actions = {
      enter = function(lines, opts)
        captured = lines
        require("fzf-lua.actions").file_sel_to_qf(lines, opts)
        require("fzf-lua.actions").file_sel_to_ll(lines, opts)
      end,
    },
  })
  local win = ready(o)
  assert(win._previewer)
  send(win, "\r")
  wait(function()
    return captured ~= nil
  end)
  eq(vim.fn.getqflist()[1].bufnr, buf)
  eq(vim.fn.getloclist(0)[1].bufnr, buf)
  require("fzf-lua.actions").buf_del(captured, o)
  eq(vim.api.nvim_buf_is_valid(buf), false)
end)
test("real fzf input changes do not rescan; hidden toggle returns to smart", function()
  local _, _, o = require("fzf-lua-smart").smart({
    cwd = fixture,
    multi = { "files" },
    file_icons = false,
    matcher = { frecency = false },
    query = "",
    hidden = false,
    previewer = false,
    actions = { ["alt-h"] = require("fzf-lua.actions").toggle_hidden },
  })
  local win = ready(o)
  send(win, "alpha")
  wait(function()
    return o.__smart.query == "alpha" and not o.__smart.sink
  end)
  eq(o.__smart.scans, 1)
  send(win, "\27h")
  wait(function()
    local current = require("fzf-lua.config").__resume_data.opts
    return current ~= o and current.__smart ~= nil
  end)
  local current = require("fzf-lua.config").__resume_data.opts
  eq(current.hidden, true)
  eq(current.query, "alpha")
  eq(current.__resume_key, "fzf-lua-smart")
  win = ready(current)
  send(win, "\3")
  wait(function()
    return current.__smart.closed
  end)
end)
test("real smart setup and call matcher overrides change results in both execution modes", function()
  local smart = require("fzf-lua-smart")
  smart.setup({ matcher = { fuzzy = false, smartcase = false, ignorecase = false, frecency = false } })
  for _, remote in ipairs({ false, true }) do
    for _, override in ipairs({ {}, { fuzzy = true } }) do
      local _, _, opts = smart.smart({
        cwd = fixture,
        multi = { "files" },
        raw_cmd = "printf '%s\\n' a_b.lua ab.lua Ab.lua",
        query = "ab",
        matcher = override,
        multiprocess = remote,
        file_icons = false,
        previewer = false,
      })
      local win = ready(opts)
      local files = vim.tbl_map(function(item)
        return item.file
      end, opts.__smart.results)
      eq(files, override.fuzzy and { "ab.lua", "a_b.lua" } or { "ab.lua" })
      send(win, "\3")
      wait(function()
        return opts.__smart.closed
      end)
    end
  end
  smart.setup({})
end)
test("real fzf hide/unhide resumes smart and closes resources", function()
  local _, _, o = require("fzf-lua-smart").smart({
    cwd = fixture,
    multi = { "files" },
    file_icons = false,
    matcher = { frecency = false },
    query = "alpha",
    previewer = false,
  })
  local win = ready(o)
  win:hide()
  assert(o.__smart.closed)
  require("fzf-lua").resume()
  wait(function()
    return not o.__smart.closed
  end)
  win = ready(o)
  send(win, "\3")
  wait(function()
    return o.__smart.closed
  end)
end)

test("real fzf match colors agree with files on both rows and update with the query", function()
  vim.api.nvim_set_hl(0, "SmartIntegrationMatch", { fg = "#112233" })
  local function cells(win, word)
    local colors = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(win.fzf_bufnr, 0, -1, false)) do
      local col = line:find(word, 1, true)
      if col and line:find(".lua", 1, true) then
        vim.cmd("redraw!")
        local pos = vim.fn.screenpos(win.fzf_winid, row, col)
        local cell = vim.api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)
        eq(cell[1], word:sub(1, 1))
        colors[#colors + 1] = cell[2].foreground
      end
    end
    return colors
  end
  for _, smart in ipairs({ false, true }) do
    local picker = smart and require("fzf-lua-smart").smart or require("fzf-lua").files
    local _, _, o = picker({
      cwd = fixture,
      multi = { "files" },
      raw_cmd = "printf '%s\\n' alpha.lua sub/init.lua",
      file_icons = false,
      matcher = { frecency = false },
      query = smart and "file:lua" or "lua",
      formatter = "path.filename_first",
      path_shorten = 1,
      previewer = false,
      -- Split windows let the headless test inspect the actual terminal cells.
      winopts = { split = "belowright new", treesitter = false },
      fzf_colors = true,
      hls = { fzf = { match = "SmartIntegrationMatch" } },
    })
    local win = require("fzf-lua.win").__SELF()
    wait(function()
      local lines = table.concat(vim.api.nvim_buf_get_lines(win.fzf_bufnr, 0, -1, false), "\n")
      return lines:find("alpha.lua", 1, true) and lines:find("init.lua", 1, true)
    end)
    eq(cells(win, "lua"), { 0x112233, 0x112233 })
    if smart then
      send(win, "\21file:init")
      wait(function()
        return o.__smart.query == "file:init" and not o.__smart.sink
      end)
      wait(function()
        return not table
          .concat(vim.api.nvim_buf_get_lines(win.fzf_bufnr, 0, -1, false), "\n")
          :find("alpha.lua", 1, true)
      end)
      eq(cells(win, "init"), { 0x112233 })
      assert(cells(win, "lua")[1] ~= 0x112233, "old match colors must be removed on reload")
    end
    send(win, "\3")
    wait(function()
      return not vim.api.nvim_buf_is_valid(win.fzf_bufnr)
    end)
  end
end)
