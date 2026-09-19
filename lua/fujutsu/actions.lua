local M = {}
local selection = require('fujutsu.selection')
local marks = require('fujutsu.marks')
local runner = require('fujutsu.runner')
local file = require('fujutsu.file')

local function protect(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  end
end
M.protect = protect

function M.ids(selected)
  return vim.tbl_map(function(entry) return entry.id end, selection.entries(selected))
end

function M.rebase_args(source, destination, mode, placement)
  assert(({ s = true, b = true, r = true })[mode], 'Invalid rebase source mode')
  assert(({ o = true, A = true, B = true })[placement], 'Invalid rebase placement')
  assert(#source > 0 and #destination > 0, 'Rebase requires sources and destinations')
  return { 'rebase', '-' .. mode, table.concat(source, ' | '), '-' .. placement, table.concat(destination, ' | ') }
end

function M.rebase(log, buf, root, selected, upper, reg, mode, placement)
  runner.guard(root)
  selection.validate(log, buf, selected)
  local contextual = M.ids(selected)
  local _, registered = marks.get(reg, log.catalog)
  if registered then
    return runner.run(root, M.rebase_args(upper and registered or contextual,
      upper and contextual or registered, mode, placement))
  end
  assert(not upper and reg == '"', 'Register ' .. reg .. ' is not a valid revision mark')
  local ok, base = pcall(file.jj, root, { 'config', 'get', 'fujutsu.rebase-base' })
  vim.ui.input({ prompt = 'Rebase ' .. mode .. ' / ' .. placement .. ' destination: ',
    default = ok and vim.trim(base) or 'main' }, function(value)
    if not value or vim.trim(value) == '' then return end
    protect(function()
      selection.validate(log, buf, selected)
      runner.run(root, M.rebase_args(contextual, { value }, mode, placement))
    end)()
  end)
end

local function specification(upper)
  vim.api.nvim_echo({ { (upper and 'R' or 'r') .. ': source [b]ranch / [s]ource / [r]evisions; Enter = bo', 'Question' } }, false, {})
  vim.cmd.redraw()
  local mode = vim.fn.getcharstr()
  if mode == '\27' then return end
  if mode == '\r' then return 'b', 'o' end
  assert(mode == 'b' or mode == 's' or mode == 'r', 'Expected b, s or r')
  vim.api.nvim_echo({ { 'Rebase ' .. mode .. ': [o]nto / [A]fter / [B]efore; Enter = onto', 'Question' } }, false, {})
  vim.cmd.redraw()
  local placement = vim.fn.getcharstr()
  if placement == '\27' then return end
  if placement == '\r' then placement = 'o' end
  assert(placement == 'o' or placement == 'A' or placement == 'B', 'Expected o, A or B')
  return mode, placement
end

function M.attach(log, buf, root)
  for _, key in ipairs({ 'r', 'R' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, key, protect(function()
        local reg = vim.v.register
        local selected = selection.capture(log, mode == 'x')
        local source, placement = specification(key == 'R')
        vim.api.nvim_echo({}, false, {})
        if source then M.rebase(log, buf, root, selected, key == 'R', reg, source, placement) end
      end), { buffer = buf, desc = 'Rebase ' .. (key == 'r' and 'context' or 'register') })
    end
  end
end

return M
