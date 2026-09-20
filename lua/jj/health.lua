local M = {}
function M.check()
  vim.health.start('Fujutsu / jj')
  if vim.fn.executable('jj') == 0 then vim.health.error('jj is not on PATH'); return end
  local version = vim.system({ 'jj', '--version' }, { text = true }):wait()
  vim.health.info(vim.trim(version.stdout or 'Unknown jj version'))
  local roots = vim.tbl_keys(require('fujutsu.diagnostics').workspaces)
  table.sort(roots)
  if #roots == 0 then vim.health.ok('No command diagnostics in this Neovim session') end
  for _, root in ipairs(roots) do
    vim.health.start(root)
    for _, item in ipairs(require('fujutsu.diagnostics').workspaces[root]) do
      local status = item.cancelled and 'cancelled' or item.code == 0 and 'completed' or 'failed'
      vim.health.info(item.command .. ' — ' .. status)
      if item.stdout ~= '' then vim.health.info(item.stdout) end
      if item.stderr ~= '' then vim.health.info(item.stderr) end
    end
  end
end
return M
