local M = {}
M.__index = M
local Task = require("fzf-lua-smart.task")
local Sources = require("fzf-lua-smart.sources")

function M.new(opts)
  opts = vim.deepcopy(opts)
  local self = setmetatable({
    opts = opts,
    generation = 0,
    scan_generation = 0,
    scans = 0,
    items = {},
    scan = Task.nop(),
    matching = Task.nop(),
    closed = false,
  }, M)
  self.ctx = Sources.context(opts)
  self.input_filter = self.ctx.filter
  self.ctx.filter.file_current = vim.fs.normalize(vim.api.nvim_buf_get_name(0), { _fast = true })
  self.main = vim.api.nvim_get_current_win()
  require("fzf-lua-smart.vendor.frecency").opts = opts.db
  local matcher_opts = vim.tbl_extend(
    "force",
    {},
    opts.matcher,
    { _file_pos_disabled = opts.__smart_line_query ~= nil }
  )
  self.matcher = require("fzf-lua-smart.vendor.matcher").new(matcher_opts)
  self.matcher.cwd = vim.fs.normalize(opts.cwd)
  self.ctx.picker.matcher = self.matcher
  self.ctx.picker.find = function(_, o)
    self:refresh(o)
  end
  self.ctx.picker.count = function()
    return #self.items
  end
  self.ctx.picker.iter = function()
    local items, index = self.results or {}, 0
    return function()
      index = index + 1
      if items[index] then
        return items[index], index
      end
    end
  end
  self.ctx.picker.list = {
    add = function(_, item)
      self.parents[#self.parents + 1] = item
      self.parent_added[item] = true
    end,
  }
  self.query = opts.query
  if self.query == nil then
    self.query = opts.live and self.ctx.filter.search or self.ctx.filter.pattern
  end
  self.query = self.query or ""
  return self
end
function M:stop_output()
  self.matching:abort()
  if self.sink then
    self.sink(nil)
    self.sink = nil
  end
end
function M:close()
  self.started = false
  self.closed, self.ctx.picker.closed = true, true
  self.generation = self.generation + 1
  self.scan:abort()
  self:stop_output()
  -- Native resume keeps the engine in saved options. It starts a fresh scan,
  -- so retaining the previous candidate graph here only keeps memory alive.
  self.items, self.results, self.parents, self.parent_added = {}, nil, nil, nil
end
function M:refresh()
  -- A reload pipe is one-shot. Queue refresh for the next native request;
  -- never recursively reuse/close the pipe from inside a search callback.
  self.force = true
end
function M:filter(query)
  local filter = self.input_filter:clone({ trim = true })
  if self.opts.live then
    filter.search = vim.trim(query)
  else
    filter.pattern = vim.trim(query)
  end
  local line_query = self.opts.__smart_line_query
  self.line = nil
  if line_query then
    if line_query == true then
      line_query = function(q)
        return q:match(":(%d+)$"), (q:gsub(":%d*$", ""))
      end
    end
    local line, pattern = line_query(query)
    self.line = tonumber(line)
    if pattern then
      if self.opts.live then
        filter.search = pattern
      else
        filter.pattern = pattern
      end
    end
  end
  local force = self.force
  self.force = nil
  if filter.opts.transform then
    force = filter.opts.transform(self.ctx.picker, filter) or force
  end
  return filter, force
end
function M:request(query, sink)
  if self.closed then
    sink(nil)
    return
  end
  self.generation = self.generation + 1
  self:stop_output()
  self.sink, self.query = sink, query or ""
  local filter, force = self:filter(self.query)
  local finding = force or not self.started or self.search ~= filter.search or self.source_id ~= filter.source_id
  self.ctx.filter = filter
  self.ctx.picker.filter = filter
  self.matcher:init(filter.pattern)
  if finding then
    self.scan:abort()
    self.scan_generation, self.scans = self.scan_generation + 1, self.scans + 1
    local scan_generation = self.scan_generation
    self.items = {}
    local scan_ctx = setmetatable({ filter = filter, meta = {}, picker = self.ctx.picker }, getmetatable(self.ctx))
    self.search, self.source_id, self.started = filter.search, filter.source_id, true
    local results
    local prepare = function()
      results = Sources.prepare(self.opts, scan_ctx)
    end
    if vim.api.nvim_win_is_valid(self.main) then
      vim.api.nvim_win_call(self.main, prepare)
    else
      prepare()
    end
    self.scan = Task.new(function(task)
      local start = vim.uv.hrtime()
      Sources.collect(self.opts, scan_ctx, results, task, function(item)
        self.items[#self.items + 1] = item
      end)
      self.scan_ms = (vim.uv.hrtime() - start) / 1e6
      if not self.closed and scan_generation == self.scan_generation then
        self:match()
      end
    end, function(err)
      vim.notify("fzf-lua-smart: " .. tostring(err), vim.log.levels.ERROR)
      if scan_generation == self.scan_generation then
        self:stop_output()
      end
    end)
  elseif not self.scan:running() then
    self:match()
  end
end
function M:match()
  local generation, matcher = self.generation, self.matcher
  self.matching:abort()
  self.matching = Task.new(function(task)
    local yield, found = Task.yielder(2), {}
    local start = vim.uv.hrtime()
    -- A reload/resume may repeat the same pattern/tick. Walk the current
    -- ancestor graph once, including parents held outside the engine by a
    -- transform. Looking only at the previous result loses parents on resume.
    -- The ordinary flat-file path needs no separate full-candidate pass.
    if matcher.opts.keep_parents then
      local cleared = {}
      for _, item in ipairs(self.items) do
        item.match_tick = nil
        local parent = item.parent
        while parent and not parent.root and not cleared[parent] do
          cleared[parent], parent.match_tick = true, nil
          parent = parent.parent
          yield()
        end
        yield()
      end
    end
    self.parents, self.parent_added = {}, {}
    local sorting = matcher.opts.sort ~= false and (not matcher:empty() or matcher.opts.sort_empty)
    matcher.sorting = sorting
    local remote = self.multiprocess == true and require("fzf-lua-smart.process").match(self, task, yield)
    for i, item in ipairs(self.items) do
      local matched
      if self.parent_added[item] then
        -- Upstream skips parents already retained by a preceding child. Do not
        -- overwrite their score/child-only state or publish them twice.
        matched = false
      elseif remote then
        local r = remote[i]
        item.score, item.pos, item.match_pos = r.score, r.pos, r.match_pos
        item.match_tick, item.frecency = r.match_tick, r.frecency
        if item.match_topk ~= nil then
          item.match_topk = nil
        end
        matched = r.matched
        if item.score ~= 0 then
          matcher:on_match(self.ctx.picker, item)
        end
      else
        matched = matcher:update(self.ctx.picker, item)
      end
      if matched then
        if self.line then
          item.pos = { self.line, 0 }
          item.match_pos = true
        end
        found[#found + 1] = item
      end
      yield()
    end
    for _, parent in ipairs(self.parents) do
      found[#found + 1] = parent
    end
    self.match_ms = (vim.uv.hrtime() - start) / 1e6
    start = vim.uv.hrtime()
    if sorting then
      local less = type(self.opts.sort) == "function" and self.opts.sort
        or require("fzf-lua-smart.vendor.sort").default(self.opts.sort)
      Task.sort(found, less, yield)
    end
    self.sort_ms = (vim.uv.hrtime() - start) / 1e6
    if self.closed or generation ~= self.generation then
      return
    end
    self.results = found
    matcher:on_done(self.ctx.picker)
    if self.on_results then
      self.on_results(found, matcher)
    end
    local sink = self.sink
    if not sink then
      return
    end
    for _, item in ipairs(found) do
      if self.closed or task.cancelled or generation ~= self.generation then
        return
      end
      sink(require("fzf-lua-smart.display").entry(item, matcher, self.render_opts or self.opts), function(err)
        if err then
          task:abort()
        end
      end)
      yield()
    end
    if self.sink == sink then
      self.sink = nil
      sink(nil)
    end
  end, function(err)
    vim.notify("fzf-lua-smart: " .. tostring(err), vim.log.levels.ERROR)
    self:stop_output()
  end)
end
return M
