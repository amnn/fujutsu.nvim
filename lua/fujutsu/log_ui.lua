local M = {}
local marks = require('fujutsu.marks')
local selection = require('fujutsu.selection')
local diagnostics = require('fujutsu.diagnostics')
local ns = vim.api.nvim_create_namespace('fujutsu.marks')

function M.header(log, root, jj)
  log.catalog = marks.catalog(root, jj, log.effective_query, log.limit)
  log.marks, log.tokens = {}, {}
  local linked = marks.linked()
  local line = 'Marks:'
  for name in ('"abcdefghijklmnopqrstuvwxyz'):gmatch('.') do
    local _, commits = marks.get(name, log.catalog)
    if commits then
      log.marks[name] = commits
      if name ~= '"' or not linked then
        local prefix = linked == name and ' "' or '  '
        local start = #line
        line = line .. prefix .. name .. (#commits == 1 and '' or '[' .. #commits .. ']')
        log.tokens[#log.tokens + 1] = { register = name, first = start + 1, last = #line }
      end
    end
  end
  if log.pinned and not log.marks[log.pinned] then log.pinned = nil end
  log.register_signature = marks.signature()
  return { line, '' }, { { kind = 'marks' }, { kind = 'margin' } }
end

function M.token(log)
  local cursor = vim.api.nvim_win_get_cursor(0)
  if not log.rows[cursor[1]] or log.rows[cursor[1]].kind ~= 'marks' then return end
  for _, token in ipairs(log.tokens or {}) do
    if cursor[2] >= token.first and cursor[2] < token.last then return token.register end
  end
end

function M.draw(log, buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for group, base in pairs({ FujutsuHeader = 'Label', FujutsuMark = 'Special',
    FujutsuMarkPinned = 'DiagnosticInfo', FujutsuMarkPreview = 'Search' }) do
    vim.api.nvim_set_hl(0, group, { default = true, link = base })
  end
  local pinned = log.pinned
  local preview = vim.api.nvim_get_current_buf() == buf and M.token(log) or nil
  preview = preview or log.preview
  if preview == pinned then preview = nil end
  local baseline = pinned or marks.linked() or '"'
  local membership = {}
  for _, id in ipairs(log.marks and log.marks[baseline] or {}) do
    membership[id] = { baseline, pinned and 'FujutsuMarkPinned' or 'FujutsuMark' }
  end
  for _, id in ipairs(log.marks and log.marks[preview] or {}) do
    membership[id] = { preview, 'FujutsuMarkPreview' }
  end
  for i, row in pairs(log.rows) do
    if row.kind == 'query' or row.kind == 'marks' then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = 6, hl_group = 'FujutsuHeader' })
      if row.kind == 'query' and (not log.query or log.query == '') then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 7, { hl_eol = true,
          end_col = #vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1], hl_group = 'Comment' })
      elseif row.kind == 'marks' then
        for _, token in ipairs(log.tokens) do
          local group = token.register == preview and 'FujutsuMarkPreview'
            or token.register == pinned and 'FujutsuMarkPinned' or 'FujutsuMark'
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, token.first, { end_col = token.last, hl_group = group })
        end
      end
    end
    local entry = row.entry or row
    local mark = membership[entry.id]
    if i == entry.first and mark then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { sign_text = mark[1] .. ' ', sign_hl_group = mark[2] })
    end
  end
end

function M.pin(log, buf)
  local name = assert(M.token(log), 'Select a mark token to pin it')
  log.pinned = log.pinned ~= name and name or nil
  M.draw(log, buf)
end

function M.attach(log, buf, root)
  local function protect(fn)
    return function()
      local ok, err = pcall(fn)
      if not ok then diagnostics.error(err, root) end
    end
  end
  for key, action in pairs({ m = 'replace', M = 'append', dm = 'remove' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, key, protect(function()
        local reg = vim.v.register
        local token = mode == 'n' and M.token(log)
        if token then
          assert(key == 'dm', 'Use dm to clear or Enter to pin a mark')
          marks.clear(token)
          log.refresh(buf)
          return
        end
        local selected = selection.capture(log, mode == 'x')
        selection.validate(log, buf, selected)
        local ids = vim.tbl_map(function(entry) return entry.id end, selection.entries(selected))
        local affected = marks.modify(reg, action, ids, log.catalog)
        log.preview = affected ~= log.pinned and affected or nil
        log.refresh(buf)
        local timer = {}
        log.preview_token = timer
        vim.defer_fn(function()
          if log.preview_token ~= timer then return end
          log.preview = nil
          M.draw(log, buf)
        end, 1500)
      end), { buffer = buf, desc = action .. ' revision mark' })
    end
  end
  local group = vim.api.nvim_create_augroup('fujutsu_marks_' .. buf, { clear = true })
  local queued = false
  local function update(force)
    if queued or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then return end
    if not force and log.register_signature == marks.signature() then M.draw(log, buf); return end
    queued = true
    vim.schedule(function()
      queued = false
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        local ok, err = pcall(log.refresh, buf)
        if not ok then diagnostics.error(err, root) end
      end
    end)
  end
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = function() update(false) end })
  vim.api.nvim_create_autocmd({ 'TextYankPost', 'BufEnter', 'CmdlineLeave' }, { group = group, callback = function(event)
    if event.event == 'TextYankPost' then marks.unlink() end
    if event.event == 'CmdlineLeave' then vim.schedule(function() update(false) end)
    else update(true) end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(group) end })
end

function M.edit_query(log, buf)
  -- input() is intentionally command-line based, rather than a ui.input()
  -- provider that may choose a full floating editor. Keep failed input editable.
  local query = log.query or ''
  while true do
    vim.fn.inputsave()
    local ok, value = pcall(vim.fn.input, { prompt = 'Revset (empty = default): ', default = query, cancelreturn = '\27' })
    vim.fn.inputrestore()
    if not ok or value == '\27' then return end
    local applied, err = pcall(require('fujutsu').change_query, buf, value)
    if applied then return end
    diagnostics.error(err, vim.b[buf].fujutsu_repo)
    query = value
  end
end

return M
