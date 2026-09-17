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

function M.open(opts)
  opts = opts or {}
  local mods = opts.smods or {}
  local root = vim.trim(jj(current_directory(), { 'root' }))
  root = vim.uv.fs_realpath(root) or root

  -- An explicit :tab modifier always requests a new tab, even if this tab
  -- already has a log window. Otherwise reuse only windows in this tab.
  if not (mods.tab and mods.tab >= 0) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].fujutsu_repo == root then
        refresh(buf)
        vim.api.nvim_set_current_win(win)
        return
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].fujutsu_repo = root
  vim.api.nvim_buf_set_name(buf, ('fujutsu://%d/log'):format(buf))
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local log = require('fujutsu.log').new(root, jj)
  local refreshed, refresh_err = pcall(log.refresh, buf)
  if not refreshed then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(refresh_err, 0)
  end
  logs[buf] = log
  vim.api.nvim_create_autocmd('BufReadCmd', {
    buffer = buf,
    callback = function()
      try_refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      logs[buf] = nil
      stale[buf] = nil
    end,
  })
  vim.keymap.set('n', '=', function()
    local success, message = pcall(log.toggle, buf)
    if not success then vim.notify(message, vim.log.levels.ERROR) end
  end, { buffer = buf, silent = true, desc = 'Toggle revision stats or file diff' })
  local ok, err = pcall(vim.cmd, { cmd = 'sbuffer', args = { tostring(buf) }, mods = mods })
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(err, 0)
  end
  vim.bo[buf].filetype = 'fujutsu'
  vim.wo.wrap = false
end

return M
