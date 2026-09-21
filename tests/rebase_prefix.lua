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
  wk_load_attempts = 0
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
  local runner = require('fujutsu.runner'); local run = runner.run
  runner.run = function(...) last_job = run(...); return last_job end
  function prepare(upper)
    last_job = nil; vim.v.errmsg = ''; notices = {}
    local log = require('fujutsu').log(); log.refresh(vim.api.nvim_get_current_buf())
    log.focus(require('fujutsu.file').resolve(repo, upper and 'destination' or 'source'))
    vim.fn.setreg('a', upper and 'source' or 'destination')
    vim.fn.setreg('"', 'not-a-revision') -- Losing the explicit register must fail.
  end
]=], dir, vim.fn.getcwd(), wk, vim.env.FUJUTSU_WHICH_KEY_TRIGGERS ~= nil)
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
  for _, sequence in ipairs({ 'R', 'Rr', 'r', 'rr', 'VR', 'Vr' }) do
    local visual = sequence:sub(1, 1) == 'V'
    local prefix = visual and sequence:sub(2) or sequence
    lua('prepare(...)', prefix:sub(1, 1) == 'R')
    input((visual and 'V' or '') .. '"a' .. prefix); pause()
    if not wk then
      local mode = vim.rpcrequest(child, 'nvim_get_mode') -- fast API, safe during pending input
      assert(mode.mode == (visual and 'V' or 'n') and not mode.blocking,
        'Timed-out prefixes must cancel without entering native replace commands')
    end
    -- Do not issue blocking exec_lua RPCs inside a UI-owned getchar loop.
    input('<Esc>'); pause(); no_error()
    if wk then assert(lua('return require("which-key.state").state == nil')) end
    assert(jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }) == baseline)
  end
  for _, sequence in ipairs({ 'R', 'Rr', 'r', 'rr', 'VR', 'Vr' }) do
    local visual = sequence:sub(1, 1) == 'V'
    local prefix = visual and sequence:sub(2) or sequence
    local upper = prefix:sub(1, 1) == 'R'
    lua('prepare(...)', upper)
    local start = (visual and 'V' or '') .. '"a' .. prefix
    input(start .. (#prefix == 1 and 'ro' or 'o'))
    assert(vim.wait(10000, function() return lua('return last_job ~= nil and last_job.result ~= nil') end, 20),
      vim.inspect(lua('return notices')))
    assert(lua('return last_job.result.code') == 0, vim.inspect(lua('return last_job.result')))
    no_error()
    assert(jj({ 'log', '--no-graph', '-r', 'parents(source)', '-T', 'commit_id' })
      == jj({ 'log', '--no-graph', '-r', 'destination', '-T', 'commit_id' }))
    jj({ 'op', 'restore', baseline })
    -- restore itself creates an operation: subsequent checks use current head.
    baseline = jj({ 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' })
    -- jj 0.44 rejects recreating an identical rewritten commit in the same second.
    vim.wait(1100, function() return false end, 20)
  end
end
local ok, err = xpcall(test, debug.traceback)
vim.fn.jobstop(child); vim.fn.delete(dir, 'rf')
assert(ok, err)
print('PASS: real paused r/R prefixes, cancellation, full sequences and explicit registers' .. (wk and ' with which-key' or ' without which-key'))
vim.cmd.qa({ bang = true })
