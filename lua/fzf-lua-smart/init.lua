local M = {}
function M.setup(opts)
  require("fzf-lua-smart.config").setup(opts)
end

local forbidden = { "enable-search", "toggle-search", "toggle-sort", "change-nth", "reload", "reload-sync", "search" }
local function check_bind(value)
  if type(value) == "table" then
    for _, bind in ipairs(value) do
      check_bind(bind)
    end
    return
  end
  if type(value) ~= "string" then
    return
  end
  for _, action in ipairs(forbidden) do
    local pattern = action:gsub("%-", "%%-") .. "%f[^%a%-]"
    assert(
      not value:find("^" .. pattern) and not value:find("[:+,]" .. pattern),
      "fzf-lua-smart owns fzf matching/sorting/reloading: conflicting bind " .. action
    )
  end
end
local reserved_flags = {
  ["--enabled"] = true,
  ["--no-disabled"] = true,
  ["--sort"] = true,
  ["-s"] = true,
  ["--tac"] = true,
  ["--filter"] = true,
  ["-f"] = true,
  ["--with-nth"] = true,
  ["--accept-nth"] = true,
  ["--delimiter"] = true,
  ["-d"] = true,
  ["--no-read0"] = true,
  ["--no-print0"] = true,
}
local function check_args(args)
  if type(args) == "table" then
    for _, arg in ipairs(args) do
      check_args(arg)
    end
  elseif type(args) == "string" then
    check_bind(args)
    for token in args:gmatch("%S+") do
      local flag = token:gsub("^['\"]", ""):match("^[^=]+") or ""
      flag = flag:gsub("['\"]$", "")
      assert(not reserved_flags[flag] and not flag:match("^%-[sfd].+"), "conflicting fzf argument " .. flag)
    end
  end
end
function M.validate(opts)
  local explicit = opts.__smart_explicit or {}
  local flags = type(explicit.fzf_opts) == "function" and opts.fzf_opts or explicit.fzf_opts
  for key, value in pairs(flags or {}) do
    if reserved_flags[key:match("^[^=]+") or key] and value ~= false then
      error("fzf-lua-smart owns fzf option " .. key)
    end
    if (key == "--disabled" or key == "--no-sort" or key == "--read0" or key == "--print0") and value == false then
      error("fzf-lua-smart requires " .. key)
    end
    if key == "--bind" then
      check_bind(value)
    end
  end
  local native = require("fzf-lua.config").setup_opts
  for _, map in ipairs({ explicit.keymap or {}, native.keymap or {} }) do
    if type(map) == "table" then
      for _, bind in pairs(map.fzf or {}) do
        check_bind(bind)
      end
    end
  end
  for _, field in ipairs({ "fzf_args", "fzf_raw_args", "fzf_cli_args" }) do
    check_args(opts[field])
  end
  check_args(explicit._fzf_cli_args)
  check_args(vim.env.FZF_DEFAULT_OPTS)
  if vim.env.FZF_DEFAULT_OPTS_FILE then
    local ok, lines = pcall(vim.fn.readfile, vim.env.FZF_DEFAULT_OPTS_FILE)
    if ok then
      check_args(table.concat(lines, "\n"))
    end
  end
  for _, name in ipairs({ "fn_reload", "fn_transform", "fn_preprocess", "fn_postprocess" }) do
    assert(explicit[name] == nil or explicit[name] == false, "fzf-lua-smart owns " .. name)
  end
  -- Inherited UI keymaps are kept except native sorting/search control.
  local default_binds = require("fzf-lua.config").defaults.keymap.fzf
  for key, value in pairs(opts.keymap.fzf or {}) do
    if not pcall(check_bind, value) then
      assert(vim.deep_equal(value, default_binds[key]), "conflicting effective fzf bind: " .. key)
      opts.keymap.fzf[key] = nil
    end
  end
  opts.fzf_opts["--sort"], opts.fzf_opts["--tac"], opts.fzf_opts["--filter"] = nil, nil, nil
  opts.fzf_opts["--no-sort"], opts.fzf_opts["--disabled"] = true, true
end

--- Open the standalone smart picker. Does not modify fzf-lua's providers.
---@param value? fzf_lua_smart.Config|fun():fzf_lua_smart.Config
---@return thread?, string?, table?
function M.smart(value)
  local opts = require("fzf-lua-smart.config").resolve(value)
  if not opts then
    return
  end
  M.validate(opts)
  local engine = require("fzf-lua-smart.engine").new(opts)
  opts.query = engine.query
  engine.render_opts = require("fzf-lua-smart.display").setup(opts)
  require("fzf-lua.make_entry").preprocess(engine.render_opts)
  opts._resume_reload = true
  -- Stateful reloads always run in the main instance. Explicit multiprocessing
  -- is handled by the search engine with immutable serializable snapshots.
  engine.multiprocess = opts.multiprocess
  opts.multiprocess = false
  opts.fn_transform, opts.fn_preprocess, opts.fn_postprocess = nil, nil, nil
  opts.rg_glob = false
  local on_close = opts.winopts.on_close
  opts.winopts.on_close = function()
    engine:close()
    if on_close then
      on_close()
    end
  end
  for _, action in pairs(opts.actions) do
    if type(action) == "table" and action.reload and type(action.fn) == "function" then
      local fn = action.fn
      action.fn = function(...)
        local ret = fn(...)
        engine.force = true
        return ret
      end
    end
  end
  if not opts.actions["ctrl-r"] then
    opts.actions["ctrl-r"] = function(_, o)
      return o.__call_fn({ resume = true })
    end
  end
  opts.__smart = engine
  return require("fzf-lua.core").fzf_live(function(args)
    local query = args[1] or ""
    return function(cb)
      local win = require("fzf-lua.win").__SELF()
      if not win or win._o.__smart ~= engine or win.closing or win:was_hidden() then
        cb(nil)
        return
      end
      -- Only a live native window may revive a closed engine during resume.
      engine.closed, engine.ctx.picker.closed = false, false
      engine:request(query, cb)
    end
  end, opts)
end
return M
