vim.opt.runtimepath:prepend(vim.fn.getcwd())
local d = require('fujutsu.diagnostics')
local messages = {}
vim.notify = function(text, level) messages[#messages + 1] = { text, level } end
vim.o.columns = 120
local function history() return vim.api.nvim_exec2('messages', { output = true }).output end
local raw = '/checkout with spaces/lua/fujutsu/actions.lua:34: Register b is not a valid revision mark'
d.error(raw)
assert(history():find('Register b is not a valid revision mark', 1, true))
assert(not history():find('actions.lua:', 1, true))
for _, native in ipairs({ 'Error: Failed to parse revset: Syntax error', 'Error: failed to read /tmp/config.lua:42: missing' }) do
  d.error('\27[31m' .. native .. '\27[0m')
  assert(history():find(native, 1, true))
end
local function summary(command, output, expected, code, level)
  local text, severity = d.summary(command, { stderr = output, code = code or 0 }, false)
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
  'jj split: extracted selected; remaining remaining')
summary('squash', 'Created new commit selected 01234567 title\n', 'jj squash: created selected')
summary('rebase', 'Working copy  (@) now at: source 01234567 title\nWarning: unresolved conflicts\n',
  'jj rebase: Warning: unresolved conflicts', nil, vim.log.levels.WARN)
summary('rebase', 'There are new conflicts in these commits:\n',
  'jj rebase: There are new conflicts in these commits:', nil, vim.log.levels.WARN)
summary('status', 'The working copy has no changes.\n', 'jj status: The working copy has no changes.')
local failure = 'Warning: prior warning\nError: immutable revision\nCaused by:\n    nested cause\nHint: how to fix it\n'
d.failure({ code = 1, stderr = failure, stdout = 'additional stdout detail' }, 'rebase')
assert(history():find(failure, 1, true) and history():find('additional stdout detail', 1, true))
assert(not history():find('checkhealth', 1, true))
assert(#messages == 0, 'Failures must not depend on the notification provider')
local text, level = d.summary('squash', { code = 1, stderr = 'editor failed' }, true)
assert(text == 'jj squash: cancelled' and level == vim.log.levels.INFO)
vim.o.columns = 65
d.notice('jj status: ' .. string.rep('界', 100))
local line = messages[#messages][1]
assert(not line:find('[\r\n]') and vim.fn.strdisplaywidth(line) <= 53)
local echo, captured = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks, keep, opts)
  assert(keep and not opts.err and chunks[1][2] == 'ErrorMsg')
  captured = chunks[1][1]
end
local large = '/native/editor.lua:4: failure\n' .. string.rep('界', 14000) .. '\nlast line'
d.failure({ code = 1, stderr = large }, 'split')
assert(captured == large, 'Native failure must not lose locations, lines or bytes')
d.failure({ code = 3 }, 'split'); assert(captured == 'jj split: failed (exit 3)')
vim.api.nvim_echo = echo
assert(d.workspaces == nil and d.record == nil, 'No private command-output history')
local health, system, executable, has = vim.health, vim.system, vim.fn.executable, vim.fn.has
local reports = {}
vim.health = {}
for _, name in ipairs({ 'start', 'ok', 'error', 'warn' }) do
  vim.health[name] = function(message) reports[#reports + 1] = { name, message } end
end
local available, supported = 1, 1
local version = { code = 0, stdout = 'jj 0.44.0\n' }
vim.fn.executable = function() return available end
vim.fn.has = function() return supported end
vim.system = function() return { wait = function() return version end } end
local function check(kind, text)
  reports = {}; require('jj.health').check()
  assert(reports[#reports][1] == kind and reports[#reports][2]:find(text, 1, true), vim.inspect(reports))
end
check('ok', 'jj 0.44.0')
available = 0; check('error', 'not on PATH'); available = 1
supported = 0; check('error', 'Neovim 0.10'); supported = 1
version = { code = 1, stderr = 'cannot execute jj' }; check('error', 'cannot execute jj')
version = { code = 0, stdout = 'jj 0.43.0' }; check('error', 'jj 0.44 or newer')
version = { code = 0, stdout = '' }; check('warn', 'no version information')
vim.health, vim.system, vim.fn.executable, vim.fn.has = health, system, executable, has
print('PASS: concise summaries, full failures in messages, no command archive and setup-only health checks')
vim.cmd.qa({ bang = true })
