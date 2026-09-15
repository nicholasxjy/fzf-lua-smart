# fzf-lua-smart

Snacks `smart` search and ranking, with the fzf-lua interface and file actions.
The only required **plugin** dependency is [fzf-lua](https://github.com/ibhagwan/fzf-lua).
Snacks is **not** loaded at runtime.

Requires macOS/Linux, Neovim **0.11+**, fzf **0.59+**, and fd/fdfind, rg or find.
Windows and skim are not supported. Optional icon providers and SQLite are not
required; neither is downloaded by this plugin.

## Install and use

```lua
-- lazy.nvim
{
  "nicholasxjy/fzf-lua-smart",
  dependencies = { "ibhagwan/fzf-lua" },
  keys = {
    { "<leader><space>", function() require("fzf-lua-smart").smart() end,
      desc = "Smart files" },
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

```lua
-- Optional. Does not call or replace fzf-lua.setup().
require("fzf-lua-smart").setup({
  matcher = { frecency = true, cwd_bonus = true, sort_empty = true },
})

require("fzf-lua-smart").smart({
  cwd = vim.fn.getcwd(),
  hidden = false,
  multi = { "buffers", "recent", "files" },
  filter = { cwd = true },
  matcher = { filename_bonus = true },
})

-- A function returning options is also accepted.
require("fzf-lua-smart").smart(function()
  return { cwd = vim.fn.getcwd(), query = "init.lua:12:3" }
end)
```

There is no `FzfLua.smart` command and `FzfLua.files` is not modified. Return
values follow `fzf_live`: coroutine, reload command, effective options (or nil
when fzf-lua cannot start). `:checkhealth fzf-lua-smart` checks prerequisites.

## Search contract

Pinned algorithms: Snacks **`882c996cf28183f4d63640de0b4c02ec886d01f2`**.
Pinned integration: fzf-lua **`05e44d38de0a79c11fba5f7bf8138791b1dbdd1e`**.

The matcher, scores, positions, source metadata, path normalization, first-file
uniqueness and comparator are ported, not approximated with fzf scoring. The
same inputs, effective search configuration, clock and history produce the
same matching results and scores.

**Deliberate ordering difference:** all candidates receive a **full stable
sort**, by default `score:desc`, `#text`, `idx`. The pinned Snacks UI keeps a
1,000-entry heap and uses its remaining item array after that. We do not
reproduce that unsorted tail or heap-dependent unstable custom-comparator ties.
Comparator ties retain enumeration order. “Order alignment” here means full
logical comparator order, not literal Snacks UI order beyond its heap.

Zero-argument results need not equal Snacks: fzf-lua defaults take precedence
(e.g. hidden files), and visit histories are separate. See
[the detailed compatibility contract](doc/compatibility.md) for pinned quirks
and fzf-specific exceptions.

## Configuration

Priority: **call → plugin setup → fzf-lua files/global → algorithm defaults**.
Repeated setup replaces plugin defaults without re-registering resources.
Native profiles, UI function options, `false` and list replacement retain
fzf-lua normalization; caller-owned tables are not changed. `multi` and
`sort.fields` are replaced as lists, not appended.

| Options | Meaning/default |
| --- | --- |
| `multi`, `sources` | Built-in `buffers`, `recent`, `files`, in that order. Entries may be names or `{ source = "files", ... }`. |
| `finders` | Alias for `multi`; the pinned Snacks implementation actually uses `multi`. |
| `matcher` | `fuzzy`, `smartcase`, `ignorecase`, `filename_bonus`, `file_pos`, `cwd_bonus`, `frecency`, `history_bonus`, `sort_empty`, `sort`, `regex`, `keep_parents`, `on_match`, `on_done`. |
| `sort` | `{ fields = { "score:desc", "#text", "idx" } }`, or a comparison function. Field records `{ name, desc, len }` also work. |
| `pattern` | Initial matcher condition; may be a function of the search facade. |
| `query` | Initial input; overrides `pattern` in ordinary mode, `search` in live mode. |
| `search` | Initial finder search; may be a function. In live mode, `pattern` remains independent. |
| `live` | Default false. Input changes finder search when true. fd uses a pattern, rg a glob, find `-name`, as upstream. |
| `limit`, `limit_live` | Finder limits, not top-N ranking. Ordinary mode is unlimited; upstream live default is 10,000. A purely synchronous buffers-only finder ignores limits, as upstream. |
| `filter` | `cwd`, `buf`, `paths`, predicate `filter(item, filter)`, and `transform(search, filter)`. Source-stage semantics are retained; not a universal post-filter. |
| `transform` | Default `"unique_file"`; also `"text_to_file"`, false or `(item, ctx) → item / false / nil`. Replacing it replaces uniqueness, as upstream. |
| `hidden`, `follow`, `cwd` | Shared options retain cross-source meaning. `hidden` also controls unlisted buffers. |
| `ignored` / `no_ignore` | Same-layer `no_ignore` wins; an upper-layer alias still overrides a lower layer. |
| `dirs` / `search_paths` | Same-layer `search_paths` wins; string or list. `rtp=true` appends runtime paths (including unloaded lazy paths when available). |
| `exclude`, `ft`, `args` | Scanner exclusions, extension(s), argv entries. Backend differences are preserved. |
| `cmd`, `raw_cmd` | Complete shell commands, not executable names. `raw_cmd` bypasses scan flags; `cmd` still receives native fzf-lua toggle handling. |
| `finder_cmd` | Select fd/fdfind/rg/find explicitly. Default selection and base flags come from fzf-lua. |
| `line_query` | Unspecified: Snacks file/line/column parser. False: no location parser. True/function: native line parser only, without installing fzf search bindings. |
| `file_ignore_patterns`, `ignore_current_file`, `cwd_only` | Additional fzf-lua filtering, without rewriting raw matching text. |
| `db.sqlite3_path` | Optional SQLite shared-library path; never a Snacks database path. |
| `multiprocess` | False/1: main-instance scheduled matching. True: headless matching worker using MessagePack snapshots, with callbacks/control/history in the main instance. |
| `winopts`, `hls`, `prompt`, `previewer`, `preview`, `formatter`, icons, path display, `actions`, `keymap` | Native fzf-lua interface configuration. See reserved controls below. |

Source merge order is **source defaults → source entry → shared top-level
options**. A source-level value cannot override an already-set shared value.
Buffer-specific `unloaded`, `current`, `nofile`, `modified`, `sort_lastused` are
supported. Recent files exclude data/cache/state paths by default.

Explicit `exclude`, `ft`, `rtp`, `args` or `finder_cmd` alongside a custom shell
command raises a configuration error. Nonempty finder search with `cmd` is
also rejected rather than guessing a shell rewrite; `raw_cmd` completely
controls enumeration. Ordinary matcher input is never appended to a shell
command; constructed finder arguments are individually shell-escaped.

### Callbacks

Types live in `lua/fzf-lua-smart/types.lua`. An Item keeps original
`text/file/cwd/buf/info/recent/source_id/idx/pos` and scoring fields. A transform
context exposes `filter`, per-find `meta`, `cwd()`, `git_root()`, `opts()`,
`clone()` and its running task. `ctx.picker` is a **search facade** exposing
`opts`, `filter`, `matcher`, `cwd()`, `count()`, `iter()`, `find()` and `closed`.
`find()` queues a refresh for the next native reload; it does not reenter a
currently running callback. It is not a simulated Snacks window/picker. Snacks window, preview, key/action
and UI lifecycle callbacks are not supported; use fzf-lua equivalents.

## Interface and lifecycle

fzf displays and selects already-ranked rows. The adapter owns `--disabled`,
`--no-sort`, `--read0`, `--print0`, the identity delimiter/`--with-nth`, and
start/change reload handling. Native inherited sorting shortcuts are removed.
Explicit attempts to enable search/sort, reverse candidates, alter identity
fields or replace reload/search controls raise errors. Ordinary UI keys pass
through. Do not use fzf `--filter` for matching this picker.

**Ctrl-R** refreshes unless you supplied an action for it. Native hidden/ignore/
follow toggle actions return to smart. `smart({ resume = true })` uses the
independent `fzf-lua-smart` resume key; normal `FzfLua.resume`/hide/unhide work.
The `files` resume record is not overwritten.

A hidden transport field contains the complete native file/buffer record;
shortened text is never used to guess a target. Custom actions should decode
with `require("fzf-lua.path").entry_to_file(line, opts)`, as native file actions
do. Matcher highlights use the native `FzfLuaFzfMatch` foreground (or your
`hls.fzf.match` / `fzf_colors.hl` override), including the built-in
`path.filename_first` and `path.dirname_first` formatters and shortened paths.
Only visible source characters are highlighted; custom formatter output is
not guessed or highlighted.

Ordinary input reuses one asynchronous scan per opening/refresh. Live input
rescans only if transformed finder search/source changes or refresh is forced.
Scoring, stable sorting and rendering yield to Neovim. A completed generation
publishes one globally sorted result sequence; outdated generations and closed
pickers cancel their work. There is no hidden ranking top-N limit.

## Independent visit history

Stored under `stdpath("data")/fzf-lua-smart/`, never Snacks' directory. On first
use with frecency enabled, eligible existing buffers are visited; subsequent
`BufWinEnter` events record visits. Floating previews, unlisted/non-file buffers
and nonexistent paths are excluded. Selection itself does not record a second
visit. Decay uses a 30-day half-life, one point per visit, and upstream recent/
buffer seed values. Store cleanup retains 10,000 highest-deadline entries
(SQLite retains cutoff ties, as upstream).

SQLite is optional. Its deadlines are integer-truncated, matching upstream
`bind_int64`; KV uses `string.buffer` and retains doubles. Missing SQLite uses
KV. Corrupt/unreadable stores are not silently replaced. Storage failures
produce one warning and use in-memory history so selection remains available.
KV saves atomically on exit and honors the upstream newer-file guard.

## Development

```sh
scripts/bootstrap.sh       # pinned development dependencies; Snacks only for tests
scripts/test.sh            # isolated XDG dirs, headless differential + real fzf tests
nvim --headless -u tests/minimal.lua -l scripts/benchmark.lua
# Test fzf-lua's current main without changing the algorithm baseline:
FZF_LUA_REF=main scripts/bootstrap.sh
```

CI covers macOS/Linux, Neovim 0.11/current stable, fzf 0.59/current, and pinned/
main fzf-lua. No claim that an unrun CI matrix has passed. The benchmark prints
scan/match/sort/render totals, timer responsiveness and Lua memory for 10k/
100k candidates, checks that ordinary queries do not rescan, and checks that
nothing was truncated. Timing is a measurement, not a latency guarantee.

## License

Original code: [MIT](LICENSE). Snacks-derived files retain **Apache-2.0**,
the license actually present at the pinned commit (not MIT). Modification
notices are in each derived file. See [NOTICE](NOTICE),
[Snacks license](licenses/snacks-Apache-2.0.txt), and
[fzf scoring provenance](licenses/fzf-MIT.txt).
