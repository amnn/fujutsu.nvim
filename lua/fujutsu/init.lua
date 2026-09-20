local M = {}

local function jj(cwd, args, colored)
  local command = { 'jj', '--no-pager', colored and '--color=always' or '--color=never' }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    error(require('fujutsu.diagnostics').plain(vim.trim(result.stderr or '') ~= '' and vim.trim(result.stderr) or 'jj failed'), 0)
  end
  return result.stdout
end

local function current_directory()
  local repo = vim.b.fujutsu_repo
  if repo then
    return repo
  end
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype == '' and name ~= '' then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

local logs = {}
local stale = {}

local function refresh(buf)
  logs[buf].refresh(buf)
  stale[buf] = nil
end

local function try_refresh(buf)
  local success, message = pcall(refresh, buf)
  if not success then require('fujutsu.diagnostics').error(message, vim.b[buf].fujutsu_repo) end
end

local group = vim.api.nvim_create_augroup('fujutsu_reload', { clear = true })
vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  callback = function(event)
    if not next(logs) or vim.bo[event.buf].buftype ~= '' then return end
    local name = vim.api.nvim_buf_get_name(event.buf)
    if name == '' then return end
    local ok, root = pcall(jj, vim.fs.dirname(name), { 'root' })
    if not ok then return end -- Files outside a jj workspace are irrelevant.
    root = vim.trim(root)
    root = vim.uv.fs_realpath(root) or root
    for buf in pairs(logs) do
      if vim.b[buf].fujutsu_repo == root then stale[buf] = true end
    end
  end,
})
vim.api.nvim_create_autocmd('BufEnter', {
  group = group,
  callback = function(event)
    if stale[event.buf] and not vim.bo[event.buf].modified then
      try_refresh(event.buf)
    end
  end,
})

function M.read_log(buf, root)
  vim.b[buf].fujutsu_repo = root
  vim.b[buf].fujutsu_log = true
  vim.bo[buf].buftype = 'nowrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  local log = logs[buf]
  if log then
    try_refresh(buf)
  else
    log = require('fujutsu.log').new(root, jj)
    local location = require('fujutsu.uri').parse(vim.api.nvim_buf_get_name(buf))
    log.query = vim.b[buf].fujutsu_query or location.query or ''
    log.limit = vim.b[buf].fujutsu_limit or location.limit
    log.refresh(buf)
    logs[buf] = log
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function()
        logs[buf] = nil
        stale[buf] = nil
      end,
    })
  end
  vim.keymap.set('n', '-', function()
    vim.cmd.edit(vim.fn.fnameescape(root .. '/.jj'))
  end, { buffer = buf, silent = true, desc = 'Open repository metadata directory' })
  for kind, pairs_ in pairs({ revision = { { '[[', ']]' } },
    file = { { '{{', '}}' }, { '[m', ']m' }, { '[/', ']/' } },
    hunk = { { '[c', ']c' } }, item = { { '(', ')' } } }) do
    for _, keys in ipairs(pairs_) do
      for index, key in ipairs(keys) do
        vim.keymap.set('n', key, function()
          log.move(kind, index == 1 and -1 or 1, vim.v.count1)
        end, { buffer = buf, silent = true, desc = 'Move to ' .. kind .. ' boundary' })
      end
    end
  end
  for key, command in pairs({ ['<CR>'] = 'edit', o = 'split', gO = 'vsplit', O = 'tabedit', p = 'pedit' }) do
    vim.keymap.set('n', key, function()
      local success, message = pcall(log.visit, buf, command)
      if not success then require('fujutsu.diagnostics').error(message, root) end
    end, { buffer = buf, silent = true, desc = 'Visit revision with ' .. command })
  end
  for key, fn in pairs({ ['='] = log.toggle, ['+'] = log.toggle_all, ['g@'] = log.head }) do
    vim.keymap.set('n', key, function()
      local success, message = pcall(fn, buf)
      if not success then require('fujutsu.diagnostics').error(message, root) end
    end, { buffer = buf, silent = true, desc = key == 'g@' and 'Jump to working-copy revision'
      or key == '+' and 'Toggle sibling expansions' or 'Toggle revision stats or file diff' })
  end
  require('fujutsu.log_ui').attach(log, buf, root)
  require('fujutsu.actions').attach(log, buf, root)
  vim.bo[buf].filetype = 'fujutsu'
end

local function focus_revision(buf, id)
  if not id then return end
  for index, row in pairs(logs[buf].rows) do
    local entry = row.entry or row
    if entry.id == id and entry.first == index then
      vim.api.nvim_win_set_cursor(0, { index, 0 })
      return
    end
  end
end

function M.open(opts)
  opts = opts or {}
  local mods = opts.smods or {}
  local root = vim.trim(jj(current_directory(), { 'root' }))
  root = vim.uv.fs_realpath(root) or root

  -- Explicit :tab always requests a new tab; otherwise reuse this tab's log.
  if not opts.new_log and not (mods.tab and mods.tab >= 0) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if logs[buf] and vim.b[buf].fujutsu_repo == root then
        refresh(buf)
        if opts.current_window then vim.cmd.buffer(buf)
        else vim.api.nvim_set_current_win(win) end
        focus_revision(buf, opts.revision)
        return
      end
    end
  end
  if opts.current_window then
    for buf in pairs(logs) do
      if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].fujutsu_repo == root
        and #vim.fn.win_findbuf(buf) == 0 then
        refresh(buf)
        vim.cmd.buffer(buf)
        focus_revision(buf, opts.revision)
        return
      end
    end
  end
  local name = require('fujutsu.uri').log_name(root, opts.query, opts.limit)
  local buf = vim.fn.bufnr(name)
  local fresh = buf == -1
  if fresh then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.b[buf].fujutsu_query, vim.b[buf].fujutsu_limit = opts.query or '', opts.limit
  end
  if not fresh and not vim.api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
  local ready, message = pcall(M.read_log, buf, root)
  if not ready then
    if fresh then vim.api.nvim_buf_delete(buf, { force = true }) end
    error(message, 0)
  end
  local ok, err = pcall(vim.cmd, { cmd = opts.current_window and 'buffer' or 'sbuffer',
    args = { tostring(buf) }, mods = mods })
  if not ok then
    if fresh then vim.api.nvim_buf_delete(buf, { force = true }) end
    error(err, 0)
  end
  vim.bo[buf].filetype = 'fujutsu'
  vim.wo.wrap = false
  focus_revision(buf, opts.revision)
end

function M.change_query(buf, query)
  local log = assert(logs[buf], 'Not a log buffer')
  query = vim.trim(query)
  local name = require('fujutsu.uri').log_name(vim.b[buf].fujutsu_repo, query, log.limit)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= buf then
    if not vim.api.nvim_buf_is_loaded(existing) then vim.fn.bufload(existing) end
    M.read_log(existing, vim.b[buf].fujutsu_repo)
    vim.cmd.buffer(existing)
    return existing
  end
  local old, effective = log.query, log.effective_query
  log.query = query
  local ok, err = pcall(log.refresh, buf)
  if not ok then log.query, log.effective_query = old, effective; error(err, 0) end
  return buf
end

function M.refresh_root(root)
  for buf in pairs(logs) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].fujutsu_repo == root then try_refresh(buf) end
  end
end

function M.log(buf) return logs[buf or vim.api.nvim_get_current_buf()] end

function M.selection()
  local buf = vim.api.nvim_get_current_buf()
  return logs[buf] and logs[buf].selection(buf)
end

function M.invalidate(root)
  for buf in pairs(logs) do
    if vim.b[buf].fujutsu_repo == root then stale[buf] = true end
  end
end

return M
