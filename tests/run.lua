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
  local ansi = require('fujutsu.ansi')
  local buf = vim.api.nvim_create_buf(false, true)
  local function marks(target)
    return vim.api.nvim_buf_get_extmarks(target, ansi.namespace, 0, -1, { details = true })
  end
  local function highlight(mark)
    return vim.api.nvim_get_hl(0, { name = mark[4].hl_group, link = false })
  end
  ansi.render(buf, '\27[1;31mα\27[39mB\27[0m plain\n\27[38;5;196mred\27[48;2;1;2;3m!\27[0m\n')
  eq({ 'αB plain', 'red!' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local spans = marks(buf)
  eq(4, #spans)
  eq(0, spans[1][3])
  eq(2, spans[1][4].end_col) -- Neovim columns are bytes, not characters.
  eq(true, highlight(spans[1]).bold)
  eq(1, highlight(spans[1]).ctermfg)
  eq(true, highlight(spans[2]).bold)
  eq(nil, highlight(spans[2]).fg)
  eq(0xff0000, highlight(spans[3]).fg)
  eq(0x010203, highlight(spans[4]).bg)
  ansi.render(buf, '\27[3;4;7;9;94;103mone\ntwo\27[23;24;27;29;39;49mplain')
  spans = marks(buf)
  eq(2, #spans)
  eq(highlight(spans[1]), highlight(spans[2]))
  eq(true, highlight(spans[1]).italic)
  eq(true, highlight(spans[1]).underline)
  eq(true, highlight(spans[1]).reverse)
  eq(true, highlight(spans[1]).strikethrough)
  eq(12, highlight(spans[1]).ctermfg)
  eq(11, highlight(spans[1]).ctermbg)
  ansi.render(buf, 'plain')
  eq({}, marks(buf))
  eq(false, vim.bo[buf].modifiable)
  eq(false, vim.bo[buf].modified)
  vim.api.nvim_buf_delete(buf, { force = true })
  print('PASS: ANSI styles, resets, byte offsets, and refresh cleanup')

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
  assert(#marks(log_buf) > 0, 'log must contain highlights')
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

  local stats_repo = repo('stats-parent')
  vim.fn.writefile({ 'remove me' }, stats_repo .. '/removed.txt')
  run({ 'jj', 'new', '-m', 'stats-child' }, stats_repo)
  vim.fn.writefile({ 'replacement', 'extra' }, stats_repo .. '/file.txt')
  vim.fn.delete(stats_repo .. '/removed.txt')
  vim.fn.writefile({ 'new' }, stats_repo .. '/space name.txt')
  vim.fn.writefile({}, stats_repo .. '/empty.txt')
  vim.fn.writefile(vim.fn['repeat']({ 'line' }, 12), stats_repo .. '/large.txt')
  vim.fn.writefile({ 'binary\ncontent' }, stats_repo .. '/binary.dat', 'b')
  vim.cmd.tabnew()
  edit(stats_repo)
  vim.cmd.J()
  local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  local function find(needle)
    for row, line in ipairs(lines()) do
      if line:find(needle, 1, true) then return row, line end
    end
  end
  local function toggle(row, col)
    vim.api.nvim_win_set_cursor(0, { row, col or 0 })
    vim.cmd('normal =')
  end
  local row, line = find('file.txt')
  assert(line:find('M ■■■■■', 1, true), line) -- Three used boxes, two neutral.
  assert(line:find('M ■■■■■  +2 -1 file.txt', 1, true), line)
  assert(select(2, find('removed.txt')):find('D ■■■■■     -1 removed.txt', 1, true))
  assert(select(2, find('space name.txt')):find('A ■■■■■  +1    space name.txt', 1, true))
  assert(select(2, find('empty.txt')):find('A ■■■■■        empty.txt', 1, true))
  assert(select(2, find('large.txt')):find('A ■■■■■ +12    large.txt', 1, true))
  local header, total = find('  ■■■■■ +15 -2')
  assert(total:match('  ■■■■■ %+15 %-2$'), total)
  eq(nil, find('Total'))
  eq('', (lines()[header - 1]:gsub('│', ''):gsub('%s', '')))
  eq('', (lines()[find('space name.txt') + 1]:gsub('│', ''):gsub('%s', '')))
  for index = header, find('space name.txt') do
    assert(not lines()[index]:find('[+-]0'), 'zero counts must be omitted')
  end
  assert(find('binary.dat'), 'binary changes must remain visible')
  local stat_marks = vim.api.nvim_buf_get_extmarks(0, ansi.namespace, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  local colors = {}
  for _, mark in ipairs(stat_marks) do colors[highlight(mark).ctermfg or -1] = true end
  assert(colors[1] and colors[2] and colors[8], 'stats need red, green, and neutral highlights')
  toggle(row, #line - 1) -- File rows belong to their revision too.
  eq(nil, find('file.txt'))
  vim.cmd.J()
  eq(nil, find('file.txt')) -- Refresh preserves an explicit collapse of @.
  toggle(find('stats-child'), 4) -- Description, not just the graph/header.
  assert(find('file.txt'))
  toggle((find('stats-child')))
  toggle((find('stats-parent')))
  assert(select(2, find('file.txt')):find('+1  file.txt', 1, true))
  eq(nil, find('space name.txt')) -- Expanding the parent doesn't expand @.
  local parent_stat = select(2, find('file.txt'))
  toggle((find('stats-child')))
  assert(select(2, find('file.txt')):find('M ■■■■■  +2 -1 file.txt', 1, true))
  local parent_unchanged = false
  for _, text_line in ipairs(lines()) do
    if text_line == parent_stat then parent_unchanged = true end
  end
  assert(parent_unchanged, 'another expanded commit must not widen the parent counts')
  toggle((find('stats-child')))
  toggle((find('  ■■■■■ +2'))) -- The unlabeled summary belongs to the entry too.
  eq(nil, find('file.txt'))
  eq(false, vim.bo.modifiable)
  print('PASS: default @ stats, A/M/D counts and colors, entry-wide toggles, refresh state')

  run({ 'jj', 'config', 'set', '--repo', 'templates.log',
    'commit_id.short() ++ " custom header\\nsecond line\\n" ++ description.remove_suffix("\\n")' }, stats_repo)
  vim.cmd.J()
  toggle(find('custom header'), 5)
  assert(find('space name.txt'))
  toggle((find('second line')))
  eq(nil, find('space name.txt'))
  print('PASS: custom multiline templates preserve revision ownership')

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
