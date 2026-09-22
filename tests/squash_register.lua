vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
local function jj(args)
  local result = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
jj({ 'git', 'init' })
local base = {}
for i = 1, 30 do base[i] = 'line ' .. i end
vim.fn.writefile(base, dir .. '/file'); vim.fn.writefile({ 'old' }, dir .. '/other')
jj({ 'bookmark', 'create', 'base' })
jj({ 'new', 'base' }); vim.fn.writefile({ 'keep target changes' }, dir .. '/target-only')
jj({ 'bookmark', 'create', 'target' })
jj({ 'new', 'base' })
local source = vim.deepcopy(base); source[28] = 'second replacement'
table.insert(source, 3, 'first addition')
vim.fn.writefile(source, dir .. '/file'); vim.fn.writefile({ 'new' }, dir .. '/other')
vim.cmd.cd(dir); vim.cmd([[J log -r 'all()']])
local buf = vim.api.nvim_get_current_buf()
local log = require('fujutsu').log(buf)
local function focus(kind)
  log.refresh(buf)
  for i, row in ipairs(log.rows) do
    if row.path == 'file' and row.entry.working_copy and row.first == i then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      if kind == 'file' then return end
      if not log.files['@'] or not log.files['@'].file then log.toggle(buf) end
      break
    end
  end
  for i, row in ipairs(log.rows) do
    if (kind == 'commit' and row.working_copy and row.first == i)
      or (kind == 'line' and row.patch == '+first addition' and row.entry.working_copy) then
      vim.api.nvim_win_set_cursor(0, { i, 0 }); return
    end
  end
  error('Missing ' .. kind)
end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function perform(text)
  keys(text)
  local job = assert(require('fujutsu.runner').latest(vim.uv.fs_realpath(dir)))
  assert(vim.wait(10000, function() return job.result ~= nil or job.editor ~= nil end, 20))
  assert(not job.editor, 'Empty descriptions should not need an editor')
  return job.result
end
local function content(rev, path) return jj({ 'file', 'show', '-r', rev, path or 'file' }) end
local base_text = table.concat(base, '\n') .. '\n'
for _, scope in ipairs({ 'visual', 'hunk', 'file', 'commit' }) do
  focus((scope == 'visual' or scope == 'hunk') and 'line' or scope)
  vim.fn.setreg('a', 'target')
  local result = perform((scope == 'visual' and 'V' or '') .. '"as')
  assert(result.code == 0, result.stderr)
  local target = content('target')
  assert(target:find('first addition', 1, true))
  assert((target:find('second replacement', 1, true) ~= nil) == (scope == 'file' or scope == 'commit'))
  assert(target:find('line 2\nfirst addition\n', 1, true), target)
  assert(content('base') == base_text, 'Explicit register must not silently target the parent')
  assert(content('target', 'target-only') == 'keep target changes\n')
  assert(content('target', 'other') == (scope == 'commit' and 'new\n' or 'old\n'))
  if scope ~= 'commit' then
    assert(not content('@'):find('first addition', 1, true), 'Selected changes must leave source')
    assert(content('@', 'other') == 'new\n')
  end
  jj({ 'undo' })
  -- These first two scopes select the same change; avoid jj 0.44's identical
  -- rewritten commit rejection within the same timestamp second.
  if scope == 'visual' then vim.wait(1100, function() return false end, 20) end
end
-- A valid unnamed mark does not change the established bare-s parent default.
focus('line'); vim.fn.setreg('"', 'target')
assert(perform('s').code == 0)
assert(content('base'):find('first addition', 1, true))
assert(content('target') == content('base'), 'Descendants inherit the rewritten parent normally')
jj({ 'undo' })
-- Let jj enforce the single-destination requirement; never choose a subset.
focus('commit'); vim.fn.setreg('a', 'base | target')
local before = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
assert(perform('"as').code ~= 0)
assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == before)
focus('commit'); vim.fn.setreg('a', 'not-a-mark')
vim.cmd('messages clear'); keys('"as')
assert(vim.api.nvim_exec2('messages', { output = true }).output:find('not a valid revision mark', 1, true))
assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == before)
print('PASS: registered squash destinations for commits/files/hunks/Visual lines, parent default and invalid destinations')
vim.cmd.cd('/'); vim.fn.delete(dir, 'rf'); vim.cmd.qa({ bang = true })
