local M = {}

-- Keep token byte offsets so UTF-8 text and graph prefixes remain aligned with
-- Neovim's extmarks. Empty tokens represent line boundaries, not buffer text.
local function tokens(lines)
  local text, positions = {}, {}
  for _, line in ipairs(lines) do
    local pos = 1
    while pos <= #line.text do
      local rest = line.text:sub(pos)
      local token = rest:match('^[%w_]+') or rest:match('^%s+')
        or rest:match('^[%z\1-\127\194-\244][\128-\191]*') or rest:sub(1, 1)
      text[#text + 1] = token
      positions[#text] = { line.row, line.col + pos - 1, line.col + pos - 1 + #token }
      pos = pos + #token
    end
    text[#text + 1] = ''
  end
  return table.concat(text, '\n') .. '\n', positions, #text
end

function M.word_spans(removed, added)
  if #removed == 0 or #added == 0 then return {} end
  local old, old_positions, old_count = tokens(removed)
  local new, new_positions, new_count = tokens(added)
  local spans = {}
  local function append(positions, first, count, group)
    for index = first, first + count - 1 do
      local position = positions[index]
      if position then
        local last = spans[#spans]
        if last and last[1] == position[1] and last[3] == position[2] and last[4] == group then
          last[3] = position[3]
        else
          spans[#spans + 1] = { position[1], position[2], position[3], group }
        end
      end
    end
  end
  local old_next, new_next = 1, 1
  for _, change in ipairs(vim.diff(old, new, { result_type = 'indices', algorithm = 'histogram' })) do
    -- A zero-length side refers to the token before the insertion point.
    local old_start = change[1] + (change[2] == 0 and 1 or 0)
    local new_start = change[3] + (change[4] == 0 and 1 or 0)
    append(old_positions, old_next, old_start - old_next, 'FujutsuDiffDeleteUnchanged')
    append(new_positions, new_next, new_start - new_next, 'FujutsuDiffAddUnchanged')
    old_next, new_next = old_start + change[2], new_start + change[4]
  end
  append(old_positions, old_next, old_count - old_next + 1, 'FujutsuDiffDeleteUnchanged')
  append(new_positions, new_next, new_count - new_next + 1, 'FujutsuDiffAddUnchanged')
  return spans
end

return M
