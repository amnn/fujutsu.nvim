vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local patch = require('fujutsu.patch')
assert(patch.apply('old\n', 'new\n', { { patch = '+new', old_line = 2, new_line = 1 } }) == 'old\nnew\n')
assert(patch.apply('old\n', 'new\n', { { patch = '-old', old_line = 1 } }) == '')
assert(patch.apply('old', 'new', { { patch = '-old', old_line = 1 },
  { patch = '+new', old_line = 2, new_line = 1 } }) == 'new')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function jj(args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end
jj({ 'git', 'init' })
jj({ 'config', 'set', '--repo', 'user.name', 'Test' })
jj({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
local base = {}
for i = 1, 30 do base[i] = 'line ' .. i end
vim.fn.writefile(base, dir .. '/file')
vim.fn.writefile({ 'other base' }, dir .. '/other')
jj({ 'describe', '-m', 'base' })
jj({ 'new' })
local source = vim.deepcopy(base)
source[2], source[28] = 'first replacement', 'second replacement'
vim.fn.writefile(source, dir .. '/file')
vim.fn.writefile({ 'other changed' }, dir .. '/other')
vim.cmd.cd(dir)
vim.cmd([[J log -r 'all()']])
local buf = vim.api.nvim_get_current_buf()
local log = require('fujutsu').log(buf)
local function file_row()
  log.refresh(buf)
  for i, row in pairs(log.rows) do
    if row.path == 'file' and row.entry.working_copy and row.first == i then
      vim.api.nvim_win_set_cursor(0, { i, 0 }); return i
    end
  end
  error('No file row')
end
local function expand()
  file_row()
  if not log.files['@'] or not log.files['@'].file then log.toggle(buf) end
end
local function focus_patch(text)
  expand()
  for i, row in pairs(log.rows) do
    if row.patch == text and row.entry.working_copy then vim.api.nvim_win_set_cursor(0, { i, 0 }); return i end
  end
  error('No patch ' .. text)
end
local function apply(key, selected)
  local job = require('fujutsu.actions').squash(log, buf, dir, selected, key, '"')
  assert(vim.wait(10000, function() return job.result ~= nil or job.editor ~= nil end, 20))
  assert(not job.editor, 'Unexpected description request for partial patch')
  assert(job.result.code == 0, job.result.stderr)
end
local capture = require('fujutsu.selection').capture
focus_patch('+first replacement')
-- Normal mode selects the whole hunk, not just the line under the cursor.
apply('s', capture(log, false))
local parent = jj({ 'file', 'show', '-r', '@-', 'file' })
assert(parent:find('first replacement', 1, true) and not parent:find('second replacement', 1, true))
assert(jj({ 'file', 'show', '-r', '@-', 'other' }) == 'other base\n')
assert(jj({ 'file', 'show', '-r', '@', 'file' }) == table.concat(source, '\n') .. '\n')
jj({ 'undo' })
-- Visual selection of only the added line does not move the paired deletion.
local line = focus_patch('+first replacement')
local selected = capture(log, false); selected.visual = true
apply('x', selected)
parent = jj({ 'file', 'show', '-r', '@-', 'file' })
assert(parent:find('line 2\nfirst replacement\n', 1, true))
assert(not parent:find('second replacement', 1, true))
assert(jj({ 'file', 'show', '-r', '@', 'file' }) == table.concat(source, '\n') .. '\n')
jj({ 'undo' })
file_row(); apply('s', capture(log, false))
assert(jj({ 'file', 'show', '-r', '@-', 'file' }) == table.concat(source, '\n') .. '\n')
assert(jj({ 'file', 'show', '-r', '@-', 'other' }) == 'other base\n')
print('PASS: file, hunk and added-line operations preserve unselected changes and final-newline semantics')
vim.cmd.cd('/')
vim.fn.delete(dir, 'rf')
vim.cmd.qa({ bang = true })
