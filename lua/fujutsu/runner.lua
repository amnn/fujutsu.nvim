-- Each asynchronous jj process owns its editor handshakes. There is no
-- repository lock: concurrent operations retain native jj semantics.
local M = { jobs = {}, serial = 0 }
local diagnostics = require('fujutsu.diagnostics')

function M.guard(root)
  root = vim.uv.fs_realpath(root) or root
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      local real = vim.uv.fs_realpath(name) or name
      assert(real:sub(1, #root + 1) ~= root .. '/', 'Save or discard unsaved workspace buffer first: ' .. name)
    end
  end
end

function M.latest(root)
  root = vim.uv.fs_realpath(root) or root
  local found
  for _, job in pairs(M.jobs) do
    if job.root == root and (not found or job.id > found.id) then found = job end
  end
  return found
end

local function verb(args)
  local i = 1
  while args[i] and args[i]:sub(1, 1) == '-' do
    local arg = args[i]
    if arg == '--config' or arg == '--config-file' or arg == '-R' or arg == '--repository'
      or arg == '--at-op' or arg == '--at-operation' then i = i + 1 end
    i = i + 1
  end
  return args[i], args[i + 1]
end

function M.needs_guard(args)
  if vim.tbl_contains(args, '--ignore-working-copy') then return false end
  local cmd, sub = verb(args)
  if vim.tbl_contains(args, '--help') or vim.tbl_contains(args, '-h') or vim.tbl_contains(args, '--version') then return false end
  if ({ log = true, diff = true, show = true, status = true, st = true,
    describe = true, config = true, help = true, version = true })[cmd] then return false end
  if (cmd == 'file' and (sub == 'list' or sub == 'show')) or (cmd == 'op' and sub == 'log')
    or (cmd == 'bookmark' and sub == 'list') then return false end
  return true
end

function M.run(root, args, opts)
  opts = opts or {}
  root = vim.uv.fs_realpath(root) or root
  local guarded = M.needs_guard(args)
  if guarded then M.guard(root) end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local script = [[#!/bin/sh
set -eu
dir=$1
shift
printf '%s\n%s' "$$" "$1" > "$dir/request.tmp"
mv "$dir/request.tmp" "$dir/request"
while [ ! -f "$dir/done" ] && [ ! -f "$dir/cancel" ]; do
  # Do not strand a helper if Neovim exits without running its cleanup hook.
  kill -0 "$FUJUTSU_EDITOR_PID" 2>/dev/null || exit 1
  sleep 0.05
done
[ ! -f "$dir/cancel" ] || exit 1
rm -f "$dir/done" "$dir/request"
]]
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), dir .. '/editor.sh')
  local command = { 'jj', '--no-pager', '--color=never', '--config',
    'ui.editor=' .. vim.json.encode({ '/bin/sh', dir .. '/editor.sh', dir }) }
  vim.list_extend(command, args)
  M.serial = M.serial + 1
  local job = { id = M.serial, dir = dir, root = root, args = args, cleanup = opts.cleanup }
  M.jobs[job.id] = job
  local timer = assert(vim.uv.new_timer())
  local function cancel()
    if M.jobs[job.id] then
      job.cancelled = true
      vim.fn.writefile({ 'cancel' }, dir .. '/cancel')
    end
  end
  local function open_editor()
    if (job.editor and vim.api.nvim_buf_is_valid(job.editor)) or not vim.uv.fs_stat(dir .. '/request') then return end
    local request = vim.fn.readfile(dir .. '/request')
    local serial = table.remove(request, 1)
    if job.request == serial then return end
    job.request = serial
    local path = table.concat(request, '\n')
    local buf = vim.api.nvim_create_buf(false, true)
    job.editor = buf
    vim.api.nvim_buf_set_name(buf, 'fujutsu-description://' .. buf)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'acwrite', 'wipe'
    vim.bo[buf].swapfile, vim.bo[buf].filetype = false, 'gitcommit'
    local lines = vim.fn.readfile(path)
    vim.list_extend(lines, { '', 'JJ: Save and close (:wq) to continue this operation.',
      'JJ: :write saves a draft; normal-mode Escape cancels this operation.' })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.b[buf].fujutsu_repo = root
    vim.cmd.sbuffer(buf)
    local saved, cancelled = false, false
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      if guarded then M.guard(root) end
      vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
      saved = true
      vim.bo[buf].modified = false
    end })
    vim.keymap.set('n', '<Esc>', function()
      cancelled = true
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, desc = 'Cancel this jj editor' })
    vim.api.nvim_create_autocmd('BufUnload', { buffer = buf, once = true, callback = function()
      if not M.jobs[job.id] then return end
      if saved and not cancelled then
        local ok, err = pcall(function() if guarded then M.guard(root) end end)
        if ok then vim.fn.writefile({ 'done' }, dir .. '/done')
        else cancel(); diagnostics.error(err, root) end
      else cancel() end
    end })
  end
  timer:start(0, 50, vim.schedule_wrap(function()
    if M.jobs[job.id] then
      local ok, err = pcall(open_editor)
      if not ok then cancel(); diagnostics.error(err, root) end
    end
  end))
  local function finish(result)
    timer:stop(); timer:close()
    M.jobs[job.id] = nil
    vim.fn.delete(dir, 'rf')
    if job.cleanup then job.cleanup() end
    job.result = result
    if job.editor and vim.api.nvim_buf_is_valid(job.editor) then vim.api.nvim_buf_delete(job.editor, { force = true }) end
    require('fujutsu').invalidate(root)
    require('fujutsu.status').repository_changed(root)
    local ok, err = pcall(function()
      vim.cmd('checktime')
      require('fujutsu').refresh_root(root)
      if opts.done then opts.done(result) end
    end)
    if not ok then diagnostics.error(err, root) end
    local cmd = verb(args) or 'command'
    diagnostics.record(root, { command = 'jj ' .. table.concat(args, ' '), code = result.code,
      stdout = result.stdout, stderr = result.stderr, cancelled = job.cancelled })
    if not opts.quiet then
      local output = diagnostics.plain((result.stdout or '') .. (result.stderr or ''))
      local warning = output:find('Warning:', 1, true) or output:lower():find('conflict', 1, true)
        or output:lower():find('diverg', 1, true)
      local status = job.cancelled and 'cancelled' or result.code ~= 0 and 'failed — :checkhealth jj'
        or warning and 'completed with warnings — :checkhealth jj' or 'completed'
      local level = not job.cancelled and (result.code ~= 0 and vim.log.levels.ERROR or warning and vim.log.levels.WARN) or nil
      diagnostics.notice('jj ' .. cmd .. ': ' .. status, level)
    end
  end
  local ok, process = pcall(vim.system, command, { cwd = root, text = true,
    env = { FUJUTSU_EDITOR_PID = tostring(vim.fn.getpid()) } }, vim.schedule_wrap(finish))
  if not ok then
    timer:stop(); timer:close(); M.jobs[job.id] = nil; vim.fn.delete(dir, 'rf')
    error(process, 0)
  end
  job.process = process
  return job
end

vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
  for _, job in pairs(M.jobs) do
    vim.fn.writefile({ 'cancel' }, job.dir .. '/cancel')
    job.process:kill(15)
    if job.cleanup then job.cleanup() end
  end
end })

return M
