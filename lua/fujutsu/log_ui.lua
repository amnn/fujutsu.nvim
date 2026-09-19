local M = {}
local marks = require('fujutsu.marks')
local selection = require('fujutsu.selection')
local ns = vim.api.nvim_create_namespace('fujutsu.marks')

function M.header(log, root, jj)
  log.catalog = marks.catalog(root, jj)
  local lines, rows = { 'Marks' }, { { kind = 'marks' } }
  log.marks = {}
  for name in ('"abcdefghijklmnopqrstuvwxyz'):gmatch('.') do
    local ids = marks.get(name, log.catalog)
    if ids then
      log.marks[name] = ids
      local short = vim.tbl_map(function(id) return id:sub(1, 8) end, ids)
      lines[#lines + 1] = ('  %s%s [%d] %s'):format(name, log.pinned == name and ' *' or '', #ids,
        table.concat(short, ' '))
      rows[#lines] = { kind = 'mark', register = name }
    end
  end
  lines[#lines + 1], rows[#lines + 1] = '', { kind = 'margin' }
  return lines, rows
end

function M.draw(log, buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local row = vim.api.nvim_get_current_buf() == buf and log.rows[vim.fn.line('.')] or nil
  local name = row and row.register or log.preview or log.pinned or '"'
  local ids = log.marks and log.marks[name] or {}
  local members = {}
  for _, id in ipairs(ids) do members[id] = true end
  vim.api.nvim_buf_set_extmark(buf, ns, log.query and 1 or 0, 0, {
    virt_text = { { '  Gutter: ' .. name, 'Comment' } },
  })
  for i, item in pairs(log.rows) do
    local entry = item.entry or item
    if i == entry.first and members[entry.change] then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { sign_text = name .. ' ', sign_hl_group = 'Special' })
    end
  end
end

function M.attach(log, buf, root)
  local function protect(fn)
    return function()
      local ok, err = pcall(fn)
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
    end
  end
  for key, action in pairs({ m = 'replace', M = 'append', d = 'remove' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, key, protect(function()
        local reg = vim.v.register
        local row = log.rows[vim.fn.line('.')]
        if mode == 'n' and row and row.register then
          assert(key == 'd', 'Use d to clear or Space to pin a mark')
          vim.fn.setreg(row.register, '', 'v')
          log.refresh(buf)
          return
        end
        local selected = selection.capture(log, mode == 'x')
        selection.validate(log, buf, selected)
        local ids = vim.tbl_map(function(entry) return entry.change end, selection.entries(selected))
        local affected = marks.modify(reg, action, ids)
        log.preview = affected
        log.refresh(buf)
        local token = {}
        log.preview_token = token
        vim.defer_fn(function()
          if log.preview_token ~= token then return end
          log.preview = nil
          M.draw(log, buf)
        end, 1500)
      end), { buffer = buf, desc = action .. ' revision mark' })
    end
  end
  vim.keymap.set('n', '<Space>', protect(function()
    local row = log.rows[vim.fn.line('.')]
    assert(row and row.register, 'Select a row in Marks to pin it')
    log.pinned = log.pinned ~= row.register and row.register or nil
    log.refresh(buf)
  end), { buffer = buf, desc = 'Pin mark gutter' })
  local group = vim.api.nvim_create_augroup('fujutsu_marks_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buf, callback = function() M.draw(log, buf) end })
  -- Native yanks replace the unnamed mark; rebuilding must happen after the
  -- yank has completed, not inside TextYankPost's textlock.
  vim.api.nvim_create_autocmd({ 'TextYankPost', 'BufEnter' }, { group = group, callback = function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf then
        local ok, err = pcall(log.refresh, buf)
        if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
      end
    end)
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(group) end })
end

return M
