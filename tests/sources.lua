local function ctx(opts, module)
  local picker = { opts = opts }
  return { picker = picker, filter = require(module).new(picker), meta = {} }
end
test("buffer and recent differential: metadata, current/unlisted/scratch/oldfiles", function()
  local before = vim.api.nvim_get_current_buf()
  local buffers = {}
  for _, spec in ipairs({ { "alpha.lua", true }, { "beta.txt", false }, { "sub/init.lua", true } }) do
    local buf = vim.fn.bufadd(fixture .. "/" .. spec[1])
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = spec[2]
    buffers[#buffers + 1] = buf
  end
  local scratch = vim.api.nvim_create_buf(true, false)
  buffers[#buffers + 1] = scratch
  vim.api.nvim_set_current_buf(buffers[1])
  vim.v.oldfiles =
    { fixture .. "/alpha.lua", fixture .. "/beta.txt", fixture .. "/missing", fixture .. "/sub/../beta.txt" }
  for _, opts in ipairs({
    {},
    { hidden = true },
    { current = false },
    { unloaded = false },
    { filter = { cwd = fixture } },
    { filter = { buf = true } },
    { filter = { buf = buffers[2] } },
  }) do
    local a = ctx(opts, "fzf-lua-smart.vendor.filter")
    local b = ctx(opts, "snacks.picker.core.filter")
    eq(
      require("fzf-lua-smart.source.buffers").buffers(opts, a),
      require("snacks.picker.source.buffers").buffers(opts, b)
    )
    local ia, ib = {}, {}
    require("fzf-lua-smart.source.recent").files(opts, a)(function(item)
      ia[#ia + 1] = item
    end)
    require("snacks.picker.source.recent").files(opts, b)(function(item)
      ib[#ib + 1] = item
    end)
    eq(ia, ib)
  end
  vim.api.nvim_set_current_buf(before)
  for _, buf in ipairs(buffers) do
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end)
test("unique_file differential: normalize, first occurrence, symlink not realpath", function()
  local link = fixture .. "/link.lua"
  vim.uv.fs_symlink(fixture .. "/alpha.lua", link)
  local a, b = { meta = {} }, { meta = {} }
  for _, item in ipairs({
    { cwd = fixture, file = "alpha.lua" },
    { file = fixture .. "/alpha.lua" },
    { file = fixture .. "/sub/../alpha.lua" },
    { file = link },
    { text = "no file" },
  }) do
    eq(
      require("fzf-lua-smart.vendor.transform").unique_file(vim.deepcopy(item), a),
      require("snacks.picker.transform").unique_file(vim.deepcopy(item), b)
    )
  end
  eq(a, b)
end)
test("source merge: shared top-level overrides source entry and source defaults", function()
  local opts = require("fzf-lua-smart.config").resolve({
    multi = { { source = "buffers", hidden = false } },
    hidden = true,
    sources = { buffers = { hidden = false } },
    matcher = { frecency = false },
  })
  local c = require("fzf-lua-smart.sources").context(opts)
  local expected = require("fzf-lua-smart.source.buffers").buffers(opts, c)
  eq(require("fzf-lua-smart.sources").prepare(opts, c)[1].items, expected)
end)
test("scanner commands: fzf defaults, aliases, backends, extensions, escaping and raw_cmd", function()
  local resolve = require("fzf-lua-smart.config").resolve
  local command = require("fzf-lua-smart.scanner").command
  local base = resolve({ matcher = { frecency = false } })
  eq(command(base, ""), require("fzf-lua.providers.files").get_files_cmd(vim.deepcopy(base)))
  local raw = resolve({ raw_cmd = "printf '%s\\n' x", hidden = false, no_ignore = true })
  eq(command(raw, "$(touch /tmp/NO)"), raw.raw_cmd)
  assert(not pcall(command, resolve({ cmd = "echo x", ft = "lua" }), ""))
  for _, backend in ipairs({ "fd", "fdfind", "rg", "find" }) do
    if vim.fn.executable(backend) == 1 then
      local o = resolve({
        finder_cmd = backend,
        cwd = fixture,
        hidden = false,
        follow = false,
        ignored = true,
        ft = "lua",
        exclude = { "beta*" },
        dirs = { "." },
        args = {},
      })
      local cmd = command(o, "")
      assert(cmd:find("lua", 1, true))
      assert(cmd:find("beta", 1, true))
      assert(not cmd:find("--hidden", 1, true))
      local out = vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { cwd = fixture }):wait()
      eq(out.code, 0, cmd .. "\n" .. out.stderr)
      assert(out.stdout:find("alpha.lua", 1, true))
    end
  end
end)
test("find follow with explicit roots does not scan the process cwd", function()
  local o = require("fzf-lua-smart.config").resolve({
    cwd = fixture,
    finder_cmd = "find",
    follow = true,
    hidden = false,
    search_paths = { "sub" },
    matcher = { frecency = false },
  })
  local command = require("fzf-lua-smart.scanner").command(o, "")
  assert(command:find("find -L 'sub'", 1, true), command)
  local out = vim.system({ vim.o.shell, vim.o.shellcmdflag, command }, { cwd = fixture }):wait()
  eq(out.code, 0)
  assert(out.stdout:find("sub/init.lua", 1, true))
  assert(not out.stdout:find("alpha.lua", 1, true))
end)
