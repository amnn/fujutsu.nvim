# TODO

- [x] `:e` should refresh the buffer.
- [x] Refresh stale logs on entry after workspace files are saved, similar to Fugitive.

## File navigation and revision editing

Implement in the following commit-sized stages. Command names describe editor
operations, even when the underlying jj operation is `diffedit`.

### 1. Visit files from the log

- [x] Enter opens the corresponding file in a split: added/context lines use the
  revision's new-side line number; removed lines use the diff base's old-side
  line number. File rows and hunk headers open the corresponding file/hunk.
- [x] Open current-workspace `@` destinations as normal files, reusing existing
  buffers. Open historical destinations as commit-pinned, readonly revision
  buffers, with normal syntax highlighting and clearly revision-qualified names.
- [x] Keep historical file buffers `modifiable`; Vim's `readonly` protects writes,
  not edits. The log itself remains `nomodifiable`. Do not add a custom mapping
  for `:setlocal noreadonly` (`:setl noro`).
- [x] Track old/new line coordinates and paths, including renames and deletions.
  For merges, use the merged-parent diff base, not an arbitrary first parent.
  Synthetic merged-parent views have no single writable revision target.
- [x] Refresh/revalidate stale log navigation before treating line numbers as
  exact. Historical buffers stay pinned even if their revision later becomes `@`.

### 2. Write historical files

- [x] Support `:write` and `:Jwrite` on revision buffers through `jj diffedit`,
  saving only the current file and preserving other files in the target revision.
  Ordinary writes rewrite the revision and rebase descendants normally, without
  switching the working copy to the edited revision.
- [x] Support `:Jwrite --restore-descendants` to preserve descendant contents
  rather than their patches: the analogue of editing staged contents while
  leaving the working-directory tree unchanged.
- [x] Support `:Jwrite --ignore-immutable` as explicit permission to bypass jj's
  immutability protection. Keep both flags unabbreviated and allow combining them.
- [x] Respect `readonly` for both write commands. Users can enable ordinary writes
  with `:setlocal noreadonly`; `:write!` / `:Jwrite!` bypass readonly and stale-file
  protection, but never implicitly bypass immutability.
- [x] Detect stale files against the latest unambiguous version of the same
  change. If only the description or other files changed, permit an ordinary
  save against the latest revision. Otherwise refuse ordinary saves and preserve
  buffer edits. Bang replaces this entire file in the latest revision with the
  buffer contents, preserving other files; it does not resurrect the old commit.
- [x] Require explicit target selection for abandoned or divergent changes, even
  with bang. Synthetic merged-parent views remain non-writable.
- [x] Protect unsaved working-copy buffers that a rewrite could affect, even with
  bang. Check freshness again as part of saving to avoid concurrent overwrites.
- [x] After successful saves, advance the writing buffer to the new commit, clear
  its modified flag, and invalidate affected logs. Other historical buffers stay
  pinned to their original snapshots. Failed writes retain edits.
- [x] Consider three-way stale-buffer reconciliation later (opened/saved base,
  buffer contents, latest revision); initial stale-write refusal is sufficient.

### 3. Add `Jedit` and `Jview`

- [x] Support `:Jedit [-r R] [file]` and `:Jview [-r R] [file]`. Revision defaults
  to `@`; omitted files use the current buffer's file identity, including historical
  buffers. In logs, infer a file only from a file row or diff under the cursor.
- [x] Resolve explicit paths relative to Neovim's current directory, like `:edit`.
  Support `--` for filenames beginning with `-`.
- [x] `Jedit` opens writable buffers; `Jview` opens readonly buffers. Both leave
  `modifiable` enabled. `@` uses real file buffers; other revisions use revision
  buffers. Opening never mutates the repository or requires immutability bypass.
- [x] Preserve normal Vim modified-buffer/hidden-buffer safeguards. Remember that
  readonly is buffer-local and affects all windows displaying that buffer.
- [x] Bare `:Jedit` from a historical buffer opens its working-copy counterpart;
  `:Jedit -r R` selects a historical revision explicitly.
- [x] Provide argument completion. Rely on Vim's unambiguous user-command prefixes
  (`:Je`, `:Jw`, etc.) rather than promising aliases that could become ambiguous.

### 4. Add ancillary edit commands

- [ ] Add `:Jsplit`, `:Jvsplit`, `:Jtabedit`, `:Jpedit`, and `:Jdrop`, following
  their Vim/Fugitive counterparts for split, vertical split, tab, preview-window,
  and existing-window reuse behavior.
- [ ] Share revision/file selection (`[-r R] [file]`), path handling, completion,
  revision-buffer identity, and editing safeguards with `Jedit`/`Jview`.
- [ ] Test window/tab placement, preview reuse, existing-buffer/window reuse,
  modified buffers, and readonly interactions.

### 5. Add restorative `Jread`

- [ ] Add `:Jread` to read a selected file version into the current buffer as a
  restorative operation, following Vim/Fugitive read conventions.
- [ ] Define and document its precise range/insertion/replacement behavior and
  revision/file defaults before implementation; share revision/path resolution
  where appropriate.
- [ ] Reading changes buffer contents, not repository history; persist through
  the destination buffer's normal write path. Preserve undo and modified-buffer
  semantics, and test restoration from historical versions.

## Commit description editing

- [ ] Enter on a commit itself opens its description in an editable buffer.
- [ ] Writing the description buffer calls `jj describe` for the corresponding
  change. Preserve edits on failure, update the buffer's revision identity after
  success, and invalidate affected logs.
- [ ] Define stale-description and immutable-revision safeguards consistently
  with historical file writes; test navigation, saving, and failure handling.

## Summary/log navigation keybindings

- [ ] Audit Fugitive's summary-page navigation mappings and port the applicable
  conventions to the log view, including `[[`, `]]`, `{{`, and `}}`.
- [ ] Define their equivalents for revision, file, and hunk boundaries; document
  any deliberate differences from Fugitive rather than assuming identical page
  structure.
- [ ] Test counts, forward/backward movement, collapsed sections, graph-only
  rows, and beginning/end-of-buffer behavior. Document the supported mappings.

## Summary parent directory handling

- [ ] Handle parent-directory navigation from the summary/log buffer: open the
  repository's `.jj` directory, analogous to Fugitive opening `.git`.

For each stage, add focused tests and update README.md with the implemented
commands, navigation semantics, and safeguards.
