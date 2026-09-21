-- Rebase is a native pending operator. Its operands are chosen by temporary
-- operator-pending mappings, so keymap UIs can use normal mode discovery.
local M = {}
local selection = require('fujutsu.selection')
local active
local operator = "v:lua.require'fujutsu.rebase'.finish"
local specs = { ['<CR>'] = { 'b', 'o' } }
for _, source in ipairs({ 'b', 's', 'r' }) do
  specs[source .. '<CR>'] = { source, 'o' }
  for _, place in ipairs({ 'o', 'A', 'B' }) do specs[source .. place] = { source, place } end
end
local function description(upper, spec)
  return 'Rebase ' .. (upper and 'register' or 'context') .. ': '
    .. ({ b = 'branch', s = 'source and descendants', r = 'revisions' })[spec[1]] .. ' '
    .. ({ o = 'onto', A = 'after', B = 'before' })[spec[2]]
end

function M.cancel()
  local request = active
  if not request then return end
  active = nil
  vim.api.nvim_del_augroup_by_id(request.group)
  if vim.go.operatorfunc == operator then vim.go.operatorfunc = request.previous_operator end
  if vim.api.nvim_buf_is_loaded(request.buf) then
    vim.api.nvim_buf_call(request.buf, function()
      for _, binding in ipairs(request.bindings) do
        local current = vim.fn.maparg(binding.key, 'o', false, true)
        if current.callback == binding.callback then
          vim.keymap.del('o', binding.key, { buffer = request.buf })
          if binding.previous.buffer == 1 then vim.fn.mapset('o', false, binding.previous) end
        end
      end
    end)
  end
  return request
end

function M.finish()
  local request = M.cancel()
  if not request or not request.spec then return end -- An unrelated motion cancels.
  local ok, err = pcall(request.run, request.log, request.buf, request.root,
    request.selection, request.upper, request.register, request.spec[1], request.spec[2])
  if not ok then require('fujutsu.diagnostics').error(err) end
end

function M.start(log, buf, root, run, upper, visual)
  M.cancel()
  local register = vim.v.register
  local selected = selection.capture(log, visual)
  selection.entries(selected) -- Reject headers before entering operator-pending mode.
  local request = { log = log, buf = buf, root = root, run = run, upper = upper,
    register = register, selection = selected, bindings = {}, previous_operator = vim.go.operatorfunc }
  request.group = vim.api.nvim_create_augroup('fujutsu_rebase_pending', { clear = true })
  active = request
  for key, spec in pairs(specs) do
    local callback = function()
      request.spec = spec
      -- Complete g@ with a harmless character motion. The operator uses the
      -- captured revisions/Visual range, never the motion's text range.
      return 'l'
    end
    request.bindings[#request.bindings + 1] = {
      key = key, previous = vim.fn.maparg(key, 'o', false, true), callback = callback,
    }
    vim.keymap.set('o', key, callback, { buffer = buf, expr = true, nowait = true,
      desc = description(upper, spec) })
  end
  -- Vim invokes operatorfunc before emitting no:n. Escape/Ctrl-C and unrelated
  -- motions also leave pending mode, so every exit restores the user's state.
  vim.api.nvim_create_autocmd('ModeChanged', { group = request.group, pattern = 'no*:*', callback = function()
    if vim.fn.mode(1):sub(1, 2) ~= 'no' then M.cancel() end
  end })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'BufUnload' }, { group = request.group, buffer = buf, callback = function()
    M.cancel()
    if vim.fn.mode(1):sub(1, 2) == 'no' then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'ni', false)
    end
  end })
  vim.go.operatorfunc = operator
  local function begin()
    -- Invoke native g@, not the log's g@ mapping for jumping to the working copy.
    if active == request then vim.api.nvim_feedkeys('g@', 'ni', false) end
  end
  -- Let Visual-mode exit settle before entering a new pending mode. Do not
  -- defer when a complete key sequence is queued: its tail must follow g@.
  if visual and vim.fn.getchar(1) == 0 then vim.defer_fn(begin, 0)
  else begin() end
end

function M.attach(log, buf, root, run)
  for _, key in ipairs({ 'r', 'R' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      vim.keymap.set(mode, key, function()
        local ok, err = pcall(M.start, log, buf, root, run, key == 'R', mode == 'x')
        if not ok then M.cancel(); require('fujutsu.diagnostics').error(err) end
      end, { buffer = buf, nowait = true, desc = 'Rebase ' .. (key == 'r' and 'context' or 'register') })
      -- Keep complete buffer-local mappings too: an already queued global rbo
      -- can otherwise beat even a nowait buffer-local r starter.
      for suffix, spec in pairs(specs) do
        vim.keymap.set(mode, key .. suffix, function()
          local ok, err = pcall(function()
            local register = vim.v.register
            run(log, buf, root, selection.capture(log, mode == 'x'), key == 'R', register, spec[1], spec[2])
          end)
          if not ok then require('fujutsu.diagnostics').error(err) end
        end, { buffer = buf, nowait = true, desc = description(key == 'R', spec) })
      end
    end
  end
end

return M
