if vim.g.loaded_fujutsu then
  return
end
vim.g.loaded_fujutsu = true

vim.api.nvim_create_user_command('J', function(opts)
  local ok, err = pcall(require('fujutsu').open, opts)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = 'fujutsu' })
  end
end, { desc = 'Open the Jujutsu log' })
