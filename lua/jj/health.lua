local M = {}
function M.check()
  vim.health.start('Fujutsu / jj')
  if vim.fn.has('nvim-0.10') == 0 then
    vim.health.error('Neovim 0.10 or newer is required'); return
  else
    vim.health.ok('Neovim 0.10 or newer')
  end
  if vim.fn.executable('jj') == 0 then vim.health.error('jj is not on PATH'); return end
  local version = vim.system({ 'jj', '--version' }, { text = true }):wait()
  if version.code ~= 0 then
    vim.health.error(vim.trim(version.stderr or '') ~= '' and vim.trim(version.stderr) or 'Could not run jj --version')
    return
  end
  local text = vim.trim(version.stdout or '')
  local major, minor = text:match('^jj (%d+)%.(%d+)')
  if major and tonumber(major) == 0 and tonumber(minor) < 44 then
    vim.health.error(text .. ': jj 0.44 or newer is required')
  elseif text ~= '' then
    vim.health.ok(text)
  else
    vim.health.warn('jj --version returned no version information')
  end
end
return M
