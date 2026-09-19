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
  -- Keeping an unterminated old final line while adding another line after it
  -- cannot represent two lines faithfully. Ask for the paired removal too.
  for i = 1, #result - 1 do
    assert(result[i]:sub(-1) == '\n', 'Select the paired newline change as well')
  end
  return table.concat(result)
end

function M.scope(log, selected)
  local first = selected.rows[selected.first]
  assert(first, 'No changes selected')
  if not selected.visual then
    if not first.path then return { kind = 'commits' } end
    if not first.old_line then return { kind = 'files', paths = { first.path } } end
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
  local kind, owner, path, rows, paths, seen = nil, nil, nil, {}, {}, {}
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
        end
      end
    end
  end
  return { kind = kind, paths = paths, row = first, rows = rows }
end

-- Configure a non-interactive diff editor that presents precisely the selected
-- source tree to jj. The matcher restricts materialization to this single path.
function M.prepare(root, scope, args)
  if scope.kind == 'commits' then return args end
  if scope.kind == 'files' then
    table.insert(args, '--')
    for _, path in ipairs(scope.paths) do args[#args + 1] = 'root-file:' .. vim.json.encode(path) end
    return args
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
  return config, function() vim.fn.delete(dir, 'rf') end
end

return M
