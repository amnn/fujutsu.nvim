vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
local function jj(args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end
jj({ 'git', 'init' }); jj({ 'config', 'set', '--repo', 'user.name', 'Test' })
jj({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'base' }, dir .. '/file')
jj({ 'describe', '-m', 'base' }); jj({ 'bookmark', 'create', 'base' })
jj({ 'new', '-m', 'child' }); jj({ 'bookmark', 'create', 'child' })
vim.cmd.cd(dir)
local runner = require('fujutsu.runner')
local function wait(job, editor)
  assert(vim.wait(10000, function() return editor and job.editor ~= nil or job.result ~= nil end, 20))
  if editor then assert(job.editor, job.result and job.result.stderr)
  else assert(job.result.code == 0, job.result.stderr) end
end
local first = runner.run(dir, { 'describe', '-r', 'base' })
wait(first, true)
local second = runner.run(dir, { 'describe', '-r', 'child' })
wait(second, true)
local draft = table.concat(vim.api.nvim_buf_get_lines(first.editor, 0, -1, false), '\n')
assert(draft:find('JJ: Change ID:', 1, true) and draft:find('JJ:     A file', 1, true))
assert(draft:find('JJ: Save and close (:wq)', 1, true) and draft:find('normal-mode Escape cancels', 1, true))
assert(first.id ~= second.id and first.dir ~= second.dir)
assert(vim.api.nvim_buf_is_valid(first.editor) and vim.api.nvim_buf_is_valid(second.editor))
assert(pcall(runner.guard, dir), 'Concurrent jobs are not repository locks')
-- External operations and read-only inspection are allowed during editors.
jj({ 'bookmark', 'create', 'external', '-r', 'base' })
vim.cmd.split(dir .. '/file')
local workspace = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(workspace, 0, -1, false, { 'unsaved' })
local read = runner.run(dir, { 'log', '--no-graph', '-r', '@' }); wait(read)
assert(not pcall(runner.run, dir, { 'new' }), 'Working-tree rewrites must still protect unsaved file buffers')
vim.bo[workspace].modified = false
local function accept(job, description)
  local win = vim.fn.win_findbuf(job.editor)[1]
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_set_lines(job.editor, 0, 1, false, { description })
  vim.cmd.write()
  assert(not job.result and vim.api.nvim_buf_is_valid(job.editor))
  vim.cmd.wq()
  wait(job)
end
accept(second, 'child updated'); accept(first, 'base updated')
assert(jj({ 'log', '--no-graph', '-r', 'base', '-T', 'description' }) == 'base updated')
local child_versions = jj({ 'log', '--no-graph', '-r', 'bookmarks(child)', '-T', 'commit_id ++ "\\t" ++ json(description) ++ "\\n"' })
local updated
for id, desc in child_versions:gmatch('(%x+)\t([^\n]+)') do
  if vim.json.decode(desc):find('child updated', 1, true) then updated = id end
end
assert(updated, child_versions)
-- Rewriting the parent concurrently with its child's description may produce
-- a conflicted bookmark. That is native jj behavior, not a plugin failure.
jj({ 'bookmark', 'set', 'child', '-r', updated })
assert(next(runner.jobs) == nil)
local third = runner.run(dir, { 'describe', '-r', 'base' }); wait(third, true)
local fourth = runner.run(dir, { 'describe', '-r', 'child' }); wait(fourth, true)
vim.api.nvim_buf_delete(third.editor, { force = true })
assert(vim.wait(10000, function() return third.result ~= nil end, 20))
assert(third.cancelled and third.result.code ~= 0 and not fourth.result)
accept(fourth, 'child accepted independently')
assert(jj({ 'log', '--no-graph', '-r', 'base', '-T', 'description' }) == 'base updated')
local history = require('fujutsu.diagnostics').workspaces[vim.uv.fs_realpath(dir)]
assert(#history >= 5)
for _, item in ipairs(history) do assert(not item.stderr:find('\27', 1, true)) end
vim.cmd('checkhealth jj')
assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find(vim.uv.fs_realpath(dir), 1, true))
print('PASS: simultaneous editors, external operations, independent cancellation, :wq and workspace diagnostics')
vim.cmd.cd('/'); vim.fn.delete(dir, 'rf'); vim.cmd.qa({ bang = true })
