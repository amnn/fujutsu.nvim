-- Real input pauses beyond timeoutlen; complete feedkeys cannot test this.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
local file = require('fujutsu.file')
local function jj(args) return vim.trim(file.jj(dir, args)) end
jj({ 'git', 'init' }); jj({ 'config', 'set', '--repo', 'revsets.log', 'all()' }); jj({ 'describe', '-m', 'source' }); vim.fn.writefile({ 'source' }, dir .. '/source')
jj({ 'bookmark', 'create', 'source' }); jj({ 'new', 'root()', '-m', 'destination' }); jj({ 'bookmark', 'create', 'destination' })
local baseline = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '--headless', '-u', 'NONE', '-i', 'NONE' }, { rpc = true })
local function lua(code, ...) return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... }) end
local function input(text) vim.rpcrequest(child, 'nvim_input', text) end
local wk = vim.env.FUJUTSU_WHICH_KEY
lua([=[
  local repo, runtime, wk, triggers = ...
  if wk == vim.NIL then wk = nil end
  vim.opt.runtimepath:prepend(runtime)
  vim.o.timeoutlen = 120
  notices = {}; vim.notify = function(text, level) notices[#notices + 1] = { text, level } end
  vim.notify_once = vim.notify
  local echo = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, ...)
    for _, chunk in ipairs(chunks) do
      if chunk[2] == 'ErrorMsg' or chunk[2] == 'WarningMsg' then
        notices[#notices + 1] = { chunk[1], vim.log.levels.WARN }
      end
    end
    return echo(chunks, ...)
  end
  wk_load_attempts = 0
  popup_count, rebase_popup = 0, false
  local floating = {}
  local function observe(buf)
    if floating[buf] and vim.fn.mode(1):sub(1, 2) == 'no' then
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      if text:find('Rebase ', 1, true) then rebase_popup = true end
    end
  end
  local open_win, set_lines = vim.api.nvim_open_win, vim.api.nvim_buf_set_lines
  vim.api.nvim_open_win = function(buf, enter, config)
    local win = open_win(buf, enter, config)
    if config.relative and config.relative ~= '' then
      popup_count = popup_count + 1; floating[buf] = true; observe(buf)
    end
    return win
  end
  vim.api.nvim_buf_set_lines = function(buf, ...)
    set_lines(buf, ...); observe(buf)
  end
  if wk then
    vim.opt.runtimepath:prepend(wk)
    local opts = { delay = 10 }
    if triggers then opts.triggers = { { '<auto>', mode = 'nxso' }, { 'r', mode = {'n', 'x'} }, { 'R', mode = {'n', 'x'} } } end
    require('which-key').setup(opts)
  else
    package.preload['which-key'] = function()
      wk_load_attempts = wk_load_attempts + 1
      error('Fujutsu must not load which-key')
    end
  end
  vim.cmd.runtime('plugin/fujutsu.lua'); vim.cmd.cd(repo); vim.cmd("J log -r 'all()'")
  original_calls = 0
  _G.original_operator = function() original_calls = original_calls + 1 end
  vim.go.operatorfunc = 'v:lua.original_operator'
  vim.keymap.set('n', 'rbo', function() error('Global mapping intercepted rebase') end)
  vim.keymap.set('o', 'boa', function() error('Longer motion intercepted rebase') end)
  user_motion = function() return 'l' end
  vim.keymap.set('o', 'bo', user_motion, { buffer = true, expr = true, desc = 'User motion' })
  function restored()
    return vim.go.operatorfunc == 'v:lua.original_operator'
      and vim.fn.maparg('bo', 'o', false, true).callback == user_motion
      and vim.fn.maparg('so', 'o') == ''
  end
  local runner = require('fujutsu.runner'); local run = runner.run
  runner.run = function(...) last_job = run(...); return last_job end
  function prepare(upper)
    last_job = nil; vim.v.errmsg = ''; notices = {}; popup_count = 0; rebase_popup = false
    local log = require('fujutsu').log(); log.refresh(vim.api.nvim_get_current_buf())
    log.focus(require('fujutsu.file').resolve(repo, upper and 'destination' or 'source'))
    vim.fn.setreg('a', upper and 'source' or 'destination')
    vim.fn.setreg('"', 'not-a-revision') -- Losing the explicit register must fail.
  end
]=], dir, vim.fn.getcwd(), wk, vim.env.FUJUTSU_WHICH_KEY_TRIGGERS == '1')
local function pause() vim.wait(450, function() return false end, 10) end
local function no_error()
  assert(lua('return vim.v.errmsg') == '', lua('return vim.v.errmsg'))
  assert(lua('return wk_load_attempts') == 0, 'Fujutsu must not probe/load which-key')
  for _, notice in ipairs(lua('return notices')) do
    assert(not notice[2] or notice[2] < vim.log.levels.WARN, vim.inspect(notice))
  end
end
local function test()
  -- Real command-line input, including retry defaults and Escape semantics.
  lua('vim.api.nvim_win_set_cursor(0, {1, 0})')
  local windows = lua('return #vim.api.nvim_tabpage_list_wins(0)')
  input('<CR>'); pause()
  assert(lua('return vim.fn.mode()') == 'c')
  assert(lua('return #vim.api.nvim_tabpage_list_wins(0)') == windows)
  input('<C-U>invalid(<CR>'); pause()
  assert(lua('return vim.fn.getcmdline()') == 'invalid(')
  input('<C-U>all()<CR>'); pause()
  assert(lua('return require("fujutsu").log().query') == 'all()')
  input('<CR>'); pause(); input('<C-U>root()<Esc>'); pause()
  assert(lua('return require("fujutsu").log().query') == 'all()')
  input('<CR>'); pause(); input('<C-U><CR>'); pause()
  assert(lua('return require("fujutsu").log().query') == '')
  assert(lua('return require("fujutsu").log().effective_query') == 'all()')
  assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == baseline)
  print('PASS: real command-line query input, retry, Escape, empty default and unchanged history')
  for _, sequence in ipairs({ 'R', 'Rb', 'Rs', 'Rr', 'r', 'rb', 'rs', 'rr', 'VR', 'Vr' }) do
    local visual = sequence:sub(1, 1) == 'V'
    local prefix = visual and sequence:sub(2) or sequence
    lua('prepare(...)', prefix:sub(1, 1) == 'R')
    input((visual and 'V' or '') .. '"a' .. prefix); pause()
    if not wk then
      local mode = vim.rpcrequest(child, 'nvim_get_mode') -- fast API, safe during pending input
      if #prefix == 1 then assert(mode.mode:sub(1, 2) == 'no', 'Rebase must wait as a native operator') end
    end
    -- Do not issue blocking exec_lua RPCs inside a UI-owned getchar loop.
    input('<Esc>'); pause(); no_error()
    if wk then
      assert(lua('return require("which-key.state").state == nil'))
      if #prefix == 1 then assert(lua('return popup_count > 0 and rebase_popup'), 'which-key must display rebase choices: ' .. sequence) end
    end
    assert(lua('return restored()'), 'Cancellation must restore operatorfunc and user mappings')
    assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == baseline)
  end
  for _, sequence in ipairs({ 'R', 'Rb', 'Rs', 'Rr', 'r', 'rb', 'rs', 'rr', 'VR', 'Vr' }) do
    local visual = sequence:sub(1, 1) == 'V'
    local prefix = visual and sequence:sub(2) or sequence
    local upper = prefix:sub(1, 1) == 'R'
    lua('prepare(...)', upper)
    if visual then input('V'); pause() end -- Also exercise an already active Visual UI.
    local start = '"a' .. prefix
    if wk then
      input('"a' .. prefix:sub(1, 1)); pause()
      if #prefix > 1 then input(prefix:sub(2)); pause() end
      input(#prefix == 1 and 'ro' or 'o')
    else input(start .. (#prefix == 1 and 'ro' or 'o')) end
    assert(vim.wait(10000, function() return lua('return last_job ~= nil and last_job.result ~= nil') end, 20),
      sequence .. ': ' .. vim.inspect(lua('return { notices, vim.fn.mode(1), vim.v.errmsg, vim.go.operatorfunc }')))
    assert(lua('return last_job.result.code') == 0, vim.inspect(lua('return last_job.result')))
    no_error()
    assert(lua('return restored()'), 'Completion must restore operatorfunc and user mappings')
    if wk then assert(lua('return popup_count > 0 and rebase_popup'), 'Continuation must follow a real rebase popup') end
    assert(jj({ 'log', '--no-graph', '-r', 'parents(source)', '-T', 'commit_id' })
      == jj({ 'log', '--no-graph', '-r', 'destination', '-T', 'commit_id' }))
    jj({ 'op', 'restore', baseline })
    -- restore itself creates an operation: subsequent checks use current head.
    baseline = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
    -- jj 0.44 rejects recreating an identical rewritten commit in the same second.
    vim.wait(1100, function() return false end, 20)
  end
  -- Ctrl-C can dismiss a keymap UI without leaving the native operator;
  -- Escape then cancels that operator, just as for other Vim operators.
  for _, ending in ipairs({ '<C-c>', 'w' }) do
    lua('prepare(true)'); input('"aR'); pause(); input(ending); pause()
    if ending == '<C-c>' then input('<Esc>'); pause() end
    no_error(); assert(lua('return restored() and last_job == nil'), ending .. ': ' .. lua('return vim.inspect({ vim.fn.mode(1), vim.go.operatorfunc, vim.fn.maparg("bo", "o", false, true), last_job })'))
    assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == baseline, 'History changed after ' .. ending)
  end
  lua([[vim.cmd.normal({ args = { 'g@l' }, bang = true })]])
  assert(lua('return original_calls') == 1, 'Restore the user operator')
  input('yy'); pause()
  assert(lua([=[return vim.fn.getreg('"') == vim.api.nvim_get_current_line() .. '\n']=]), 'Preserve native yanks')
  lua('prepare(true)'); input('qm"aRroq'); pause()
  assert(vim.wait(10000, function() return lua('return last_job ~= nil and last_job.result ~= nil') end, 20))
  assert(lua('return last_job.result.code == 0 and restored()'))
  assert(lua('return vim.fn.getreg("m")') == '"aRro', 'Record physical keys, not internal dispatch')
  jj({ 'op', 'restore', baseline }); vim.wait(1100, function() return false end, 20)
  lua('prepare(true)'); input('@m'); pause()
  assert(vim.wait(10000, function() return lua('return last_job ~= nil and last_job.result ~= nil') end, 20))
  assert(lua('return last_job.result.code == 0 and restored()')); no_error()
  -- A register-prefixed Visual squash is a complete single-key action, not
  -- an incomplete rebase prefix. Exercise the actual operation through the UI.
  lua('prepare(false)'); input('V'); pause(); input('"'); pause(); input('a'); pause(); input('s'); pause()
  assert(vim.wait(10000, function() return lua('return last_job ~= nil and (last_job.editor ~= nil or last_job.result ~= nil)') end, 20))
  assert(lua('return last_job.editor ~= nil'), vim.inspect(lua('return notices')))
  lua([=[
    vim.api.nvim_buf_set_lines(last_job.editor, 0, -1, false, {'combined description'})
    vim.api.nvim_buf_call(last_job.editor, function() vim.cmd.write() end)
    vim.api.nvim_buf_delete(last_job.editor, {})
  ]=])
  assert(vim.wait(10000, function() return lua('return last_job.result ~= nil') end, 20))
  assert(lua('return last_job.result.code == 0 and restored()')); no_error()
  assert(jj({ 'file', 'show', '-r', 'destination', 'source' }) == 'source')
  print('PASS: real Visual "as preserves the registered destination with a paused register picker')
end
local ok, err = xpcall(test, debug.traceback)
vim.fn.jobstop(child); vim.fn.delete(dir, 'rf')
assert(ok, err)
print('PASS: real paused r/R prefixes, cancellation, full sequences and explicit registers' .. (wk and ' with which-key' or ' without which-key'))
vim.cmd.qa({ bang = true })
