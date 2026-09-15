# fzf-lua-smart

> Snacks-style `smart` search & frecency ranking powered by the [fzf-lua](https://github.com/ibhagwan/fzf-lua) interface.

**fzf-lua-smart** brings the intelligent multi-source file picker from [Snacks.nvim](https://github.com/folke/snacks.nvim) to **fzf-lua**. It combines open buffers, recently visited files, and project files into a single unified search with smart frecency and contextual scoring—with **zero runtime dependency on Snacks**.

---

## 🌟 Why fzf-lua-smart?

- **Unified Multi-Source Search**: One keypress searches active `buffers`, `recent` files, and project `files` simultaneously with automatic deduplication.
- **Intelligent Scoring & Ranking**: Ported matching algorithm from Snacks combining **frecency**, **cwd bonus**, and **filename bonus** for intuitive candidate prioritization.
- **Zero Snacks Runtime**: Pure Lua implementation with no external runtime dependencies beyond `fzf-lua`.
- **Native fzf-lua Power**: Retains all fzf-lua benefits—rich previewers, floating window presets, path formatters (`path.filename_first`), syntax highlighting, and native actions (split, vsplit, quickfix).
- **Full Stable Sort**: Eliminates Snacks' 1,000-item heap truncation; all candidates receive a complete, predictable stable sort.
- **Fast & Non-Blocking**: Asynchronous file scanning, incremental matching that yields smoothly to Neovim UI, and optional worker multiprocessing for massive codebases.
- **Isolated Frecency History**: Safe, independent visit history stored under `stdpath("data")/fzf-lua-smart/` (built-in atomic KV store, optional SQLite), with zero interference with Snacks or other plugins.

---

## 📋 Requirements

- **Neovim** >= 0.11
- **fzf** >= 0.59
- **[fzf-lua](https://github.com/ibhagwan/fzf-lua)**
- One file scanner CLI: **`fd`** / `fdfind` (recommended), `rg`, or `find`
- macOS or Linux (Windows and skim are not supported)

---

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "nicholasxjy/fzf-lua-smart",
  dependencies = { "ibhagwan/fzf-lua" },
  keys = {
    {
      "<leader><space>",
      function()
        require("fzf-lua-smart").smart()
      end,
      desc = "Smart File Search",
    },
  },
}
```

### [`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack) (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/ibhagwan/fzf-lua",
  "https://github.com/nicholasxjy/fzf-lua-smart",
})

vim.keymap.set("n", "<leader><space>", function()
  require("fzf-lua-smart").smart()
end, { desc = "Smart File Search" })
```

Verify your environment anytime with:

```vim
:checkhealth fzf-lua-smart
```

---

## 🚀 Usage

### Basic Call

```lua
-- Open the smart picker
require("fzf-lua-smart").smart()
```

### With Custom Options

Pass options per-call to customize behavior on the fly:

```lua
require("fzf-lua-smart").smart({
  cwd = vim.fn.getcwd(),
  hidden = true,                -- include hidden files
  multi = { "buffers", "recent", "files" }, -- search sources order
  filter = { cwd = true },      -- restrict recent files to current working directory
})

-- Dynamic query or location jumping (e.g. "init.lua:12:3")
require("fzf-lua-smart").smart(function()
  return { query = "init.lua:12:3" }
end)
```

---

## ⚙️ Configuration

`setup()` is **optional**. It sets plugin defaults without modifying `fzf-lua.setup()` or altering standard `FzfLua.files`.

```lua
require("fzf-lua-smart").setup({
  -- Sources to search (in priority order)
  multi = { "buffers", "recent", "files" },

  -- Matching & Scoring options
  matcher = {
    frecency = true,        -- boost frequently & recently accessed files
    cwd_bonus = true,       -- score bonus for files inside current working directory
    filename_bonus = true,  -- score bonus when match occurs in filename
    sort_empty = true,      -- sort candidates by score when search query is empty
  },

  -- Search & Filtering options
  filter = { cwd = true },  -- filter recent files by cwd
  hidden = false,           -- show hidden files
  follow = false,           -- follow symlinks

  -- Performance (optional: set true to enable worker multiprocessing for large repos)
  multiprocess = false,
})
```

### Option Reference

Option resolution follows: **call options → plugin setup → fzf-lua files/global defaults → algorithm defaults**.

| Category | Option | Default | Description |
|---|---|---|---|
| **Sources** | `multi` / `sources` | `{"buffers", "recent", "files"}` | Sources and their priority order. |
| | `transform` | `"unique_file"` | Deduplication across sources (`"unique_file"`, `"text_to_file"`, or custom fn). |
| **Matcher** | `matcher.frecency` | `true` | Apply 30-day half-life decay frecency bonus. |
| | `matcher.cwd_bonus` | `true` | Score bonus (+10) for files under current working directory. |
| | `matcher.filename_bonus`| `true` | Score bonus for matches within filename. |
| | `matcher.sort_empty` | `true` | Sort candidates even with an empty query (by frecency/cwd). |
| | `matcher.fuzzy` | `true` | Enable fuzzy matching. |
| **Scanning**| `cwd` | `vim.fn.getcwd()` | Root directory for file scanning. |
| | `hidden` | `false` | Include hidden files (also includes unlisted buffers). |
| | `follow` | `false` | Follow symbolic links. |
| | `exclude` | `nil` | Patterns or directories to exclude. |
| | `live` | `false` | When true, typing updates the underlying finder search. |
| **Engine** | `multiprocess` | `false` | Use headless MessagePack worker for matching on massive datasets. |
| | `db.sqlite3_path` | `nil` | Optional path to `sqlite3` library for frecency storage (defaults to fast KV store). |
| **UI** | `winopts`, `previewer`, etc. | *inherited* | Passed transparently to native `fzf-lua`. |

---

## ⌨️ Controls & Keymaps

The smart picker runs inside native `fzf-lua`, supporting all your existing `fzf-lua` keymaps and actions:

- **`<CR>` / `<C-x>` / `<C-v>` / `<C-t>`**: Open file in current buffer, split, vsplit, or new tab.
- **`<C-q>`**: Send matching entries to quickfix list.
- **`<C-r>`**: Refresh candidate list and rescanning.
- **Toggle Actions**: Inherited fzf-lua toggles (e.g. toggle hidden, toggle follow) work out of the box and seamlessly refresh the smart search.
- **Resume**: `require("fzf-lua-smart").smart({ resume = true })` resumes the previous smart search with an independent resume state from `FzfLua.files`.

---

## 🔬 Compatibility & Design

- **Algorithms Pinned**: Faithfully ported from Snacks (`882c996c`) and fzf-lua (`05e44d38`).
- **Highlights**: Highlights matching characters using native `FzfLuaFzfMatch` / `fzf_colors.hl`, compatible with `path.filename_first` and shortened paths.
- **Details**: For edge-case behaviors and design trade-offs, refer to [doc/compatibility.md](doc/compatibility.md) and `:help fzf-lua-smart`.

---

## 🛠️ Development & Testing

```sh
# Fetch pinned dependencies (Snacks is fetched only for test differential comparison)
scripts/bootstrap.sh

# Run comprehensive differential and live fzf tests
scripts/test.sh

# Run performance benchmarks
nvim --headless -u tests/minimal.lua -l scripts/benchmark.lua
```

---

## 📄 License

- Original code: [MIT](LICENSE).
- Ported Snacks algorithms retain **Apache-2.0** as licensed upstream.
- See [NOTICE](NOTICE), [licenses/snacks-Apache-2.0.txt](licenses/snacks-Apache-2.0.txt), and [licenses/fzf-MIT.txt](licenses/fzf-MIT.txt) for details.
