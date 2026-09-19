local M = {}
local file = require('fujutsu.file')

function M.select(args)
  local revision, path, literal = '@', nil, false
  local i = 1
  while i <= #args do
    local arg = args[i]
    if not literal and arg == '--' then literal = true
    elseif not literal and arg == '-r' then
      i = i + 1
      revision = assert(args[i], '-r requires a revision')
    elseif not literal and arg:sub(1, 1) == '-' then error('Unknown argument: ' .. arg, 0)
    elseif path then error('Expected one file', 0)
    else path = arg end
    i = i + 1
  end
  local meta = vim.b.fujutsu_file
  local root = vim.b.fujutsu_repo
  local row
  if not path and not meta and root then row = require('fujutsu').selection() end
  if not root then
    local name = vim.api.nvim_buf_get_name(0)
    local cwd = vim.bo.buftype == '' and name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
    root = vim.trim(file.jj(cwd, { 'root' }))
    root = vim.uv.fs_realpath(root) or root
  end
  if path then
    local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
    if absolute:sub(1, #root + 1) ~= root .. '/' then
      local real_root = vim.uv.fs_realpath(vim.fn.getcwd())
      if real_root and not vim.startswith(path, '/') then absolute = vim.fs.normalize(real_root .. '/' .. path) end
    end
    if absolute:sub(1, #root + 1) ~= root .. '/' then error('File is outside the repository', 0) end
    path = absolute:sub(#root + 2)
  elseif meta and not meta.description then path = meta.path
  elseif row then path = row.path
  elseif vim.bo.buftype == '' then
    local name = vim.api.nvim_buf_get_name(0)
    name = vim.uv.fs_realpath(name) or name
    if name:sub(1, #root + 1) == root .. '/' then path = name:sub(#root + 2) end
  end
  if not path or path == '' then error('No file under cursor; specify a file explicitly', 0) end
  local id = file.resolve(root, revision)
  return root, id, path, revision == '@'
end

function M.open(command, readonly, opts)
  local root, id, path, workspace = M.select(opts.fargs)
  return file.open(root, id, path, { workspace = workspace, command = command,
    readonly = readonly, mods = opts.smods, explicit = not workspace })
end

function M.read(opts)
  if not vim.bo.modifiable then error('Buffer is not modifiable', 0) end
  local root, id, path = M.select(opts.fargs)
  local content = file.content(root, id, path)
  local whole = opts.range == 0 or (opts.range == 2 and opts.line1 == 1
    and opts.line2 == vim.api.nvim_buf_line_count(0))
  if whole then
    file.set_content(0, content)
  else
    local lines = vim.split(content:gsub('\n$', ''), '\n', { plain = true })
    if content == '' then lines = {} end
    local start = opts.range == 1 and opts.line2 or opts.line1 - 1
    vim.api.nvim_buf_set_lines(0, start, opts.line2, false, lines)
  end
end

function M.complete(lead, line)
  if line:match('%s%-r%s+[^%s]*$') then
    local root = vim.b.fujutsu_repo or vim.fn.getcwd()
    local ok, text = pcall(file.jj, root, { 'log', '--no-graph', '-T', 'change_id.shortest() ++ "\\n"' })
    local candidates = { '@', '@-' }
    if ok then vim.list_extend(candidates, vim.split(vim.trim(text), '\n')) end
    return vim.tbl_filter(function(s) return vim.startswith(s, lead) end, candidates)
  end
  local matches = vim.fn.getcompletion(lead, 'file')
  if vim.startswith('-r', lead) then table.insert(matches, '-r') end
  if vim.startswith('--', lead) then table.insert(matches, '--') end
  return matches
end

-- Shell-style quoting for Ex arguments, without a shell or expansion. Vim's
-- fargs does not remove shell quotes around a revset containing spaces.
function M.argv(text)
  local args, token, quote, started = {}, '', nil, false
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '\\' and quote ~= "'" then
      i = i + 1
      assert(i <= #text, 'Trailing backslash')
      token, started = token .. text:sub(i, i), true
    elseif quote then
      if c == quote then quote = nil else token = token .. c end
    elseif c == "'" or c == '"' then quote, started = c, true
    elseif c:match('%s') then
      if started then args[#args + 1], token, started = token, '', false end
    else token, started = token .. c, true end
    i = i + 1
  end
  assert(not quote, 'Unclosed argument quote')
  if started then args[#args + 1] = token end
  return args
end

function M.execute(opts)
  local args = M.argv(opts.args or '')
  if #args == 0 then return require('fujutsu').open(opts) end
  if args[1] == 'log' then
    local query, limit
    local i = 2
    while i <= #args do
      local flag = args[i]
      assert(flag == '-r' or flag == '--revisions' or flag == '-n' or flag == '--limit',
        'Log buffers support -r/--revisions and -n/--limit')
      i = i + 1
      local value = assert(args[i], 'Missing value for ' .. flag)
      if flag == '-r' or flag == '--revisions' then query = value
      else assert(value:match('^%d+$'), 'Invalid log limit'); limit = value end
      i = i + 1
    end
    return require('fujutsu').open(vim.tbl_extend('force', opts,
      { new_log = true, query = query, limit = limit }))
  end
  local root = vim.b.fujutsu_repo
  if not root then
    local name = vim.api.nvim_buf_get_name(0)
    local cwd = vim.bo.buftype == '' and name ~= '' and vim.fs.dirname(name) or vim.fn.getcwd()
    root = vim.trim(file.jj(cwd, { 'root' }))
    root = vim.uv.fs_realpath(root) or root
  end
  return require('fujutsu.runner').run(root, args)
end

return M
