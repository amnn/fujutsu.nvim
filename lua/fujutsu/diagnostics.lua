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

function M.error(message, root)
  M.record(root, { command = 'validation', code = 1, stderr = tostring(message) })
  local first = M.plain(message):match('[^\r\n]+') or 'Jujutsu failed'
  M.notice(first .. ' (:checkhealth jj)', vim.log.levels.ERROR)
end

return M
