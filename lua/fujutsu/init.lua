local M = {}

local function jj(cwd, args, colored)
  local command = { 'jj', '--no-pager', colored and '--color=always' or '--color=never' }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'jj failed', 0)
  end
  return result.stdout
end

local function current_directory()
  local repo = vim.b.fujutsu_repo
  if repo then
    return repo
  end
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == '' and name ~= '' then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local logs = {}
local stale = {}

local function refresh(buf)
  logs[buf].refresh(buf)
  stale[buf] = nil
end

local function try_refresh(buf)
  local success, message = pcall(refresh, buf)
  if not success then vim.notify(message, vim.log.levels.ERROR) end
end

local group = vim.api.nvim_create_augroup('fujutsu_reload', { clear = true })
vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(event)
    if not next(logs) or vim.bo[event.buf].buftype ~= '' then return end
    local name = vim.api.nvim_buf_get_name(event.buf)
    if name == '' then return end
    local ok, root = pcall(jj, vim.fs.dirname(name), { 'root' })
    if not ok then return end -- Files outside a jj workspace are irrelevant.
    root = vim.trim(root)
    root = vim.uv.fs_realpath(root) or root
    for buf in pairs(logs) do
      if vim.b[buf].fujutsu_repo == root then stale[buf] = true end
    end
  end,
})
vim.api.nvim_create_autocmd('BufEnter', {
  group = group,
  callback = function(event)
    if stale[event.buf] and not vim.bo[event.buf].modified then
      try_refresh(event.buf)
    end
  end,
})

function M.read_log(buf, root)
  vim.b[buf].fujutsu_repo = root
  vim.bo[buf].buftype = 'nowrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  local log = logs[buf]
  if log then
    try_refresh(buf)
  else
    log = require('fujutsu.log').new(root, jj)
    log.refresh(buf)
    logs[buf] = log
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        logs[buf] = nil
        stale[buf] = nil
      end,
    })
  end
  vim.keymap.set('n', '-', function()
    vim.cmd.edit(vim.fn.fnameescape(root .. '/.jj'))
  end, { buffer = buf, silent = true, desc = 'Open repository metadata directory' })
  for kind, pairs_ in pairs({ revision = { { '[[', ']]' } },
    file = { { '{{', '}}' }, { '[m', ']m' }, { '[/', ']/' } },
    hunk = { { '[c', ']c' } }, item = { { '(', ')' } } }) do
    for _, keys in ipairs(pairs_) do
      for index, key in ipairs(keys) do
        vim.keymap.set('n', key, function()
          log.move(kind, index == 1 and -1 or 1, vim.v.count1)
        end, { buffer = buf, silent = true, desc = 'Move to ' .. kind .. ' boundary' })
      end
    end
  end
  vim.keymap.set('n', '<CR>', function()
    local success, message = pcall(log.visit, buf)
    if not success then vim.notify(message, vim.log.levels.ERROR) end
  end, { buffer = buf, silent = true, desc = 'Visit file revision' })
  vim.keymap.set('n', '=', function()
    local success, message = pcall(log.toggle, buf)
    if not success then vim.notify(message, vim.log.levels.ERROR) end
  end, { buffer = buf, silent = true, desc = 'Toggle revision stats or file diff' })
  vim.bo[buf].filetype = 'fujutsu'
end

function M.open(opts)
  opts = opts or {}
  local mods = opts.smods or {}
  local root = vim.trim(jj(current_directory(), { 'root' }))
  root = vim.uv.fs_realpath(root) or root

  -- Explicit :tab always requests a new tab; otherwise reuse this tab's log.
  if not (mods.tab and mods.tab >= 0) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if logs[buf] and vim.b[buf].fujutsu_repo == root then
        refresh(buf)
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, require('fujutsu.uri').name(root, 'log', tostring(buf)))
  local ready, message = pcall(M.read_log, buf, root)
  if not ready then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(message, 0)
  end
  local ok, err = pcall(vim.cmd, { cmd = 'sbuffer', args = { tostring(buf) }, mods = mods })
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(err, 0)
  end
  vim.bo[buf].filetype = 'fujutsu'
  vim.wo.wrap = false
end

function M.selection()
  local buf = vim.api.nvim_get_current_buf()
  return logs[buf] and logs[buf].selection(buf)
end

function M.invalidate(root)
  for buf in pairs(logs) do
    if vim.b[buf].fujutsu_repo == root then stale[buf] = true end
  end
end

return M
