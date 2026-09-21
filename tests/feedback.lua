-- End-to-end checks from the manual walkthrough; no user configuration needed.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
local file, ui = require('fujutsu.file'), require('fujutsu.log_ui')
local app, marks = require('fujutsu'), require('fujutsu.marks')
local diagnostics = require('fujutsu.diagnostics')
local function jj(args) return vim.trim(file.jj(dir, args)) end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b })) end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
jj({ 'git', 'init' }); jj({ 'config', 'set', '--repo', 'revsets.log', 'all()' })
for _, name in ipairs({ 'side', 'other', 'feature', 'main' }) do
  jj({ 'new', 'root()', '-m', name }); vim.fn.writefile({ name }, dir .. '/' .. name)
  jj({ 'bookmark', 'create', name })
end
vim.cmd.cd(dir); vim.cmd.J()
local buf, log = vim.api.nvim_get_current_buf(), app.log()
local function focus(name) log.focus(file.resolve(dir, name)) end
local function token(name)
  for i, row in pairs(log.rows) do
    if row.kind == 'marks' then
      for _, t in ipairs(log.tokens) do
        if t.register == name then vim.api.nvim_win_set_cursor(0, { i, t.first }); return end
      end
    end
  end
  error('Missing token ' .. name)
end
local ns = vim.api.nvim_create_namespace('fujutsu.marks')
local function overlays()
  local signs, headers = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, opts = log.rows[mark[2] + 1], mark[4]
    if opts.sign_text then signs[(row.entry or row).id] = { vim.trim(opts.sign_text), opts.sign_hl_group } end
    if row.kind == 'marks' then
      for _, t in ipairs(log.tokens) do if t.first == mark[3] then headers[t.register] = opts.hl_group end end
    end
  end
  return signs, headers
end
focus('side'); keys('"am'); focus('other'); keys('"aM')
token('a'); keys('<CR>')
focus('main'); keys('M'); eq(nil, log.preview); keys('dm'); eq(nil, log.preview)
focus('other'); keys('"bm'); focus('feature'); keys('"bM')
local signs, headers = overlays()
eq({ 'a', 'FujutsuMarkPinned' }, signs[file.resolve(dir, 'side')])
eq({ 'b', 'FujutsuMarkPreview' }, signs[file.resolve(dir, 'other')])
eq({ 'b', 'FujutsuMarkPreview' }, signs[file.resolve(dir, 'feature')])
eq('FujutsuMarkPinned', headers.a); eq('FujutsuMarkPreview', headers.b)
eq('DiagnosticWarn', vim.api.nvim_get_hl(0, { name = 'FujutsuMarkPreview' }).link)
eq('DiagnosticInfo', vim.api.nvim_get_hl(0, { name = 'FujutsuMarkPinned' }).link)
assert(vim.wait(2500, function() return log.preview == nil end, 20))
signs = overlays(); eq({ 'a', 'FujutsuMarkPinned' }, signs[file.resolve(dir, 'other')])
eq(nil, signs[file.resolve(dir, 'feature')])
token('b'); vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
signs, headers = overlays(); eq('b', signs[file.resolve(dir, 'other')][1]); eq('FujutsuMarkPreview', headers.b)
print('PASS: three-way overlays, expiry, hover, matching header/gutter and theme links')

focus('side'); keys('"am'); focus('other'); keys('M')
eq('a', marks.linked()); eq(2, #log.marks.a)
keys('dm'); eq({ (file.resolve(dir, 'side')) }, log.marks.a)
local named = vim.fn.getreg('a')
focus('main'); keys('m'); eq(nil, marks.linked()); eq(1, #log.marks.a)
focus('feature'); keys('M'); eq(2, #log.marks['"']); eq(1, #log.marks.a)
eq(named, vim.fn.getreg('a'))
assert(vim.tbl_contains(log.marks['"'], (file.resolve(dir, 'main')))
  and vim.tbl_contains(log.marks['"'], (file.resolve(dir, 'feature'))))
local header = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
assert(header:find('"[2]', 1, true) and not header:find('a[', 1, true), header)
local op = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
keys(":let @b = 'main | side'<CR>")
assert(vim.wait(1000, function() return log.marks.b and #log.marks.b == 2 end, 10))
keys(":let @b = 'mine()'<CR>")
assert(vim.wait(1000, function() return not log.marks.b end, 10))
keys(":let @b = 'main | side'<CR>")
vim.wait(50, function() return false end)
buf = app.change_query(buf, 'main'); log = app.log(buf)
eq('main | side', vim.fn.getreg('b')); eq(nil, log.marks.b)
local notices, notify = {}, vim.notify
vim.notify = function(text, level) notices[#notices + 1] = { text, level } end
focus('main'); keys('"bRro')
local errors = vim.api.nvim_exec2('messages', { output = true }).output
assert(errors:find('not a valid revision mark', 1, true))
assert(not errors:find('actions.lua:', 1, true))
eq(op, jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }))
print('PASS: weak-link mapping sequence, native register edits and partial-scope rejection without mutation')

buf = app.change_query(buf, ''); log = app.log(buf)
local dim = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if log.rows[mark[2] + 1].kind == 'query' and mark[4].hl_group == 'Comment' then dim = true end
end
assert(dim)
buf = app.change_query(buf, 'all()'); log = app.log(buf)
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  assert(not (log.rows[mark[2] + 1].kind == 'query' and mark[4].hl_group == 'Comment'))
end
eq(op, jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }))
local win, count = vim.api.nvim_get_current_win(), #vim.api.nvim_tabpage_list_wins(0)
vim.cmd([[J log -r 'all()']]); eq(win, vim.api.nvim_get_current_win()); eq(count, #vim.api.nvim_tabpage_list_wins(0))
eq(true, vim.bo[buf].buflisted); eq('delete', vim.bo[buf].bufhidden)
vim.cmd.split(); eq(count + 1, #vim.api.nvim_tabpage_list_wins(0)); vim.cmd.close()
eq(true, vim.api.nvim_buf_is_loaded(buf)); eq(true, vim.bo[buf].buflisted)
local name = vim.api.nvim_buf_get_name(buf)
vim.cmd.close(); eq(false, vim.api.nvim_buf_is_loaded(buf)); eq(false, vim.bo[buf].buflisted); eq(nil, app.log(buf))
vim.cmd.edit(vim.fn.fnameescape(name)); eq(true, vim.bo.buflisted); eq('all()', app.log().query)
vim.cmd([[tab J log -r 'all()']]); eq(buf, vim.api.nvim_get_current_buf())
eq(1, #vim.api.nvim_tabpage_list_wins(0)); vim.cmd.tabclose()
vim.cmd.tabnew(); vim.cmd.cd(dir); vim.cmd([[J log -r 'all()']])
eq(buf, vim.api.nvim_get_current_buf()); eq(2, #vim.api.nvim_tabpage_list_wins(0))
vim.cmd.tabclose(); log = app.log(buf)
print('PASS: default query styling, window reuse, listing, last-window unload and cross-tab reconstruction')

focus('main'); keys('<CR>')
local description = vim.api.nvim_get_current_buf()
local content = file.buffer_content(description)
assert(content:find('JJ: Change ID:', 1, true) and content:find('JJ:     A main', 1, true))
assert(content:find(':write saves this description to jj', 1, true) and content:find('Escape', 1, true))
vim.api.nvim_buf_set_lines(description, 0, 1, false, { 'saved with comments' }); vim.cmd.write()
eq('saved with comments', jj({ 'log', '--no-graph', '-r', 'main', '-T', 'description' }))
assert(file.buffer_content(description):find('JJ: Change ID:', 1, true))
vim.api.nvim_buf_set_lines(description, 0, 1, false, { 'discard me' }); keys('<Esc>')
eq('saved with comments', jj({ 'log', '--no-graph', '-r', 'main', '-T', 'description' }))
vim.cmd.J(); log = app.log(); buf = vim.api.nvim_get_current_buf(); focus('main'); keys('<CR>')
vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'saved with wq' }); vim.cmd.wq()
eq('saved with wq', jj({ 'log', '--no-graph', '-r', 'main', '-T', 'description' }))
print('PASS: Enter description has native context and accurate guidance; write/wq strip comments; Escape discards only unsaved edits')

vim.cmd.edit(dir .. '/main'); vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved' })
local dirty = vim.api.nvim_get_current_buf()
local job = require('fujutsu.runner').run(dir, { 'status' })
assert(vim.wait(10000, function() return job.result ~= nil end, 20)); eq(0, job.result.code)
local ok, err = pcall(require('fujutsu.runner').run, dir, { 'new' }); eq(false, ok)
diagnostics.error(err, dir)
errors = vim.api.nvim_exec2('messages', { output = true }).output
assert(errors:find('Save or discard', 1, true) and not errors:find('runner.lua:', 1, true))
vim.bo[dirty].modified = false
vim.notify = notify
print('PASS: read-only status with unsaved edits; clean guard error in message history')
vim.cmd.cd('/'); vim.fn.delete(dir, 'rf'); vim.cmd.qa({ bang = true })
