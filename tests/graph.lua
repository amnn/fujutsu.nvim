vim.opt.runtimepath:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
local captured
local function jj(_, args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = dir, text = true }):wait()
  assert(r.code == 0, r.stderr)
  for _, arg in ipairs(args) do if arg:find('\30ENTRY', 1, true) then captured = r.stdout end end
  return r.stdout
end
local function run(args) return jj(dir, args) end
run({ 'git', 'init' }); run({ 'config', 'set', '--repo', 'user.name', 'Test' })
run({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'base' }, dir .. '/one'); vim.fn.writefile({ 'base' }, dir .. '/two')
run({ 'describe', '-m', 'base' }); run({ 'bookmark', 'create', 'base' })
run({ 'new', '-m', 'left' }); vim.fn.writefile({ 'left' }, dir .. '/one'); vim.fn.delete(dir .. '/two')
run({ 'bookmark', 'create', 'left' })
run({ 'new', 'base', '-m', 'right' }); vim.fn.writefile({ 'right' }, dir .. '/three')
run({ 'bookmark', 'create', 'right' }); run({ 'new', 'left', 'right', '-m', 'merge' })
run({ 'config', 'set', '--repo', 'templates.log', vim.json.encode('description.first_line() ++ "\\n"') })
local log = require('fujutsu.log').new(dir, jj); log.query = 'all()'
local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_set_current_buf(buf)
local transitions = 0
local function check()
  log.refresh(buf)
  local displayed = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for line in captured:gmatch('[^\n]+') do
    if line:find('\30END\31', 1, true) or line:find('\30DIFF\31', 1, true) then
      local graph = line:gsub('\30.-\31', '')
      local edges = graph:gsub('│', ''):gsub('[|:%s]', '')
      if edges ~= '' then
        transitions = transitions + 1
        assert(vim.tbl_contains(displayed, graph), 'Graph transition lost: ' .. graph)
      end
    end
  end
end
check()
vim.api.nvim_win_set_cursor(0, { 1, 0 }); log.toggle_all(buf); check()
local files = 0
for _, row in pairs(log.rows) do if row.path then files = files + 1 end end
assert(files > 0)
-- A one-line deletion must use five red squares, not magnitude-based blanks.
local ns = require('fujutsu.ansi').namespace
local deleted
for i, row in pairs(log.rows) do if row.status == 'D' then deleted = i; break end end
assert(deleted)
local red = false
local text = vim.api.nvim_buf_get_lines(buf, deleted - 1, deleted, false)[1]
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { deleted - 1, 0 }, { deleted - 1, -1 }, { details = true })) do
  if mark[4].hl_group == 'FujutsuStatDelete' and text:sub(mark[3] + 1, mark[4].end_col) == '■■■■■' then red = true end
end
assert(red)
local left = vim.trim(run({ 'log', '--no-graph', '-r', 'left', '-T', 'commit_id' }))
log.focus(left); log.toggle_all(buf); check()
local hunks = 0
for _, row in pairs(log.rows) do if row.hunk and row.entry.id == left then hunks = hunks + 1 end end
assert(hunks == 2)
log.focus(left); log.toggle_all(buf); check()
for _, row in pairs(log.rows) do assert(not (row.hunk and row.entry.id == left)) end
vim.api.nvim_win_set_cursor(0, { 1, 0 }); log.toggle_all(buf); check()
for _, row in pairs(log.rows) do assert(not row.path) end
assert(transitions > 0, 'Fixture must exercise graph transitions sharing sentinel rows')
run({ 'config', 'unset', '--repo', 'templates.log' }); check()
print('PASS: merge/fork transitions survive expansion; group toggles and proportional stat boxes')
vim.fn.delete(dir, 'rf'); vim.cmd.qa({ bang = true })
