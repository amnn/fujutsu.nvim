local M = {}
local selection = require('fujutsu.selection')
local marks = require('fujutsu.marks')
local runner = require('fujutsu.runner')
local file = require('fujutsu.file')

local function protect(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then require('fujutsu.diagnostics').error(err) end
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
  local registered = marks.resolve(reg, log.catalog, root, file.jj)
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

function M.squash(log, buf, root, selected, key, reg)
  runner.guard(root)
  selection.validate(log, buf, selected)
  local contextual = M.ids(selected)
  local args = { 'squash' }
  if key == 'S' then
    local sources = marks.resolve(reg, log.catalog, root, file.jj)
    assert(sources, 'Register ' .. reg .. ' is not a valid revision mark')
    vim.list_extend(args, { '--from', table.concat(sources, ' | '), '--into', table.concat(contextual, ' | ') })
  elseif key == 'x' then
    vim.list_extend(args, { '--from', table.concat(contextual, ' | '), '--insert-before', table.concat(contextual, ' | ') })
  else
    vim.list_extend(args, { '-r', table.concat(contextual, ' | ') })
  end
  local cleanup, complete
  if key ~= 'S' then
    local patch = require('fujutsu.patch')
    args, cleanup, complete = patch.prepare(root, patch.scope(log, selected), args)
  end
  if key == 'x' and #contextual == 1 and not complete then
    -- split -B preserves the remainder's identity and description. Unlike
    -- squash it never abandons an emptied source, so complete selections
    -- retain squash (one atomic operation, including bookmark movement).
    local index = assert(vim.fn.index(args, 'squash') + 1)
    args[index], args[index + 1] = 'split', '-r'
    table.insert(args, index + 5, '-m')
    table.insert(args, index + 6, '')
  end
  local ok, result = pcall(runner.run, root, args, { cleanup = cleanup })
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
  local args = key == 'ge' and { 'edit', ids[1] }
    or { 'new', key == 'gn' and '--insert-after' or '--insert-before', ids[1] }
  if key == 'gN' then args[#args + 1] = '--no-edit' end
  return runner.run(root, args, { done = function(result)
    if result.code ~= 0 or key == 'ge' then return end
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_get_current_buf() ~= buf then return end
    local entry = selection.entries(selected)[1]
    local rev = key == 'gn' and '@' or 'parents(change_id(' .. entry.change .. ') & all())'
    local ok, created = pcall(file.resolve, root, rev)
    if ok then log.focus(created) end
  end })
end

function M.history(root, command)
  assert(command == 'undo' or command == 'redo', 'Expected undo or redo')
  return runner.run(root, { command })
end

function M.attach(log, buf, root)
  for key, command in pairs({ u = 'undo', ['<C-r>'] = 'redo' }) do
    vim.keymap.set('n', key, protect(function() M.history(root, command) end),
      { buffer = buf, desc = command .. ' repository operation' })
  end
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
  require('fujutsu.rebase').attach(log, buf, root, M.rebase)
end

return M
