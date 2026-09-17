local M = {}
local generated = {}

-- Replace our derived defaults, but leave explicit user definitions alone.
local function derived(name, style)
  local current = vim.api.nvim_get_hl(0, { name = name, link = true })
  if next(current) == nil or vim.deep_equal(current, generated[name]) then
    vim.api.nvim_set_hl(0, name, style)
    generated[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
  end
end

function M.refresh()
  for name, link in pairs({
    diffLine = 'Statement', diffSubname = 'PreProc',
    FujutsuDiffAdd = 'DiffAdd', FujutsuDiffDelete = 'DiffDelete',
    FujutsuDiffHunk = 'diffLine', FujutsuDiffContext = 'diffSubname',
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  for kind, base in pairs({ Add = 'Added', Delete = 'Removed', Change = 'Changed', Neutral = 'Comment' }) do
    local style = vim.api.nvim_get_hl(0, { name = base, link = false })
    -- Links inherit backgrounds and reverse video too. Copy only foregrounds
    -- so stats stay unboxed, regardless of how the colorscheme styles the base.
    derived('FujutsuStat' .. kind, {
      fg = style.fg or normal.fg,
      ctermfg = style.ctermfg or normal.ctermfg,
    })
  end
  for _, kind in ipairs({ 'Add', 'Delete' }) do
    local style = vim.api.nvim_get_hl(0, { name = 'FujutsuDiff' .. kind, link = false })
    local dark = vim.o.background == 'dark'
    local fg = style.fg or normal.fg or (dark and 0xffffff or 0x000000)
    local bg = style.bg or normal.bg or (dark and 0x000000 or 0xffffff)
    if style.reverse then fg, bg = bg, fg end
    local dimmed = 0
    for _, shift in ipairs({ 0, 8, 16 }) do
      local scale = 2 ^ shift
      local front, back = math.floor(fg / scale) % 256, math.floor(bg / scale) % 256
      dimmed = dimmed + math.floor((front + back) / 2) * scale
    end
    -- Only the foreground changes; the underlying diff background survives.
    derived('FujutsuDiff' .. kind .. 'Unchanged', { fg = dimmed, ctermfg = 8 })
  end
end

vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('fujutsu.highlights', { clear = true }),
  callback = function()
    M.refresh()
    require('fujutsu.ansi').refresh()
  end,
})

return M
