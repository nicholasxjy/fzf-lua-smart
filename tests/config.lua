local C = require("fzf-lua-smart.config")
test("smart matcher defaults and all nine overrides agree with Snacks", function()
  local generic = require("snacks.picker.config.defaults").defaults.matcher
  local smart = vim.tbl_deep_extend("force", {}, generic, require("snacks.picker.config.sources").smart.matcher)
  eq(C.algorithm_defaults().matcher, smart)
  eq(C.resolve({}).matcher, smart)
  eq(C.resolve({ matcher = generic }).matcher, generic)
  eq(C.algorithm_defaults().sort, require("snacks.picker.config.defaults").defaults.sort)
  eq(vim.tbl_count(smart), 9)
  for key, value in pairs(smart) do
    C.setup({ matcher = { [key] = not value } })
    eq(C.resolve({}).matcher, vim.tbl_extend("force", {}, smart, { [key] = not value }), key .. " setup")
    eq(C.resolve({ matcher = { [key] = value } }).matcher, smart, key .. " call")
  end
  C.setup({})
end)
test("config precedence, aliases, lists, false, functions and non-mutation", function()
  local fzf = require("fzf-lua")
  fzf.setup({
    defaults = { prompt = "global>", ignored = true, dirs = { "/global" } },
    files = { hidden = true, prompt = "files>", matcher = { filename_bonus = false } },
  })
  local setup = { ignored = false, dirs = { "/setup" }, multi = { "files" }, matcher = { frecency = false } }
  local call = { no_ignore = true, ignored = false, search_paths = { fixture }, dirs = { "/wrong" }, hidden = false }
  local saved_setup, saved_call = vim.deepcopy(setup), vim.deepcopy(call)
  C.setup(setup)
  local opts = C.resolve(function()
    return call
  end)
  eq(opts.prompt, "files>")
  eq(opts.no_ignore, true)
  eq(opts.search_paths, { fixture })
  eq(opts.hidden, false)
  eq(opts.matcher.filename_bonus, false)
  eq(opts.matcher.frecency, false)
  eq(opts.multi, { "files" })
  eq(setup, saved_setup)
  eq(call, saved_call)
  C.setup({})
  fzf.setup({})
end)
test("config reads fzf setup afresh and does not register or replace providers", function()
  local fzf = require("fzf-lua")
  local files = fzf.files
  fzf.setup({ files = { prompt = "first>" } })
  eq(C.resolve({}).prompt, "first>")
  fzf.setup({ files = { prompt = "second>" } })
  eq(C.resolve({}).prompt, "second>")
  C.setup({})
  C.setup({})
  eq(fzf.files, files)
  eq(rawget(fzf, "smart"), nil)
  fzf.setup({})
end)
test("line_query inheritance suppressed before normalize; function retained for adapter", function()
  local parse = function(q)
    return 3, q:gsub("@3", "")
  end
  require("fzf-lua").setup({ files = { line_query = parse } })
  local o = C.resolve({})
  eq(o.__smart_line_query, parse)
  eq(o.line_query, false)
  for _, arg in ipairs(o._fzf_cli_args) do
    assert(not arg:find("start,change:+transform:", 1, true))
  end
  require("fzf-lua").setup({})
end)
test("explicit conflicting fzf options/binds fail, normal UI maps survive", function()
  local smart = require("fzf-lua-smart")
  for _, options in ipairs({
    { fzf_opts = { ["--sort"] = true } },
    { fzf_opts = { ["--tac"] = true } },
    { keymap = { fzf = { ["ctrl-z"] = "enable-search" } } },
    { fzf_args = "--sort" },
    { fn_reload = function() end },
  }) do
    assert(not pcall(function()
      smart.validate(C.resolve(options))
    end))
  end
  local o = C.resolve({ keymap = { fzf = { ["ctrl-z"] = "toggle-preview" } } })
  smart.validate(o)
  eq(o.keymap.fzf["ctrl-z"], "toggle-preview")
  eq(o.fzf_opts["--no-sort"], true)
  eq(o.fzf_opts["--disabled"], true)
  smart.validate(C.resolve({ keymap = { fzf = { ["ctrl-z"] = "execute-silent(echo search)" } } }))
end)
test("profiles and native function-valued UI configuration remain usable", function()
  local o = C.resolve({
    profile = "default",
    winopts = function()
      return { width = 0.6 }
    end,
    actions = function()
      return { enter = function() end }
    end,
  })
  eq(o.winopts.width, 0.6)
  assert(type(o.actions.enter) == "function" or type(o.actions.enter.fn) == "function")
end)
test("function-valued keymap and fzf_opts conflicts are rejected after native resolution", function()
  for _, options in ipairs({
    {
      keymap = function()
        return { fzf = { ["ctrl-r"] = "toggle-sort" } }
      end,
    },
    {
      fzf_opts = function()
        return { ["--sort"] = true }
      end,
    },
  }) do
    assert(not pcall(function()
      require("fzf-lua-smart").validate(C.resolve(options))
    end))
  end
  require("fzf-lua").setup({
    files = {
      keymap = function()
        return { fzf = { ["ctrl-z"] = "reload(echo x)" } }
      end,
    },
  })
  assert(not pcall(function()
    require("fzf-lua-smart").validate(C.resolve({}))
  end))
  require("fzf-lua").setup({})
end)
test("alternate and raw fzf controls cannot bypass search and transport ownership", function()
  for _, options in ipairs({
    { fzf_opts = { ["--enabled"] = true } },
    { fzf_opts = { ["--no-read0"] = true } },
    { fzf_opts = { ["--accept-nth"] = "2" } },
    { fzf_raw_args = "--enabled" },
    { fzf_args = { "--tac" } },
    { fzf_cli_args = { "--no-print0" } },
    { fzf_opts = { ["--bind"] = { "ctrl-z:toggle-preview", "ctrl-s:toggle-sort" } } },
  }) do
    assert(not pcall(function()
      require("fzf-lua-smart").validate(C.resolve(options))
    end), vim.inspect(options))
  end
end)
test("explicit global fzf ordering/transport overrides cannot silently bypass ownership", function()
  require("fzf-lua").setup({ fzf_opts = { ["--sort"] = true } })
  assert(not pcall(function()
    require("fzf-lua-smart").validate(C.resolve({}))
  end))
  require("fzf-lua").setup({})
  assert(not pcall(function()
    require("fzf-lua-smart").validate(C.resolve({ fzf_opts = { ["--read0"] = false } }))
  end))
end)
test("checkhealth reports a missing configured fzf binary without throwing", function()
  local previous, errors = vim.health, {}
  vim.health = setmetatable({}, {
    __index = function(_, key)
      return function(message)
        if key == "error" then
          errors[#errors + 1] = message
        end
      end
    end,
  })
  require("fzf-lua").setup({ fzf_bin = fixture .. "/not-installed-fzf" })
  local ok, err = pcall(require("fzf-lua-smart.health").check)
  require("fzf-lua").setup({})
  vim.health = previous
  assert(ok, err)
  assert(#errors > 0 and errors[1]:find("fzf", 1, true))
end)
test("explicit empty algorithm lists replace defaults and inherited line_query=false is preserved", function()
  local opts = C.resolve({ multi = {}, sort = { fields = {} } })
  eq(opts.multi, {})
  eq(opts.sort.fields, {})
  require("fzf-lua").setup({ defaults = { line_query = false } })
  eq(C.resolve({}).__smart_line_query, false)
  require("fzf-lua").setup({})
end)
