-- Run jj asynchronously so its text editor can live in this Neovim instance.
-- A private file handshake avoids shell interpolation of repository arguments
-- and works without a Neovim server or external Python/RPC dependencies.
local M = { active = {} }
local file = require('fujutsu.file')

function M.guard(root)
  local real_root = vim.uv.fs_realpath(root) or root
  assert(not M.active[root] and not M.active[real_root], 'A Jujutsu operation is already running in this repository')
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      local real = vim.uv.fs_realpath(name) or name
      assert(real:sub(1, #real_root + 1) ~= real_root .. '/', 'Save or discard unsaved workspace buffer first: ' .. name)
    end
  end
end

function M.head(root)
  return vim.trim(file.jj(root, { '--ignore-working-copy', 'op', 'log', '--no-graph', '-n', '1', '-T', 'id' }))
end

function M.run(root, args, opts)
  opts = opts or {}
  root = vim.uv.fs_realpath(root) or root
  M.guard(root)
  -- Snapshot before freezing the operation identity used by pending editors.
  file.jj(root, { 'log', '--no-graph', '-r', '@', '-T', 'commit_id' })
  local expected = M.head(root)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local script = [[#!/bin/sh
set -eu
dir=$1
shift
printf '%s\n%s' "$$" "$1" > "$dir/request.tmp"
mv "$dir/request.tmp" "$dir/request"
while [ ! -f "$dir/done" ] && [ ! -f "$dir/cancel" ]; do sleep 0.05; done
[ ! -f "$dir/cancel" ] || exit 1
rm -f "$dir/done" "$dir/request"
]]
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), dir .. '/editor.sh')
  local command = { 'jj', '--no-pager', '--color=never', '--config',
    'ui.editor=' .. vim.json.encode({ '/bin/sh', dir .. '/editor.sh', dir }) }
  vim.list_extend(command, args)
  local job = { dir = dir, root = root, args = args, cleanup = opts.cleanup }
  M.active[root] = job
  local timer = assert(vim.uv.new_timer())
  local function cancel()
    if M.active[root] == job then
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
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
    vim.bo[buf].modified = false
    vim.b[buf].fujutsu_repo = root
    vim.cmd.sbuffer(buf)
    local accepted = false
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      local ok, err = pcall(function()
        -- A modified real buffer or external jj operation invalidates this edit.
        local active = M.active[root]
        M.active[root] = nil
        local safe, message = pcall(M.guard, root)
        M.active[root] = active
        assert(safe, message)
        file.resolve(root, '@') -- Also detect saved/on-disk edits during the dialog.
        assert(M.head(root) == expected, 'Repository changed while editing; cancel and retry')
        vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
        vim.fn.writefile({ 'done' }, dir .. '/done')
        accepted = true
        vim.bo[buf].modified = false
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
    end })
    vim.keymap.set('n', '<Esc>', function() vim.api.nvim_buf_delete(buf, { force = true }) end,
      { buffer = buf, desc = 'Cancel repository operation' })
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
      if not accepted then cancel() end
    end })
    vim.notify('Edit the combined description; :write accepts, Esc cancels the operation')
  end
  timer:start(0, 50, vim.schedule_wrap(function()
    if M.active[root] == job then
      local ok, err = pcall(open_editor)
      if not ok then cancel(); vim.notify(tostring(err), vim.log.levels.ERROR) end
    end
  end))
  job.process = vim.system(command, { cwd = root, text = true }, vim.schedule_wrap(function(result)
    timer:stop(); timer:close()
    M.active[root] = nil
    vim.fn.delete(dir, 'rf')
    if job.cleanup then job.cleanup() end
    job.result = result
    if job.editor and vim.api.nvim_buf_is_valid(job.editor) then
      vim.api.nvim_buf_delete(job.editor, { force = true })
    end
    require('fujutsu').invalidate(root)
    require('fujutsu.status').repository_changed(root)
    local ok, err = pcall(function()
      vim.cmd('checktime')
      require('fujutsu').refresh_root(root)
      if opts.done then opts.done(result, expected) end
    end)
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
    if job.cancelled then
      vim.notify('Jujutsu operation cancelled')
    elseif result.code ~= 0 then
      vim.notify(vim.trim(result.stderr or 'jj failed'), vim.log.levels.ERROR)
    elseif not opts.quiet then
      local output = vim.trim((result.stdout or '') .. (result.stderr or ''))
      if output ~= '' then vim.notify(output) end
    end
  end))
  return job
end

vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
  for _, job in pairs(M.active) do
    vim.fn.writefile({ 'cancel' }, job.dir .. '/cancel')
    job.process:kill(15)
    if job.cleanup then job.cleanup() end
  end
end })

return M
