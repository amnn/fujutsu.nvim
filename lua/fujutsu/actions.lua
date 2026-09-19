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

function M.squash(log, buf, root, selected, key, reg)
  runner.guard(root)
  selection.validate(log, buf, selected)
  local contextual = M.ids(selected)
  local args = { 'squash' }
  if key == 'S' then
    local _, sources = marks.get(reg, log.catalog)
    assert(sources, 'Register ' .. reg .. ' is not a valid revision mark')
    vim.list_extend(args, { '--from', table.concat(sources, ' | '), '--into', table.concat(contextual, ' | ') })
  elseif key == 'x' then
    vim.list_extend(args, { '--from', table.concat(contextual, ' | '), '--insert-before', table.concat(contextual, ' | ') })
  else
    vim.list_extend(args, { '-r', table.concat(contextual, ' | ') })
  end
  local cleanup
  if key ~= 'S' then
    local patch = require('fujutsu.patch')
    args, cleanup = patch.prepare(root, patch.scope(log, selected), args)
  end
  local ok, result = pcall(runner.run, root, args, { done = function() if cleanup then cleanup() end end })
  if not ok then
    if cleanup then cleanup() end
    error(result, 0)
  end
  return result
end

function M.create(log, buf, root, selected, key)
  runner.guard(root)
  selection.validate(log, buf, selected)
  local ids = M.ids(selected)
  assert(#ids == 1, 'Select one contextual revision')
  local known = vim.deepcopy(log.catalog)
  local args = key == 'ge' and { 'edit', ids[1] }
    or { 'new', key == 'gn' and '--insert-after' or '--insert-before', ids[1] }
  if key == 'gN' then args[#args + 1] = '--no-edit' end
  return runner.run(root, args, { done = function(result)
    if result.code ~= 0 or key == 'ge' then return end
    local current = marks.catalog(root, file.jj)
    local created
    for change, id in pairs(current) do
      if known[change] == nil then
        assert(not created, 'More than one new change; select its description in the log')
        created = id
      end
    end
    if created then
      file.open(root, created, 'description', { description = true, explicit = true, readonly = false, command = 'edit' })
    end
  end })
end

function M.attach(log, buf, root)
  for _, key in ipairs({ 'gn', 'gN', 'ge' }) do
    vim.keymap.set('n', key, protect(function()
      M.create(log, buf, root, selection.capture(log, false), key)
    end), { buffer = buf, desc = key == 'ge' and 'Edit contextual revision' or 'Insert empty commit' })
  end
  for _, key in ipairs({ 's', 'S', 'x' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, key, protect(function()
        local reg = vim.v.register
        local selected = selection.capture(log, mode == 'x')
        M.squash(log, buf, root, selected, key, reg)
      end), { buffer = buf, desc = key == 'x' and 'Extract context before source' or 'Squash changes' })
    end
  end
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
