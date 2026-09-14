local M = {}
local util = require("fzf-lua-smart.util")
local function esc(s)
  return vim.fn.shellescape(tostring(s))
end
local function paths(value)
  if type(value) == "string" then
    return { value }
  end
  return vim.deepcopy(value or {})
end

function M.command(opts, search)
  local native = require("fzf-lua.providers.files")
  local custom = (opts.raw_cmd and opts.raw_cmd ~= "") or (opts.cmd and opts.cmd ~= "")
  if custom then
    for _, key in ipairs({ "exclude", "ft", "rtp", "args", "finder_cmd" }) do
      assert(opts[key] == nil or opts[key] == false, key .. " cannot be combined safely with cmd/raw_cmd")
    end
    assert(opts.raw_cmd or not search or search == "", "live finder search cannot be combined with cmd; use finder_cmd")
    return native.get_files_cmd(vim.deepcopy(opts)), opts.cwd
  end
  local backend = opts.finder_cmd
  if backend then
    assert(vim.tbl_contains({ "fd", "fdfind", "rg", "find" }, backend), "finder_cmd must be fd/fdfind/rg/find")
    assert(vim.fn.executable(backend) == 1, "finder not executable: " .. backend)
  else
    for _, name in ipairs({ "fdfind", "fd", "rg", "find" }) do
      if vim.fn.executable(name) == 1 then
        backend = name
        break
      end
    end
  end
  assert(backend, "no file finder available (fd/fdfind/rg/find)")
  local dirs = paths(opts.search_paths)
  if opts.rtp then
    vim.list_extend(dirs, util.rtp())
  end
  local is_fd, is_rg, is_find = backend == "fd" or backend == "fdfind", backend == "rg", backend == "find"
  local base = vim.deepcopy(opts)
  base.search_paths = nil
  local roots = { "." }
  if is_find and #dirs > 0 then
    roots = {}
    -- Preserve upstream find's reversed root insertion before native -L handling.
    for i = #dirs, 1, -1 do
      roots[#roots + 1] = esc(vim.fs.normalize(dirs[i]))
    end
  end
  base.cmd = backend
    .. " "
    .. (is_fd and opts.fd_opts or is_rg and opts.rg_opts or (table.concat(roots, " ") .. " " .. opts.find_opts))
  local command = native.get_files_cmd(base)
  local extra = {}
  local function add(...)
    for _, arg in ipairs({ ... }) do
      extra[#extra + 1] = esc(arg)
    end
  end
  for _, e in ipairs(opts.exclude or {}) do
    if is_fd then
      add("-E", e)
    elseif is_rg then
      add("-g", "!" .. e)
    else
      add("-not", "-path", e)
    end
  end
  for _, ft in ipairs(paths(opts.ft)) do
    if is_fd then
      add("-e", ft)
    elseif is_rg then
      add("-g", "*." .. ft)
    else
      add("-name", "*." .. ft)
    end
  end
  for _, arg in ipairs(opts.args or {}) do
    add(arg)
  end
  local pattern, args = util.parse(search or "")
  for _, arg in ipairs(args) do
    add(arg)
  end
  if pattern ~= "" then
    if is_fd then
      add(pattern)
    elseif is_rg then
      add("--glob", pattern)
    else
      add("-name", pattern)
    end
  end
  if #dirs > 0 then
    if is_fd and pattern == "" then
      add(".")
    end
    local normalized = {}
    for _, dir in ipairs(dirs) do
      -- fzf-lua accepts relative search_paths; execution cwd gives their meaning.
      normalized[#normalized + 1] = vim.fs.normalize(dir)
    end
    if not is_find then
      for _, dir in ipairs(normalized) do
        add(dir)
      end
    end
  end
  if #extra > 0 then
    command = command .. " " .. table.concat(extra, " ")
  end
  return command, not (opts.rtp or #dirs > 0) and vim.fs.normalize(opts.cwd or vim.uv.cwd() or ".") or nil
end

-- Callback output is consumed in scheduled, yielding search tasks, not libuv callbacks.
function M.run(command, cwd, task, emit, yield)
  local chunks, head, done, result = {}, 1, false, nil
  local proc = vim.system({ vim.o.shell, vim.o.shellcmdflag, command }, {
    cwd = cwd,
    text = false,
    detach = true,
    stdout = function(err, data)
      if task.cancelled then
        return
      end
      if err then
        result = { code = -1, stderr = tostring(err) }
      end
      if data then
        chunks[#chunks + 1] = data
      end
      task:resume()
    end,
  }, function(res)
    if task.cancelled then
      return
    end
    result, done = result or res, true
    task:resume()
  end)
  task:on_cancel(function()
    if not done then
      pcall(vim.uv.kill, -proc.pid, "sigterm")
      pcall(proc.kill, proc, 15)
      vim.defer_fn(function()
        if not done then
          pcall(vim.uv.kill, -proc.pid, "sigkill")
        end
      end, 200)
    end
  end)
  local pending, stopped = "", false
  local function send(line)
    if stopped then
      return
    end
    if emit(line) == false then
      stopped = true
      pcall(vim.uv.kill, -proc.pid, "sigterm")
      pcall(proc.kill, proc, 15)
    end
  end
  while not done or head <= #chunks do
    while head <= #chunks do
      local data = pending .. chunks[head]
      chunks[head], head, pending = false, head + 1, ""
      local from = 1
      while true do
        local last = data:find("\n", from, true)
        if not last then
          pending = data:sub(from)
          break
        end
        local line = data:sub(from, last - 1):gsub("\r$", "")
        send(line)
        from = last + 1
        yield()
      end
    end
    if not done then
      require("fzf-lua-smart.task").suspend()
    end
  end
  if pending ~= "" then
    send(pending)
  end
  if stopped then
    return { code = 0 }
  end
  return result
end
return M
