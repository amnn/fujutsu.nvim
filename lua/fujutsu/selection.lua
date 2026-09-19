local M = {}

-- Capture visual coordinates before leaving Visual mode. All mutations validate
-- this snapshot after refreshing, including every line of a partial selection.
function M.capture(log, visual)
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local first, last = cursor, cursor
  if visual then
    assert(vim.fn.mode() ~= '\22', 'Blockwise change selection is not supported')
    first = vim.fn.line('v')
    first, last = math.min(first, cursor), math.max(first, cursor)
    vim.cmd.normal({ args = { '\27' }, bang = true })
  end
  local rows = {}
  for i = first, last do rows[i] = vim.deepcopy(log.rows[i]) end
  return { first = first, last = last, rows = rows, visual = visual }
end

function M.validate(log, buf, selection)
  log.refresh(buf)
  for i = selection.first, selection.last do
    assert(vim.deep_equal(selection.rows[i], log.rows[i]), 'Log changed; select the sources again')
  end
end

function M.entries(selection)
  local entries, seen = {}, {}
  for i = selection.first, selection.last do
    local row = selection.rows[i]
    local entry = row and (row.entry or row)
    if entry and entry.id and not seen[entry.id] then
      entries[#entries + 1], seen[entry.id] = entry, true
    end
  end
  assert(#entries > 0, 'No commit selected')
  return entries
end

return M
