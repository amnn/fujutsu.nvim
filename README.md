# fujutsu.nvim

A small, Fugitive-inspired [Jujutsu](https://jj-vcs.dev/) interface for Neovim.
Browse the log, navigate revision files, and edit historical contents and descriptions.

## Requirements

- Neovim 0.10 or newer
- `jj` 0.44 or newer on your `PATH`

## Installation

Add this repository with your preferred Neovim plugin manager. No setup call is
needed. For local development, add the checkout to your runtime path in `init.lua`:

```lua
vim.opt.runtimepath:prepend('/path/to/fujutsu.nvim')
```

## Usage

- `:J` opens `jj log` in a split and focuses it.
- If the current tab already shows a log for the same repository, `:J` refreshes
  and focuses that window instead. Logs for other repositories remain open.
- `:tab J` opens the log in a new tab, even if the current tab already shows it.
- `:e` (or `:e!`) refreshes the current log buffer in place.
- Saving a file in Neovim marks logs for that workspace stale. Each refreshes
  when you enter it, preserving expansion choices; a visible log split does not
  refresh immediately on save. Changes outside Neovim still require `:e` or `:J`.
- Press `=` on a revision's header, description, or total to toggle its file
  stats. Only the working-copy revision (`@`) is expanded initially.
- Press `=` on a file row to toggle its inline diff underneath it. Diffs start
  at the hunk header, without extra indentation or Git's file headers, and use
  your theme's `DiffAdd`/`DiffDelete` backgrounds, dimming unchanged words within
  replacement blocks so changed words stand out at normal brightness.
  Hunk headers include preceding section context when available. A blank-line
  margin follows each diff, shared with the status margin for the last file.
  Binary, rename, and mode-change metadata remain visible.
  Each file expands independently; pressing `=` inside
  a diff collapses it. Expansion choices survive `:J` and `:e` refreshes in that buffer.
- Stats blocks have graph-preserving blank lines on either side and a total
  header. File rows show an `A`/`M`/`D` status (also `R`/`C` for renames/copies),
  five boxes, right-aligned addition `+` / deletion `-` line counts, then the filename.
  The header shows five boxes and counts for the whole change. Boxes show the
  proportion of added and removed lines, with unused boxes gray for small diffs.
  Zero counts are omitted; binary and empty-file changes remain visible.
- Close a log window with `:q`. The read-only log stays hidden so jump-list
  navigation can return to it; use `:bwipeout` to discard it explicitly.

The repository is resolved from the current file's directory, or the current
working directory for unnamed/special buffers. From a log buffer, its repository
is reused. Logs in other tabs are never focused automatically.

The view uses your configured `jj log` defaults, preserving ANSI colors and styles
as Neovim highlights, with paging and log word wrapping disabled. The first 16 colors use
`g:terminal_color_0` through `g:terminal_color_15` when set.
Log rendering and validation run synchronously; large repositories may briefly
block the editor. Repository actions run asynchronously, with a per-repository
lock while jj or its internal description editor is active.

## Marks and log queries

`m` replaces the unnamed revision mark, `M` adds to it, and `d` removes
contextual commits. These also accept Visual selections and register prefixes:
`"am`, `"aM` (or `"Am`), and `"ad`. Marks contain commit sets, not partial
patches, and are stored as ordinary `change_id(...) | change_id(...)` text.
Normal yanks are unchanged and can replace the unnamed mark.

The Marks section lists valid non-empty marks. On a mark row, `d` clears it
and Space pins/unpins its gutter. Hover previews that mark; modifications
briefly preview the affected mark. Otherwise the pinned or unnamed mark is
shown. Pinning never changes which register a command modifies.

Every log shows its effective Query. Enter on that row opens an editor;
Enter applies it, normal-mode Escape cancels. Invalid queries remain editable.
`:J log -r 'REVSET' [-n LIMIT]` opens a separate query-specific log.

`:J COMMAND ...` executes jj asynchronously without a shell. Single/double
quotes group arguments; use native command-line `<C-r>a` to insert a mark,
for example `:J rebase -r '<C-r>a' -o main`. Commands that request a text
editor open one inside Neovim: `:write` accepts, normal-mode Escape cancels.
Save modified workspace buffers before repository commands. Avoid simultaneous
external jj mutations while an operation is running.

## Squash and extraction

`s` squashes contextual changes into their parent. `S` squashes the unnamed
mark into the contextual commit (`"aS` uses mark `a`). `x` extracts contextual
changes into a new commit inserted immediately before their source. `X` is
unassigned. Parent ambiguity and invalid multi-source combinations follow jj's
errors, not a plugin-selected first parent.

For lowercase actions, a file row selects the entire file; a hunk header or
diff line selects its hunk. Visual selection within one diff selects changed
lines (whole lines, even in characterwise Visual mode). Added and removed lines
can be selected independently. Context lines do not move. Mixed scopes,
blockwise selections, and partial selections spanning files/commits are
rejected. Visual selections of file rows within one commit are supported.
Binary/rename/symlink changes require whole-file selection; conflicted revisions
must be resolved before selecting partial lines. Final-newline changes that
cannot be represented independently require selecting the paired change too.

Emptied sources are abandoned, including whole-commit extraction. jj creates a
fresh empty working-copy commit when `@` is abandoned. Combined descriptions
are edited inside Neovim with `:write` to accept and Escape to cancel the
operation. Extraction preserves descriptions when abandoning their sources.

## Repository undo and redo

In a log, `u` runs `jj undo` and `<C-r>` runs `jj redo`. Native jj operation
history includes external commands; marks, expansion and navigation do not
create undo steps. jj reports the operation restored. These bindings do not
change native text undo/redo in file or description buffers.

## Creating and checking out commits

`gn` inserts an empty commit after context (child side) and edits it as `@`.
Existing children are rebased onto it. `gN` inserts before context (parent
side) without moving `@`. Both open the new description for editing.
`ge` runs `jj edit` on the owning revision without creating a commit.
These operations protect unsaved workspace buffers and respect jj immutability.
They do not implicitly move bookmarks.

## Rebasing from the log

Use `[rR][sbr][oAB]`: lowercase `r` takes its source from context and its
other operand from a register; uppercase `R` takes registered sources and the
contextual destination. The unnamed register is the default; `"aRro` uses `a`.
Source modes are jj's source-and-descendants (`s`), branch (`b`), and explicit
revisions (`r`). Placement is onto (`o`), insert-after (`A`), or insert-before
(`B`). Multiple registered destinations are supported. Revision sets retain
native jj topology; selection order does not create a stack.

`r<Enter>` and `R<Enter>` complete with `bo`; `rs<Enter>` completes with `so`.
Escape cancels the pending specification. Lowercase prompts for a destination
only when the unnamed register is not a valid mark; its suggested base is
`main`, configurable with `jj config set --repo fujutsu.rebase-base NAME`.
Explicit invalid registers fail rather than falling back or using a subset.

## Colors

Plugin-owned stats use theme highlights rather than the terminal ANSI palette:

| Highlight | Color source | Used for |
| --- | --- | --- |
| `FujutsuStatAdd` | `Added` | Added boxes, `+` counts, `A` status |
| `FujutsuStatDelete` | `Removed` | Removed boxes, `-` counts, `D` status |
| `FujutsuStatChange` | `Changed` | Other status letters |
| `FujutsuStatNeutral` | `Comment` | Unused boxes |
| `FujutsuDiffAdd` | `DiffAdd` | Added diff lines |
| `FujutsuDiffDelete` | `DiffDelete` | Removed diff lines |

Addition/deletion colors are usually green/red, but follow your theme. Stats copy
only the source group's GUI and terminal foregrounds, never its background or
reverse-video styling. These foreground-only defaults are regenerated on
`ColorScheme` and `:J` refresh. Inline diff groups link to their sources and retain
the theme's diff backgrounds.
The log and graph separately preserve `jj`'s configured ANSI colors.

Override any group with `vim.api.nvim_set_hl`, for example:

```lua
vim.api.nvim_set_hl(0, 'FujutsuStatAdd', { fg = '#80c080' })
vim.api.nvim_set_hl(0, 'FujutsuStatDelete', { fg = '#e08080' })
```

`FujutsuDiffAddUnchanged` and `FujutsuDiffDeleteUnchanged` default to a foreground
halfway between the effective corresponding `FujutsuDiff*` foreground and
background, falling back to `Normal`. They keep the diff background intact.
Without true color, both use terminal color 8. These groups can also be overridden.

Derived colors update on `:J` refresh and `ColorScheme`; existing log ANSI
highlights also update on `ColorScheme`. Explicit plugin-group overrides are
preserved unless the colorscheme clears them. To keep overrides across theme
changes, reapply them in your own `ColorScheme` autocmd.

## File navigation

Enter on a log file, hunk, or diff line visits it in an editing window, keeping
the log open. In the current tab, prefer a suitable window already displaying the
destination, then the previous editing window, then another editing window. Only
create a split if none is available. Repeated visits reuse buffers and windows;
an already displayed destination is not reloaded, so its unsaved edits survive.
Preview, fixed-width/fixed-buffer, diff, and special-purpose windows are not
replaced. Normal modified-buffer safeguards apply; no bang is implied.

| Log mapping | Placement |
| --- | --- |
| Enter | Reuse an editing window |
| `o` | New horizontal split |
| `gO` | New vertical split |
| `O` | New tab |
| `p` | Reusable preview window; keep focus in the log |

This follows Fugitive's distinction between visiting and explicitly splitting.
`Jedit`/`Jview` from a log use the same editor selection; elsewhere they edit the
current window. Only `Jdrop` searches other tabs for existing windows. Different
commits still have separate buffers, even when their file contents match.

Added/context lines use new-side coordinates; removed lines and deleted files use
the old path and parent-side coordinates. Merge old sides use jj's merged-parent tree, not its
first parent, and have no writable revision target. Navigation refreshes the log
first; if the selected row changed, select it again rather than trusting stale
coordinates.

Current-workspace destinations reuse normal file buffers. Historical files have
commit-qualified `fujutsu://` names and syntax highlighting, and remain pinned.
They are `readonly` but `modifiable` (unlike the log). Use normal `:setlocal
noreadonly` to permit writes; there is no custom toggle mapping.

### Revision-aware statusline context

| File version | VC segment |
| --- | --- |
| Working-copy file in a jj workspace | `@ qvkwzrsntplm` |
| Historical file | `○ qvkwzrsntplm` |
| Synthetic merged parents | `⋎ qvkwzrsntplm` |
| Non-jj file | Existing Git branch (lualine) / no additional label (native) |

IDs are the first 12 characters of the jj **change ID**, stable across rewrites;
the historical buffer's URI still identifies its exact pinned commit. A pinned
buffer remains historical even if its commit becomes `@`. Descriptions and
historical directories show the same context. There are no extra readonly or
modified indicators: your existing statusline owns those.

Working-copy IDs are cached per workspace, read asynchronously on navigation,
saves, and focus changes without snapshotting the repository. Until the first
lookup finishes, the working-copy segment shows just `@`. Redrawing the
statusline never runs repository commands.

Fujutsu detects the active statusline automatically, including late-loaded setups:

- **lualine:** replaces configured `branch` components with `fujutsu_branch`
  in-place, including configured inactive sections and inline extensions. It
  preserves component placement, icons, formatting, colors, conditions, and
  padding, and delegates to the original Git branch component outside jj.
  The jj markers replace the default Git branch icon; Git fallback keeps ``.
  An explicitly configured `icon` is still respected, in addition to the marker.
  The markers are ordinary Unicode and do not require a Nerd Font.
  Nothing is added to the filename section. If a layout has no branch component,
  add `'fujutsu_branch'` wherever you want its VC segment.
- **Native or other/custom statuslines:** retains the existing format or `%!`
  expression and appends the context to its result for jj working-copy and
  historical buffers. This also supports expression-based providers such as mini.statusline,
  heirline, lightline, feline, and airline without force-loading them. Their
  configuration tables are not changed.

For custom statusline layouts, `require('fujutsu.status').label()` returns the
plain label (or an empty string). A native statusline expression using this
function is detected and not automatically decorated a second time:

```lua
vim.opt.statusline:append(" %{v:lua.require('fujutsu.status').label()}")
```

With a global statusline, only the active window's context is shown. Fujutsu does
not create or modify winbars.

## Writing historical files

`:write` and `:Jwrite[!] [--restore-descendants] [--ignore-immutable]` save only
this file through `jj diffedit`, without checking out the target revision.
Ordinary writes rebase descendant patches; `--restore-descendants` instead
preserves their trees, including working-copy contents. Both full-length flags
can be combined. Bang bypasses readonly and stale-file checks, **not** jj's
immutability protection.

Saves find the latest unique visible version of the same change. Description-only
and unrelated-file rewrites are safe; a changed file requires bang, which replaces
the latest file rather than resurrecting the opened commit. Abandoned/divergent
changes require reopening an explicitly selected commit (`Jedit -r <commit-id>`),
even with bang. This records the selected branch and rechecks the visible versions
before saving; a further external rewrite requires explicit reselection. Merge
base views cannot be saved. Any unsaved real-file buffer in the repository blocks
rewrites (a deliberately conservative safeguard), including bang writes. The diff
editor rechecks revision identity before and after copying; concurrent jj
operations can still produce jj operation divergence and should not be run during
saves. Symlink and binary writes are unsupported.

Successful saves advance only the writing buffer, clear its modified flag, and
invalidate logs; failures retain edits. Other historical buffers remain pinned.
Three-way stale-buffer reconciliation is deferred.

## Selecting files

`:Jedit [-r R] [file]` opens writable files; `:Jview [-r R] [file]` opens them
readonly. Both leave `modifiable` enabled. Revision defaults to `@`, even from a
historical buffer: bare `Jedit` returns to its workspace counterpart. Explicit
non-`@` selections remain historical snapshots. Omitted filenames use the current
file's identity; in logs only file rows and their diffs infer filenames.

Explicit paths are relative to Neovim's current directory, like `:edit`, and must
be inside the current repository. Escape spaces with backslashes; use `--` before
filenames starting with `-`. File and revision argument completion is available.
Normal modified/hidden-buffer safeguards apply. Readonly is buffer-local, so
changing it affects every window showing that buffer. Opening does not rewrite
history and never needs an immutability override. Use Vim's unambiguous command
prefixes (`:Je`, `:Jw`); no extra aliases are installed.

### Other opening commands

`Jsplit`, `Jvsplit`, `Jtabedit`, `Jpedit`, and `Jdrop` take the same
`[-r R] [file]` arguments and completion as `Jedit`. They use Vim's split,
vertical split, new tab, preview window, and existing-window reuse operations,
respectively, including command modifiers and modified-buffer safeguards.
`Jpedit` leaves focus in the original window and reuses its preview window.
These commands select writable buffers, including when reusing a readonly
buffer; that option change is shared by all its windows.

### Restoring buffer contents

`:Jread [-r R] [file]` replaces the entire current buffer with the selected
version (revision defaults to `@`; filename defaults match `Jedit`). Unlike
plain Vim `:read`, this no-range form is restorative. `:NJread` inserts after
line N (`:0Jread` prepends); `:N,MJread` replaces those inclusive lines, and
`:%Jread` replaces the whole buffer. Insertions/ranged replacements retain the
destination's final-newline setting; whole-buffer restoration adopts the source's.

Reading never rewrites history, clears readonly, or changes file identity. It is
undoable and marks the destination modified; readonly buffers may still be
edited, while nomodifiable buffers reject reads. Save using the destination's
normal write command and safeguards. `@` reads the snapshotted on-disk version,
not unsaved contents in another buffer.

## Commit descriptions

Enter on a commit row visits its description in a writable, `gitcommit`-highlighted
editing window. `:write` / `:Jwrite` call `jj describe` for the latest unique visible
version of that change. Concurrent file-only rewrites are allowed; changed
descriptions require bang. Readonly, abandoned/divergent changes, immutable
revisions, and unsaved workspace buffers follow historical-write safeguards.
Use `Jwrite! --ignore-immutable` only when explicitly intending both overrides.
`--restore-descendants` is rejected for descriptions (trees do not change).
Successful writes adopt jj's normalized description and new revision identity,
clear modified, and invalidate logs; failures keep your edits.

## Log boundary mappings

Normal-mode mappings accept counts, move strictly forward/backward, and stop at
the last available boundary without wrapping. Only visible boundaries count:
collapsed files/hunks are not expanded, and graph-only/margin rows are skipped.

| Previous / next | Destination |
| --- | --- |
| `[[` / `]]` | Revision starts |
| `{{` / `}}`, `[m` / `]m`, `[/` / `]/` | File rows |
| `[c` / `]c` | Expanded hunk headers |
| `(` / `)` | File rows and expanded hunk headers |

Audited against Fugitive's `NextSection`, `NextFile`, `NextHunk`, `NextItem`, and
mapping definitions in [autoload/fugitive.vim](https://github.com/tpope/vim-fugitive/blob/master/autoload/fugitive.vim).
Fugitive's summary has staged/unstaged sections; this log has revisions instead.
`{{`/`}}` are our explicit file-boundary aliases, not Fugitive mappings. Unlike
Fugitive, movement never reveals or hides diffs. Section-end mappings and `J`/`K`
hunk aliases are not ported; their normal Vim behavior is retained.

## Parent directory

Press `-` in a log to edit that repository's `.jj` directory in the current
window. Real directory browsing is delegated to your configured handler (such as
Oil or netrw), without changing Neovim's current directory.

In historical files, `-` opens a read-only directory listing **in the same pinned
revision**, not the working-copy directory and not a filesystem interpretation of
the virtual URI. Enter opens the selected file or subdirectory; `-` ascends again.
Counts ascend multiple directory levels, stopping at the revision's root. From
that root listing, `-` returns to the repository log in the current window,
reusing an existing log buffer and focusing the owning revision when it is in
the configured log view. It does not switch revisions or silently choose a
merge's first parent; `Ctrl-O` can return to the directory listing.
Synthetic merged-parent listings contain only the diff's old-side changed paths;
they remain non-writable and never substitute a single parent revision.

`Ctrl-O` goes back and `Ctrl-I` goes forward. Hidden logs retain expansion state;
URI-wide readers can reconstruct logs, files, descriptions, and trees after their
buffers are unloaded or deleted. Normal modified/hidden-buffer safeguards still
apply. Explicit `:bwipeout` can remove Vim jump-list entries; directory browsers
also control the lifetime of their own buffers. No plugin-specific back/forward
mappings are needed.

## Tests

With Neovim and jj installed, run from the checkout:

```sh
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/edit.lua
nvim --headless -u NONE -l tests/safety.lua
nvim --headless -u NONE -l tests/parents.lua
nvim --headless -u NONE -l tests/windows.lua
nvim --headless -u NONE -l tests/status.lua
nvim --headless -u NONE -l tests/marks.lua
nvim --headless -u NONE -l tests/log_actions.lua
nvim --headless -u NONE -l tests/rebase.lua
nvim --headless -u NONE -l tests/squash.lua
nvim --headless -u NONE -l tests/patch.lua
nvim --headless -u NONE -l tests/create.lua
```

Tests create and remove temporary jj repositories; no plugin test dependencies
are needed. To exercise parent navigation with Oil's actual directory handler,
run `tests/parents.lua` with `FUJUTSU_TEST_OIL=/path/to/oil.nvim`.
For real lualine integration, run `tests/status.lua` with
`FUJUTSU_TEST_LUALINE=/path/to/lualine.nvim`.

## License

[Apache License 2.0](LICENSE).
