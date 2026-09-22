local M = {}
local selection = require('fujutsu.selection')
local sources = { b = 'branch', s = 'source and descendants', r = 'revisions' }

function M.attach(log, buf, root, run)
  -- Keep the native register prefix in charge of reading its operand. A
  -- register-picker mapping can suspend/remove the following prefix guards.
  -- This identity mapping neither captures nor replays register contents.
  vim.keymap.set('n', '"', '"', { buffer = buf, desc = 'Use native register prefix' })
  for _, key in ipairs({ 'r', 'R' }) do
    local title = 'Rebase ' .. (key == 'r' and 'context' or 'register')
    local specs = { ['<CR>'] = { 'b', 'o' } }
    for _, source in ipairs({ 'b', 's', 'r' }) do
      specs[source .. '<CR>'] = { source, 'o' }
      for _, place in ipairs({ 'o', 'A', 'B' }) do specs[source .. place] = { source, place } end
    end
    -- Literal no-op guards prevent native Replace fallthrough. They are not
    -- executable prefix callbacks, so keymap UIs can discover their children.
    -- Never use nowait on a prefix: complete specifications must remain reachable.
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, desc = title .. '…' })
    for _, source in ipairs({ 'b', 's', 'r' }) do
      vim.keymap.set('n', key .. source, '<Nop>', {
        buffer = buf, desc = title .. ': ' .. sources[source] .. '…',
      })
    end
    for _, suffix in ipairs({ '', 'b', 's', 'r' }) do
      vim.keymap.set('n', key .. suffix .. '<Esc>', '<Esc>', { buffer = buf, desc = 'Cancel rebase' })
    end
    for suffix, spec in pairs(specs) do
      vim.keymap.set('n', key .. suffix, function()
        local ok, err = pcall(function()
          local register = vim.v.register
          run(log, buf, root, selection.capture(log, false), key == 'R', register, spec[1], spec[2])
        end)
        if not ok then require('fujutsu.diagnostics').error(err) end
      end, { buffer = buf, nowait = true, desc = title .. ': ' .. sources[spec[1]] .. ' '
        .. ({ o = 'onto', A = 'after', B = 'before' })[spec[2]] })
    end
  end
end

return M
