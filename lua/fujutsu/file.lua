local M = {}

function M.jj(root, args)
  local command = { 'jj', '--no-pager', '--color=never' }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root, text = false }):wait()
  if result.code ~= 0 then error(vim.trim(result.stderr), 0) end
  return result.stdout
end

function M.resolve(root, revision)
  local text = M.jj(root, { 'log', '--no-graph', '-r', revision, '-T',
    'commit_id ++ "\\t" ++ change_id ++ "\\n"' })
  local lines = vim.split(vim.trim(text), '\n', { plain = true })
  if #lines ~= 1 or lines[1] == '' then error('Select one unambiguous revision explicitly', 0) end
  local id, change = lines[1]:match('^(%x+)\t(%a+)$')
  assert(id, 'Invalid revision identity')
  return id, change
end

function M.visible(root, change)
  return M.jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r',
    'change_id(' .. change .. ') & all()', '-T', 'commit_id' })
end

function M.target(root, meta)
  local visible = M.visible(root, meta.change)
  if meta.target_fingerprint then
    if visible ~= meta.target_fingerprint then error('Selected target changed; select it explicitly again', 0) end
    return meta.id, visible
  end
  if #visible ~= #meta.id then error('Abandoned or divergent change; select a commit explicitly with Jedit -r', 0) end
  return visible, visible
end

function M.new_id(root, meta)
  local visible = M.visible(root, meta.change)
  if #visible == #meta.id then return visible end
  if meta.target_fingerprint then
    local candidates = {}
    for offset = 1, #visible, #meta.id do
      local id = visible:sub(offset, offset + #meta.id - 1)
      if not meta.target_fingerprint:find(id, 1, true) then candidates[#candidates + 1] = id end
    end
    if #candidates == 1 then return candidates[1] end
    if #candidates == 0 and visible:find(meta.id, 1, true) then return meta.id end
  end
  error('Save completed but target became ambiguous; inspect jj history before retrying', 0)
end

function M.content(root, id, path)
  return M.jj(root, { '--ignore-working-copy', 'file', 'show', '-r', id, '--', 'root-file:' .. vim.json.encode(path) })
end

-- Let jj materialize its actual merged-parent tree, including conflict markers.
function M.base(root, id, path)
  local output = vim.fn.tempname()
  local tool = { '-c', 'cat -- "$1/$3" > "$2"', 'fujutsu', '$left', output, path }
  local ok, err = pcall(M.jj, root, { '--ignore-working-copy', '--config',
    'merge-tools.fujutsu-read.diff-args=' .. vim.json.encode(tool),
    '--config', 'merge-tools.fujutsu-read.program="/bin/sh"',
    'diff', '-r', id, '--tool', 'fujutsu-read' })
  -- program is separate from arguments.
  local data
  if ok then
    local fd = assert(io.open(output, 'rb')); data = fd:read('*a'); fd:close()
  end
  vim.fn.delete(output)
  if not ok then error(err, 0) end
  return data
end

function M.set_content(buf, content)
  local eol = content:sub(-1) == '\n'
  local lines = vim.split(eol and content:sub(1, -2) or content, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = eol
  vim.bo[buf].fixendofline = false
end

function M.read(buf, location)
  local root, id, path = location.root, location.id, location.path
  local description = location.kind == 'description'
  local content = description and M.jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r', id, '-T', 'description' })
    or (location.base and M.base(root, id, path) or M.content(root, id, path))
  local _, change = M.resolve(root, id)
  local previous = vim.b[buf].fujutsu_file
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  M.set_content(buf, content)
  vim.b[buf].fujutsu_repo = root
  vim.b[buf].fujutsu_file = { id = id, change = change, path = path, base = location.base,
    description = description, content = content,
    target_fingerprint = previous and previous.target_fingerprint }
  vim.bo[buf].filetype = description and 'gitcommit' or (vim.filetype.match({ filename = path, buf = buf }) or '')
  vim.bo[buf].modified = false
  if not previous then vim.bo[buf].readonly = true end
  vim.keymap.set('n', '-', function()
    require('fujutsu.tree').parent(vim.v.count1)
  end, { buffer = buf, silent = true, desc = 'Open parent in this revision' })
end

function M.open(root, id, path, opts)
  opts = opts or {}
  local name = opts.workspace and (root .. '/' .. path)
    or require('fujutsu.uri').name(root, opts.description and 'description' or 'file', id, path, opts.base)
  local command = opts.command or 'split'
  require('fujutsu.window').open(command, name, opts.mods)
  local win = vim.api.nvim_get_current_win()
  if command == 'pedit' then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[candidate].previewwindow then win = candidate; break end
    end
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if opts.explicit and not opts.workspace then
    local meta = vim.b[buf].fujutsu_file
    local visible = M.visible(root, meta.change)
    meta.target_fingerprint = #visible ~= #meta.id and visible or nil
    vim.b[buf].fujutsu_file = meta
  end
  if opts.readonly ~= nil then vim.bo[buf].readonly = opts.readonly end
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(opts.line or 1, vim.api.nvim_buf_line_count(buf))), 0 })
  return buf
end

function M.check_write(buf, opts)
  if vim.bo[buf].readonly and not opts.bang then error('Buffer is readonly; use :setlocal noreadonly or bang', 0) end
  local meta = vim.b[buf].fujutsu_file
  assert(meta, 'Not a revision buffer')
  if meta.base then error('Merged-parent views have no writable revision target', 0) end
  local root = vim.b[buf].fujutsu_repo
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(other) and vim.bo[other].buftype == '' and vim.bo[other].modified then
      local name = vim.api.nvim_buf_get_name(other)
      local real = vim.uv.fs_realpath(name) or name
      if real:sub(1, #root + 1) == root .. '/' then
        error('Save or discard unsaved workspace buffer first: ' .. name, 0)
      end
    end
  end
  -- Snapshot on-disk workspace changes before checking the target.
  M.resolve(root, '@')
  local id, fingerprint = M.target(root, meta)
  local latest = meta.description and M.jj(root, { 'log', '--no-graph', '-r', id, '-T', 'description' })
    or M.content(root, id, meta.path)
  if latest ~= meta.content and not opts.bang then error('Stale revision contents; use bang to replace the latest file', 0) end
  return root, meta, id, fingerprint
end

function M.buffer_content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

function M.advance(buf, root, meta, content)
  meta.id = M.new_id(root, meta)
  if meta.target_fingerprint then meta.target_fingerprint = M.visible(root, meta.change) end
  meta.content = content
  vim.b[buf].fujutsu_file = meta
  local name = require('fujutsu.uri').name(root, meta.description and 'description' or 'file', meta.id, meta.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= buf then name = name .. '?buffer=' .. buf end
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].modified = false
  require('fujutsu').invalidate(root)
  vim.cmd('checktime')
end

function M.write(buf, opts)
  opts = opts or {}
  local root, meta, id, fingerprint = M.check_write(buf, opts)
  local content = M.buffer_content(buf)
  if content:find('\0', 1, true) then error('Binary revision writes are not supported', 0) end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local payload = assert(io.open(dir .. '/content', 'wb')); payload:write(content); payload:close()
  if meta.description then
    if opts.restore_descendants then
      vim.fn.delete(dir, 'rf')
      error('--restore-descendants applies only to file writes', 0)
    end
    local editor = [[set -eu
set -- "$1" "change_id($2)" "$3" "$4" "$5"
latest=$(jj --no-pager --color=never --ignore-working-copy -R "$1" log --no-graph -r "$2 & all()" -T commit_id)
[ "$latest" = "$3" ] || { echo 'Revision changed during save' >&2; exit 1; }
cp -- "$4" "$5"
latest=$(jj --no-pager --color=never --ignore-working-copy -R "$1" log --no-graph -r "$2 & all()" -T commit_id)
[ "$latest" = "$3" ] || { echo 'Revision changed during save' >&2; exit 1; }
]]
    local args = { '--config', 'ui.editor=' .. vim.json.encode({ '/bin/sh', '-c', editor,
      'fujutsu', root, meta.change, fingerprint, dir .. '/content' }), 'describe', '-r', id }
    if opts.ignore_immutable then table.insert(args, '--ignore-immutable') end
    local ok, err = pcall(M.jj, root, args)
    vim.fn.delete(dir, 'rf')
    if not ok then error(err, 0) end
    local latest = M.new_id(root, meta)
    content = M.jj(root, { 'log', '--no-graph', '-r', latest, '-T', 'description' })
    M.set_content(buf, content) -- jj normalizes description whitespace.
    M.advance(buf, root, meta, content)
    return
  end
  local script = [[#!/bin/sh
set -eu
right=$1
root=$2
change="change_id($3)"
expected=$4
path=$5
payload=$6
latest=$(jj --no-pager --color=never --ignore-working-copy -R "$root" log --no-graph -r "$change & all()" -T commit_id)
[ "$latest" = "$expected" ] || { echo 'Revision changed during save' >&2; exit 1; }
[ ! -L "$right/$path" ] || { echo 'Symlink writes are not supported' >&2; exit 1; }
mkdir -p -- "$(dirname -- "$right/$path")"
cp -- "$payload" "$right/$path"
latest=$(jj --no-pager --color=never --ignore-working-copy -R "$root" log --no-graph -r "$change & all()" -T commit_id)
[ "$latest" = "$expected" ] || { echo 'Revision changed during save' >&2; exit 1; }
]]
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), dir .. '/write.sh')
  local args = { '--config', 'merge-tools.fujutsu-write.program="/bin/sh"', '--config',
    'merge-tools.fujutsu-write.edit-args=' .. vim.json.encode({ dir .. '/write.sh', '$right', root,
      meta.change, fingerprint, meta.path, dir .. '/content' }),
    'diffedit', '-r', id, '--tool', 'fujutsu-write' }
  if opts.restore_descendants then table.insert(args, '--restore-descendants') end
  if opts.ignore_immutable then table.insert(args, '--ignore-immutable') end
  vim.list_extend(args, { '--', 'root-file:' .. vim.json.encode(meta.path) })
  local ok, err = pcall(M.jj, root, args)
  vim.fn.delete(dir, 'rf')
  if not ok then error(err, 0) end
  M.advance(buf, root, meta, content)
end

return M
