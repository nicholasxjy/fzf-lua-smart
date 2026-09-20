-- Derived from folke/snacks.nvim, commit 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: standalone integration and a one-string filename-boundary cache.
--- This is a port of the scoring logic from fzf. See:
--- https://github.com/junegunn/fzf/blob/master/src/algo/algo.go
---@class fzf_lua_smart.Score
---@field score number
---@field consecutive number
---@field prev? number
---@field prev_class number
---@field is_file boolean
---@field first_bonus number
---@field str string
---@field path_from? number
---@field path_sep? number
---@field opts fzf_lua_smart.MatcherConfig
---@field bonus_matrix number[][]
---@field bonus_boundary_white number
---@field bonus_boundary_delimiter number
local M = {}
M.__index = M

-- Scoring constants. Same as fzf:
local SCORE_MATCH = 16
local SCORE_GAP_START = -3
local SCORE_GAP_EXTENSION = -1

local BONUS_BOUNDARY = SCORE_MATCH / 2 -- 8
local BONUS_NONWORD = SCORE_MATCH / 2 -- 8
local BONUS_CAMEL_123 = BONUS_BOUNDARY - 1 -- 7
local BONUS_CONSECUTIVE = -(SCORE_GAP_START + SCORE_GAP_EXTENSION) -- 4
local BONUS_FIRST_CHAR_MULTIPLIER = 2
local BONUS_NO_PATH_SEP = BONUS_BOUNDARY - 2 -- added when there is no path separator following the from position

local PATH_SEP = package.config:sub(1, 1)

-- ASCII char classes (simplified); adapt as needed:
local CHAR_WHITE = 0
local CHAR_NONWORD = 1
local CHAR_DELIMITER = 2
local CHAR_LOWER = 3
local CHAR_UPPER = 4
local CHAR_LETTER = 5
local CHAR_NUMBER = 6

-- Table to classify ASCII bytes quickly:
local CHAR_CLASS = {} ---@type number[]
for b = 0, 255 do
  local c = CHAR_NONWORD
  local char = string.char(b)
  if char:match("%s") then
    c = CHAR_WHITE
  elseif char:match("[/\\,:;|]") then
    c = CHAR_DELIMITER
  elseif b >= 48 and b <= 57 then -- '0'..'9'
    c = CHAR_NUMBER
  elseif b >= 65 and b <= 90 then -- 'A'..'Z'
    c = CHAR_UPPER
  elseif b >= 97 and b <= 122 then -- 'a'..'z'
    c = CHAR_LOWER
  end
  CHAR_CLASS[b] = c
end

---@param opts? fzf_lua_smart.MatcherConfig
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = opts or {}
  self.score = 0
  self.is_file = true
  self.consecutive = 0
  self.prev_class = CHAR_WHITE
  self.str = ""
  self.first_bonus = 0
  self.bonus_matrix = {}
  self.bonus_boundary_white = BONUS_BOUNDARY + 2
  self.bonus_boundary_delimiter = BONUS_BOUNDARY + 1
  if self.opts.history_bonus then
    self.bonus_boundary_white = BONUS_BOUNDARY
    self.bonus_boundary_delimiter = BONUS_BOUNDARY
  end
  self:compute_bonus_matrix()
  return self
end

function M:compute_bonus_matrix()
  for prev = 0, 6 do
    self.bonus_matrix[prev] = {}
    for curr = 0, 6 do
      self.bonus_matrix[prev][curr] = self:compute_bonus(prev, curr)
    end
  end
end

-- Helper to compute boundary/camelCase bonuses (mimics fzf approach)
function M:compute_bonus(prev, curr)
  -- If transitioning from whitespace/delimiter/nonword to letter => boundary bonus
  if curr > CHAR_NONWORD then
    if prev == CHAR_WHITE then
      return self.bonus_boundary_white
    elseif prev == CHAR_DELIMITER then
      return self.bonus_boundary_delimiter
    elseif prev == CHAR_NONWORD then
      return BONUS_BOUNDARY
    end
  end

  -- camelCase transitions or letter->number transitions
  if (prev == CHAR_LOWER and curr == CHAR_UPPER) or (prev ~= CHAR_NUMBER and curr == CHAR_NUMBER) then
    return BONUS_CAMEL_123
  end

  if curr == CHAR_NONWORD or curr == CHAR_DELIMITER then
    return BONUS_NONWORD
  elseif curr == CHAR_WHITE then
    return BONUS_BOUNDARY + 2
  end
  return 0
end

---@param str string
---@param pos number
function M:is_left_boundary(str, pos)
  return pos == 1 or CHAR_CLASS[str:byte(pos - 1)] < CHAR_LOWER
end

---@param str string
---@param pos number
function M:is_right_boundary(str, pos)
  return pos == #str or CHAR_CLASS[str:byte(pos + 1)] < CHAR_LOWER
end

---@param str string
---@param first number
function M:init(str, first)
  if self.str ~= str then
    self.path_from = nil
  end
  self.str = str
  self.score = 0
  self.consecutive = 0
  self.prev_class = CHAR_WHITE
  self.prev = nil
  self.first_bonus = 0
  if first > 1 then
    self.prev_class = CHAR_CLASS[str:byte(first - 1)] or CHAR_NONWORD
  end
  if self.is_file and self.opts.filename_bonus then
    if not self.path_from or first < self.path_from or self.path_sep > 0 and first >= self.path_sep then
      -- Keep the next separator, rather than scanning the entire string for
      -- its last separator. This preserves the cheap single-start path while
      -- repeated forward starts search each directory span only once.
      self.path_from = first
      self.path_sep = str:find(PATH_SEP, first + 1, true) or 0
      if PATH_SEP ~= "/" then
        local slash = str:find("/", first + 1, true) or 0
        if slash > 0 and (self.path_sep == 0 or slash < self.path_sep) then
          self.path_sep = slash
        end
      end
    end
    if self.path_sep == 0 then
      self.score = self.score + BONUS_NO_PATH_SEP
    end
  end
  self:update(first)
end

---@param pos number
function M:update(pos)
  local b = self.str:byte(pos)
  local class = CHAR_CLASS[b] or CHAR_NONWORD
  local bonus = 0
  local gap = self.prev and pos - self.prev - 1 or 0

  if gap > 0 then
    self.prev_class = CHAR_CLASS[self.str:byte(pos - 1)] or CHAR_NONWORD
    bonus = self.bonus_matrix[self.prev_class][class] or 0
    self.score = self.score + SCORE_GAP_START + (gap - 1) * SCORE_GAP_EXTENSION
    self.consecutive = 0
    self.first_bonus = 0
  else
    bonus = self.bonus_matrix[self.prev_class][class] or 0
    -- No gap => consecutive chunk
    if self.consecutive == 0 then
      -- New chunk => store the boundary/camel bonus
      self.first_bonus = bonus
    else
      -- If we see a bigger boundary/camel bonus than what started the chunk, update
      if bonus >= BONUS_BOUNDARY and bonus > self.first_bonus then
        self.first_bonus = bonus
      end
      -- Take the max of the current bonus, the chunk's firstBonus, or BONUS_CONSECUTIVE
      bonus = math.max(bonus, self.first_bonus, BONUS_CONSECUTIVE)
    end
    self.consecutive = self.consecutive + 1
  end

  if not self.prev then
    bonus = (bonus * BONUS_FIRST_CHAR_MULTIPLIER)
  end

  self.score = self.score + SCORE_MATCH + bonus

  -- Update for next iteration
  self.prev_class = class
  self.prev = pos
end

---@param str string
---@param from number
---@param to number
function M:get(str, from, to)
  self:init(str, from)
  for i = from + 1, to do
    self:update(i)
  end
  return self.score
end

return M
