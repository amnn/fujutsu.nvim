local M = {}

local function available(win)
  return vim.api.nvim_win_get_config(win).relative == ''
    and not vim.wo[win].previewwindow and not vim.wo[win].winfixwidth
    and not vim.wo[win].winfixbuf and not vim.wo[win].diff
end

local function usable(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local kind, ft = vim.bo[buf].buftype, vim.bo[buf].filetype
  return (kind == '' or kind == 'acwrite') and ft ~= 'gitcommit' and ft ~= 'gitrebase'
end

local function editor(name)
  local previous = vim.fn.win_getid(vim.fn.winnr('#'))
  local fallback
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if available(win) then
      -- An already displayed description can be focused, but do not replace
      -- a description/rebase editor with a different destination.
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == name then return win end
      if usable(win) then
        if win == previous then fallback = win else fallback = fallback or win end
      end
    end
  end
  return fallback
end

function M.open(command, name, mods)
  mods = vim.deepcopy(mods or {})
  local origin = vim.api.nvim_get_current_win()
  if (command == 'edit' or command == 'drop') and vim.b.fujutsu_log
    and not (mods.tab and mods.tab >= 0) then
    local target = editor(name)
    if target then
      vim.api.nvim_set_current_win(target)
      if vim.api.nvim_buf_get_name(0) == name then return end
    else
      -- No editing window remains. Create just one; subsequent visits reuse it.
      local displayed = vim.fn.win_findbuf(vim.fn.bufnr(name))
      if command ~= 'drop' or #displayed == 0 then
        command = 'split'
        if not mods.split or mods.split == '' then mods.split = 'belowright' end
      end
    end
  end
  local ok, err = pcall(vim.cmd, { cmd = command, args = { vim.fn.fnameescape(name) }, mods = mods })
  if not ok then
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    error(err, 0)
  end
end

return M
