local M = { defaults = {}, resume_key = "fzf-lua-smart" }

local function copy(v)
  return vim.deepcopy(v)
end
-- Alias normalization happens before, never after, precedence merging.
function M.layer(value)
  local o = copy(value or {})
  for k, v in pairs(copy(o)) do
    if type(k) == "string" and k:find(".", 1, true) then
      local keys = vim.split(k, ".", { plain = true })
      local dst = o
      for i = 1, #keys - 1 do
        dst[keys[i]] = dst[keys[i]] or {}
        dst = dst[keys[i]]
      end
      dst[keys[#keys]], o[k] = v, nil
    end
  end
  for alias, native in pairs({ ignored = "no_ignore", dirs = "search_paths", finders = "multi" }) do
    if o[native] == nil and o[alias] ~= nil then
      o[native] = o[alias]
    end
    o[alias] = nil
  end
  if o.sources then
    for name, source in pairs(o.sources) do
      o.sources[name] = M.layer(source)
    end
  end
  if type(o.multi) == "table" then
    for i, source in ipairs(o.multi) do
      if type(source) == "table" then
        o.multi[i] = M.layer(source)
      end
    end
  end
  return o
end
function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "setup expects a table")
  M.defaults = M.layer(opts)
end

function M.algorithm_defaults()
  return {
    multi = { "buffers", "recent", "files" },
    matcher = {
      fuzzy = true,
      smartcase = true,
      ignorecase = true,
      sort_empty = true,
      filename_bonus = true,
      file_pos = true,
      cwd_bonus = true,
      frecency = true,
      history_bonus = false,
    },
    sort = { fields = { "score:desc", "#text", "idx" } },
    limit_live = 10000,
    transform = "unique_file",
    sources = {
      recent = {
        filter = {
          paths = {
            [vim.fn.stdpath("data")] = false,
            [vim.fn.stdpath("cache")] = false,
            [vim.fn.stdpath("state")] = false,
          },
        },
      },
    },
    db = {},
  }
end

function M.resolve(value)
  assert(vim.fn.has("nvim-0.11") == 1, "fzf-lua-smart requires Neovim >= 0.11")
  assert(jit.os ~= "Windows", "fzf-lua-smart supports macOS and Linux")
  local fzf = require("fzf-lua.config")
  local call = M.layer(type(value) == "function" and value() or value)
  if call.resume then
    call = vim.tbl_deep_extend("keep", call, copy(fzf.resume_get(nil, { __resume_key = M.resume_key }) or {}))
  end
  local input = vim.tbl_deep_extend("keep", call, copy(M.defaults))
  -- Resolve native profiles with native loading/merging, without changing setup.
  local profile = input.profile or input[1] or fzf.globals.files.profile or fzf.globals.files[1]
  local p = profile and require("fzf-lua.utils").load_profiles(profile, 1) or {}
  local native = vim.tbl_deep_extend("keep", {}, p, fzf.setup_opts)
  local global = M.layer(p.defaults or fzf.setup_opts.defaults)
  local files = M.layer(native.files)
  -- Only inject fields whose alias resolution needs to happen before native merge.
  local aliases = vim.tbl_deep_extend("keep", {}, files, global)
  for _, key in ipairs({ "no_ignore", "search_paths", "multi" }) do
    if input[key] == nil then
      input[key] = aliases[key]
    end
  end
  local line_query = input.line_query
  if line_query == nil then
    line_query = files.line_query
  end
  if line_query == nil then
    line_query = global.line_query
  end
  -- Do not let normalize_opts install fzf search() bindings.
  input.line_query = false
  local original = copy(input)
  original.line_query = line_query
  local dynamic = {}
  for _, key in ipairs({ "keymap", "fzf_opts" }) do
    if type(input[key]) == "function" then
      local fn = input[key]
      input[key] = function(o)
        local ret = fn(o)
        dynamic[key] = copy(ret)
        return ret
      end
    end
  end
  local opts = fzf.normalize_opts(input, "files", M.resume_key)
  if not opts then
    return
  end
  assert(not opts.__SK_VERSION, "fzf-lua-smart does not support skim")
  assert(require("fzf-lua.utils").has(opts, "fzf", { 0, 59 }), "fzf-lua-smart requires fzf >= 0.59")
  opts = vim.tbl_deep_extend("keep", opts, M.algorithm_defaults())
  opts.__smart_line_query = line_query
  opts.line_query = false
  opts.__call_opts = original
  opts.__call_fn = require("fzf-lua-smart").smart
  opts.__smart_explicit = vim.tbl_deep_extend("keep", {}, call, M.defaults, files, global)
  for key, value in pairs(dynamic) do
    opts.__smart_explicit[key] = value
  end
  if type(native.fzf_opts) == "table" then
    if type(opts.__smart_explicit.fzf_opts) ~= "function" then
      opts.__smart_explicit.fzf_opts =
        vim.tbl_deep_extend("keep", opts.__smart_explicit.fzf_opts or {}, copy(native.fzf_opts))
    end
  end
  opts.cwd = opts.cwd or vim.fn.getcwd()
  assert(type(opts.multi) == "table", "multi must be a list of buffers/recent/files")
  for _, spec in ipairs(opts.multi) do
    local name = type(spec) == "string" and spec or spec.source
    assert(name == "buffers" or name == "recent" or name == "files", "unknown smart source: " .. tostring(name))
  end
  return opts
end
return M
