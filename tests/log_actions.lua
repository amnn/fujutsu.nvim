vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local surrounded = false
vim.keymap.set('n', 'ds', function() surrounded = true end, { desc = 'Simulated nvim-surround mapping' })
local tmp = vim.fn.tempname()
local function run(args)
  local r = vim.system(vim.list_extend({ 'jj', '--no-pager', '--color=never' }, args), { cwd = tmp, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end
vim.fn.mkdir(tmp, 'p'); run({ 'git', 'init' })
run({ 'config', 'set', '--repo', 'user.name', 'Test' })
run({ 'config', 'set', '--repo', 'user.email', 'test@example.com' })
run({ 'describe', '-m', 'source' })
vim.fn.writefile({ 'hello' }, tmp .. '/file')
local id = run({ 'log', '--no-graph', '-r', '@', '-T', 'change_id' })
vim.cmd.cd(tmp); vim.cmd.J()
local buf = vim.api.nvim_get_current_buf()
local log = require('fujutsu').log(buf)
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function find(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(text, 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }); return i end
  end
  error('Missing row: ' .. text)
end
local function mark_token(name)
  local row = find('Marks:')
  for _, token in ipairs(log.tokens) do
    if token.register == name then vim.api.nvim_win_set_cursor(0, { row, token.first }); return end
  end
  error('Missing mark token')
end
keys('ggg@')
assert(log.rows[vim.fn.line('.')].working_copy)
assert(vim.fn.maparg('@', 'n') == '')
find('source'); keys('m')
assert(vim.fn.getreg('"') == log.catalog.short[id])
find('source'); keys('"am'); keys('"aM')
local header = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
assert(header == 'Marks: "a', header)
mark_token('a'); keys('<CR>')
assert(log.pinned == 'a')
find('source'); keys('M')
assert(log.preview == nil, 'Modifying the pinned mark must not flash its highlight')
find('source'); keys('"adm')
assert(vim.fn.getreg('a') == '' and log.pinned == nil)
find('source'); keys('yy')
assert(not require('fujutsu.marks').get('"', log.catalog))
vim.wait(50, function() return false end)
assert(not require('fujutsu.marks').linked())
-- Both overlays survive; the preview register replaces the pinned identifier
-- where they overlap. Header and gutter use the same highlight groups.
find('source'); keys('"am'); mark_token('a'); keys('<CR>')
find('source'); keys('"bm')
local ns = vim.api.nvim_create_namespace('fujutsu.marks')
local signs = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
local previewed = false
for _, mark in ipairs(signs) do
  if mark[4].sign_text == 'b ' then assert(mark[4].sign_hl_group == 'FujutsuMarkPreview'); previewed = true end
end
assert(previewed)
assert(vim.fn.maparg('d', 'n') == '' and vim.fn.maparg('dm', 'n') ~= '')
keys('ds'); assert(surrounded, 'dm must coexist with surround commands')
print('PASS: compact marks, alias sigils, Enter pinning, dm, weak links and preview precedence')
local commands = require('fujutsu.commands')
assert(vim.deep_equal(commands.argv([[rebase -r 'foo | bar' -o "main"]]), { 'rebase', '-r', 'foo | bar', '-o', 'main' }))
local input = vim.fn.input
local answers = { 'invalid(', '@' }
vim.fn.input = function() return table.remove(answers, 1) end
find('Query:'); keys('<CR>')
vim.fn.input = input
assert(vim.api.nvim_get_current_buf() == buf and vim.b[buf].fujutsu_query == '@')
assert(#answers == 0, 'Invalid query should be offered for correction')
-- Mark contents persist globally, but root is no longer in this buffer's scope.
vim.fn.setreg('c', string.rep('z', 8)); log.refresh(buf)
assert(not log.marks.c)
local query_before = log.query
vim.fn.input = function() return '\27' end
find('Query:'); keys('<CR>'); vim.fn.input = input
assert(log.query == query_before)
local job = commands.execute({ args = 'describe -r @ -m "command description"' })
assert(vim.wait(10000, function() return job.result ~= nil end, 20)); assert(job.result.code == 0, job.result.stderr)
assert(run({ 'log', '--no-graph', '-r', '@', '-T', 'description' }) == 'command description')
vim.cmd([[J log -r '@']]); assert(vim.api.nvim_get_current_buf() == buf)
vim.cmd([[J log -r '@ | root()']])
assert(vim.api.nvim_get_current_buf() ~= buf)
local other = vim.api.nvim_get_current_buf()
assert(require('fujutsu').log(other).marks.c)
local name = vim.api.nvim_buf_get_name(0)
assert(name:find('/log/?revset=', 1, true) and not name:find('%%7B'))
vim.cmd.bwipeout(); vim.cmd.edit(vim.fn.fnameescape(name))
assert(vim.b.fujutsu_query == '@ | root()')
buf = require('fujutsu').change_query(buf, '')
log = require('fujutsu').log(buf)
run({ 'config', 'set', '--repo', 'revsets.log', 'root()' })
log.refresh(buf)
assert(log.query == '' and log.effective_query == 'root()')
local cursor = vim.api.nvim_win_get_cursor(0)
log.head(buf)
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(0)) and log.query == '')
local uri = require('fujutsu.uri')
local root = '/tmp/repo?x#y%20'
local parsed = uri.parse(uri.log_name(root, 'bookmarks("a/b")', '12'))
assert(parsed.root == root and parsed.query == 'bookmarks("a/b")' and parsed.limit == '12')
local file_name = uri.name(root, 'file', string.rep('a', 40), 'a?x#y%20.txt')
assert(uri.parse(file_name).path == 'a?x#y%20.txt' and uri.parse(file_name).root == root)
assert(uri.parse(uri.name(root, 'tree', string.rep('a', 40), 'sub/log/')).kind == 'tree')
print('PASS: command-line queries, validation retry, buffer identity, scoped marks, defaults and readable URIs')
vim.cmd.cd('/'); vim.fn.delete(tmp, 'rf'); vim.cmd.qa({ bang = true })
