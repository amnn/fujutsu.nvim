vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')

local function run(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function repo(name)
  local path = tmp .. '/' .. name
  run({ 'jj', 'git', 'init', path })
  run({ 'jj', 'describe', '-m', name }, path)
  vim.fn.writefile({ name }, path .. '/file.txt')
  return vim.uv.fs_realpath(path)
end

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path .. '/file.txt'))
end

local function tests()
  local a, b = repo('repo-a'), repo('repo-b')
  edit(a)
  local original = vim.api.nvim_get_current_win()
  vim.cmd.J()
  local log_win, log_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  eq(2, #vim.api.nvim_tabpage_list_wins(0))
  eq(a, vim.b.fujutsu_repo)
  eq('nofile', vim.bo.buftype)
  eq(false, vim.bo.modifiable)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(text:find('repo%-a'), 'log must contain repository description')
  assert(not text:find('\27'), 'log must not contain ANSI escapes')
  print('PASS: J opens the repository log in a scratch split')

  vim.api.nvim_set_current_win(original)
  vim.cmd.J()
  eq(log_win, vim.api.nvim_get_current_win())
  eq(log_buf, vim.api.nvim_get_current_buf())
  eq(2, #vim.api.nvim_tabpage_list_wins(0))
  vim.cmd.J()
  eq(log_win, vim.api.nvim_get_current_win())
  print('PASS: J focuses the existing log, including from the log itself')

  vim.api.nvim_set_current_win(original)
  edit(b)
  vim.cmd.J()
  eq(3, #vim.api.nvim_tabpage_list_wins(0))
  eq(b, vim.b.fujutsu_repo)
  assert(log_buf ~= vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_win_is_valid(log_win))
  print('PASS: another repository gets its own split')

  local first_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd('tab J')
  eq(2, #vim.api.nvim_list_tabpages())
  eq(1, #vim.api.nvim_tabpage_list_wins(0))
  eq(b, vim.b.fujutsu_repo)
  assert(first_tab ~= vim.api.nvim_get_current_tabpage())
  vim.cmd.J()
  eq(1, #vim.api.nvim_tabpage_list_wins(0))
  print('PASS: tab J creates a new tab even when a log already exists')

  vim.cmd.tabnew()
  edit(a)
  vim.cmd.J()
  eq(2, #vim.api.nvim_tabpage_list_wins(0))
  assert(log_buf ~= vim.api.nvim_get_current_buf())
  print('PASS: logs in other tabs are not focused')

  vim.cmd.tabnew()
  vim.cmd.cd(vim.fn.fnameescape(a))
  vim.cmd.J()
  eq(a, vim.b.fujutsu_repo)
  print('PASS: unnamed buffers use the current directory')

  vim.cmd.tabnew()
  vim.cmd.cd(vim.fn.fnameescape(tmp))
  local notifications = {}
  local notify = vim.notify
  vim.notify = function(message) notifications[#notifications + 1] = message end
  vim.cmd.J()
  vim.notify = notify
  eq(1, #notifications)
  eq(1, #vim.api.nvim_tabpage_list_wins(0))
  print('PASS: outside a repository reports an error without creating a split')
end

local ok, err = xpcall(tests, debug.traceback)
vim.cmd.cd(vim.fn.fnameescape(vim.env.HOME))
vim.fn.delete(tmp, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
