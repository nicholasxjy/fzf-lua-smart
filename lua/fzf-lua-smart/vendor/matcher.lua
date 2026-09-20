-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone integration, file_pos/line_query gates, and bounded
-- regex/greedy-suffix caches that preserve upstream scores and first-best ties.
local Async = require("fzf-lua-smart.task")

---@class fzf_lua_smart.Item
---@field match_tick? number
---@field match_topk? number

---@class fzf_lua_smart.MatcherConfig
---@field regex? boolean used internally for positions of sources that use regex
---@field on_match? fun(matcher: fzf_lua_smart.Matcher, item: fzf_lua_smart.Item)
---@field on_done? fun(matcher: fzf_lua_smart.Matcher)
---@field keep_parents? boolean
---@field sort? boolean

---@class fzf_lua_smart.Matcher
---@field opts fzf_lua_smart.MatcherConfig
---@field mods fzf_lua_smart.matcher.Mods[][]
---@field one? fzf_lua_smart.matcher.Mods
---@field pattern string
---@field tick number
---@field task fzf_lua_smart.Async
---@field live? boolean
---@field score fzf_lua_smart.Score
---@field sorting? boolean
---@field file? {path: string, pos: fzf_lua_smart.Pos}
---@field cwd string
---@field frecency? fzf_lua_smart.Frecency
---@field subset? boolean
local M = {}
M.__index = M
M.DEFAULT_SCORE = 1000
M.INVERSE_SCORE = 1000
local BONUS_FRECENCY = 8
local BONUS_CWD = 10

local YIELD_MATCH = 1 -- ms

---@class fzf_lua_smart.matcher.Mods
---@field pattern string
---@field chars string[]
---@field entropy number higher entropy is less likely to match
---@field field? string
---@field ignorecase? boolean
---@field fuzzy? boolean
---@field regex? boolean
---@field word? boolean
---@field exact_suffix? boolean
---@field exact_prefix? boolean
---@field inverse? boolean

---@param opts? fzf_lua_smart.MatcherConfig|{}
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = vim.tbl_deep_extend("force", {
    fuzzy = true,
    smartcase = true,
    ignorecase = true,
  }, opts or {})
  self.pattern = ""
  self.task = Async.nop()
  self.mods = {}
  self.sorting = true
  self.tick = 0
  self.score = require("fzf-lua-smart.vendor.score").new(self.opts)
  self._fuzzy_matches = {}
  self.frecency = self.opts.frecency and require("fzf-lua-smart.vendor.frecency").new() or nil
  return self
end

function M:empty()
  return not next(self.mods)
end

function M:running()
  return self.task:running()
end

function M:abort()
  self.task:abort()
end

function M:close()
  self:abort()
  self.task = Async.nop()
end

---@param picker fzf_lua_smart.Search
---@param item fzf_lua_smart.Item
function M:on_match(picker, item)
  if self.opts.on_match then
    self.opts.on_match(self, item)
  end

  if not self.opts.keep_parents or item.score == 0 then
    return
  end

  local parent = item.parent
  item.child_match_only = false
  while parent and not parent.root do
    if parent.score == 0 or parent.match_tick ~= self.tick then
      parent.score = 1
      parent.child_match_only = true
      parent.match_tick = self.tick
      parent.match_topk = nil
      picker.list:add(parent, self.sorting)
    else
      break
    end
    parent = parent.parent
  end
end

---@param picker fzf_lua_smart.Search
function M:on_done(_)
  if self.opts.on_done then
    self.opts.on_done(self)
  end
end

---@param pattern string
---@return boolean changed
function M:init(pattern)
  pattern = vim.trim(pattern)
  if pattern == self.pattern then
    return false
  end
  self.tick = self.tick + 1
  self.file = nil
  self.mods = {}
  self.subset = self.pattern ~= "" and pattern:find(self.pattern, 1, true) == 1 and not pattern:find("[^%s%w]")
  self.pattern = pattern
  self:abort()
  self.one = nil
  if pattern == "" then
    return true
  end
  if self.opts.regex then
    self.mods = { { self:_prepare(pattern) } }
  else
    local is_or = false
    for _, p in ipairs(vim.split(pattern, " +")) do
      if p == "|" then
        is_or = true
      else
        local mods = self:_prepare(p)
        if mods.pattern ~= "" then
          if is_or and #self.mods > 0 then
            table.insert(self.mods[#self.mods], mods)
          else
            table.insert(self.mods, { mods })
          end
        end
        is_or = false
      end
    end
  end
  for _, ors in ipairs(self.mods) do
    -- sort by entropy, lower entropy is more likely to match
    table.sort(ors, function(a, b)
      return a.entropy < b.entropy
    end)
  end
  -- sort by entropy, higher entropy is less likely to match
  table.sort(self.mods, function(a, b)
    return a[1].entropy > b[1].entropy
  end)
  if #self.mods == 1 and #self.mods[1] == 1 then
    self.one = self.mods[1][1]
  end
  return true
end

---@param pattern string
---@return fzf_lua_smart.matcher.Mods
function M:_prepare(pattern)
  ---@type fzf-lua-smart.matcher.Mods
  local mods = { pattern = pattern, entropy = 0, chars = {} }

  if self.opts.regex then
    mods.regex = true
  else
    local file_patterns = {
      "^(.*[/\\].*):(%d*):(%d*)$",
      "^(.*[/\\].*):(%d*)$",
      "^(.+%.[a-z_]+):(%d*):(%d*)$",
      "^(.+%.[a-z_]+):(%d*)$",
    }

    for _, p in ipairs((self.opts.file_pos == false or self.opts._file_pos_disabled) and {} or file_patterns) do
      local file, line, col = pattern:match(p)
      if file then
        mods.field = "file"
        mods.pattern = file .. "$"
        self.file = {
          path = file,
          pos = { tonumber(line) or 1, tonumber(col) or 0 },
        }
        break
      end
    end

    -- minimum two chars for field pattern
    local field, p = pattern:match("^([%w_][%w_]+):(.*)$")
    if field then
      mods.field = field
      mods.pattern = p
    end
    mods.ignorecase = self.opts.ignorecase
    local is_lower = mods.pattern:lower() == mods.pattern
    if self.opts.smartcase then
      mods.ignorecase = is_lower
    end
    mods.fuzzy = self.opts.fuzzy
    if not mods.fuzzy then
      mods.entropy = mods.entropy + 10
    end
    if mods.pattern:sub(1, 1) == "!" then
      mods.fuzzy, mods.inverse = false, true
      mods.pattern = mods.pattern:sub(2)
      mods.entropy = mods.entropy - 1
    end
    if mods.pattern:sub(1, 1) == "'" then
      mods.fuzzy = false
      mods.pattern = mods.pattern:sub(2)
      mods.entropy = mods.entropy + 10
      if mods.pattern:sub(-1, -1) == "'" then
        mods.word = true
        mods.pattern = mods.pattern:sub(1, -2)
        mods.entropy = mods.entropy + 10
      end
    elseif mods.pattern:sub(1, 1) == "^" then
      mods.fuzzy, mods.exact_prefix = false, true
      mods.pattern = mods.pattern:sub(2)
      mods.entropy = mods.entropy + 20
    end
    if mods.pattern:sub(-1, -1) == "$" then
      mods.fuzzy = false
      mods.exact_suffix = true
      mods.pattern = mods.pattern:sub(1, -2)
      mods.entropy = mods.entropy + 20
    end
    local rare_chars = #mods.pattern:gsub("[%w%s]", "")
    mods.entropy = mods.entropy + math.min(#mods.pattern, 20) + rare_chars * 2
    if not mods.ignorecase and not is_lower then
      mods.entropy = mods.entropy * 2
    end
    if mods.ignorecase then
      mods.pattern = mods.pattern:lower()
    end
  end

  for c = 1, #mods.pattern do
    mods.chars[c] = mods.pattern:sub(c, c)
  end
  return mods
end

---@param picker fzf_lua_smart.Search
---@param item fzf_lua_smart.Item
---@return boolean matched
function M:update(picker, item)
  if item.match_pos then
    item.pos = nil
  end
  local score = self:match(item)
  item.match_tick = self.tick
  -- Writing nil to a missing key can grow a full LuaJIT hash table on reload.
  -- This UI-only field is normally absent in the standalone search engine.
  if item.match_topk ~= nil then
    item.match_topk = nil
  end
  if score ~= 0 then
    if item.score_add then
      score = score + item.score_add
    end
    if item.score_mul then
      score = score * item.score_mul
    end
    if self.file and not item.pos then
      item.pos = self.file.pos
      item.match_pos = true
    end
    if item.file then
      if self.frecency then
        item.frecency = item.frecency or self.frecency:get(item)
        score = score + (1 - 1 / (1 + item.frecency)) * BONUS_FRECENCY
      end
      if
        self.opts.cwd_bonus
        and (self.cwd == item.cwd or require("fzf-lua-smart.util").path(item):find(self.cwd, 1, true) == 1)
      then
        score = score + BONUS_CWD
      end
    end
    item.score = score
    self:on_match(picker, item)
  else
    item.score = 0
  end
  return score > 0
end

--- Matches an item and returns the score.
--- Score is 0 if no match is found.
---@param item fzf_lua_smart.Item
function M:match(item)
  if self:empty() then
    return M.DEFAULT_SCORE -- empty pattern matches everything
  end
  local score, s = 0, nil
  -- fast path for single pattern
  if self.one then
    return self:_match(item, self.one) or 0
  end
  for _, any in ipairs(self.mods) do
    -- fast path for single OR pattern
    if #any == 1 then
      s = self:_match(item, any[1])
    else
      for _, mods in ipairs(any) do
        s = self:_match(item, mods)
        if s then
          break
        end
      end
    end
    if not s then
      return 0
    end
    score = score + s
  end
  return score
end

--- Returns the fields that are used in the pattern.
---@return string[]
function M:fields()
  local ret = {} ---@type table<string,boolean>
  for _, any in ipairs(self.mods) do
    for _, mods in ipairs(any) do
      ret[mods.field or "text"] = true
    end
  end
  return vim.tbl_keys(ret)
end

--- Returns the positions of the matched pattern in the item.
--- All search patterns are combined with OR.
---@param item fzf_lua_smart.Item
function M:positions(item)
  local all = {} ---@type fzf-lua-smart.matcher.Mods[]
  local ret = {} ---@type table<string,number[]>
  for _, any in ipairs(self.mods) do
    vim.list_extend(all, any)
  end
  for _, mods in ipairs(all) do
    local _, from, to, str = self:_match(item, mods)
    if from and to and str then
      local field = mods.field or "text"
      ret[field] = ret[field] or {}
      local pos = ret[field]
      if mods.fuzzy then
        vim.list_extend(pos, self:fuzzy_positions(str, mods.chars, from))
      else
        for c = from, to do
          pos[#pos + 1] = c
        end
      end
    end
  end
  return ret
end

--- Returns the column of the first position of the matched pattern in the item.
---@param buf number
---@param item fzf_lua_smart.Item
---@return fzf_lua_smart.Pos?
function M:bufpos(buf, item)
  if not item.pos then
    return
  end
  local line = vim.api.nvim_buf_get_lines(buf, item.pos[1] - 1, item.pos[1], false)[1] or ""
  local positions = self:positions({ text = line, idx = 1, score = 0 }).text or {}
  table.sort(positions)
  return #positions > 0 and { item.pos[1], positions[1] - 1 } or nil
end

---@param str string
---@param pattern string[]
---@param from number
function M:fuzzy_positions(str, pattern, from)
  local ret = { from } ---@type number[]
  for i = 2, #pattern do
    ret[#ret + 1] = string.find(str, pattern[i], ret[#ret] + 1, true)
  end
  return ret
end

---@param str string
---@param pattern string
---@return number? score, number? from, number? to, string? str
function M:regex(str, pattern)
  if self._regex_pattern ~= pattern then
    local ok, re = pcall(vim.regex, pattern)
    self._regex_pattern, self._regex = pattern, ok and re or false
  end
  if not self._regex then
    return
  end
  local from, to = self._regex:match_str(str)
  if from and to then
    from = from + 1
    return self.score:get(str, from, to), from, to, str
  end
end

---@param item fzf_lua_smart.Item
---@param mods fzf_lua_smart.matcher.Mods
---@return number? score, number? from, number? to, string? str
function M:_match(item, mods)
  self.score.is_file = item.file ~= nil
  local str = item.text

  if mods.regex then
    return self:regex(str, mods.pattern)
  end

  if mods.field then
    if item[mods.field] == nil then
      if mods.inverse then
        return M.INVERSE_SCORE
      end
      return
    end
    str = tostring(item[mods.field])
  end

  local str_orig = str
  str = mods.ignorecase and str:lower() or str
  local from, to ---@type number?, number?
  if mods.fuzzy then
    return self:fuzzy(str, str_orig, mods.chars)
  end
  if mods.exact_prefix then
    if str:sub(1, #mods.pattern) == mods.pattern then
      from, to = 1, #mods.pattern
    end
  elseif mods.exact_suffix then
    if str:sub(-#mods.pattern) == mods.pattern then
      from, to = #str - #mods.pattern + 1, #str
    end
  else
    from, to = str:find(mods.pattern, 1, true)
    -- word match
    while mods.word and from and to do
      local bound_left = self.score:is_left_boundary(str, from)
      local bound_right = self.score:is_right_boundary(str, to)
      if bound_left and bound_right then
        break
      end
      from, to = str:find(mods.pattern, to + 1, true)
    end
  end
  if mods.inverse then
    if not from then
      return M.INVERSE_SCORE
    end
    return
  end
  if from then
    ---@cast to number
    return self.score:get(str_orig, from, to), from, to, str
  end
end

---@param str string
---@param str_orig string
---@param pattern string[]
---@param init? number
---@param matches? number[] greedy positions from the preceding start in this string
---@return number? from, number? to
function M:fuzzy_find(str, str_orig, pattern, init, matches)
  local from = string.find(str, pattern[1], init or 1, true)
  if not from then
    return
  end
  self.score:init(str_orig, from)
  ---@type number?, number
  local last, n = from, #pattern
  for i = 2, n do
    -- Every start moves right, so each greedy suffix position is monotone. If
    -- its previous position still follows this prefix, it remains the first
    -- possible match. Do not search the same long gap for every start byte.
    local cached = init and matches and matches[i]
    last = cached and cached > last and cached or string.find(str, pattern[i], last + 1, true)
    if last then
      if matches then
        matches[i] = last
      end
      self.score:update(last)
    else
      return
    end
  end
  return from, last
end

--- Score every greedy forward match, retaining the first best score as upstream
--- does. Reuse suffix positions only within this call, never across items.
---@param str string
---@param str_orig string
---@param pattern string[]
---@return number? score, number? from, number? to, string? str
function M:fuzzy(str, str_orig, pattern)
  local matches = self._fuzzy_matches
  local from, to = self:fuzzy_find(str, str_orig, pattern, nil, matches)
  if not from then
    return
  end
  ---@cast to number

  local best_from, best_to, best_score = from, to, self.score.score
  while from do
    if self.score.score > best_score then
      best_from, best_to, best_score = from, to, self.score.score
    end
    from, to = self:fuzzy_find(str, str_orig, pattern, from + 1, matches)
  end
  return best_score, best_from, best_to, str
end

return M
