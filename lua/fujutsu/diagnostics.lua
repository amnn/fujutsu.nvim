local M = { workspaces = {} }

function M.plain(text)
  return (tostring(text or ''):gsub('\27%][^\7]*\7', ''):gsub('\27%[[0-?]*[ -/]*[@-~]', ''))
end

function M.record(root, item)
  root = root or vim.b.fujutsu_repo or vim.fn.getcwd()
  root = vim.uv.fs_realpath(root) or root
  local history = M.workspaces[root] or {}
  M.workspaces[root] = history
  item.stdout, item.stderr = M.plain(item.stdout), M.plain(item.stderr)
  history[#history + 1] = item
  if #history > 30 then table.remove(history, 1) end
  -- Diagnostics are bounded even for commands that produce large outputs.
  for _, key in ipairs({ 'stdout', 'stderr' }) do
    if #item[key] > 32768 then item[key] = item[key]:sub(1, 32768) .. '\n[output truncated]' end
  end
end

-- Summarize native facts, not just exit status. Full streams remain in health.
function M.summary(command, result, cancelled, label)
  local title = label or ('jj ' .. command)
  if cancelled then return title .. ': cancelled', vim.log.levels.INFO end
  local lines = vim.split(M.plain((result.stderr or '') .. '\n' .. (result.stdout or '')), '\n')
  local facts, seen, rebased, warning, failure, first = {}, {}, {}, nil, nil, nil
  local function add(value)
    if value and not seen[value] then facts[#facts + 1], seen[value] = value, true end
  end
  for _, line in ipairs(lines) do
    if line:match('%S') and not first then first = line end
    if line:match('^Error:') or line:match('^Internal error:') then failure = failure or line end
    if line:match('^Warning:') or line:match('^Concurrent modification')
      or line:match('^There are .*conflicts') or line:match('^Divergent changes:')
      or line:find('(conflict)', 1, true) then warning = warning or line end
    local created = line:match('^Created new commit (%S+)')
    local selected = line:match('^Selected changes%s*:%s*(%S+)')
    local remaining = line:match('^Remaining changes%s*:%s*(%S+)')
    local head = line:match('^Working copy%s+%(@%) now at:%s*(%S+)')
    local undo = line:match('^Undid operation:%s*(%S+)')
    local redo = line:match('^Redid operation:%s*(%S+)')
    if created then add('created ' .. created) end
    if selected then add('extracted ' .. selected) end
    if remaining then add('remaining ' .. remaining) end
    if head then add('@ ' .. head) end
    if undo then add('undid ' .. undo) end
    if redo then add('redid ' .. redo) end
    if line:match('^Rebased %d+') then rebased[#rebased + 1] = line:gsub('%.$', '') end
  end
  if command == 'rebase' then
    for i = #rebased, 1, -1 do table.insert(facts, 1, rebased[i]) end
  else
    for _, value in ipairs(rebased) do add(value) end
  end
  if result.code ~= 0 then
    return title .. ': ' .. (failure or first or 'failed') .. ' (:checkhealth jj)', vim.log.levels.ERROR
  end
  if warning then return title .. ': ' .. warning .. ' (:checkhealth jj)', vim.log.levels.WARN end
  return title .. ': ' .. (#facts > 0 and table.concat(facts, '; ') or first or 'completed'), vim.log.levels.INFO
end

function M.notice(text, level)
  local line = M.plain(text):gsub('[\r\n\t]+', ' ')
  local width = math.max(1, vim.o.columns - 12)
  local suffix = line:match(' %(:checkhealth jj%)$') or ''
  if #suffix < width and suffix ~= '' then line = line:sub(1, -#suffix - 1); width = width - #suffix
  else suffix = '' end
  if vim.fn.strdisplaywidth(line) > width then
    line = vim.fn.strcharpart(line, 0, width)
    repeat line = vim.fn.strcharpart(line, 0, math.max(0, vim.fn.strchars(line) - 1))
    until vim.fn.strdisplaywidth(line) < width
    line = line .. '…'
  end
  vim.notify(line .. suffix, level or vim.log.levels.INFO, { title = 'fujutsu' })
end

function M.error(message, root)
  M.record(root, { command = 'validation', code = 1, stderr = tostring(message) })
  local first = M.plain(message):match('[^\r\n]+') or 'Jujutsu failed'
  -- Lua assertions carry a source location; native jj diagnostics do not.
  -- Keep the original above, and strip only a leading Lua-file location here.
  if first:match('^/') or first:match('^[%a]:[/\\]') or first:match('^[%w_.%-/]+%.lua:%d+:') then
    first = first:gsub('^.-%.lua:%d+:%s*', '')
  end
  M.notice(first .. ' (:checkhealth jj)', vim.log.levels.ERROR)
end

return M
