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

for name, command in pairs({ Jedit = 'edit', Jview = 'edit', Jsplit = 'split',
  Jvsplit = 'vsplit', Jtabedit = 'tabedit', Jpedit = 'pedit', Jdrop = 'drop' }) do
  vim.api.nvim_create_user_command(name, function(opts)
    require('fujutsu.commands').open(command, name == 'Jview', opts)
  end, { nargs = '*', complete = function(...)
    return require('fujutsu.commands').complete(...)
  end, desc = 'Open a workspace or historical file' })
end

vim.api.nvim_create_user_command('Jread', function(opts)
  require('fujutsu.commands').read(opts)
end, { nargs = '*', range = true, complete = function(...)
  return require('fujutsu.commands').complete(...)
end, desc = 'Restore or insert a file version into this buffer' })

vim.api.nvim_create_user_command('Jwrite', function(opts)
  local flags = { bang = opts.bang }
  for _, arg in ipairs(opts.fargs) do
    if arg == '--restore-descendants' then flags.restore_descendants = true
    elseif arg == '--ignore-immutable' then flags.ignore_immutable = true
    else error('Unknown Jwrite argument: ' .. arg) end
  end
  require('fujutsu.file').write(vim.api.nvim_get_current_buf(), flags)
end, { bang = true, nargs = '*', complete = function(lead)
  return vim.tbl_filter(function(s) return vim.startswith(s, lead) end,
    { '--restore-descendants', '--ignore-immutable' })
end, desc = 'Write this historical file through jj diffedit' })
