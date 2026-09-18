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

  local highlights = require('fujutsu.highlights')
  local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local palette_buf = vim.api.nvim_create_buf(false, true)
  local old_red, old_green = vim.g.terminal_color_1, vim.g.terminal_color_2
  vim.g.terminal_color_1, vim.g.terminal_color_2 = '#123456', '#654321'
  ansi.render(palette_buf, '\27[31mred\27[32mgreen\27[0m')
  eq(0x123456, highlight(marks(palette_buf)[1]).fg)
  eq(0x654321, highlight(marks(palette_buf)[2]).fg)
  highlights.refresh()
  for _, background in ipairs({ 'light', 'dark' }) do
    vim.o.background = background
    for kind, base in pairs({ Add = 'Added', Delete = 'Removed', Change = 'Changed', Neutral = 'Comment' }) do
      vim.api.nvim_set_hl(0, base, { fg = '#123456', bg = '#abcdef', ctermfg = 2, ctermbg = 1,
        reverse = true, bold = true })
      vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'fujutsu-test' })
      eq({ fg = 0x123456, ctermfg = 2 }, hl('FujutsuStat' .. kind))
      vim.api.nvim_set_hl(0, base, { fg = '#654321', bg = '#fedcba', ctermfg = 3, ctermbg = 4 })
      vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'fujutsu-test' })
      eq({ fg = 0x654321, ctermfg = 3 }, hl('FujutsuStat' .. kind))
    end
  end
  vim.api.nvim_set_hl(0, 'FujutsuStatAdd', { fg = '#abcdef' })
  for _, background in ipairs({ 'light', 'dark' }) do
    vim.o.background = background
    vim.api.nvim_set_hl(0, 'Normal', {})
    vim.api.nvim_set_hl(0, 'FujutsuDiffAdd', { bg = '#204060' })
    highlights.refresh()
    eq(background == 'dark' and 0x8f9faf or 0x102030, hl('FujutsuDiffAddUnchanged').fg)
    vim.api.nvim_set_hl(0, 'Normal', { fg = '#102030', bg = '#304050' })
    vim.api.nvim_set_hl(0, 'FujutsuTestEmpty', {})
    vim.api.nvim_set_hl(0, 'FujutsuDiffAdd', { link = 'FujutsuTestEmpty' })
    highlights.refresh()
    eq(0x203040, hl('FujutsuDiffAddUnchanged').fg)
    vim.api.nvim_set_hl(0, 'FujutsuDiffAdd', { fg = '#204060', bg = '#a0c0e0' })
    vim.api.nvim_set_hl(0, 'FujutsuDiffDelete', { fg = '#e0c0a0', bg = '#604020' })
    highlights.refresh()
    eq(0x6080a0, hl('FujutsuDiffAddUnchanged').fg)
    eq(0xa08060, hl('FujutsuDiffDeleteUnchanged').fg)
    eq(nil, hl('FujutsuDiffAddUnchanged').bg)
    eq(8, hl('FujutsuDiffAddUnchanged').ctermfg)
    -- Changing effective base colors must update previously generated defaults.
    vim.api.nvim_set_hl(0, 'FujutsuDiffAdd', { fg = '#ffffff', bg = '#000000' })
    vim.g.terminal_color_1, vim.g.terminal_color_2 = '#112233', '#445566'
    vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'fujutsu-test' })
    eq(0x7f7f7f, hl('FujutsuDiffAddUnchanged').fg)
    eq(0xabcdef, hl('FujutsuStatAdd').fg)
    eq(0x112233, highlight(marks(palette_buf)[1]).fg)
    eq(0x445566, highlight(marks(palette_buf)[2]).fg)
  end
  vim.api.nvim_set_hl(0, 'FujutsuDiffAddUnchanged', { fg = '#fedcba' })
  highlights.refresh()
  vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'fujutsu-test' })
  eq(0xfedcba, hl('FujutsuDiffAddUnchanged').fg)
  vim.g.terminal_color_1, vim.g.terminal_color_2 = old_red, old_green
  vim.cmd.colorscheme('default')
  eq(hl('Added').fg, hl('FujutsuStatAdd').fg)
  eq(nil, hl('FujutsuStatAdd').bg)
  assert(hl('FujutsuDiffAddUnchanged').fg)
  vim.api.nvim_buf_delete(palette_buf, { force = true })
  print('PASS: semantic defaults, palette overrides, light/dark dimming, and colorscheme refresh')

  local word_spans = require('fujutsu.diff').word_spans
  eq({
    { 2, 2, 5, 'FujutsuDiffDeleteUnchanged' }, { 3, 2, 5, 'FujutsuDiffAddUnchanged' },
    { 2, 8, 13, 'FujutsuDiffDeleteUnchanged' }, { 3, 8, 13, 'FujutsuDiffAddUnchanged' },
  },
    word_spans({ { row = 2, col = 2, text = 'α old tail' } },
      { { row = 3, col = 2, text = 'α new tail' } }))
  eq({}, word_spans({}, { { row = 0, col = 0, text = 'added' } }))
  eq({ { 0, 1, 10, 'FujutsuDiffDeleteUnchanged' }, { 1, 5, 14, 'FujutsuDiffAddUnchanged' } },
    word_spans({ { row = 0, col = 1, text = 'same tail' } },
      { { row = 1, col = 1, text = 'new same tail' } }))
  print('PASS: unchanged-word spans, insertions, and UTF-8 byte offsets')

  local a, b = repo('repo-a'), repo('repo-b')
  edit(a)
  local original = vim.api.nvim_get_current_win()
  vim.cmd.J()
  local log_win, log_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  eq(2, #vim.api.nvim_tabpage_list_wins(0))
  eq(a, vim.b.fujutsu_repo)
  eq('nowrite', vim.bo.buftype)
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
  for _, mark in ipairs(stat_marks) do
    local name = mark[4].hl_group
    colors[name] = true
    if name:match('^FujutsuStat') then
      local chunk = line:sub(mark[3] + 1, mark[4].end_col)
      assert(not chunk:find('│', 1, true), 'stat highlights must not cover the graph')
      assert(not chunk:find('file.txt', 1, true), 'stat highlights must not cover filenames')
    end
  end
  assert(colors.FujutsuStatAdd and colors.FujutsuStatDelete and colors.FujutsuStatNeutral,
    'stats need semantic addition, deletion, and neutral highlights')
  local collapsed = lines()
  toggle(row, #line - 1)
  eq(row, vim.api.nvim_win_get_cursor(0)[1])
  local hunk = lines()[row + 1]
  assert(hunk:find('@@ -1,1 +1,2 @@', 1, true), hunk)
  eq(select(2, find('file.txt')):find('M ■', 1, true), hunk:find('@@', 1, true))
  assert(find('+replacement'))
  assert(find('-stats-parent'))
  eq(nil, find('diff --git'))
  eq(nil, find('--- a/file.txt'))
  eq(nil, find('+++ b/file.txt'))
  local function diff_highlight(needle, name)
    local index, content = find(needle)
    local found = false
    for _, mark in ipairs(marks(vim.api.nvim_get_current_buf())) do
      if mark[2] == index - 1 and mark[4].hl_group == name then
        eq(content:find(needle, 1, true) - 1, mark[3])
        eq(#content, mark[4].end_col)
        found = true
      end
    end
    assert(found, 'missing diff highlight: ' .. name)
  end
  diff_highlight('+replacement', 'FujutsuDiffAdd')
  diff_highlight('-stats-parent', 'FujutsuDiffDelete')
  diff_highlight('@@ -1,1 +1,2 @@', 'FujutsuDiffHunk')
  local function graph_blank(text_line)
    return text_line:gsub('│', ''):gsub('%s', '') == ''
  end
  local diff_end = find('+extra')
  assert(graph_blank(lines()[diff_end + 1]), 'diff needs a trailing margin')
  assert(not graph_blank(lines()[diff_end + 2]), 'margin must be only one line')
  vim.cmd.J()
  assert(find('+replacement'), 'refresh preserves expanded diffs')
  toggle((find('+replacement'))) -- Diff rows collapse their file, not the revision.
  eq(row, vim.api.nvim_win_get_cursor(0)[1])
  eq(collapsed, lines())
  toggle((find('space name.txt')))
  assert(find('+new'))
  local last_diff_end = find('+new')
  assert(graph_blank(lines()[last_diff_end + 1]), 'last diff shares the status margin')
  assert(not graph_blank(lines()[last_diff_end + 2]), 'last diff must not double the margin')
  toggle((find('removed.txt')))
  assert(find('-remove me'))
  assert(find('+new'), 'files expand independently')
  toggle((find('removed.txt')))
  toggle((find('space name.txt')))
  eq(collapsed, lines())
  toggle((find('binary.dat')))
  assert(find('Binary files'))
  toggle((find('binary.dat')))
  toggle((find('empty.txt')))
  assert(find('new file mode'))
  toggle((find('empty.txt')))
  eq(collapsed, lines())
  print('PASS: inline per-file diff toggles, independent state, refresh, binary and empty files')
  toggle((find('stats-child')))
  eq(nil, find('file.txt'))
  vim.cmd.J()
  eq(nil, find('file.txt')) -- Refresh preserves an explicit collapse of @.
  toggle(find('stats-child'), 4) -- Description, not just the graph/header.
  assert(find('file.txt'))
  toggle((find('stats-child')))
  toggle((find('stats-parent')))
  assert(select(2, find('file.txt')):find('+1  file.txt', 1, true))
  eq(nil, find('space name.txt')) -- Expanding the parent doesn't expand @.
  toggle((find('file.txt')))
  assert(find('+stats-parent'), 'historical files use their own revision diff')
  eq(nil, find('+replacement'))
  toggle((find('file.txt')))
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

  local paths_repo = repo('diff-paths')
  run({ 'jj', 'new', '-m', 'renamed-file' }, paths_repo)
  local unusual = 'glob:[name] "quoted".txt'
  assert(vim.uv.fs_rename(paths_repo .. '/file.txt', paths_repo .. '/' .. unusual))
  vim.cmd.tabnew()
  vim.cmd.cd(vim.fn.fnameescape(paths_repo))
  vim.cmd.J()
  local renamed = assert(find('■')) + 1
  assert(lines()[renamed]:find('R ■', 1, true), lines()[renamed])
  toggle(renamed)
  assert(find('rename from file.txt'), 'rename diffs use the actual target, not the display path')
  assert(find('rename to '))
  toggle(renamed)
  eq(nil, find('rename from file.txt'))
  vim.fn.writefile({ 'new contents' }, paths_repo .. '/' .. unusual)
  toggle(renamed)
  assert(find('+new contents'), 'literal filesets handle quotes and metacharacters')
  local reload_buf, reload_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local reload_name = vim.api.nvim_buf_get_name(0)
  vim.fn.writefile({ 'updated contents' }, paths_repo .. '/' .. unusual)
  vim.cmd.cd(vim.fn.fnameescape(b)) -- Reload must use the buffer's repository, not cwd.
  vim.cmd.edit()
  eq(reload_buf, vim.api.nvim_get_current_buf())
  eq(reload_win, vim.api.nvim_get_current_win())
  eq(reload_name, vim.api.nvim_buf_get_name(0))
  eq(paths_repo, vim.b.fujutsu_repo)
  eq('fujutsu', vim.bo.filetype)
  eq('nowrite', vim.bo.buftype)
  eq(false, vim.bo.modifiable)
  eq(false, vim.bo.modified)
  assert(find('+updated contents'), 'working-copy diff expansions survive :e snapshot changes')
  eq(nil, find('+new contents'))
  diff_highlight('+updated contents', 'FujutsuDiffAdd')
  toggle((find('renamed-file')))
  vim.cmd('edit!')
  eq(nil, find('rename from file.txt'))
  eq(nil, find('+updated contents'))
  toggle((find('renamed-file')))
  assert(find('+updated contents'), ':e! preserves revision and file expansion choices')
  print('PASS: :e and :e! reload the same log with preserved expansion state and highlights')
  run({ 'jj', 'config', 'set', '--repo', 'templates.log', 'invalid_template(' }, paths_repo)
  local reload_errors, notify_reload = {}, vim.notify
  vim.notify = function(message, level)
    reload_errors[#reload_errors + 1] = { message, level }
  end
  vim.cmd.edit()
  vim.notify = notify_reload
  eq(1, #reload_errors)
  eq(vim.log.levels.ERROR, reload_errors[1][2])
  eq(false, vim.bo.modifiable)
  eq(false, vim.bo.modified)
  run({ 'jj', 'config', 'unset', '--repo', 'templates.log' }, paths_repo)
  vim.cmd.edit()
  assert(find('+updated contents'), 'reload must recover after a jj error')
  print('PASS: failed :e reports an error and allows retry')
  print('PASS: rename paths, literal filenames, and live working-copy diffs')

  local before_write = lines()
  vim.cmd.split(vim.fn.fnameescape(paths_repo .. '/' .. unusual))
  local file_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'saved in vim' })
  vim.cmd.write()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'saved twice in vim' })
  vim.cmd.write()
  eq(file_win, vim.api.nvim_get_current_win())
  eq(before_write, vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false))
  vim.api.nvim_set_current_win(reload_win)
  assert(find('+saved twice in vim'), 'entering a stale log refreshes its expanded diff')
  eq(nil, find('+updated contents'))
  local tick = vim.api.nvim_buf_get_changedtick(reload_buf)
  vim.api.nvim_set_current_win(file_win)
  vim.api.nvim_set_current_win(reload_win)
  eq(tick, vim.api.nvim_buf_get_changedtick(reload_buf))

  vim.api.nvim_set_current_win(file_win)
  edit(b)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unrelated repository write' })
  vim.cmd.write()
  vim.api.nvim_set_current_win(reload_win)
  eq(tick, vim.api.nvim_buf_get_changedtick(reload_buf))

  vim.api.nvim_set_current_win(file_win)
  vim.cmd.edit(vim.fn.fnameescape(paths_repo .. '/' .. unusual))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'retry automatic refresh' })
  vim.cmd.write()
  run({ 'jj', 'config', 'set', '--repo', 'templates.log', 'invalid_template(' }, paths_repo)
  reload_errors = {}
  vim.notify = function(message, level)
    reload_errors[#reload_errors + 1] = { message, level }
  end
  vim.api.nvim_set_current_win(reload_win)
  vim.notify = notify_reload
  eq(1, #reload_errors)
  eq(vim.log.levels.ERROR, reload_errors[1][2])
  run({ 'jj', 'config', 'unset', '--repo', 'templates.log' }, paths_repo)
  vim.api.nvim_set_current_win(file_win)
  vim.api.nvim_set_current_win(reload_win)
  assert(find('+retry automatic refresh'), 'failed automatic refresh remains stale for retry')
  print('PASS: writes invalidate only their repository; log entry refreshes lazily and retries errors')

  local context_repo = repo('hunk-context')
  local source = { 'local function first()' }
  for _ = 2, 11 do source[#source + 1] = '  unchanged()' end
  source[#source + 1] = 'end'
  source[#source + 1] = 'local function second()'
  for _ = 14, 23 do source[#source + 1] = '  unchanged()' end
  source[#source + 1] = 'end'
  vim.fn.writefile(source, context_repo .. '/file.txt')
  run({ 'jj', 'new', '-m', 'context-child' }, context_repo)
  source[8], source[20] = '  changed_first()', '  changed_second()'
  vim.fn.writefile(source, context_repo .. '/file.txt')
  vim.cmd.tabnew()
  edit(context_repo)
  vim.cmd.J()
  toggle((find('file.txt')))
  local first_hunk, first_text = find('@@ -5,7 +5,7 @@ local function first()')
  assert(first_hunk, 'first hunk needs its preceding function context')
  assert(find('@@ -17,7 +17,7 @@ local function second()'))
  local context_mark, header_mark
  for _, mark in ipairs(marks(vim.api.nvim_get_current_buf())) do
    if mark[2] == first_hunk - 1 then
      if mark[4].hl_group == 'FujutsuDiffContext' then context_mark = mark end
      if mark[4].hl_group == 'FujutsuDiffHunk' then header_mark = mark end
    end
  end
  assert(context_mark and header_mark)
  local dimmed_words = 0
  for _, mark in ipairs(marks(vim.api.nvim_get_current_buf())) do
    if mark[4].hl_group == 'FujutsuDiffAddUnchanged' or mark[4].hl_group == 'FujutsuDiffDeleteUnchanged' then
      local style = highlight(mark)
      assert(style.fg, 'unchanged words need a dimmed foreground')
      eq(nil, style.bg)
      eq(nil, style.bold)
      dimmed_words = dimmed_words + 1
    end
  end
  assert(dimmed_words > 0)
  eq(first_text:find('local function', 1, true) - 1, context_mark[3])
  eq(context_mark[3] - 1, header_mark[4].end_col)
  run({ 'jj', 'new', '-m', 'context-grandchild' }, context_repo)
  source[1] = 'local function unrelated_working_copy()'
  vim.fn.writefile(source, context_repo .. '/file.txt')
  vim.cmd.J()
  toggle((find('context-child')))
  -- Skip the working-copy file row to expand the historical file.
  local child = find('context-child')
  for index = child + 1, #lines() do
    if lines()[index]:find('file.txt', 1, true) then toggle(index); break end
  end
  assert(find('@@ -5,7 +5,7 @@ local function first()'), 'context must come from the displayed revision')
  toggle((find('@@ -5,7 +5,7 @@ local function first()')))
  eq(nil, find('@@ -5,7 +5,7 @@ local function first()'))
  print('PASS: per-hunk section context, separate highlights, and historical revision contents')

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
