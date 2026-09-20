local M = {}
local file = require('fujutsu.file')

-- Lines include their terminators so selection never adds a final newline as
-- a side effect. A selected replacement can independently remove/add lines.
local function lines(content)
  local result = {}
  for line in content:gmatch('[^\n]*\n') do result[#result + 1] = line end
  local tail = content:match('([^\n]+)$')
  if tail then result[#result + 1] = tail end
  return result
end

function M.apply(base, source, rows)
  local old, new = lines(base), lines(source)
  local remove, insert, changed = {}, {}, false
  for _, row in ipairs(rows) do
    local prefix = row.patch and row.patch:sub(1, 1)
    if prefix == '-' then
      assert(old[row.old_line] and old[row.old_line]:gsub('\n$', '') == row.patch:sub(2), 'Stale removed line')
      remove[row.old_line], changed = true, true
    elseif prefix == '+' then
      assert(new[row.new_line] and new[row.new_line]:gsub('\n$', '') == row.patch:sub(2), 'Stale added line')
      insert[row.old_line] = insert[row.old_line] or {}
      table.insert(insert[row.old_line], new[row.new_line])
      changed = true
    end
  end
  assert(changed, 'Selection contains no changed lines')
  local result = {}
  for i = 1, #old + 1 do
    vim.list_extend(result, insert[i] or {})
    if old[i] and not remove[i] then result[#result + 1] = old[i] end
  end
  -- An intermediate tree may retain an unterminated old line followed by a
  -- selected addition. Supply its separator; jj leaves the compensating edit
  -- in the source. The final selected line retains its original EOF status.
  for i = 1, #result - 1 do
    if result[i]:sub(-1) ~= '\n' then result[i] = result[i] .. '\n' end
  end
  return table.concat(result)
end

function M.scope(log, selected)
  local first = selected.rows[selected.first]
  assert(first, 'No changes selected')
  if not selected.visual then
    if not first.path then return { kind = 'commits' } end
    if not first.old_line then
      return { kind = 'files', paths = { first.path }, owner = first.entry.id,
        renames = first.status == 'R' and { [first.path] = true } or {} }
    end
    local start = selected.first
    while start > 1 and not log.rows[start].hunk do
      start = start - 1
      assert(log.rows[start] and log.rows[start].path == first.path, 'No hunk selected')
    end
    local rows = {}
    for i = start + 1, #log.rows do
      local row = log.rows[i]
      if not row or row.hunk or row.first ~= first.first or not row.patch then break end
      rows[#rows + 1] = row
    end
    return { kind = 'lines', row = first, rows = rows }
  end
  local kind, owner, path, rows, paths, seen, renames = nil, nil, nil, {}, {}, {}, {}
  for i = selected.first, selected.last do
    local row = selected.rows[i]
    if row and (row.id or row.entry) then
      local current = row.patch and 'lines' or row.path and 'files' or 'commits'
      assert(not kind or kind == current, 'Mixed commit/file/line selection; select one scope explicitly')
      kind = current
      if current ~= 'commits' then
        assert(not owner or owner == row.entry.id, 'Partial selections must belong to one commit')
        owner = row.entry.id
        if current == 'lines' then
          assert(not path or path == row.path, 'Select changed lines within one file')
          path = row.path
          rows[#rows + 1] = row
        elseif not seen[row.path] then
          paths[#paths + 1], seen[row.path] = row.path, true
          if row.status == 'R' then renames[row.path] = true end
        end
      end
    end
  end
  return { kind = kind, paths = paths, row = first, rows = rows, owner = owner, renames = renames }
end

-- Configure a non-interactive diff editor that presents precisely the selected
-- source tree to jj. The matcher restricts materialization to this single path.
local function covers_files(root, owner, paths)
  local selected = {}
  for _, path in ipairs(paths) do selected[path] = true end
  local all = vim.json.decode(file.jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r', owner,
    '-T', 'json(diff.stat().files().map(|f| f.path()))' }))
  for _, path in ipairs(all) do if not selected[path] then return false end end
  return true
end

function M.prepare(root, scope, args)
  if scope.kind == 'commits' then return args, nil, true end
  if scope.kind == 'files' then
    -- jj's fileset matcher selects tree paths, not a rendered rename pair.
    -- Include the old path too or a whole-file rename becomes only an addition.
    if next(scope.renames or {}) then
      local pairs_ = file.jj(root, { '--ignore-working-copy', 'diff', '-r', scope.owner, '-T',
        'json(source.path()) ++ "\\t" ++ json(target.path()) ++ "\\n"' })
      for source, target in pairs_:gmatch('([^\n]+)\t([^\n]+)\n') do
        if scope.renames[vim.json.decode(target)] then
          scope.paths[#scope.paths + 1] = vim.json.decode(source)
        end
      end
    end
    table.insert(args, '--')
    for _, path in ipairs(scope.paths) do args[#args + 1] = 'root-file:' .. vim.json.encode(path) end
    return args, nil, covers_files(root, scope.owner, scope.paths)
  end
  assert(scope.kind == 'lines', 'No changes selected')
  local row = scope.row
  assert(row.status == 'A' or row.status == 'M' or row.status == 'D', 'Select the whole file for renames or copies')
  local diff = file.jj(root, { '--ignore-working-copy', 'diff', '-r', row.entry.id, '--git', '--',
    'root-file:' .. vim.json.encode(row.path) })
  assert(not diff:find('120000', 1, true) and not diff:find('160000', 1, true), 'Select the whole file for symlinks or submodules')
  assert(vim.trim(file.jj(root, { '--ignore-working-copy', 'log', '--no-graph', '-r', row.entry.id,
    '-T', 'conflict' })) == 'false', 'Resolve conflicts before selecting partial patches')
  local base = row.status == 'A' and '' or file.base(root, row.entry.id, row.path)
  local source = row.status == 'D' and '' or file.content(root, row.entry.id, row.path)
  assert(not base:find('\0', 1, true) and not source:find('\0', 1, true), 'Select the whole file for binary changes')
  local content = M.apply(base, source, scope.rows)
  local complete = content == source and not diff:find('\nold mode ', 1, true)
    and covers_files(root, row.entry.id, { row.path })
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local payload = assert(io.open(dir .. '/content', 'wb')); payload:write(content); payload:close()
  local script = [[#!/bin/sh
set -eu
left=$1
right=$2
path=$3
payload=$4
action=$5
root=$6
change=$7
expected=$8
check_revision() {
  latest=$(jj --no-pager --color=never --ignore-working-copy -R "$root" log --no-graph -r "change_id($change) & all()" -T commit_id)
  [ "$latest" = "$expected" ] || { echo 'Source changed; select the patch again' >&2; exit 1; }
}
check_revision
[ ! -L "$right/$path" ] && [ ! -L "$left/$path" ] || exit 1
if [ "$action" = remove ]; then
  rm -f -- "$right/$path"
else
  mkdir -p -- "$(dirname -- "$right/$path")"
  # Preserve old executable mode for partial patches; a file selection moves
  # metadata. Added files keep their newly materialized mode.
  if [ -f "$left/$path" ]; then
    cp -p -- "$left/$path" "$right/$path"
    chmod u+w "$right/$path"
  fi
  cat -- "$payload" > "$right/$path"
fi
check_revision
]]
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), dir .. '/select.sh')
  local config = { '--config', 'merge-tools.fujutsu-select.program="/bin/sh"', '--config',
    'merge-tools.fujutsu-select.edit-args=' .. vim.json.encode({ dir .. '/select.sh', '$left', '$right',
      row.path, dir .. '/content', row.status == 'D' and content == '' and 'remove' or 'write',
      root, row.entry.change, row.entry.id }) }
  vim.list_extend(config, args)
  vim.list_extend(config, { '--tool', 'fujutsu-select', '--', 'root-file:' .. vim.json.encode(row.path) })
  return config, function() vim.fn.delete(dir, 'rf') end, complete
end

return M
