# fzf-lua-smart

## Installation

Requires Neovim >= 0.11, fzf >= 0.59, [fzf-lua](https://github.com/ibhagwan/fzf-lua), and `fd`/`fdfind`, `rg`, or `find` on macOS/Linux. Snacks.nvim is not required.

### lazy.nvim

```lua
{
  "nicholasxjy/fzf-lua-smart",
  dependencies = { "ibhagwan/fzf-lua" },
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/ibhagwan/fzf-lua",
  "https://github.com/nicholasxjy/fzf-lua-smart",
})
```

## Usage

Search open buffers, recent files, and project files:

```lua
require("fzf-lua-smart").smart()

vim.keymap.set("n", "<leader><space>", function()
  require("fzf-lua-smart").smart()
end, { desc = "Smart File Search" })
```

Pass options per call, or set defaults with the optional `setup()`:

```lua
require("fzf-lua-smart").setup({
  hidden = true,
  filter = { cwd = true },
})

require("fzf-lua-smart").smart({ cwd = "~/projects/my-project" })
require("fzf-lua-smart").smart({ query = "init.lua:12:3" })
require("fzf-lua-smart").smart({ resume = true })
```

Existing fzf-lua UI settings and actions are inherited. Run `:checkhealth fzf-lua-smart` to check dependencies.

## Configuration

All options below can be passed to `setup()` or `smart()`. `setup()` is optional; calling it again replaces the previous plugin defaults. It does not modify `fzf-lua.setup()` or `FzfLua.files`.

Priority, highest first: **call options → plugin setup → effective fzf-lua files/global/profile options → algorithm defaults**. Explicit `false` values are preserved. Lists such as `multi` and `sort.fields` replace lower-priority lists.

### Example

This uses the default Snacks `smart` matcher, with explicit choices for filtering and scanning:

```lua
require("fzf-lua-smart").setup({
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
  filter = { cwd = true }, -- restrict buffer/recent candidates to cwd
  hidden = true,          -- include hidden files and unlisted buffers
  follow = false,         -- do not follow symlinks during scanning
  multiprocess = false,   -- match in the main Neovim instance
})
```

### Matching and ranking

These defaults follow **Snacks `smart`**, which enables `cwd_bonus`, `frecency`, and `sort_empty`. The generic Snacks picker defaults have those three disabled.

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `matcher.fuzzy` | boolean | `true` | Match non-contiguous characters. `false` uses contiguous matching; explicit query operators still apply. |
| `matcher.smartcase` | boolean | `true` | Lowercase queries ignore case; queries containing uppercase letters are case-sensitive. Takes precedence over `ignorecase`. |
| `matcher.ignorecase` | boolean | `true` | Controls case-insensitive matching when `smartcase = false`. Matching is byte-based, not Unicode case folding. |
| `matcher.sort_empty` | boolean | `true` | Rank candidates even with an empty query. `false` preserves candidate enumeration order for empty input. |
| `matcher.filename_bonus` | boolean | `true` | Add a filename bonus of 6 for file items when no path separator follows the first matched byte. |
| `matcher.file_pos` | boolean | `true` | Retained for upstream compatibility. The pinned parser supports locations but **does not consult this flag**; use `line_query` to control parsing. |
| `matcher.cwd_bonus` | boolean | `true` | Add 10 when the item's cwd matches or its full path starts with the picker cwd. This preserves upstream's raw-prefix behavior. |
| `matcher.frecency` | boolean | `true` | Boost frequently/recently visited files using 30-day decay. Adds `8 * (1 - 1 / (1 + frecency))`. |
| `matcher.history_bonus` | boolean | `false` | Use history-style boundary weights: whitespace/delimiter bonuses become 8/8 instead of 10/9. Does not read visit history or add a chronological score. |
| `matcher.sort` | boolean | enabled | `false` disables comparator sorting for all queries, independently of `sort_empty`. |
| `matcher.regex` | boolean | disabled | Interpret the pattern as a Vim regular expression instead of the fuzzy query syntax. |
| `matcher.keep_parents` | boolean | disabled | Retain ancestors of matched items when custom transforms provide `item.parent`. |
| `matcher.on_match` | function | unset | Called as `function(matcher, item)` after scoring a match. |
| `matcher.on_done` | function | unset | Called as `function(matcher)` after a matching round finishes. |
| `sort` | table or function | see below | Sort-field configuration, or a comparator `function(a, b)` returning whether `a` precedes `b`. |
| `sort.fields` | list | `{ "score:desc", "#text", "idx" }` | Highest score, then shortest original matching text, then source enumeration index. Prefix a field with `#` for length; append `:asc` or `:desc` for direction. Field records `{ name = "score", desc = true, len = false }` are also accepted. |

Sorting covers the complete result set; comparator ties retain enumeration order. It does not reproduce Snacks' unsorted tail beyond its 1,000-item UI heap.

Frecency data is isolated under `stdpath("data")/fzf-lua-smart/`; no Snacks history is imported. Matcher callbacks receive the search engine's matcher/items, not Snacks windows or UI objects.

### Sources and transforms

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `multi` | list | `{ "buffers", "recent", "files" }` | Enabled sources and their order. Entries are names or records such as `{ source = "buffers", current = false }`. Only these three sources are supported. |
| `finders` | list | unset | Alias for `multi`. `multi` wins if both occur in the same configuration layer. |
| `sources` | table | recent-path exclusions | Per-source settings keyed by `buffers`, `recent`, or `files`; not a source-name list. Recent files exclude Neovim's data/cache/state directories by default. |
| `transform` | string, function, or `false` | `"unique_file"` | `"unique_file"` keeps the first occurrence of each normalized file path. `"text_to_file"` fills a missing file field from item text. A function receives `(item, ctx)` and can mutate the item, return a replacement, or return `false` to drop it. `nil` keeps the item; `false` as the option disables transformation/deduplication. |

Source options merge in this order: **source defaults → `multi` entry → shared top-level options**. Shared values win, even over an explicit source entry.

```lua
require("fzf-lua-smart").smart({
  multi = { { source = "buffers", current = false }, "recent", "files" },
  sources = {
    buffers = { unloaded = false },
    files = { ft = { "lua", "vim" } },
  },
})
```

Buffer-specific settings are available under `sources.buffers`, in a `multi` record, or at the top level:

| Option | Source default | Behavior |
| --- | --- | --- |
| `hidden` | `false` before shared overrides | Include unlisted buffers. The inherited shared `hidden` value also applies here. |
| `unloaded` | `true` | Include buffers that are not currently loaded. |
| `current` | `true` | Include the current buffer. |
| `nofile` | `false` | Include buffers with `buftype = "nofile"`. |
| `modified` | unset | `true` keeps only modified buffers. |
| `sort_lastused` | `true` | Enumerate buffers by last-used time before matcher sorting. |

Recent candidates combine session buffers and `vim.v.oldfiles`, skip nonexistent files, and exclude the current file. Transforms receive a search-only `ctx`; callback types are documented in [types.lua](lua/fzf-lua-smart/types.lua).

### Query, location and limits

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `cwd` | string | current working directory | Root for file scanning and cwd-based scoring. |
| `query` | string | derived from `pattern`/`search` | Initial input. Overrides `pattern` in normal mode, or `search` in live mode. |
| `pattern` | string or function | `""` | Matcher pattern. A function receives the search facade and returns a string. |
| `search` | string or function | `""` | Finder search, distinct from fuzzy matching. Backend pattern syntax applies. Functions receive the search facade. |
| `live` | boolean | disabled | `true` sends typed input to the finder and rescans when its search changes; `pattern` remains an independent matcher condition. Normal typing only rematches existing candidates. |
| `line_query` | boolean or function | unspecified/inherited | Unspecified uses the Snacks location parser; `false` disables it; `true` parses a trailing `:line`; a function `(query)` returns `(line, remaining_pattern)`. Native parsing replaces the Snacks parser rather than running both. |
| `limit` | integer | unlimited | Stop asynchronous candidate collection after this many accepted items in normal mode. This is not a top-N ranking limit. |
| `limit_live` | integer | `10000` | Candidate collection limit in live mode. A purely synchronous buffers-only source ignores finder limits. |
| `resume` | boolean | disabled | Restore the previous smart picker options/query using an independent resume key. |

Default location parsing supports queries such as `init.lua:12` and `src/init.lua:12:3`. Lines are 1-based and Snacks columns are 0-based; the adapter converts them for native fzf-lua actions.

### Filtering

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `filter.cwd` | boolean or string | unset | `true` restricts buffer/recent candidates to the picker cwd; a string uses that directory instead. |
| `filter.buf` | boolean or buffer ID | unset | Restrict candidates to a buffer/file. Pass an explicit buffer ID: upstream's `true`/`0` handling has a preserved quirk. |
| `filter.paths` | path-to-boolean table | recent excludes data/cache/state | Each prefix condition must pass: `true` requires a prefix, `false` excludes it. For example, `{ ["/project/vendor"] = false }`. |
| `filter.filter` | function | unset | Predicate `(item, filter)`; return `true` to keep the item. |
| `filter.transform` | function | unset | Called as `(search, filter)` before finding/matching. Can change `filter.pattern` or `filter.search`; returning `true` forces a refresh. |
| `file_ignore_patterns` | list of Lua patterns | inherited | Additional native fzf-lua path filtering, including files-source candidates. |
| `ignore_current_file` | boolean | inherited/off | Exclude the current file from all sources. |
| `cwd_only` | boolean | inherited/off | Apply native fzf-lua cwd filtering to all sources. |

`filter.*` predicates run in the buffer/recent sources, not as a universal post-filter on the files source. Use scanner exclusions or the native filtering options for project files. A custom `transform` can filter items across all sources.

### File scanning

Native options are inherited from your effective fzf-lua configuration. The values below describe a stock setup, not unconditional plugin defaults.

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `hidden` | boolean | inherited; stock `true` | Include dotfiles; also includes unlisted buffers. |
| `follow` | boolean | inherited/off | Follow symbolic links during scanning. |
| `no_ignore` | boolean | inherited/off | Include files normally excluded by backend ignore rules. |
| `ignored` | boolean | unset | Alias for `no_ignore`; the native name wins within the same layer. |
| `search_paths` | string or list | scan cwd | Explicit scan roots. Absolute paths are recommended when combining external directories with buffers/recent files. |
| `dirs` | string or list | unset | Alias for `search_paths`; the native name wins within the same layer. |
| `exclude` | list | unset | Backend exclusions: fd `-E`, rg negative globs, or find `-not -path`. |
| `ft` | string or list | unset | Filename extensions, not Neovim filetype names. Multiple extensions use backend semantics; find combines them with AND. |
| `rtp` | boolean | disabled | Add runtimepath roots, including unloaded lazy.nvim plugin roots when available. |
| `finder_cmd` | string | auto-detected | Choose `"fdfind"`, `"fd"`, `"rg"`, or `"find"`. Automatic preference follows that order. |
| `args` | list of strings | unset | Extra scanner arguments, individually shell-escaped. |
| `fd_opts`, `rg_opts`, `find_opts` | string | inherited | Native backend option strings. |
| `cmd` | string | unset/inherited | Custom shell command processed by native fzf-lua file-command/toggle handling. |
| `raw_cmd` | string | unset/inherited | Custom shell command returned unchanged; takes precedence over `cmd`. |

`cmd`/`raw_cmd` cannot be combined with `exclude`, `ft`, `rtp`, `args`, or `finder_cmd`. Nonempty finder search is rejected with `cmd`; `raw_cmd` owns enumeration and does not automatically consume that search. Custom commands must emit one filename per line, not NUL-separated records.

### Execution, storage and interface

| Option | Type | Default | Behavior |
| --- | --- | --- | --- |
| `multiprocess` | boolean or `1` | inherited; stock `1` | Only `true` enables a headless matching worker. `false` and `1` match in the main instance with scheduled yielding. |
| `db.sqlite3_path` | string | unset | Optional SQLite shared-library path. Otherwise the library is loaded by name when available; KV storage is the fallback. Nothing is downloaded. |
| `profile` | string or list | inherited | Load a native fzf-lua profile without changing global setup. |
| `winopts`, `prompt`, `hls` | native fzf-lua types | inherited | Window layout, prompt and highlight settings. |
| `previewer`, `preview` | native fzf-lua types | inherited | Native file preview settings. |
| `file_icons`, `git_icons` | native fzf-lua types | inherited | Entry icon settings. |
| `formatter`, `path_shorten` | native fzf-lua types | inherited | Display formatting only; matching text and file identity remain unchanged. |
| `actions`, `keymap` | native fzf-lua types | inherited | Native selection actions and UI keymaps. |
| `fzf_colors`, `fzf_opts` | native fzf-lua types | inherited | Native color/UI options, except reserved matching/sorting/transport controls. |

The plugin owns fzf matching, sorting, reloads and transport (`--disabled`, `--no-sort`, `--read0`, `--print0`, delimiter and hidden identity fields). Conflicting options or bindings such as `toggle-sort`, `enable-search`, and custom `reload` bindings are rejected. Native reload actions remain supported. `fn_reload`, `fn_transform`, `fn_preprocess`, and `fn_postprocess` are reserved; use `transform` for candidate changes.

See `:help fzf-lua-smart` and [compatibility notes](doc/compatibility.md) for preserved upstream quirks and callback boundaries.
