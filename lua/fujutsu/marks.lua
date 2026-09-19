-- Registers remain ordinary Vim text. Only our explicit change-ID union format
-- is recognized as a mark; arbitrary yanks are never evaluated as revsets.
local M = {}

function M.parse(text)
  local ids, seen = {}, {}
  for _, part in ipairs(vim.split(vim.trim(text), '|', { plain = true })) do
    local id = vim.trim(part):match('^change_id%(([k-z]+)%)$')
    if not id or #id ~= 32 then return nil end
    if not seen[id] then ids[#ids + 1], seen[id] = id, true end
  end
  return #ids > 0 and ids or nil
end

function M.format(ids)
  return table.concat(vim.tbl_map(function(id) return 'change_id(' .. id .. ')' end, ids), ' | ')
end

function M.catalog(root, jj)
  local visible = {}
  local text = jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r', 'all()',
    '-T', 'change_id ++ "\\t" ++ commit_id ++ "\\n"' })
  for change, commit in text:gmatch('([k-z]+)\t(%x+)\n') do
    visible[change] = visible[change] == nil and commit or false
  end
  return visible
end

function M.get(register, catalog)
  local ids = M.parse(vim.fn.getreg(register))
  if not ids then return end
  local commits = {}
  for _, id in ipairs(ids) do
    if not catalog[id] then return end
    commits[#commits + 1] = catalog[id]
  end
  return ids, commits
end

function M.modify(register, action, ids)
  register = register or '"'
  assert(register == '"' or register:match('^[a-zA-Z]$'), 'Use the unnamed register or a-z for marks')
  if register:match('^[A-Z]$') then
    register = register:lower()
    if action == 'replace' then action = 'append' end
  end
  local result = action == 'replace' and {} or (M.parse(vim.fn.getreg(register)) or {})
  local members = {}
  for _, id in ipairs(ids) do members[id] = true end
  if action == 'remove' then
    result = vim.tbl_filter(function(id) return not members[id] end, result)
  else
    local seen = {}
    for _, id in ipairs(result) do seen[id] = true end
    for _, id in ipairs(ids) do
      if not seen[id] then result[#result + 1], seen[id] = id, true end
    end
  end
  vim.fn.setreg(register, M.format(result), 'v')
  -- setreg() does not implement the unnamed-register alias of a native yank.
  if register ~= '"' and action ~= 'remove' then vim.fn.setreg('"', M.format(result), 'v') end
  return register
end

return M
