# Compatibility and pinned behavior

## Baselines and evidence

- Snacks: `882c996cf28183f4d63640de0b4c02ec886d01f2`.
- fzf-lua: `05e44d38de0a79c11fba5f7bf8138791b1dbdd1e`.
- Snacks is Apache-2.0 at this revision. The initial design's MIT assumption was
  corrected from the actual source license before porting.
- Tests import Snacks only from the ignored development checkout. Production
  modules import Neovim, LuaJIT facilities and fzf-lua, not Snacks.

Derived files map to the same-named Snacks picker core/source modules;
`vendor/sort.lua` and `vendor/transform.lua` come from picker root modules.
`util.lua` contains only the upstream path/text/rtp/query-argument utilities.
`sqlite.lua` retains upstream SQLite deadline representation but changes error
and handle management. `vendor/frecency.lua` changes store creation and autocmd
ownership, not score/deadline/seed/visit calculation. Matcher UI execution was
removed; the adapter schedules search and supplies callback context.

`tests/matcher.lua` compares parsed modifiers, sets, exact numeric scores,
Item mutations and byte positions for generic/`smart` defaults and shared matcher
factors toggled individually, with both file and non-file items and frozen
frecency. Deterministic randomized/repeated-byte cases also exercise the greedy
suffix and filename-boundary caches. Separate assertions cover the intentional
`file_pos=false` correction. It also compares full logical order of 3,000
history-boosted results.
`tests/config.lua` checks all nine defaults and setup/call overrides against
upstream; `tests/engine.lua` compares scores, order and positions through query
reloads in both the main process and worker, including empty-query restoration.
`tests/sources.lua` compares raw buffer/recent metadata, filtering and unique-file
behavior against upstream.
`tests/history.lua` compares fixed-clock decay/seed/visit operations and tests
both persistence representations. Engine and real terminal tests cover the
fzf boundary independently.

## Matcher defaults

The algorithm defaults match `picker/config/defaults.lua` merged with
`picker/config/sources.lua:smart`, not the generic picker table alone:

| Factor | Generic picker | `smart` / this plugin |
| --- | --- | --- |
| `fuzzy` | `true` | `true` |
| `smartcase` | `true` | `true` |
| `ignorecase` | `true` | `true` |
| `sort_empty` | `false` | `true` |
| `filename_bonus` | `true` | `true` |
| `file_pos` | `true` | `true` |
| `cwd_bonus` | `false` | `true` |
| `frecency` | `false` | `true` |
| `history_bonus` | `false` | `false` |

Every factor can be overridden through setup or per-call options, including
explicit `false`. `smartcase` takes precedence over `ignorecase`.
`filename_bonus` adds 6 for file items when no path separator follows the first
matched byte. `history_bonus` changes whitespace/delimiter boundary weights from
10/9 to 8/8; it neither reads visit history nor adds a chronological score.
Nested and dotted matcher keys are normalized before merging plugin, native
files/defaults, and profile options, so lower-priority spellings cannot override
higher-priority values.

## Location parsing correction

The pinned upstream parser ignores `matcher.file_pos`. This plugin intentionally
honors `file_pos=false`: location suffixes remain query text and do not set a
jump position. The default (`true`) retains upstream parsing, scoring and byte
positions. Field queries such as `file:lua` still work when locations are off.
Explicit native `line_query` takes precedence: false disables location parsing;
true/function uses only the native parser. Main-process and worker tests cover
these switches through setup and per-call overrides.

## Deliberate full-sort exception

The approved result is a **full stable comparator sort** without an implicit
candidate cap. Snacks `picker/core/list.lua` creates a minheap with
`capacity = 1000` at lines 97–100. `list:add` (320–343) inserts/evicts heap
members; `list:get` (354) returns `topk:get(idx) or items[idx]`. The tail is not
fully comparator-sorted. Heap sorting itself uses unstable `table.sort`.

This plugin does not reproduce that UI artifact. Default ordering has `idx` as
a final tie-breaker; custom comparator ties retain candidate enumeration order.
Differential *order* tests compare full logical comparator sort, not the
upstream UI heap/tail. Scores and matcher positions remain exact.

## Observable quirks preserved

- `core/matcher.lua:fuzzy` says “forward/backward” in its comment but repeatedly
  runs greedy forward scans. The same starts, scores, positions and first-best
  ties are retained. This plugin reuses monotone suffix positions between starts
  and caches the next filename separator for the current string; neither is a
  backward scan or a different scoring algorithm.
- UTF-8 matching uses bytes and Lua's case conversion, not Unicode case folding.
- All OR alternatives contribute highlight positions, not only the alternative
  whose score was used; OR alternatives are tried in upstream entropy order.
- The cwd bonus tests `path:find(cwd, 1, true) == 1`, without a separator boundary.
  `/work-other/x` therefore receives the `/work` bonus. `filter.cwd` *does* check
  path boundaries. The bonus is 10, applied after add/multiply and frecency.
- Frecency adds `8 * (1 - 1 / (1 + frecency))`. Seeds do not write to the store.
  SQLite snapshots are copies; KV snapshots share its in-memory table. A visit
  does not independently refresh an existing SQLite snapshot cache.
- `Filter:init` refers to `M.current_buf`, not `self.current_buf`, for `buf=0`/
  `buf=true`. The pinned behavior is retained. Pass an explicit buffer id when
  you need deterministic buffer filtering.
- Source configuration is merged with shared options **last**. For example,
  `hidden` is both a file-scan and buffer-list option.
- Buffers match their joined buffer id, full name, filetype and buftype, not
  merely the path. Sorting length is the byte length of this original text.
- Recent files combine session buffers (lastused order) and oldfiles, normalize
  paths without realpath, check existence and exclude the current file.
- `filter` is applied by the buffer/recent source, not automatically by the
  files source. `filter.transform` changes finder/matcher state before a find.
- `unique_file` is a transform, applied before the added fzf-native filtering.
  Replacing it disables uniqueness, and its “seen” mark is first-appearance,
  not first appearance surviving every later filter.
- Finder limits stop asynchronous collection before later transforms; a
  buffers-only synchronous result ignores the limit. Live defaults to 10,000;
  ordinary collection has no limit.
- Explicit find directories are inserted in reverse order, matching Snacks.
  Multiple `ft` filters on find are AND predicates, whereas fd/rg have their
  own backend semantics. No tool enumeration order is promised across runs.
- With explicit dirs/rtp, files have no Item.cwd, as upstream. Relative roots
  therefore retain upstream's relative-path identity semantics. Absolute roots
  are recommended when mixing scans of external trees with buffer/recent items.

## fzf-lua semantics that take precedence

- Native effective files/global/profile options, including default hidden=true,
  exclusion of `.git`/`.jj`, backend preference fdfind before fd, display,
  preview and actions, are inherited on each invocation.
- `cmd` and `raw_cmd` are shell commands. Executable selection uses the distinct
  `finder_cmd`. `raw_cmd` returns unchanged and overrides scan construction.
  Unsafe explicit scanning extensions fail early, rather than silently being
  ignored or injected into a custom shell pipeline.
- `no_ignore` and `search_paths` win over their Snacks aliases within a layer;
  each layer is canonicalized before precedence merge.
- `query` is the initial input. `line_query` retains native boolean/function
  semantics, but the native binding that would run `search()` is not installed.
- fzf's matching/sorting controls are reserved. Default inherited sort shortcuts
  are removed, explicit conflicting controls are errors, including raw/list
  arguments, `--enabled`, transport overrides and every entry of bind lists.
  Native reload actions force a new scan; regular typing does not.
- Items carry a base64 native file/buffer/location record in a hidden field.
  `path.entry_to_file` decodes it before native preview/actions. Formatting is
  for display only. Custom actions should use this same decoder; do not split
  the visible string to infer a filename.
- Positions are byte columns. Snacks uses zero-based columns; the native
  transport adds one before fzf-lua converts back for cursor movement.
- Default file command output is line-delimited, like inherited fzf files
  commands. Control/newline path display is escaped; custom finder commands
  must emit one filename per line (not NUL-separated records).

## Search context, not UI emulation

`Filter` exposes upstream pattern/search/cwd/buf/file/paths/meta and
`clone/init/is_empty/set_cwd/match/filter`. Transforms receive a Context with
`filter`, shared per-find `meta`, `cwd/git_root/opts/clone`, and the running
scheduled task. `ctx.picker` is a search facade; `iter()` yields `(item, index)`
from the last completed sorted result set, while `count()` counts collected
candidates. `find()` queues a refresh for the next native reload rather than
reentering an active callback. Window/list navigation,
Snacks preview/action APIs and its UI lifecycle are deliberately outside the
interface. Configure those through native fzf-lua options.

## Execution and resource ownership

Regex compilation (including invalid patterns) is cached for the most recently
used pattern. Stable merge sorting skips already ordered runs and buffers only
left runs; it still sorts all results and yields to input/timers. Comparators
must define a consistent strict weak ordering.

Retained-parent bookkeeping belongs to one matching round. Before matching,
the engine resets candidates and their current ancestor graph once (only when
`keep_parents` is enabled). This includes external parents shared by transform
closures across queries, close/resume and picker instances; an unchanged or
colliding pattern tick cannot suppress those parents.

The matcher still clears existing `match_topk` metadata, but does not insert an
absent nil-valued key. Such writes can expand full LuaJIT hash tables on each
candidate during repeated queries even though the field remains logically nil.

Completed/cancelled tasks release their coroutine stacks and cleanup closures.
Closing or hiding a picker releases its candidate/result/parent arrays even if
native resume options keep the engine alive. Resume already requests a fresh
scan, so no candidate cache needs to survive close. References intentionally
retained by user callbacks remain the caller's responsibility.

See [performance checks](performance.md) for reproducible benchmarks.

## Storage safety changes

All persistence is isolated to `stdpath('data')/fzf-lua-smart`. No migration,
import or read of Snacks history occurs. Optional SQLite loading does not
trigger downloads. SQLite statements are finalized; errors are checked. KV
writes atomically to a sibling temp file, preserving numeric encoding and
upstream newer-writer guard. A failed or corrupt backend yields a once-per-
session warning and a memory-only store, never a silent corrupt-file overwrite.
These are lifecycle/safety improvements, not alternate scoring algorithms.

## Changing baselines

Update the explicit commit in bootstrap, provenance headers and documentation;
review upstream changes and re-run the differential, storage, lifecycle,
real-fzf and performance tests. Do not update vendored scoring implicitly just
because the fzf-lua integration matrix's main branch changes.
