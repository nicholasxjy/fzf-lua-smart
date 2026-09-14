vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/.deps/fzf-lua")
vim.opt.shadafile = "NONE"
vim.o.swapfile = false
vim.o.termguicolors = true
