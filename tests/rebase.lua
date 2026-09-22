vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function jj(args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end
local function id(rev, template) return jj({ 'log', '--no-graph', '-r', rev, '-T', template or 'commit_id' }) end
jj({ 'git', 'init' })
jj({ 'config', 'set', '--repo', 'user.name', 'Test' })
jj({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
for _, name in ipairs({ 'A', 'B', 'C' }) do
  jj({ 'describe', '-m', name }); vim.fn.writefile({ name }, dir .. '/' .. name)
  jj({ 'bookmark', 'create', name, '-r', '@' }); jj({ 'new' })
end
jj({ 'new', 'root()', '-m', 'destination' })
jj({ 'bookmark', 'create', 'D' })
vim.cmd.cd(dir)
vim.cmd([[J log -r 'all()']])
local buf = vim.api.nvim_get_current_buf()
local log = require('fujutsu').log(buf)
local marks = require('fujutsu.marks')
marks.modify('a', 'replace', { id('A', 'change_id'), id('C', 'change_id') }, log.catalog)
log.refresh(buf)
local function focus(rev)
  local commit = id(rev)
  for i, row in pairs(log.rows) do
    if row.id == commit and row.first == i then vim.api.nvim_win_set_cursor(0, { i, 0 }); return end
  end
  error('No revision ' .. rev)
end
focus('D')
local selected = require('fujutsu.selection').capture(log, false)
local job = require('fujutsu.actions').rebase(log, buf, dir, selected, true, 'a', 'r', 'o')
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(id('parents(C)') == id('A'))
assert(id('parents(A)') == id('D'))
assert(id('B & ancestors(C)') == '')
-- Multiple destination marks create a merged parent set.
marks.modify('a', 'replace', { id('B', 'change_id'), id('C', 'change_id') }, log.catalog)
log.refresh(buf); focus('@')
selected = require('fujutsu.selection').capture(log, false)
-- Create an independent source, avoiding a cycle through D.
jj({ 'new', 'root()', '-m', 'merge-source' })
log.refresh(buf); focus('@')
selected = require('fujutsu.selection').capture(log, false)
job = require('fujutsu.actions').rebase(log, buf, dir, selected, false, 'a', 'r', 'o')
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(id('parents(@)', 'commit_id ++ "\\n"'):find('\n'))
print('PASS: explicit revision ancestry, register-to-context rebases and multi-parent destinations')
-- Exercise the actual multi-key dispatcher and its symmetric Enter defaults.
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
jj({ 'new', 'root()', '-m', 'key-source' })
log.refresh(buf)
marks.modify('a', 'replace', { id('@', 'change_id') }, log.catalog)
log.refresh(buf); focus('D')
keys('"aR<Enter>')
local root = vim.uv.fs_realpath(dir)
job = assert(require('fujutsu.runner').latest(root), 'Mapping did not start rebase')
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(id('parents(@)') == id('D'))
local old = id('@')
keys('R<Esc>')
assert(not require('fujutsu.runner').latest(root) and id('@') == old)
marks.modify('a', 'replace', { id('B', 'change_id') }, log.catalog)
log.refresh(buf); focus('@'); keys('"arso')
job = assert(require('fujutsu.runner').latest(root))
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(id('parents(@)') == id('B'))
print('PASS: R Enter, explicit lowercase register destination and Escape grammar mappings')
-- Reclaim multi-source selection by marking in Visual mode, then using R.
jj({ 'new', 'root()', '-m', 'visual source a' }); jj({ 'bookmark', 'create', 'visual-a' })
jj({ 'new', '-m', 'visual source b' }); jj({ 'bookmark', 'create', 'visual-b' })
log.refresh(buf); focus('visual-b'); keys('V'); focus('visual-a'); keys('"am')
local registered = marks.resolve('a', log.catalog, dir, require('fujutsu.file').jj)
assert(#registered == 2, 'Visual marking must select both source revisions')
focus('D'); keys('Rro')
job = assert(require('fujutsu.runner').latest(root))
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(id('parents(visual-a)') == id('D'))
assert(id('parents(visual-b)') == id('visual-a'))
print('PASS: Visual mark followed by Normal R rebases the selected revision set')
-- Exercise compound mappings independently of jj, without borrowing operators.
vim.cmd.tabnew()
local fixture = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(fixture, 0, -1, false, { 'one', 'two', 'three' })
vim.bo.modifiable = false
local snapshot = { rows = { { id = 'one' }, { id = 'two' }, { id = 'three' } } }
local previous_operator = vim.go.operatorfunc
local user_motion = function() return 'l' end
vim.keymap.set('o', 'bo', user_motion, { buffer = fixture, expr = true, desc = 'User motion' })
local previous_map = vim.fn.maparg('bo', 'o', false, true)
local captured, fail
local function capture_run(_, _, _, selected, upper, reg, source, place)
  assert(vim.go.operatorfunc == previous_operator)
  assert(vim.deep_equal(previous_map, vim.fn.maparg('bo', 'o', false, true)))
  captured = { selected, upper, reg, source, place }
  if fail then error('Expected rebase failure') end
end
local visual_calls = 0
for _, key in ipairs({ 'r', 'R' }) do
  vim.keymap.set('x', key, function()
    visual_calls = visual_calls + 1
    vim.cmd.normal({ args = { '\27' }, bang = true })
  end, { desc = 'User Visual mapping' })
end
require('fujutsu.rebase').attach(snapshot, fixture, '/unused', capture_run)
local quote = vim.fn.maparg('"', 'n', false, true)
assert(quote.buffer == 1 and quote.noremap == 1 and quote.rhs == '"')
assert(vim.fn.maparg('"', 'x') == '', 'Leave Visual register handling alone')
assert(#vim.api.nvim_buf_get_keymap(fixture, 'x') == 0, 'No Visual rebase mappings')
keys('Vr'); keys('VR'); assert(visual_calls == 2 and captured == nil)
for _, prefix in ipairs({ 'r', 'R' }) do
  for _, source in ipairs({ 'b', 's', 'r' }) do
    for _, place in ipairs({ 'o', 'A', 'B', '<CR>' }) do
      captured = nil; vim.api.nvim_win_set_cursor(0, { 1, 0 })
      keys('"a' .. prefix .. source .. place)
      assert(captured and captured[2] == (prefix == 'R') and captured[3] == 'a')
      assert(captured[4] == source and captured[5] == (place == '<CR>' and 'o' or place))
      assert(captured[1].first == 1 and captured[1].last == 1 and not captured[1].visual)
    end
  end
end
captured = nil; vim.api.nvim_win_set_cursor(0, { 3, 4 })
keys('"aRro'); assert(captured and captured[1].first == 3)
fail = true; keys('"aRro')
assert(vim.go.operatorfunc == previous_operator)
assert(vim.deep_equal(previous_map, vim.fn.maparg('bo', 'o', false, true)))
assert(vim.api.nvim_exec2('messages', { output = true }).output:find('Expected rebase failure', 1, true))
assert(table.concat(vim.api.nvim_buf_get_lines(fixture, 0, -1, false), '\n') == 'one\ntwo\nthree')
print('PASS: Normal-only compound rebases, user Visual bindings, EOF and unchanged operator state')
vim.cmd.cd('/')
vim.fn.delete(dir, 'rf')
vim.cmd.qa({ bang = true })
