# fujutsu.nvim

A small, Fugitive-inspired [Jujutsu](https://jj-vcs.dev/) interface for Neovim.
Currently provides a read-only log view.

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
  a diff collapses it. Expansion choices survive `:J` refreshes in that buffer.
- Stats blocks have graph-preserving blank lines on either side and a total
  header. File rows show an `A`/`M`/`D` status (also `R`/`C` for renames/copies),
  five boxes, right-aligned addition `+` / deletion `-` line counts, then the filename.
  The header shows five boxes and counts for the whole change. Boxes show the
  proportion of added and removed lines, with unused boxes gray for small diffs.
  Zero counts are omitted; binary and empty-file changes remain visible.
- Close a log with `:q`. It is a disposable, read-only scratch buffer.

The repository is resolved from the current file's directory, or the current
working directory for unnamed/special buffers. From a log buffer, its repository
is reused. Logs in other tabs are never focused automatically.

The view uses your configured `jj log` defaults, preserving ANSI colors and styles
as Neovim highlights, with paging and log word wrapping disabled. The first 16 colors use
`g:terminal_color_0` through `g:terminal_color_15` when set.
Commands run synchronously; large repositories may briefly block the editor.

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

## Tests

With Neovim and jj installed, run from the checkout:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Tests create and remove temporary jj repositories; no plugin test dependencies
are needed.

## License

[Apache License 2.0](LICENSE).
