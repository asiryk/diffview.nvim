# TODO

Personal fork of `sindrets/diffview.nvim` (upstream HEAD is 2024-06, unmaintained).
Goal: reduce open / file-switch latency on Neovim 0.12 + macOS.

## Context: where the time actually goes

Measured with a record/replay harness — every git call captured, then replayed
from cache with `uv.spawn` counted to prove zero processes were started.

| scenario | open -> first diff | git spawns |
|---|---|---|
| upstream, `/usr/bin/git` | 289 ms | 15 |
| upstream, brew git | 165 ms | 15 |
| after `02a7f23` | ~100 ms | 10 |
| **git cost forced to zero** | **58 ms** | **0** |

Two conclusions worth keeping in mind before optimizing further:

1. Process startup dominates, not the queries. `git version` — which does no
   work — costs ~6.5 ms (brew) / ~15 ms (`/usr/bin/git`, the xcode-select
   shim). So **spawn count matters more than what each command asks for**.
   Already fixed outside the repo by installing brew git, which precedes
   `/usr/bin` on PATH.
2. There is a hard floor around 58 ms that is pure Neovim: buffer creation,
   `nvim_buf_set_lines`, filetype/treesitter attach (~15 ms), window/option
   churn, and scheduler hops. No amount of git work touches it. Zed's
   "instant" (~16 ms, one frame) is not reachable here.

Remaining prize is therefore roughly 100 ms -> ~60 ms.

## Performance

### 1. Long-lived `git cat-file --batch` for blob reads
Biggest remaining win. Every file opened spawns `git show <rev>:<path>`
(`vcs/adapters/git/init.lua:284`, used via `vcs/adapter.lua:345`).
`cat-file --batch` is built for this: keep one process open, write
`<rev>:<path>` to stdin, read blob contents from stdout. Removes the per-file
spawn entirely, which is most of what is left in the file-switch path.

Needs process lifecycle management (start lazily, tie to adapter lifetime,
restart on death, handle the `<oid> missing` reply). Not a contained patch —
budget a session for it.

### 2. Collapse the status queries
`git status --porcelain=v2 --branch` answers in one invocation several of what
are currently separate calls. Related: `vcs/utils.lua:69` `diff_file_list()`
awaits tracked -> untracked -> staged **sequentially** (`:76`, `:102`, `:120`).
Only tracked-before-untracked is a real dependency; staged is independent and
can run concurrently. Worth ~20-30 ms.

Be careful: the ordering feeds `files:set_working()` / `set_staged()` and a
merge_sort over the combined working list — check that concurrent completion
does not reorder the panel.

## Neovim 0.12 modernization

Done — floor is 0.12 (`bootstrap.lua:27`, `health.lua:27`, README) and no
deprecated API calls remain. For reference, the two non-obvious traps hit
while porting:

- `nvim_buf_add_highlight` clamped out-of-range columns; `nvim_buf_set_extmark`
  *raises* on them. The port needs `strict = false` to keep the old behaviour
  (`renderer.lua:515`).
- The new `vim.validate` signature rejects the old shorthand type names
  (`"n"`, `"s"`, ...) — they have to be spelled out (`"number"`, `"string"`).

## Reproducing the measurements

Harness pattern that worked (headless nvim, one open per process):

- Wrap `vim.uv.spawn` before loading diffview to count *real* process starts —
  do not trust wrapping `Job.start`, which cache-hits can bypass.
- Time from just before `:DiffviewOpen` to the first `User
  DiffviewDiffBufWinEnter` autocmd.
- Write results from **inside** the autocmd to a file. A `vim.wait(ms, pred)`
  in a `-c` chunk gets aborted when diffview's async chain throws, and stderr
  interleaves unreliably.
- `:DiffviewClose` quits headless nvim when the view is the last tab — open a
  spare tab first, or use one process per sample.
- Repeated open/close cycles in one process eventually kill headless nvim
  (the teardown race also patched around in the user's nvim config via
  `Layout:sync_scroll`). One process per sample avoids it.
