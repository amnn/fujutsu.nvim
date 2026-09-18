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
  local command = opts.command or 'split'
  vim.cmd({ cmd = command, args = { vim.fn.fnameescape(name) }, mods = opts.mods or {} })
  local buf = vim.api.nvim_get_current_buf()
  if not opts.workspace and not vim.b[buf].fujutsu_file then
    local content = opts.base and M.base(root, id, path) or M.content(root, id, path)
    local _, change = M.resolve(root, id)
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].swapfile = false
    M.set_content(buf, content)
    vim.b[buf].fujutsu_repo = root
    vim.b[buf].fujutsu_file = { id = id, change = change, path = path, base = opts.base, content = content }
    vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ''
    vim.bo[buf].modified = false
    vim.bo[buf].readonly = true
  end
  if opts.readonly ~= nil then vim.bo[buf].readonly = opts.readonly end
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(opts.line or 1, vim.api.nvim_buf_line_count(buf))), 0 })
  return buf
end

return M
