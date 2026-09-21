vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local file, actions, selection = require('fujutsu.file'), require('fujutsu.actions'), require('fujutsu.selection')
local dirs, notices = {}, {}
local notify = vim.notify
vim.notify = function(text, level, opts)
  notices[#notices + 1] = text
  notify(text, level, opts)
end
local function fixture(extra)
  local dir = vim.fn.tempname(); dirs[#dirs + 1] = dir; vim.fn.mkdir(dir, 'p')
  local function jj(args) return vim.trim(file.jj(dir, args)) end
  jj({ 'git', 'init' }); jj({ 'config', 'set', '--repo', 'revsets.log', 'all()' })
  local lines = {}; for i = 1, 30 do lines[i] = 'line ' .. i end
  vim.fn.writefile(lines, dir .. '/file'); jj({ 'describe', '-m', 'base' }); jj({ 'new', '-m', 'source description' })
  lines[2], lines[28] = 'first replacement', 'last replacement'
  vim.fn.writefile(lines, dir .. '/file')
  if extra then vim.fn.writefile({ 'extra' }, dir .. '/extra') end
  jj({ 'bookmark', 'create', 'source' })
  vim.cmd.enew(); vim.cmd.cd(dir); vim.cmd.J()
  return dir, jj, vim.api.nvim_get_current_buf(), require('fujutsu').log()
end
local function run(dir, log, buf, selected, expected)
  local job = actions.squash(log, buf, dir, selected, 'x', '"')
  assert(vim.tbl_contains(job.args, expected), vim.inspect(job.args))
  assert(vim.wait(10000, function() return job.result ~= nil or job.editor ~= nil end, 20))
  if job.editor then vim.cmd.write(); vim.cmd.bdelete() end
  assert(vim.wait(10000, function() return job.result ~= nil end, 20))
  assert(job.result.code == 0, job.result.stderr)
  assert(notices[#notices]:find('jj ' .. expected .. ':', 1, true) == 1, notices[#notices])
  local history = require('fujutsu.diagnostics').workspaces[vim.uv.fs_realpath(dir)]
  assert(history[#history].command:find(' ' .. expected .. ' ', 1, true))
  return job
end
for _, case in ipairs({ 'whole', 'file-all', 'file-part', 'hunk', 'all-lines' }) do
  local partial = case == 'file-part' or case == 'hunk'
  local dir, jj, buf, log = fixture(case == 'file-part')
  local before, change = file.resolve(dir, 'source')
  local original = file.content(dir, before, 'file')
  local start = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
  log.focus(before)
  if case ~= 'whole' then
    for i, row in pairs(log.rows) do
      if row.entry and row.entry.id == before and row.path == 'file' and i == row.first then
        vim.api.nvim_win_set_cursor(0, { i, 0 }); break
      end
    end
    if case == 'hunk' or case == 'all-lines' then log.toggle(buf) end
    if case == 'hunk' then
      for i, row in pairs(log.rows) do if row.patch == '+first replacement' then vim.api.nvim_win_set_cursor(0, { i, 0 }); break end end
    end
  end
  local selected = selection.capture(log, false)
  if case == 'all-lines' then
    local first, last
    for i, row in pairs(log.rows) do
      if row.entry and row.entry.id == before and row.patch then first, last = math.min(first or i, i), math.max(last or i, i) end
    end
    selected = { first = first, last = last, rows = {}, visual = true }
    for i = first, last do selected.rows[i] = vim.deepcopy(log.rows[i]) end
  end
  run(dir, log, buf, selected, partial and 'split' or 'squash')
  if partial then
    local remaining, current_change = file.resolve(dir, 'source')
    assert(current_change == change and remaining ~= before)
    assert(file.content(dir, remaining, 'file') == original)
    assert(jj({ 'log', '--no-graph', '-r', 'source', '-T', 'description' }) == 'source description')
    assert(jj({ 'log', '--no-graph', '-r', 'source-', '-T', 'description' }) == '')
    local parent = file.content(dir, file.resolve(dir, 'source-'), 'file')
    assert(parent:find('first replacement', 1, true))
    if case == 'hunk' then assert(not parent:find('last replacement', 1, true)) end
  else
    assert(file.visible(dir, change) == '', 'Complete extraction must abandon the source')
    assert(jj({ 'log', '--no-graph', '-r', 'source', '-T', 'description' }) == 'source description')
    assert(file.content(dir, file.resolve(dir, 'source'), 'file') == original)
  end
  local previous = jj({ 'op', 'log', '--no-graph', '-n', '2', '-T', 'id ++ "\n"' })
  assert(previous:sub(-#start) == start, 'Extraction must be one operation')
  jj({ 'undo' }); assert(file.resolve(dir, 'source') == before)
  print('PASS: extraction ' .. case .. ', descriptions, identity/bookmarks, abandonment and atomic undo')
end
-- split rejects empty commits; retain the existing native squash behavior.
do
  local dir, jj, buf, log = fixture(false)
  jj({ 'new', '-m', 'empty description' }); jj({ 'bookmark', 'create', 'empty-source' })
  log.refresh(buf)
  local before, change = file.resolve(dir, '@'); log.focus(before)
  run(dir, log, buf, selection.capture(log, false), 'squash')
  assert(file.visible(dir, change) == '')
  assert(jj({ 'log', '--no-graph', '-r', 'empty-source', '-T', 'description' }) == 'empty description')
  jj({ 'undo' }); assert(file.resolve(dir, 'empty-source') == before)
  print('PASS: empty-source extraction retains native squash descriptions and undo')
end
-- Native whole-file metadata through split, with an independent remainder.
do
  local dir, jj, buf, log = fixture(true)
  jj({ 'new', '-m', 'metadata changes' })
  assert(vim.uv.fs_rename(dir .. '/file', dir .. '/renamed'))
  local binary = assert(io.open(dir .. '/binary', 'wb')); binary:write('a\0b'); binary:close()
  assert(vim.uv.fs_symlink('extra', dir .. '/link'))
  vim.fn.writefile({ 'literal path' }, dir .. '/literal [name].txt')
  vim.fn.writefile({ 'remainder' }, dir .. '/extra')
  log.refresh(buf)
  for _, path in ipairs({ 'renamed', 'binary', 'link', 'literal [name].txt' }) do
    local selected
    for i, row in pairs(log.rows) do
      if row.path == path and row.entry and row.entry.working_copy and row.first == i then
        vim.api.nvim_win_set_cursor(0, { i, 0 }); selected = selection.capture(log, false); break
      end
    end
    assert(selected, path); run(dir, log, buf, selected, 'split')
    if path == 'renamed' then
      assert(jj({ 'file', 'list', '-r', '@-' }):find('renamed', 1, true))
      assert(not jj({ 'file', 'list', '-r', '@-' }):match('^file\n'))
    elseif path == 'binary' then assert(file.content(dir, file.resolve(dir, '@-'), path) == 'a\0b')
    elseif path == 'link' then assert(jj({ 'diff', '-r', '@-', '--git' }):find('120000', 1, true))
    else assert(file.content(dir, file.resolve(dir, '@-'), path) == 'literal path\n') end
  end
  print('PASS: split preserves complete rename, binary and symlink selections')
end
-- Selecting every text line still leaves a source when mode metadata remains.
do
  local dir, jj, buf, log = fixture(false)
  assert(vim.uv.fs_chmod(dir .. '/file', 493)) -- 0755
  log.refresh(buf)
  for i, row in pairs(log.rows) do
    if row.path == 'file' and row.entry.working_copy and row.first == i then
      vim.api.nvim_win_set_cursor(0, { i, 0 }); log.toggle(buf); break
    end
  end
  local first, last
  for i, row in pairs(log.rows) do
    if row.entry and row.entry.working_copy and row.patch then first, last = math.min(first or i, i), math.max(last or i, i) end
  end
  local selected = { first = first, last = last, rows = {}, visual = true }
  for i = first, last do selected.rows[i] = vim.deepcopy(log.rows[i]) end
  run(dir, log, buf, selected, 'split')
  assert(jj({ 'diff', '-r', '@', '--git' }):find('new mode 100755', 1, true))
  assert(not jj({ 'diff', '-r', '@-', '--git' }):find('new mode', 1, true))
  assert(jj({ 'diff', '-r', '@-', '--git' }):find('+first replacement', 1, true))
  print('PASS: complete text selection leaves mode metadata in the split remainder')
end
-- Multi-source extraction remains one native squash, not a series of splits.
do
  local dir, jj, buf, log = fixture(false)
  jj({ 'new', 'source-', '-m', 'sibling description' }); vim.fn.writefile({ 'sibling' }, dir .. '/sibling')
  jj({ 'bookmark', 'create', 'sibling' }); log.refresh(buf)
  local a, b = file.resolve(dir, 'source'), file.resolve(dir, 'sibling')
  log.focus(b); log.toggle(buf) -- collapse working-copy stats before selecting commits
  local first, last
  for i, row in pairs(log.rows) do
    if (row.id == a or row.id == b) and row.first == i then first, last = math.min(first or i, i), math.max(last or i, i) end
  end
  local selected = { first = first, last = last, visual = true, rows = {} }
  for i = first, last do selected.rows[i] = vim.deepcopy(log.rows[i]) end
  run(dir, log, buf, selected, 'squash')
  assert(file.resolve(dir, 'source') == file.resolve(dir, 'sibling'))
  local description = jj({ 'log', '--no-graph', '-r', 'source', '-T', 'description' })
  assert(description:find('source description', 1, true) and description:find('sibling description', 1, true))
  jj({ 'undo' }); assert(file.resolve(dir, 'source') == a and file.resolve(dir, 'sibling') == b)
  print('PASS: multi-source extraction preserves combined descriptions and atomic undo')
end
vim.cmd.cd('/'); for _, dir in ipairs(dirs) do vim.fn.delete(dir, 'rf') end
vim.cmd.qa({ bang = true })
