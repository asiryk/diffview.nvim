# CLAUDE.md

## What this repo is

A personal fork of `sindrets/diffview.nvim`. Upstream HEAD is from 2024-06 and
is effectively unmaintained.

## Commands

```sh
make test                                   # all specs (plenary busted)
TEST_PATH=lua/diffview/tests/functional make test   # subset
```

Specs only cover `stream` and `pathlib`. **Nothing in the git adapter, the
render path, or the view layer is covered** — changes there need to be
verified by hand (see "Verifying changes").

## Architecture

`plugin/diffview.lua` registers the commands and does nothing else eagerly;
everything past `require("diffview.bootstrap")` is lazily required.

Commands: `DiffviewOpen`, `DiffviewFileHistory`, `DiffviewClose`,
`DiffviewFocusFiles`, `DiffviewToggleFiles`, `DiffviewRefresh`, `DiffviewLog`.

The open path, which is worth knowing in full because most changes touch it:

```
:DiffviewOpen
  -> diffview/init.lua      M.open()
  -> diffview/lib.lua       M.diffview_open()      parse args, pick adapter
  -> vcs/init.lua           get_adapter()          rev-parse toplevel + git-dir
  -> scene/views/diff/diff_view.lua
       DiffView:init()      builds FilePanel + FileDict
       DiffView:open()      creates the tabpage and window layout
       DiffView:post_open() schedules the first update_files()
  -> vcs/utils.lua          diff_file_list()       tracked/untracked/staged
  -> vcs/adapters/git/init.lua
       tracked_files()      diff --name-status + --numstat (parallel MultiJob)
       untracked_files()    ls-files --others
  -> scene/file_entry.lua   FileEntry.with_layout() -> vcs/file.lua File objects
  -> scene/layout.lua       Layout:open_files()    -> Window:load_file()
                                                   -> File:create_buffer()
```

Key modules:

| path | role |
|---|---|
| `vcs/adapter.lua`, `vcs/adapters/{git,hg}/` | VCS abstraction; git adapter is where nearly all the cost lives |
| `scene/view.lua` -> `standard_view.lua` -> `diff_view.lua` / `file_history_view.lua` | view hierarchy |
| `scene/layout.lua` + `scene/layouts/diff_{1,2,3,4}*.lua` | window arrangements (`Diff2Hor` is the common one) |
| `scene/window.lua`, `scene/file_entry.lua`, `vcs/file.lua` | a diff side: window <- entry <- file/buffer |
| `ui/panel.lua`, `renderer.lua` | panel buffers and the component render tree |
| `job.lua`, `multi_job.lua` | libuv process wrappers |
| `async.lua`, `control.lua` | the custom coroutine runtime and its sync primitives |

## Conventions

**Custom OOP** (`oop.lua`). `oop.create_class("Name", Super)`, instances via
`Class({...})` calling `:init()`, `self:super(opt)` for the parent
constructor. Subclassing a lazily-accessed class needs `Super.__get()`.

**Lazy modules** (`lazy.lua`). `lazy.require("mod")` and
`lazy.access("mod", "Export")` return proxies that load on first index. This
is why most files have a block of `local X = lazy.access(...)` at the top
rather than plain `require`. Keep the pattern — eager requires at module scope
create load cycles.

**Custom async** (`async.lua`), not `vim.loop` callbacks and not coroutine
libraries from elsewhere:
- `async.void(fn)` — fire-and-forget task.
- `async.wrap(fn, nparams)` — last parameter is the callback.
- `await(waitable)` — `Job`, `MultiJob` and futures are all `Waitable`.
- `async.scheduler()` — yield until the API is safe (checks `textlock` via
  FFI in `ffi.lua`).

**Errors inside this runtime propagate destructively.** An error thrown in a
`User Diffview*` autocmd callback unwinds the whole coroutine chain and tears
the view down — you get a wall of `async.lua:187` tracebacks whose top frame
is the real cause. When a change produces that, look at the *innermost* frame,
not the diffview ones.

## Performance invariants

The single most important fact about this codebase: **git process startup
dominates, not the queries**. `git version` — which does no work — costs
~6.5 ms with brew git. So the number of spawns matters far more than what any
one command asks for.

Consequences to preserve:

- **Never add a per-file git call.** `is_binary()` used to shell out to
  `git grep` once per side of every file opened; the verdict now comes from
  `--numstat`'s `-\t-` marker (tracked) or a NUL-byte scan of the file
  (untracked). Do not reintroduce that pattern.
- **`VCSAdapter:exec_sync()` blocks the UI thread** (`utils.job` ->
  `Job:sync()` -> `vim.wait`). It is fine during setup, never in a path that
  runs per file or per keystroke.
- Roughly 58 ms of the open is Neovim itself — buffer creation, treesitter
  attach, scheduler hops — and no git-side change reaches it.

## Verifying changes

Given the near-total absence of test coverage, prove behaviour is unchanged by
diffing observable state against the previous commit rather than eyeballing.
Patterns that worked:

- **Entry list**: walk `view.files:iter()` and dump path/status/stats/binary.
- **Render output**: dump panel buffer lines plus every extmark
  (`nvim_buf_get_extmarks` with `details = true`) and compare.
- **Highlights**: compare `nvim_get_hl(0, {})` filtered to `Diffview*`.
  Serialize table values properly — `tostring` prints addresses and produces
  fake diffs.

Headless traps that will waste time otherwise:

- `:DiffviewClose` quits headless Neovim when the view is the last tab. Open a
  spare tab first, or use one process per sample.
- `vim.wait(ms, predicate)` inside a `-c` chunk gets aborted when the async
  chain throws, silently skipping the rest of that chunk. Write results from
  inside an autocmd or a `vim.defer_fn` instead.
- stderr interleaves unreliably under `--headless`; write to a file.
- Wrap `vim.uv.spawn` to count real processes. Wrapping `Job.start` misses
  nothing but also proves nothing if a cache can bypass it.
