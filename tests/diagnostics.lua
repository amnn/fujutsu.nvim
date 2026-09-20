vim.opt.runtimepath:prepend(vim.fn.getcwd())
local d = require('fujutsu.diagnostics')
local messages = {}
vim.notify = function(text, level) messages[#messages + 1] = { text, level } end
vim.o.columns = 120
local root = '/unused/fujutsu-tests'
local raw = '/checkout with spaces/lua/fujutsu/actions.lua:34: Register b is not a valid revision mark'
d.error(raw, root)
assert(messages[#messages][1] == 'Register b is not a valid revision mark (:checkhealth jj)')
assert(d.workspaces[root][1].stderr == raw)
for _, native in ipairs({ 'Error: Failed to parse revset: Syntax error', 'Error: failed to read /tmp/config.lua:42: missing' }) do
  d.error('\27[31m' .. native .. '\27[0m', root)
  assert(messages[#messages][1] == native .. ' (:checkhealth jj)')
end
local function summary(command, output, expected, code, level, label)
  local text, severity = d.summary(command, { stderr = output, code = code or 0 }, false, label)
  assert(text == expected, text)
  assert(severity == (level or vim.log.levels.INFO))
end
summary('new', 'Working copy  (@) now at: abcd1234 01234567 (empty) (no description set)\nParent commit (@-) : parent\n',
  'jj new: @ abcd1234')
summary('new', 'Created new commit abcd1234 01234567 (empty)\n', 'jj new: created abcd1234')
summary('edit', 'Working copy  (@) now at: source 01234567 title\n', 'jj edit: @ source')
summary('rebase', 'Rebased 2 commits onto destination\nWorking copy  (@) now at: source 01234567 title\n',
  'jj rebase: Rebased 2 commits onto destination; @ source')
summary('undo', 'Undid operation: abcd12345678 (date) old operation\nRestored to operation: 999999\n', 'jj undo: undid abcd12345678')
summary('redo', 'Redid operation: abcd12345678 (date) old operation\n', 'jj redo: redid abcd12345678')
summary('split', 'Selected changes : selected 01234567 title\nRemaining changes: remaining 76543210 title\n',
  'Extract: extracted selected; remaining remaining', nil, nil, 'Extract')
summary('squash', 'Created new commit selected 01234567 title\n', 'Extract: created selected', nil, nil, 'Extract')
summary('rebase', 'Working copy  (@) now at: source 01234567 title\nWarning: unresolved conflicts\n',
  'jj rebase: Warning: unresolved conflicts (:checkhealth jj)', nil, vim.log.levels.WARN)
summary('rebase', 'There are new conflicts in these commits:\n',
  'jj rebase: There are new conflicts in these commits: (:checkhealth jj)', nil, vim.log.levels.WARN)
summary('status', 'The working copy has no changes.\n', 'jj status: The working copy has no changes.')
summary('rebase', 'Error: immutable revision\nlong detail\n', 'jj rebase: Error: immutable revision (:checkhealth jj)', 1, vim.log.levels.ERROR)
summary('rebase', 'Warning: other warning\nError: immutable revision\n', 'jj rebase: Error: immutable revision (:checkhealth jj)', 1, vim.log.levels.ERROR)
local text, level = d.summary('squash', { code = 1, stderr = 'editor failed' }, true)
assert(text == 'jj squash: cancelled' and level == vim.log.levels.INFO)
vim.o.columns = 65
d.error('/checkout/lua/fujutsu/runner.lua:12: Save or discard unsaved workspace buffer first: ' .. string.rep('界', 100), root)
local line = messages[#messages][1]
assert(not line:find('[\r\n]') and vim.fn.strdisplaywidth(line) <= 53)
assert(line:find('… (:checkhealth jj)', 1, true), line)
for i = 1, 40 do d.record(root, { stderr = string.rep('x', 40000), command = tostring(i) }) end
assert(#d.workspaces[root] == 30 and #d.workspaces[root][1].stderr < 33000)
print('PASS: clean Lua/native errors, action-aware native summaries, warning/error precedence, width and bounded full diagnostics')
vim.cmd.qa({ bang = true })
