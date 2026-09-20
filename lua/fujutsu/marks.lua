-- Registers are native Vim text; only unions of symbols present in this log
-- are marks. No background evaluation of arbitrary revset expressions.
local M = {}
local link

function M.unlink() link = nil end

function M.linked()
  if link then
    local info = vim.fn.getreginfo('"')
    if info.points_to ~= link.name or vim.fn.getreg(link.name) ~= link.text
      or vim.fn.getregtype(link.name) ~= link.type then link = nil end
  end
  return link and link.name
end

function M.signature()
  local parts = { M.linked() or '', vim.fn.getreginfo('"').points_to or '' }
  for name in ('"abcdefghijklmnopqrstuvwxyz'):gmatch('.') do
    local text = vim.fn.getreg(name)
    parts[#parts + 1] = #text .. ':' .. text .. vim.fn.getregtype(name)
  end
  return table.concat(parts, '\0')
end

function M.parse(text)
  text = vim.trim(text)
  if text == '' or text:find('[\r\n]') then return end
  local parts, start, quoted, escaped = {}, 1, false, false
  for i = 1, #text do
    local c = text:sub(i, i)
    if escaped then escaped = false
    elseif quoted and c == '\\' then escaped = true
    elseif c == '"' then quoted = not quoted
    elseif c == '|' and not quoted then parts[#parts + 1], start = text:sub(start, i - 1), i + 1 end
  end
  if quoted then return end
  parts[#parts + 1] = text:sub(start)
  for i, part in ipairs(parts) do
    part = vim.trim(part)
    if part == '' then return end
    if part:sub(1, 1) == '"' then
      local ok, value = pcall(vim.json.decode, part)
      if not ok or type(value) ~= 'string' then return end
      part = value
    elseif part:find('[%s()&~,:]') then return end
    parts[i] = part
  end
  return parts
end

function M.format(ids) return table.concat(ids, ' | ') end

function M.catalog(root, jj, query, limit)
  local template = 'json(commit_id) ++ "\\t" ++ json(change_id) ++ "\\t"'
    .. ' ++ json(stringify(change_id.shortest(8))) ++ "\\t"'
    .. ' ++ json(stringify(commit_id.shortest(8))) ++ "\\t"'
    .. ' ++ json(local_bookmarks.map(|b| b.name())) ++ "\\t" ++ json(current_working_copy) ++ "\\t"'
    .. ' ++ json(diff.stat().files().map(|f| f.path())) ++ "\\t"'
    .. ' ++ json(remote_bookmarks.map(|b| stringify(b.name() ++ "@" ++ b.remote()))) ++ "\\n"'
  local args = { 'log', '--no-graph', '-r', query or 'all()', '-T', template }
  if limit then vim.list_extend(args, { '-n', limit }) end
  local catalog = { symbols = {}, entries = {}, by_id = {}, short = {} }
  local function symbol(name, id)
    local previous = catalog.symbols[name]
    if previous == nil then catalog.symbols[name] = id
    elseif previous ~= id then catalog.symbols[name] = false end
  end
  for line in jj(root, args):gmatch('[^\n]+') do
    local fields = vim.split(line, '\t', { plain = true })
    for i, field in ipairs(fields) do fields[i] = vim.json.decode(field) end
    local id, change, short, commit_short, bookmarks, wc, paths, remotes = unpack(fields)
    local entry = { id = id, change = change, short = short, commit_short = commit_short, working_copy = wc, paths = paths }
    catalog.entries[#catalog.entries + 1], catalog.by_id[id] = entry, entry
    catalog[change] = catalog[change] == nil and id or false
    catalog.short[change] = short
    -- Prefix validity is deliberately scoped to this buffer. Before mutations
    -- jj resolves the original expression too, catching out-of-view ambiguity.
    for i = 1, #change do symbol(change:sub(1, i), id) end
    for i = 1, #id do symbol(id:sub(1, i), id) end
    symbol(short, id); symbol(commit_short, id)
    for _, name in ipairs(bookmarks) do symbol(name, id) end
    for _, name in ipairs(remotes) do symbol(name, id) end
    if wc then symbol('@', id) end
  end
  return catalog
end

function M.get(register, catalog)
  local parts = M.parse(vim.fn.getreg(register))
  if not parts then return end
  local changes, commits, seen = {}, {}, {}
  for _, part in ipairs(parts) do
    local id = catalog.symbols[part]
    if not id then return end
    if not seen[id] then
      changes[#changes + 1], commits[#commits + 1], seen[id] = catalog.by_id[id].change, id, true
    end
  end
  return changes, commits
end

function M.resolve(register, catalog, root, jj)
  local _, commits = M.get(register, catalog)
  if not commits then return end
  local output = jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r', vim.trim(vim.fn.getreg(register)),
    '-T', 'commit_id ++ "\\n"' })
  local resolved = vim.split(vim.trim(output), '\n', { plain = true })
  table.sort(resolved); table.sort(commits)
  assert(vim.deep_equal(resolved, commits), 'Register resolves differently outside this log; refresh or use an explicit revision')
  return commits
end

function M.modify(register, action, ids, catalog)
  register = register or '"'
  assert(register == '"' or register:match('^[a-zA-Z]$'), 'Use the unnamed register or a-z for marks')
  if register:match('^[A-Z]$') then
    register = register:lower()
    if action == 'replace' then action = 'append' end
  end
  if register == '"' then
    if action == 'replace' then M.unlink()
    else register = M.linked() or register end
  end
  local result = {}
  if action ~= 'replace' and vim.fn.getreg(register) ~= '' then
    local _, existing = M.get(register, catalog)
    result = assert(existing, 'Register is not a valid mark in this log')
  end
  ids = vim.tbl_map(function(id)
    return assert(catalog.by_id[id] and id or catalog[id], 'Select an unambiguous revision in this log')
  end, ids)
  local members = {}
  for _, id in ipairs(ids) do members[id] = true end
  if action == 'remove' then result = vim.tbl_filter(function(id) return not members[id] end, result)
  else
    local seen = {}
    for _, id in ipairs(result) do seen[id] = true end
    for _, id in ipairs(ids) do if not seen[id] then result[#result + 1], seen[id] = id, true end end
  end
  local text = M.format(vim.tbl_map(function(id)
    local entry = assert(catalog.by_id[id])
    return assert(catalog[entry.change] and catalog.short[entry.change] or entry.commit_short)
  end, result))
  local previous = M.linked()
  vim.fn.setreg(register, text, 'v')
  if text == '' then
    if previous == register or register == '"' then M.unlink() end
    return register
  end
  if register ~= '"' and (action ~= 'remove' or previous == register) then
    vim.fn.setreg('"', { points_to = register })
    link = { name = register, text = text, type = 'v' }
  elseif register == '"' then M.unlink() end
  return register
end

function M.clear(register)
  if register == '"' then register = M.linked() or register end
  vim.fn.setreg(register, '', 'v')
  if link and link.name == register then M.unlink() end
end

return M
