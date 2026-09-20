vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
if vim.env.FUJUTSU_TEST_OIL then
  vim.opt.runtimepath:append(vim.env.FUJUTSU_TEST_OIL)
  require('oil').setup()
  -- Reproduce the user's global parent mapping; virtual buffers must override it.
  vim.keymap.set('n', '-', function() require('oil').open(vim.fn.expand('%:h')) end)
end
local file = require('fujutsu.file')
local root = vim.fn.tempname() .. ' repo #%'
vim.fn.mkdir(root .. '/nested/deeper', 'p')
root = vim.uv.fs_realpath(root)
local function jj(args) return file.jj(root, args) end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b })) end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
  vim.wait(100, function() return false end, 10)
end
local function test()
  jj({ 'git', 'init' })
  vim.fn.writefile({ 'historical', 'second line' }, root .. '/nested/deeper/file #?%.lua')
  vim.fn.writefile({ 'sibling' }, root .. '/nested/other.txt')
  local id = file.resolve(root, '@')
  jj({ 'new' })
  vim.fn.delete(root .. '/nested', 'rf') -- Parent browsing must not use disk.
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.J()
  local logbuf = vim.api.nvim_get_current_buf()
  local logname = vim.api.nvim_buf_get_name(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd.clearjumps()
  keys('-')
  local directory = vim.api.nvim_buf_get_name(0)
  eq(vim.env.FUJUTSU_TEST_OIL and 'oil' or '', vim.bo.filetype)
  keys('<C-o>')
  eq(logbuf, vim.api.nvim_get_current_buf()); eq(2, vim.fn.line('.'))
  eq(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  keys('<C-i>'); eq(directory, vim.api.nvim_buf_get_name(0))
  eq(false, vim.api.nvim_buf_is_loaded(logbuf))
  eq(false, vim.bo[logbuf].buflisted)
  vim.cmd.edit(vim.fn.fnameescape(logname))
  eq(logbuf, vim.api.nvim_get_current_buf()); eq('fujutsu', vim.bo.filetype)
  eq(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  eq(1, vim.fn.maparg('-', 'n', false, true).buffer)
  -- Wiping removes jump-list entries in Vim itself, but reopening the URI must work.
  vim.cmd.enew(); vim.api.nvim_buf_delete(logbuf, { force = true })
  vim.cmd.edit(vim.fn.fnameescape(logname))
  eq(root, vim.b.fujutsu_repo); eq('fujutsu', vim.bo.filetype)
  print('PASS: log parent browsing, Ctrl-O/Ctrl-I, unload, and URI reconstruction')

  file.open(root, id, 'nested/deeper/file #?%.lua', { command = 'edit' })
  local historical = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(0)
  eq('lua', vim.bo.filetype)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd.clearjumps()
  keys('-')
  local tree = vim.api.nvim_get_current_buf()
  eq('nested/deeper', vim.b.fujutsu_tree.path); eq(id, vim.b.fujutsu_tree.id)
  eq({ 'file #?%.lua' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  eq(false, vim.bo.modifiable)
  keys('<C-o>'); eq(historical, vim.api.nvim_get_current_buf()); eq(2, vim.fn.line('.'))
  eq('historical\nsecond line\n', file.buffer_content(0))
  keys('<C-i>'); eq(tree, vim.api.nvim_get_current_buf())
  keys('<CR>'); eq(historical, vim.api.nvim_get_current_buf())
  keys('2-'); eq('nested', vim.b.fujutsu_tree.path)
  eq({ 'deeper/', 'other.txt' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  keys('99-'); eq('', vim.b.fujutsu_tree.path)
  local top = vim.api.nvim_get_current_buf()
  local windows = #vim.api.nvim_tabpage_list_wins(0)
  keys('-')
  eq('fujutsu', vim.bo.filetype)
  eq(id, require('fujutsu').selection().id)
  eq(windows, #vim.api.nvim_tabpage_list_wins(0))
  keys('<C-o>'); eq(top, vim.api.nvim_get_current_buf())
  local logcount = 0
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buffer].fujutsu_log then logcount = logcount + 1 end
  end
  keys('-'); eq('fujutsu', vim.bo.filetype)
  local after = 0
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buffer].fujutsu_log then after = after + 1 end
  end
  eq(logcount, after) -- Reuse the hidden log rather than allocating another.
  require('fujutsu.tree').open(root, id, 'nested/deeper', false)
  vim.cmd.edit() -- Reinstall mappings through the URI reader, too.
  keys('-'); eq('nested', vim.b.fujutsu_tree.path); eq(id, vim.b.fujutsu_tree.id)
  eq('deeper/', vim.api.nvim_get_current_line())
  vim.api.nvim_buf_delete(historical, { force = true })
  vim.cmd.edit(vim.fn.fnameescape(name))
  eq(id, vim.b.fujutsu_file.id); eq(true, vim.bo.readonly); eq(true, vim.bo.modifiable)
  eq('historical\nsecond line\n', file.buffer_content(0))
  print('PASS: pinned parents, root-to-log navigation and reuse, counts, URI escaping, and reload')

  vim.cmd('only!'); vim.o.hidden = false
  vim.bo.readonly = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
  eq(false, pcall(require('fujutsu.tree').parent, 1))
  eq(name, vim.api.nvim_buf_get_name(0)); eq(true, vim.bo.modified)
  vim.o.hidden = true
  keys('-'); keys('<C-o>')
  eq('unsaved\n', file.buffer_content(0)); eq(true, vim.bo.modified)
  print('PASS: parent navigation retains normal modified/hidden-buffer safeguards')
end
local ok, err = xpcall(test, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd.cquit(1) end
vim.cmd('qa!')
