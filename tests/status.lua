vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime('plugin/fujutsu.lua')
local file, status = require('fujutsu.file'), require('fujutsu.status')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect({ expected = a, actual = b })) end
local function includes(text, part) assert(text:find(part, 1, true), vim.inspect({ text, part })) end
local function rendered(win)
  return vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win, maxwidth = 250 }).str
end
local function test()
  file.jj(root, { 'git', 'init' })
  vim.fn.writefile({ 'base' }, root .. '/file.lua')
  local id, change = file.resolve(root, '@')
  file.jj(root, { 'new' })
  local label = '○ ' .. change:sub(1, 12)
  local _, wc = file.resolve(root, '@')
  local working = '@ ' .. wc:sub(1, 12)
  local function workspace_label()
    assert(vim.wait(5000, function() return status.label() == working end, 10), status.label())
  end
  local original = 'CUSTOM %f %r %m %= %l:%c'
  vim.wo.statusline = original
  vim.wo.winbar = 'untouched winbar'
  file.open(root, id, 'file.lua', { command = 'edit' })
  local win = vim.api.nvim_get_current_win()
  eq(label, status.label()); includes(rendered(win), label); includes(rendered(win), 'CUSTOM')
  includes(rendered(win), '[RO]'); eq('untouched winbar', vim.wo.winbar)
  vim.bo.readonly = false
  eq(label, status.label())
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })
  includes(rendered(win), '[+]')
  vim.cmd.split()
  local split = vim.api.nvim_get_current_win()
  vim.cmd.Jedit()
  workspace_label(); includes(rendered(split), working); includes(rendered(split), 'CUSTOM')
  includes(rendered(win), label) -- Inactive-window context, not the current buffer.
  vim.api.nvim_set_current_win(win)
  vim.cmd('Jwrite --restore-descendants')
  assert(vim.b.fujutsu_file.id ~= id)
  eq(label, status.label()) -- jj change ID is stable across rewrites.
  vim.cmd.tabedit(vim.fn.fnameescape(root .. '/file.lua'))
  workspace_label(); includes(rendered(vim.api.nvim_get_current_win()), 'CUSTOM')
  eq('untouched winbar', vim.wo[win].winbar)
  vim.cmd.tabclose(); vim.api.nvim_set_current_win(win)
  require('fujutsu.tree').parent(1); eq(label, status.label())
  file.open(root, id, 'description', { command = 'edit', description = true })
  eq(label, status.label())
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/file.lua'))
  workspace_label(); includes(rendered(win), working)
  vim.cmd.enew(); eq('', status.label()); eq(original, vim.wo.statusline)
  print('PASS: change IDs, native statusline state, inactive windows, rewrites, restoration, and untouched winbars')

  -- Preserve expression-based providers; evaluate their output before adding
  -- the label. No provider-specific Lua module needs to be force-loaded.
  _G.FujutsuTestProvider = function() return 'PROVIDER %f %= %l' end
  local expression = '%!v:lua.FujutsuTestProvider()'
  vim.wo.statusline = expression
  file.open(root, id, 'file.lua', { command = 'edit' })
  includes(rendered(win), 'PROVIDER'); includes(rendered(win), label)
  for text, expected in pairs({ ['%{lightline#active()}'] = 'lightline',
    ['%!v:lua.MiniStatusline.active()'] = 'mini.statusline',
    ['%!v:lua.require("heirline").eval_statusline()'] = 'heirline',
    ['%#lualine_c_normal#'] = 'lualine', [expression] = 'custom', ['%f %m'] = 'native' }) do
    eq(expected, status.detect(text))
  end
  vim.wo.statusline = 'NEW %f %= %l'
  status.refresh(); includes(rendered(win), 'NEW'); includes(rendered(win), label)
  local manual = "%f %{v:lua.require('fujutsu.status').label()}"
  vim.wo.statusline = manual
  status.refresh(); eq(manual, vim.wo.statusline)
  vim.cmd.Jedit(); workspace_label()
  file.jj(root, { 'new' })
  _, wc = file.resolve(root, '@')
  working = '@ ' .. wc:sub(1, 12)
  vim.api.nvim_exec_autocmds('FocusGained', {})
  workspace_label()
  local system = vim.system
  vim.system = function() error('A redraw must not execute commands') end
  for _ = 1, 10 do eq(working, status.label()); rendered(win) end
  vim.system = system
  vim.cmd.enew(); eq('', status.label())
  print('PASS: provider detection, custom expressions, statusline replacement, and manual integration without duplication')

  if vim.env.FUJUTSU_TEST_LUALINE then
    -- Load/setup AFTER Fujutsu: exercise late detection using the real plugin.
    vim.opt.runtimepath:append(vim.env.FUJUTSU_TEST_LUALINE)
    local lualine = require('lualine')
    local formatter = function(text) return '<' .. text .. '>' end
    local color = { fg = '#abcdef' }
    local condition = function() return true end
    lualine.setup({ options = { theme = 'gruvbox', globalstatus = false, icons_enabled = false },
      sections = { lualine_b = { { 'branch', fmt = formatter, icon = 'VC', color = color, padding = 2, cond = condition } },
        lualine_c = { 'filename' } },
      inactive_sections = { lualine_b = { 'branch' }, lualine_c = { 'filename' } } })
    lualine.refresh({ scope = 'all', force = true })
    file.open(root, id, 'file.lua', { command = 'edit' }) -- BufWinEnter detects the provider.
    local function copies(components)
      local n = 0
      for _, c in ipairs(components) do
        if c == 'fujutsu_branch' or type(c) == 'table' and c[1] == 'fujutsu_branch' then n = n + 1 end
      end
      return n
    end
    local configured = lualine.get_config().sections.lualine_b[1]
    eq('fujutsu_branch', configured[1]); eq(formatter, configured.fmt)
    eq('VC', configured.icon); eq(color, configured.color); eq(2, configured.padding)
    eq(condition, configured.cond)
    eq(1, copies(lualine.get_config().sections.lualine_b))
    eq(1, copies(lualine.get_config().inactive_sections.lualine_b))
    eq({ 'filename' }, lualine.get_config().sections.lualine_c)
    status.refresh(); status.refresh()
    eq(1, copies(lualine.get_config().sections.lualine_b))
    file.open(root, id, 'file.lua', { command = 'edit' })
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), '<' .. label .. '>')
    local meta = vim.b.fujutsu_file
    meta.base = true; vim.b.fujutsu_file = meta
    lualine.refresh({ scope = 'all', force = true }); includes(rendered(win), '⋎ ' .. change:sub(1, 12))
    meta.base = false; vim.b.fujutsu_file = meta
    vim.api.nvim_set_current_win(split)
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), label)
    status.track_workspace(vim.api.nvim_get_current_buf()); workspace_label()
    lualine.refresh({ scope = 'all', force = true }); includes(rendered(split), working)
    local config = lualine.get_config()
    config.options.globalstatus = true
    lualine.setup(config)
    vim.api.nvim_set_current_win(win)
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), label)
    -- Default Git icon must not be added alongside the jj markers.
    config.options.icons_enabled = true
    config.sections.lualine_b = { 'fujutsu_branch' }
    lualine.setup(config)
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), label); assert(not rendered(win):find('', 1, true))
    vim.cmd.Jedit(); workspace_label()
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), working); assert(not rendered(win):find('', 1, true))
    file.open(root, id, 'file.lua', { command = 'edit' })
    meta = vim.b.fujutsu_file
    meta.base = true; vim.b.fujutsu_file = meta
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), '⋎ ' .. change:sub(1, 12)); assert(not rendered(win):find('', 1, true))
    config.sections.lualine_b = { { 'fujutsu_branch', icon = 'VC' } }
    lualine.setup(config)
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), 'VC'); includes(rendered(win), '⋎ ' .. change:sub(1, 12))
    config.sections.lualine_b = { 'fujutsu_branch' }
    lualine.setup(config)
    local branch = require('lualine.components.branch')
    local original_update = branch.update_status
    branch.update_status = function() return 'git-fallback' end
    vim.cmd.enew()
    eq('git-fallback', require('lualine.components.fujutsu_branch').update_status({}, true))
    lualine.refresh({ scope = 'all', force = true })
    includes(rendered(win), ''); includes(rendered(win), 'git-fallback')
    branch.update_status = original_update
    print('PASS: branch replacement, styling, working/historical/merge identity, Git fallback, and global statusline')
  end
end
local ok, err = xpcall(test, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd.cquit(1) end
vim.cmd('qa!')
