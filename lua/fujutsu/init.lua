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
        logs[buf].refresh(buf)
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
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function() logs[buf] = nil end,
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
