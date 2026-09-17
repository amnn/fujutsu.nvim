# fujutsu.nvim

A small, Fugitive-inspired [Jujutsu](https://jj-vcs.dev/) interface for Neovim.
Currently provides a read-only log view.

## Requirements

- Neovim 0.10 or newer
- `jj` on your `PATH`

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
- Close a log with `:q`. It is a disposable, read-only scratch buffer.

The repository is resolved from the current file's directory, or the current
working directory for unnamed/special buffers. From a log buffer, its repository
is reused. Logs in other tabs are never focused automatically.

The view uses your configured `jj log` defaults, preserving ANSI colors and styles
as Neovim highlights, with paging disabled. The first 16 colors use
`g:terminal_color_0` through `g:terminal_color_15` when set.
Commands run synchronously; large repositories may briefly block the editor.

## Tests

With Neovim and jj installed, run from the checkout:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Tests create and remove temporary jj repositories; no plugin test dependencies
are needed.

## License

[Apache License 2.0](LICENSE).
