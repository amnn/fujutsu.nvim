local M = {}

M.namespace = vim.api.nvim_create_namespace('fujutsu.ansi')

local palette = {
  '#000000', '#800000', '#008000', '#808000',
  '#000080', '#800080', '#008080', '#c0c0c0',
  '#808080', '#ff0000', '#00ff00', '#ffff00',
  '#0000ff', '#ff00ff', '#00ffff', '#ffffff',
}

local function color(index)
  if not index or index < 0 or index > 255 then return nil end
  if index < 16 then
    return vim.g['terminal_color_' .. index] or palette[index + 1]
  end
  if index >= 232 then
    local gray = 8 + (index - 232) * 10
    return ('#%02x%02x%02x'):format(gray, gray, gray)
  end
  local n = index - 16
  local function component(value) return value == 0 and 0 or 55 + value * 40 end
  return ('#%02x%02x%02x'):format(
    component(math.floor(n / 36)), component(math.floor(n / 6) % 6), component(n % 6))
end

local function sgr(style, parameters)
  local codes = {}
  for _, value in ipairs(vim.split(parameters, ';', { plain = true })) do
    codes[#codes + 1] = tonumber(value) or 0
  end
  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 then
      style = {}
    elseif code == 1 then style.bold = true
    elseif code == 3 then style.italic = true
    elseif code == 4 then style.underline = true
    elseif code == 7 then style.reverse = true
    elseif code == 9 then style.strikethrough = true
    elseif code == 22 then style.bold = nil
    elseif code == 23 then style.italic = nil
    elseif code == 24 then style.underline = nil
    elseif code == 27 then style.reverse = nil
    elseif code == 29 then style.strikethrough = nil
    elseif code == 39 then style.fg = nil; style.ctermfg = nil
    elseif code == 49 then style.bg = nil; style.ctermbg = nil
    else
      local key, index
      if code >= 30 and code <= 37 then key, index = 'fg', code - 30
      elseif code >= 40 and code <= 47 then key, index = 'bg', code - 40
      elseif code >= 90 and code <= 97 then key, index = 'fg', code - 90 + 8
      elseif code >= 100 and code <= 107 then key, index = 'bg', code - 100 + 8
      elseif code == 38 or code == 48 then
        key = code == 38 and 'fg' or 'bg'
        if codes[i + 1] == 5 then
          index = codes[i + 2]
          i = i + 2
        elseif codes[i + 1] == 2 and codes[i + 4] then
          local r, g, b = codes[i + 2], codes[i + 3], codes[i + 4]
          if r <= 255 and g <= 255 and b <= 255 then
            style[key] = ('#%02x%02x%02x'):format(r, g, b)
            style['cterm' .. key] = nil
          end
          i = i + 4
        end
      end
      if key and index and color(index) then
        style[key] = color(index)
        style['cterm' .. key] = index
      end
    end
    i = i + 1
  end
  return style
end

local definitions = {}

-- Existing extmarks keep their group names across colorscheme changes.
function M.refresh()
  for name, original in pairs(definitions) do
    local style = vim.deepcopy(original)
    for _, key in ipairs({ 'fg', 'bg' }) do
      if style['cterm' .. key] then style[key] = color(style['cterm' .. key]) end
    end
    vim.api.nvim_set_hl(0, name, style)
  end
end

function M.render(buf, text)
  local lines, spans, style = {}, {}, {}
  local groups = {}
  local function group()
    local parts = {}
    for _, key in ipairs({ 'fg', 'bg', 'ctermfg', 'ctermbg', 'bold', 'italic', 'underline', 'reverse', 'strikethrough' }) do
      if style[key] ~= nil then parts[#parts + 1] = key .. tostring(style[key]):gsub('#', '') end
    end
    if #parts == 0 then return nil end
    local name = 'FujutsuAnsi_' .. table.concat(parts, '_')
    if not groups[name] then
      vim.api.nvim_set_hl(0, name, style)
      definitions[name] = vim.deepcopy(style)
      groups[name] = true
    end
    return name
  end
  for row, line in ipairs(vim.split(text:gsub('\n$', ''), '\n', { plain = true })) do
    local chunks, col, pos = {}, 0, 1
    local function append(chunk)
      if chunk == '' then return end
      chunks[#chunks + 1] = chunk
      local hl = group()
      if hl then spans[#spans + 1] = { row - 1, col, col + #chunk, hl } end
      col = col + #chunk
    end
    while true do
      local first, last, parameters = line:find('\27%[([%d;]*)m', pos)
      if not first then append(line:sub(pos)); break end
      append(line:sub(pos, first - 1))
      style = sgr(style, parameters)
      pos = last + 1
    end
    lines[row] = table.concat(chunks)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, M.namespace, span[1], span[2], {
      end_col = span[3], hl_group = span[4],
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

return M
