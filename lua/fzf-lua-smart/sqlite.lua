-- Derived from Snacks picker/util/db.lua at 882c996cf28183f4d63640de0b4c02ec886d01f2.
-- Apache-2.0; see licenses/snacks-Apache-2.0.txt.
-- Modified: no downloads/global config, checked errors, finalized statements.
local ffi = require("ffi")
ffi.cdef([[
  typedef struct sqlite3 sqlite3;
  typedef struct sqlite3_stmt sqlite3_stmt;
  int sqlite3_open(const char*, sqlite3**);
  int sqlite3_close(sqlite3*);
  const char *sqlite3_errmsg(sqlite3*);
  int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
  int sqlite3_step(sqlite3_stmt*);
  int sqlite3_finalize(sqlite3_stmt*);
  int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
  int sqlite3_bind_int64(sqlite3_stmt*, int, long long);
  const unsigned char *sqlite3_column_text(sqlite3_stmt*, int);
]])
local M = {}
function M.library(path)
  return ffi.load(path or "sqlite3")
end
function M.open(path, lib)
  local handle = ffi.new("sqlite3*[1]")
  local code = lib.sqlite3_open(path, handle)
  local db = handle[0]
  if code ~= 0 then
    local message = ffi.string(lib.sqlite3_errmsg(db))
    lib.sqlite3_close(db)
    error(message)
  end
  local self = {}
  local function query(sql, binds, rows)
    local out = ffi.new("sqlite3_stmt*[1]")
    assert(lib.sqlite3_prepare_v2(db, sql, #sql, out, nil) == 0, ffi.string(lib.sqlite3_errmsg(db)))
    local stmt = out[0]
    local ok, failure = pcall(function()
      for i, v in ipairs(binds or {}) do
        local rc = type(v) == "string" and lib.sqlite3_bind_text(stmt, i, v, #v, nil)
          or lib.sqlite3_bind_int64(stmt, i, v)
        assert(rc == 0, "sqlite bind failed")
      end
      local rc = lib.sqlite3_step(stmt)
      while rc == 100 do
        if rows then
          rows(stmt)
        end
        rc = lib.sqlite3_step(stmt)
      end
      assert(rc == 101, ffi.string(lib.sqlite3_errmsg(db)))
    end)
    local rc = lib.sqlite3_finalize(stmt)
    assert(ok, failure)
    assert(rc == 0, "sqlite finalize failed: " .. rc)
  end
  function self:close()
    if db ~= nil then
      local rc = lib.sqlite3_close(db)
      assert(rc == 0, "sqlite close failed: " .. rc)
      db = nil
    end
  end
  local ok, failure = pcall(function()
    query("PRAGMA journal_mode=WAL;")
    query("CREATE TABLE IF NOT EXISTS data (key TEXT PRIMARY KEY, value INTEGER NOT NULL);")
    query("DELETE FROM data WHERE value < (SELECT value FROM data ORDER BY value DESC LIMIT 1 OFFSET 9999);")
  end)
  if not ok then
    self:close()
    error(failure)
  end
  function self:set(key, value)
    query("INSERT OR REPLACE INTO data (key,value) VALUES (?,?);", { key, value })
  end
  function self:get_all()
    local ret = {}
    query("SELECT key,value FROM data;", nil, function(stmt)
      local key, value = lib.sqlite3_column_text(stmt, 0), lib.sqlite3_column_text(stmt, 1)
      assert(key ~= nil and value ~= nil, "invalid sqlite history row")
      ret[ffi.string(key)] = assert(tonumber(ffi.string(value)), "invalid sqlite history value")
    end)
    return ret
  end
  return self
end
return M
