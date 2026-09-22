vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local visual_s = false
vim.keymap.set('x', 'S', function()
  visual_s = true
  vim.cmd.normal({ args = { '\27' }, bang = true })
end, { desc = 'User Visual S' })
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function jj(args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end
jj({ 'git', 'init' })
jj({ 'config', 'set', '--repo', 'user.name', 'Test' })
jj({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
jj({ 'describe', '-m', 'parent description' })
vim.fn.writefile({ 'parent' }, dir .. '/parent')
jj({ 'new', '-m', 'source description' })
vim.fn.writefile({ 'source' }, dir .. '/source')
vim.cmd.cd(dir)
vim.cmd([[J log -r 'all()']])
local buf = vim.api.nvim_get_current_buf()
local log = require('fujutsu').log(buf)
local actions = require('fujutsu.actions')
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'x')) do
  assert(mapping.lhs ~= 'S', 'Fujutsu must not install a Visual S mapping')
end
assert(vim.fn.maparg('S', 'n', false, true).buffer == 1)
for _, key in ipairs({ 's', 'x' }) do
  assert(vim.fn.maparg(key, 'x', false, true).buffer == 1, 'Keep partial-patch Visual actions')
end
local operation = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
keys('VS')
assert(visual_s, 'Preserve the user Visual S mapping')
assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == operation)
print('PASS: S is Normal-only; user Visual S and partial-patch mappings remain intact')
local function focus_wc()
  log.refresh(buf)
  for i, row in pairs(log.rows) do
    if row.working_copy and row.first == i then vim.api.nvim_win_set_cursor(0, { i, 0 }); return end
  end
end
local function squash()
  focus_wc()
  return actions.squash(log, buf, dir, require('fujutsu.selection').capture(log, false), 's', '"')
end
local before = jj({ 'log', '--no-graph', '-r', '@', '-T', 'commit_id' })
local job = squash()
assert(vim.wait(10000, function() return job.editor ~= nil or job.result ~= nil end, 20))
assert(job.editor and vim.api.nvim_buf_is_valid(job.editor), 'Expected internal description editor')
local content = table.concat(vim.api.nvim_buf_get_lines(job.editor, 0, -1, false), '\n')
assert(content:find('parent description', 1, true) and content:find('source description', 1, true))
vim.api.nvim_buf_delete(job.editor, { force = true })
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code ~= 0)
assert(jj({ 'log', '--no-graph', '-r', '@', '-T', 'commit_id' }) == before)
vim.api.nvim_set_current_buf(buf)
job = squash()
assert(vim.wait(10000, function() return job.editor ~= nil end, 20))
vim.api.nvim_buf_set_lines(job.editor, 0, -1, false, { 'combined description' })
vim.api.nvim_buf_call(job.editor, function() vim.cmd.write() end)
assert(job.result == nil and vim.api.nvim_buf_is_valid(job.editor), 'Writing saves a draft without closing')
vim.api.nvim_buf_delete(job.editor, {})
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(jj({ 'log', '--no-graph', '-r', '@-', '-T', 'description' }) == 'combined description')
assert(jj({ 'file', 'show', '-r', '@-', 'source' }) == 'source')
-- Whole-commit extraction preserves the description when its source disappears.
jj({ 'describe', '-m', 'extract description' })
vim.fn.writefile({ 'extract' }, dir .. '/extract')
vim.api.nvim_set_current_buf(buf); focus_wc()
job = actions.squash(log, buf, dir, require('fujutsu.selection').capture(log, false), 'x', '"')
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(jj({ 'log', '--no-graph', '-r', '@-', '-T', 'description' }) == 'extract description')
print('PASS: squash descriptions, cancellation atomicity, empty-source abandonment and full extraction')
-- Multiple marked commits squash into the cursor, with all descriptions kept
-- in the editor draft and all emptied sources abandoned.
local sources = {}
for _, name in ipairs({ 'one', 'two' }) do
  jj({ 'new', 'root()', '-m', name .. ' description' })
  vim.fn.writefile({ name }, dir .. '/' .. name)
  sources[#sources + 1] = jj({ 'log', '--no-graph', '-r', '@', '-T', 'change_id' })
end
jj({ 'new', 'root()', '-m', 'target description' })
vim.api.nvim_set_current_buf(buf); focus_wc()
require('fujutsu.marks').modify('a', 'replace', sources, log.catalog)
keys('"aS')
job = assert(require('fujutsu.runner').latest(vim.uv.fs_realpath(dir)), 'Normal S must start squash')
assert(vim.wait(10000, function() return job.editor ~= nil end, 20))
content = table.concat(vim.api.nvim_buf_get_lines(job.editor, 0, -1, false), '\n')
for _, word in ipairs({ 'one description', 'two description', 'target description' }) do
  assert(content:find(word, 1, true))
end
assert(pcall(require('fujutsu.runner').guard, dir), 'Pending editor must not lock repository writes')
vim.api.nvim_buf_set_lines(job.editor, 0, -1, false, { 'all descriptions combined' })
vim.api.nvim_set_current_buf(job.editor)
vim.cmd.wq()
assert(vim.wait(10000, function() return job.result ~= nil end, 20))
assert(job.result.code == 0, job.result.stderr)
assert(jj({ 'file', 'show', '-r', '@', 'one' }) == 'one')
assert(jj({ 'file', 'show', '-r', '@', 'two' }) == 'two')
for _, source in ipairs(sources) do
  assert(jj({ 'log', '--no-graph', '-r', 'change_id(' .. source .. ') & all()', '-T', 'commit_id' }) == '')
end
print('PASS: multiple register sources, combined descriptions and normal write/close lifecycle')
vim.cmd.cd('/')
vim.fn.delete(dir, 'rf')
vim.cmd.qa({ bang = true })
