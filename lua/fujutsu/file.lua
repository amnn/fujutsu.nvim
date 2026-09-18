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

function M.open(root, id, path, opts)
  opts = opts or {}
  local name = opts.workspace and (root .. '/' .. path)
    or ('fujutsu://%s/%s/%s'):format(root, opts.base and (id .. '-parents') or id, path)
  local content, change
  if not opts.workspace and vim.fn.bufnr(name) == -1 then
    content = opts.base and M.base(root, id, path) or M.content(root, id, path)
    local ignored
    ignored, change = M.resolve(root, id)
  end
  local command = opts.command or 'split'
  vim.cmd({ cmd = command, args = { vim.fn.fnameescape(name) }, mods = opts.mods or {} })
  local buf = vim.api.nvim_get_current_buf()
  if not opts.workspace and not vim.b[buf].fujutsu_file then
    content = content or (opts.base and M.base(root, id, path) or M.content(root, id, path))
    if not change then local ignored; ignored, change = M.resolve(root, id) end
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].swapfile = false
    M.set_content(buf, content)
    vim.b[buf].fujutsu_repo = root
    vim.b[buf].fujutsu_file = { id = id, change = change, path = path, base = opts.base, content = content }
    vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ''
    vim.bo[buf].modified = false
    vim.bo[buf].readonly = true
    vim.api.nvim_create_autocmd('BufReadCmd', { buffer = buf, callback = function()
      M.set_content(buf, vim.b[buf].fujutsu_file.content)
      vim.bo[buf].modified = false
    end })
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      M.write(buf, { bang = vim.v.cmdbang == 1 })
    end })
  end
  if opts.readonly ~= nil then vim.bo[buf].readonly = opts.readonly end
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(opts.line or 1, vim.api.nvim_buf_line_count(buf))), 0 })
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
  local id = M.resolve(root, meta.change .. ' & all()')
  local latest = meta.description and M.jj(root, { 'log', '--no-graph', '-r', id, '-T', 'description' })
    or M.content(root, id, meta.path)
  if latest ~= meta.content and not opts.bang then error('Stale revision contents; use bang to replace the latest file', 0) end
  return root, meta, id
end

function M.buffer_content(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

function M.advance(buf, root, meta, content)
  meta.id = M.resolve(root, meta.change .. ' & all()')
  meta.content = content
  vim.b[buf].fujutsu_file = meta
  local name = ('fujutsu://%s/%s/%s'):format(root, meta.id, meta.path)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= buf then name = name .. '?buffer=' .. buf end
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].modified = false
  require('fujutsu').invalidate(root)
  vim.cmd('checktime')
end

function M.write(buf, opts)
  opts = opts or {}
  local root, meta, id = M.check_write(buf, opts)
  local content = M.buffer_content(buf)
  if content:find('\0', 1, true) then error('Binary revision writes are not supported', 0) end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local payload = assert(io.open(dir .. '/content', 'wb')); payload:write(content); payload:close()
  local script = [[#!/bin/sh
set -eu
right=$1
root=$2
change=$3
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
      meta.change, id, meta.path, dir .. '/content' }),
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
