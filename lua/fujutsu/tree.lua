local M = {}
local file = require('fujutsu.file')
local uri = require('fujutsu.uri')

local function dirname(path)
  local parent = vim.fs.dirname(path)
  return parent == '.' and '' or (parent or '')
end

function M.open(root, id, path, base, focus)
  vim.cmd.edit(vim.fn.fnameescape(uri.name(root, 'tree', id, path, base)))
  if focus then
    for index, entry in ipairs(vim.b.fujutsu_tree.entries) do
      if entry.path == focus then vim.api.nvim_win_set_cursor(0, { index, 0 }); break end
    end
  end
end

function M.parent(count)
  local tree, revision = vim.b.fujutsu_tree, vim.b.fujutsu_file
  local meta = tree or revision
  assert(meta, 'Not a revision buffer')
  local path = meta.description and '' or meta.path
  if tree and path == '' then
    require('fujutsu').open({ current_window = true, revision = meta.id })
    return
  end
  local focus = path
  for _ = 1, count or 1 do
    focus, path = path, dirname(path)
  end
  M.open(vim.b.fujutsu_repo, meta.id, path, meta.base, focus)
end

function M.read(buf, location)
  local root, id, path = location.root, location.id, location.path
  local args = { '--ignore-working-copy' }
  if location.base then
    -- The diff editor materializes the changed old-side paths, not a named
    -- commit tree. Do not pretend it is one of the individual parents.
    vim.list_extend(args, { 'diff', '-r', id, '-T',
      'if(status != "added", json(source.path()) ++ "\\n")' })
  else
    vim.list_extend(args, { 'log', '--no-graph', '-r', id, '-T',
      'self.files().map(|f| json(f.path()) ++ "\\n").join("")' })
  end
  local paths = file.jj(root, args)
  local prefix = path == '' and '' or path .. '/'
  local entries, seen = {}, {}
  for line in paths:gmatch('[^\n]+') do
    local filename = vim.json.decode(line)
    if vim.startswith(filename, prefix) then
      local relative = filename:sub(#prefix + 1)
      local name = relative:match('^[^/]+')
      if name and not seen[name] then
        seen[name] = true
        entries[#entries + 1] = { name = name, path = prefix .. name, directory = relative:find('/', 1, true) ~= nil }
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.directory ~= b.directory then return a.directory end
    return a.name < b.name
  end)
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = vim.fn.strtrans(entry.name) .. (entry.directory and '/' or '')
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nowrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = 'fujutsu-tree'
  vim.b[buf].fujutsu_repo = root
  local _, change = file.resolve(root, id)
  vim.b[buf].fujutsu_tree = { id = id, change = change, path = path, base = location.base, entries = entries }
  vim.keymap.set('n', '-', function() M.parent(vim.v.count1) end,
    { buffer = buf, silent = true, desc = 'Open parent in this revision' })
  vim.keymap.set('n', '<CR>', function()
    local entry = vim.b[buf].fujutsu_tree.entries[vim.api.nvim_win_get_cursor(0)[1]]
    if not entry then return end
    if entry.directory then M.open(root, id, entry.path, location.base)
    else file.open(root, id, entry.path, { base = location.base, command = 'edit', explicit = true }) end
  end, { buffer = buf, silent = true, desc = 'Open entry in this revision' })
end

return M
