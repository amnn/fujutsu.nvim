vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local file = require('fujutsu.file')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
local function jj(args) return file.jj(root, args) end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b })) end
local function count() return #vim.api.nvim_tabpage_list_wins(0) end
local function mapped(key) vim.fn.maparg(key, 'n', false, true).callback() end
local function contains(text, part) assert(text:find(part, 1, true), ('%q does not contain %q'):format(text, part)) end
local function test()
  jj({ 'git', 'init' })
  for _, path in ipairs({ 'alpha.lua', 'beta.lua', 'percent%name.lua' }) do
    vim.fn.writefile({ 'base' }, root .. '/' .. path)
  end
  local base = file.resolve(root, '@')
  jj({ 'new' })
  for _, path in ipairs({ 'alpha.lua', 'beta.lua' }) do vim.fn.writefile({ 'changed' }, root .. '/' .. path) end
  file.resolve(root, '@')
  vim.cmd.cd(root)
  vim.cmd.edit('alpha.lua')
  local editor, alpha = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.wo.winbar = 'user winbar'
  vim.cmd.J()
  local logwin, logbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local function select(path)
    vim.api.nvim_set_current_win(logwin)
    for index, line in ipairs(vim.api.nvim_buf_get_lines(logbuf, 0, -1, false)) do
      if vim.endswith(line, ' ' .. path) then vim.api.nvim_win_set_cursor(0, { index, 0 }); return end
    end
    error('Missing log file row: ' .. path)
  end
  select('alpha.lua'); mapped('<CR>')
  eq(editor, vim.api.nvim_get_current_win()); eq(alpha, vim.api.nvim_get_current_buf()); eq(2, count())
  for _ = 1, 3 do
    select('beta.lua'); mapped('<CR>'); eq(editor, vim.api.nvim_get_current_win())
    select('alpha.lua'); mapped('<CR>'); eq(alpha, vim.api.nvim_get_current_buf()); eq(2, count())
  end
  vim.cmd.vsplit('beta.lua')
  local other = vim.api.nvim_get_current_win()
  -- Even when the previous window is different, focus an already displayed target.
  select('alpha.lua'); mapped('<CR>'); eq(editor, vim.api.nvim_get_current_win()); eq(3, count())
  vim.api.nvim_buf_set_lines(alpha, 0, -1, false, { 'unsaved alpha' })
  select('alpha.lua'); mapped('<CR>'); eq(true, vim.bo.modified)
  eq('unsaved alpha\n', file.buffer_content(0)); vim.bo.modified = false
  vim.api.nvim_win_close(other, false)
  print('PASS: Enter reuses target/previous editing windows and preserves existing buffer edits')

  vim.api.nvim_set_current_win(logwin); vim.cmd.only()
  select('beta.lua'); mapped('<CR>'); eq(2, count())
  editor = vim.api.nvim_get_current_win()
  select('alpha.lua'); mapped('<CR>'); eq(editor, vim.api.nvim_get_current_win()); eq(2, count())
  for _, option in ipairs({ 'previewwindow', 'winfixwidth', 'winfixbuf', 'diff' }) do
    vim.wo[editor][option] = true
    local protected = vim.api.nvim_win_get_buf(editor)
    select('beta.lua'); mapped('<CR>'); eq(3, count())
    eq(protected, vim.api.nvim_win_get_buf(editor))
    local created = vim.api.nvim_get_current_win()
    vim.wo[editor][option] = false
    vim.api.nvim_win_close(created, false)
    vim.api.nvim_set_current_win(editor)
  end
  vim.o.hidden = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved editor' })
  local edited = vim.api.nvim_get_current_buf()
  local notify, messages = vim.notify, {}
  vim.notify = function(message) messages[#messages + 1] = tostring(message) end
  select('beta.lua'); mapped('<CR>')
  vim.notify = notify
  eq(2, count()); eq(logwin, vim.api.nvim_get_current_win()); eq(true, vim.bo[edited].modified)
  contains(table.concat(messages), 'E37')
  vim.bo[edited].modified = false
  vim.cmd('Jedit beta.lua'); eq(editor, vim.api.nvim_get_current_win()); eq(2, count())
  print('PASS: one fallback split, protected windows, modified-buffer refusal, and Jedit from logs')

  select('alpha.lua'); mapped('o'); eq(3, count())
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
  select('alpha.lua'); mapped('gO'); eq(3, count()); assert(vim.api.nvim_win_get_width(0) < vim.o.columns)
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
  local tab = vim.api.nvim_get_current_tabpage()
  local tabs = #vim.api.nvim_list_tabpages()
  select('alpha.lua'); mapped('O'); eq(tabs + 1, #vim.api.nvim_list_tabpages())
  vim.cmd.tabclose(); eq(tab, vim.api.nvim_get_current_tabpage())
  select('alpha.lua'); mapped('p'); eq(logwin, vim.api.nvim_get_current_win()); eq(3, count())
  select('beta.lua'); mapped('p'); eq(logwin, vim.api.nvim_get_current_win()); eq(3, count())
  vim.cmd.pclose()
  print('PASS: explicit split, vertical split, tab, and reusable preview mappings')
  vim.api.nvim_set_current_win(logwin)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  require('fujutsu').log(logbuf).move('revision', 1, 1)
  mapped('<CR>'); eq(editor, vim.api.nvim_get_current_win())
  local description = vim.api.nvim_get_current_buf()
  eq(true, vim.b.fujutsu_file.description)
  vim.api.nvim_set_current_win(logwin); mapped('<CR>')
  eq(description, vim.api.nvim_get_current_buf()); eq(2, count())
  vim.cmd('Jedit alpha.lua')

  vim.api.nvim_set_current_win(editor)
  vim.wo.winbar = 'user winbar'
  vim.api.nvim_set_current_win(logwin)
  vim.cmd('Jview -r ' .. base .. ' alpha.lua')
  eq(editor, vim.api.nvim_get_current_win()); eq(2, count())
  eq(base, vim.b.fujutsu_file.id)
  print('PASS: Jview from logs reuses an editing window')
end
local ok, err = xpcall(test, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd.cquit(1) end
vim.cmd('qa!')
