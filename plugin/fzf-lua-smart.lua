if vim.g.loaded_fzf_lua_smart then
  return
end
vim.g.loaded_fzf_lua_smart = true
-- Record buffer visits from startup; the history store opens on first use.
require("fzf-lua-smart.config").track()
