local M = {}

function M.plain(text)
  return (tostring(text or ''):gsub('\27%][^\7]*\7', ''):gsub('\27%[[0-?]*[ -/]*[@-~]', ''))
end

-- Summarize successful native outcomes; failures bypass this path entirely.
function M.summary(command, result, cancelled)
  local title = 'jj ' .. command
  if cancelled then return title .. ': cancelled', vim.log.levels.INFO end
  local lines = vim.split(M.plain((result.stderr or '') .. '\n' .. (result.stdout or '')), '\n')
  local facts, seen, rebased, warning, first = {}, {}, {}, nil, nil
  local function add(value)
    if value and not seen[value] then facts[#facts + 1], seen[value] = value, true end
  end
  for _, line in ipairs(lines) do
    if line:match('%S') and not first then first = line end
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
  if warning then return title .. ': ' .. warning, vim.log.levels.WARN end
  return title .. ': ' .. (#facts > 0 and table.concat(facts, '; ') or first or 'completed'), vim.log.levels.INFO
end

function M.notice(text, level)
  local line = M.plain(text):gsub('[\r\n\t]+', ' ')
  local width = math.max(1, vim.o.columns - 12)
  if vim.fn.strdisplaywidth(line) > width then
    line = vim.fn.strcharpart(line, 0, width)
    repeat line = vim.fn.strcharpart(line, 0, math.max(0, vim.fn.strchars(line) - 1))
    until vim.fn.strdisplaywidth(line) < width
    line = line .. '…'
  end
  vim.notify(line, level or vim.log.levels.INFO, { title = 'fujutsu' })
end

local function error_message(text)
  if text == '' then text = 'Jujutsu failed' end
  -- Use message history directly: notification providers need not retain text.
  -- No line/width/size truncation; :messages contains the complete failure.
  -- Do not set the API's err flag: inside BufReadCmd it would rethrow an
  -- already handled failure as a Vim/Lua callback error with another trace.
  vim.api.nvim_echo({ { text, 'ErrorMsg' } }, true, {})
end

function M.error(message)
  local text = M.plain(message)
  -- Remove Lua's location prefix, not native errors or their continuation lines.
  if text:match('^/') or text:match('^[%a]:[/\\]') or text:match('^[%w_.%-/]+%.lua:%d+:') then
    text = text:gsub('^[^\r\n]-%.lua:%d+:%s*', '')
  end
  error_message(text)
end

function M.failure(result, command)
  local parts = {}
  for _, stream in ipairs({ 'stderr', 'stdout' }) do
    local text = M.plain(result[stream])
    if text:match('%S') then parts[#parts + 1] = text end
  end
  error_message(#parts > 0 and table.concat(parts, '\n')
    or ('jj ' .. command .. ': failed (exit ' .. tostring(result.code) .. ')'))
end

return M
