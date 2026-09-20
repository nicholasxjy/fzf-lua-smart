# Performance checks

Run from the repository root after `scripts/bootstrap.sh`:

```sh
scripts/test.sh
nvim --headless -u tests/minimal.lua -l scripts/benchmark_core.lua
nvim --headless -u tests/minimal.lua -l scripts/benchmark.lua
```

The core benchmark uses deterministic 10,000/100,000-item inputs, one warm-up
and three measured iterations. Each JSON record reports the median duration,
Lua allocations with GC paused during the measured operation, and a result
checksum. Data generation and warm-up are outside the measurement. Sorting
includes a final order check. Allocation counts are **not** process RSS or
native regex/fzf/worker memory.

The end-to-end benchmark includes scheduled collection, scoring, full stable
sorting, display encoding, pipe writes and the real fzf terminal. It reports
phase timings, time until fzf displays the complete candidate count, timer
responsiveness and Lua heap size. A second record measures live Lua memory
before/after close with full GC, while saved options still reference the engine.
Unlike core measurements, these include
scheduler/IO delays and garbage collection. Run comparisons on the same machine,
Neovim, fzf and fzf-lua versions without concurrent tests or benchmarks.

## Example comparison

Local macOS arm64 / Neovim 0.13-dev measurements, comparing original commit
`2099298` against the optimized implementation in consecutive processes with
identical inputs. Times are medians of three warm iterations; all result
checksums agree. These are examples, not machine-independent latency promises.

| Core operation | Candidates | Before | After |
| --- | ---: | ---: | ---: |
| Fuzzy `flua` | 100,000 | 23.48 ms | 20.58 ms |
| Regex `file.*lua` | 100,000 | 182.07 ms | 63.12 ms |
| Stable sort, ordered | 100,000 | 115.55 ms | 27.18 ms |
| Stable sort, reversed | 100,000 | 121.24 ms | 106.14 ms |
| Stable sort, mixed | 100,000 | 246.73 ms | 165.77 ms |
| Fuzzy `ab`, repeated 2,048-byte prefix | 1,000 | 236.35 ms | 61.31 ms |

For 100,000 items, measured Lua allocations fall from 1,024 KiB to 512 KiB for
mixed/reversed sorting, and to about 0.06 KiB for ordered sorting. Warm regex
matching removes 5,469 KiB of per-candidate Lua allocations (native regex memory
is not included). At 10,000 items, ordinary fuzzy matching is approximately
unchanged (1.74 vs 1.78 ms); the optimizations primarily target redundant work.

A separate 100,000-candidate end-to-end comparison used the same working
directory, Neovim and fzf 0.73.1 executable (bypassing executable-manager shims).
Initial matching fell from 23.83 to 5.89 ms and sorting from 82.64 to 52.76 ms,
but the complete picker remained approximately unchanged at 1.15 seconds.
Rendering, transport and scheduling still dominate total time; kernel speedups
do not imply the same end-to-end speedup.

After a query reload and full GC, live Lua memory before close was 50.8 MiB
before vs 44.6 MiB after optimization. Closing the picker left **100,000 vs zero**
engine-owned candidates; GC-measured Lua memory after close fell from **50.7 to
3.6 MiB** while saved options still held the engine. These are whole-Lua-heap
observations, not candidate-only allocations or total process RSS. In particular,
removing the redundant flat-file reset pass requires avoiding nil writes to
absent `match_topk` fields, which otherwise expand full LuaJIT hash tables on
subsequent queries.

The final 64-test suite passes locally with the pinned fzf-lua on Neovim
0.13-dev, the minimum Neovim 0.11 / fzf 0.59 combination, and the existing local
fzf-lua `main` checkout. This is not a substitute for the Linux/macOS CI matrix.

## Optimization boundaries

- Keep the pinned greedy fuzzy scoring, first-best ties, OR behavior and byte
  positions. Avoid repeated searches; do not replace the scoring algorithm.
- Cache regex compilation and filename-boundary lookup within a matcher, not in
  an unbounded global candidate cache.
- Keep a full stable sort with no top-N truncation. Comparators must define a
  consistent strict weak ordering; ties preserve source enumeration order.
- Keep yielding to Neovim during matching and sorting so input can cancel work.
- Treat collected candidates and retained parents as engine-owned transient
  state. A closed/hidden picker can rescan on resume instead of retaining that
  state through fzf-lua's saved options.

Correctness is checked against the pinned Snacks matcher, including numeric
scores and byte highlights, with additional deterministic randomized cases.
Engine tests cover repeated queries, synthetic parents, main/worker parity,
cancellation and garbage-collectability. Real terminal tests cover hide/resume,
selection, preview and native actions.
