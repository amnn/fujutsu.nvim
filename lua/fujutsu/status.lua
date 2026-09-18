local M = {}
local wrapper = "%!v:lua.require('fujutsu.status').render()"
local windows, departures = {}, {}
local workspace_buffers, workspaces = {}, {}
local applying, queued = false, false
local default = '%<%f %h%w%m%r%=%-14.(%l,%c%V%) %P'

function M.label(buf)
  -- Lualine passes its component object as the first argument.
  buf = type(buf) == 'number' and buf ~= 0 and buf or vim.api.nvim_get_current_buf()
  local meta = vim.b[buf].fujutsu_file or vim.b[buf].fujutsu_tree
  if meta and meta.change then return (meta.base and '⋎ ' or '○ ') .. meta.change:sub(1, 12) end
  local workspace = workspace_buffers[buf]
  if workspace and workspace.name == vim.api.nvim_buf_get_name(buf) then
    local change = workspaces[workspace.root].change
    return '@' .. (change and (' ' .. change:sub(1, 12)) or '')
  end
  return ''
end

local function refresh_workspace(root, workspace)
  if workspace.pending then workspace.again = true; return end
  workspace.pending = true
  vim.system({ 'jj', '--ignore-working-copy', '--no-pager', '--color=never', 'log',
    '--no-graph', '-r', '@', '-T', 'change_id' }, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      workspace.pending = false
      workspace.change = result.code == 0 and vim.trim(result.stdout) or nil
      if workspace.again then
        workspace.again = false
        refresh_workspace(root, workspace)
      end
      M.refresh()
      local lualine = package.loaded.lualine
      if type(lualine) == 'table' and lualine.refresh then
        lualine.refresh({ scope = 'all', place = { 'statusline' } })
      end
      vim.cmd.redrawstatus()
    end)
  end)
end

-- Discover on navigation, not while lualine draws. Cache per workspace and read
-- its recorded identity asynchronously without snapshotting files or editing it.
function M.track_workspace(buf)
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  workspace_buffers[buf] = nil
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or name == '' or name:find('://', 1, true)
    or vim.fn.isdirectory(name) == 1 then return end
  local path = vim.uv.fs_realpath(name) or name
  local marker = vim.fs.find('.jj', { path = vim.fs.dirname(path), upward = true, type = 'directory' })[1]
  if not marker or vim.fn.executable('jj') == 0 then return end
  local root = vim.fs.dirname(marker)
  local workspace = workspaces[root] or {}
  workspaces[root] = workspace
  workspace_buffers[buf] = { name = name, root = root }
  refresh_workspace(root, workspace)
end

function M.detect(value)
  for _, name in ipairs({ 'lualine', 'heirline', 'lightline', 'feline', 'airline' }) do
    if value:lower():find(name, 1, true) then return name end
  end
  if value:find('MiniStatusline', 1, true) then return 'mini.statusline' end
  return value:sub(1, 2) == '%!' and 'custom' or 'native'
end

local function append(value, label)
  if label == '' then return value end
  -- Append outside the provider's format: a %= substring might be inside
  -- an expression or escaped literal rather than an alignment directive.
  return value .. ' ' .. label:gsub('%%', '%%%%')
end

function M.render()
  local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  local state = windows[win]
  local value = state and state.original or ''
  if value == '' then value = vim.go.statusline end
  if value == '' or value == wrapper then value = default end
  if value:sub(1, 2) == '%!' then value = tostring(vim.fn.eval(value:sub(3))) end
  return append(value, M.label(vim.api.nvim_win_get_buf(win)))
end

local function integrate_lualine()
  local lualine = package.loaded.lualine
  if type(lualine) ~= 'table' or not lualine.get_config or not lualine.setup then return false end
  local config = lualine.get_config()
  local changed = false
  local function replace(sections)
    for _, components in pairs(sections or {}) do
      for index, component in ipairs(components) do
        if component == 'branch' then
          components[index] = 'fujutsu_branch'
          changed = true
        elseif type(component) == 'table' and component[1] == 'branch' then
          component[1] = 'fujutsu_branch'
          changed = true
        end
      end
    end
  end
  replace(config.sections)
  replace(config.inactive_sections)
  -- Inline extensions may define their own VC slot. String extension names
  -- remain lualine's responsibility and are not force-loaded here.
  for _, extension in ipairs(config.extensions or {}) do
    if type(extension) == 'table' then
      replace(extension.sections)
      replace(extension.inactive_sections)
    end
  end
  if changed then lualine.setup(config) end
  return true
end

function M.refresh()
  if applying then return end
  applying = true
  local ok, err = pcall(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local value = vim.api.nvim_get_option_value('statusline', { win = win, scope = 'local' })
      local state = windows[win]
      local historical = M.label(vim.api.nvim_win_get_buf(win)) ~= ''
      local original = (value == wrapper or value == '') and state and state.original
        or (value == '' and historical and departures[win]) or value
      local effective = original == '' and vim.go.statusline or original
      local provider = M.detect(effective)
      local lualine = provider == 'lualine' and integrate_lualine()
      local manual = effective:find('fujutsu.status', 1, true) and effective:find('label', 1, true)
      if historical and not lualine and not manual then
        if value ~= wrapper then
          windows[win] = { original = original, provider = provider }
          vim.api.nvim_set_option_value('statusline', wrapper, { win = win, scope = 'local' })
        end
      elseif state then
        if value == wrapper or value == '' then
          vim.api.nvim_set_option_value('statusline', state.original, { win = win, scope = 'local' })
        end
        windows[win] = nil
      end
    end
  end)
  applying = false
  if not ok then error(err, 0) end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('fujutsu_status', { clear = true })
  local leaving
  vim.api.nvim_create_autocmd('BufLeave', { group = group, callback = function()
    local win = vim.api.nvim_get_current_win()
    local value = vim.api.nvim_get_option_value('statusline', { win = win, scope = 'local' })
    departures[win] = value == wrapper and windows[win] and windows[win].original or value
  end })
  vim.api.nvim_create_autocmd('WinLeave', { group = group, callback = function()
    leaving = vim.api.nvim_get_current_win()
  end })
  vim.api.nvim_create_autocmd('WinNew', { group = group, callback = function()
    local win = vim.api.nvim_get_current_win()
    if vim.wo[win].statusline == wrapper then
      local origin = vim.fn.win_getid(vim.fn.winnr('#'))
      windows[win] = vim.deepcopy(windows[origin] or windows[leaving] or { original = '' })
    end
  end })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'BufWritePost', 'BufFilePost', 'VimEnter', 'FocusGained' }, {
    group = group, callback = function(event)
      M.track_workspace(event.buf)
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(event)
    M.track_workspace(event.buf)
    M.refresh()
  end })
  vim.api.nvim_create_autocmd('WinEnter', { group = group, callback = M.refresh })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(event)
    workspace_buffers[event.buf] = nil
  end })
  vim.api.nvim_create_autocmd('OptionSet', { group = group, pattern = 'statusline', callback = function()
    if applying or queued then return end
    queued = true
    vim.schedule(function() queued = false; M.refresh() end)
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(event)
    local win = tonumber(event.match)
    windows[win], departures[win] = nil, nil
    if leaving == win then leaving = nil end
  end })
end

return M
