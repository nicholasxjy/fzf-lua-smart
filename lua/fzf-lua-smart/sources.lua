local M = {}
local Filter = require("fzf-lua-smart.vendor.filter")
local util = require("fzf-lua-smart.util")
local Context = {}
Context.__index = Context
function Context:cwd()
  return self.filter.cwd
end
function Context:opts(opts)
  self._opts = setmetatable(opts or {}, { __index = self._opts or self.picker.opts })
  return self._opts
end
function Context:clone(opts)
  return setmetatable({ _opts = opts }, { __index = self })
end
function Context:git_root()
  return vim.fs.root(self:cwd(), ".git") or self:cwd()
end
function M.context(opts)
  local search = { opts = opts, closed = false }
  function search:cwd()
    return self.opts.cwd
  end
  local filter = Filter.new(search)
  search.filter = filter
  return setmetatable({ picker = search, filter = filter, meta = {} }, Context)
end

-- Match fzf-lua.make_entry.file's filtering stage without touching matching text.
function M.native_filter(item, opts, current)
  local path = require("fzf-lua.path")
  local file = util.path(item)
  if not file then
    return true
  end
  if opts.ignore_current_file and file == current then
    return false
  end
  local display = opts.strip_cwd_prefix and path.strip_cwd_prefix(file) or file
  if opts.absolute_path then
    if not path.is_absolute(display) then
      display = path.join({ opts.cwd, display })
    end
  else
    display = path.relative_to(display, opts.cwd)
  end
  if path.is_absolute(display) then
    if opts.cwd_only and not path.is_relative_to(display, opts.cwd) then
      return false
    end
    if not opts.absolute_path then
      display = path.HOME_to_tilde(display)
    end
  end
  for _, pattern in ipairs(opts.file_ignore_patterns or {}) do
    if #pattern > 0 and display:match(pattern) then
      return false
    end
  end
  return true
end

function M.prepare(opts, ctx)
  local results = {}
  for id, spec in ipairs(opts.multi) do
    spec = type(spec) == "string" and { source = spec } or spec
    local source = vim.tbl_deep_extend("force", {}, opts.sources[spec.source] or {}, spec)
    -- Upstream shared top-level values deliberately override source values.
    local fopts = vim.tbl_deep_extend("force", source, opts)
    local c = ctx:clone(fopts)
    if not vim.tbl_isempty(fopts.filter or {}) then
      c.filter = ctx.filter:clone():init(fopts)
    end
    if ctx.filter.source_id ~= nil and ctx.filter.source_id ~= id then
      results[id] = { items = {}, ctx = c }
    elseif spec.source == "buffers" then
      results[id] = { items = require("fzf-lua-smart.source.buffers").buffers(fopts, c), ctx = c }
    elseif spec.source == "recent" then
      results[id] = { finder = require("fzf-lua-smart.source.recent").files(fopts, c), ctx = c }
    else
      local cmd, cwd = require("fzf-lua-smart.scanner").command(fopts, c.filter.search)
      results[id] = { cmd = cmd, cwd = cwd, opts = fopts, ctx = c }
    end
  end
  return results
end

function M.collect(opts, ctx, results, task, emit)
  ctx.async = task
  local yield = require("fzf-lua-smart.task").yielder(2)
  local limit = (opts.live and opts.limit_live or opts.limit) or math.huge
  local async = false
  for _, result in ipairs(results) do
    async = async or not result.items
  end
  local count = 0
  local transform = opts.transform
  if type(transform) == "string" then
    transform = assert(require("fzf-lua-smart.vendor.transform")[transform], "unknown transform: " .. transform)
  end
  local stopped = false
  local function add(item, id)
    if async and count >= limit then
      stopped = true
      return
    end
    item.source_id = id
    local t = transform and transform(item, ctx)
    item = type(t) == "table" and t or item
    if t ~= false and M.native_filter(item, opts, ctx.filter.file_current) then
      count = count + 1
      item.idx, item.score = count, 1000
      emit(item)
    end
    yield()
  end
  for id, result in ipairs(results) do
    if stopped then
      break
    end
    result.ctx.async = task
    if result.items then
      for _, item in ipairs(result.items) do
        add(item, id)
        if stopped then
          break
        end
      end
    elseif result.finder then
      result.finder(function(item)
        if not stopped then
          add(item, id)
        end
      end)
    else
      local res = require("fzf-lua-smart.scanner").run(result.cmd, result.opts.cwd, task, function(line)
        if stopped then
          return false
        end
        -- Upstream files source's transform does not apply Filter:match.
        add({ text = line, file = line, cwd = result.cwd }, id)
        return not stopped
      end, yield)
      if res and res.code ~= 0 and not opts.live then
        vim.notify(
          "fzf-lua-smart finder failed (" .. res.code .. "): " .. (res.stderr or result.cmd),
          vim.log.levels.WARN
        )
      end
    end
  end
end
return M
