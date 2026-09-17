local M = {}
local render = require('fujutsu.ansi').render

local function plain(text)
  return (text:gsub('\27%[[%d;]*m', ''))
end

local function color(code, text)
  return '\27[' .. code .. 'm' .. text .. '\27[0m'
end

local function parse_stat(text)
  local status, added, removed, path = plain(text):match('^STAT\t([%u ])\t(%d+)\t(%d+)\t(.*)$')
  if not status then return end
  return { status = status, added = tonumber(added), removed = tonumber(removed), path = vim.json.decode(path) }
end

local function count(value, sign, code, width)
  local text = value == 0 and '' or sign .. value
  return string.rep(' ', width - #text) .. color(code, text)
end

local function stat(file, widths)
  local status, added, removed = file.status, file.added, file.removed
  -- Keep control characters in filenames from creating extra buffer rows.
  local path = vim.fn.strtrans(file.path)
  local total = added + removed
  local used = math.min(5, total)
  local green = total == 0 and 0 or math.floor(used * added / total + 0.5)
  if added > 0 and removed > 0 and used > 1 then
    green = math.max(1, math.min(used - 1, green))
  end
  local boxes = color('32', string.rep('■', green))
    .. color('31', string.rep('■', used - green))
    .. color('90', string.rep('■', 5 - used))
  local code = status == 'A' and '32' or status == 'D' and '31' or '33'
  return color(code, status) .. ' ' .. boxes
    .. ' ' .. count(added, '+', '32', widths.added)
    .. ' ' .. count(removed, '-', '31', widths.removed) .. (path == '' and '' or ' ' .. path)
end

function M.new(root, jj)
  local state = { expanded = {}, working_copy = true, rows = {} }

  function state.refresh(buf)
    local predicate = state.working_copy and 'current_working_copy' or 'false'
    for id, expanded in pairs(state.expanded) do
      if expanded then
        predicate = predicate .. ' || (!current_working_copy && stringify(commit_id) == "' .. id .. '")'
      end
    end
    local configured = vim.trim(jj(root, { 'config', 'get', 'templates.log' }))
    -- Markers provide revision ownership independently of graph glyphs, colors,
    -- abbreviated IDs, multiline descriptions, and the user's log template.
    -- Let jj draw the graph alongside file rows, including merges and forks.
    local template = '"\x1eENTRY\t" ++ commit_id ++ "\t" ++ current_working_copy ++ "\x1f" ++ ('
      .. configured .. ') ++ if(!stringify(' .. configured .. ').ends_with("\n"), "\n") ++ if('
      .. '(' .. predicate .. ') && diff.stat().files().len() > 0, '
      .. '"\n\x1eSTAT\t \t" ++ diff.stat().total_added() ++ "\t" ++ diff.stat().total_removed()'
      .. ' ++ "\t" ++ json("") ++ "\x1f\n" ++ '
      .. 'diff.stat().files().map(|f| "\x1eSTAT\t" ++ separate("\t", '
      .. 'f.status_char(), f.lines_added(), f.lines_removed(), json(f.display_diff_path()))'
      .. ' ++ "\x1f\n").join("") ++ "\n") ++ "\x1eEND\x1f\n"'
    -- Wrapping must happen in the editor, not through our metadata markers.
    local output = jj(root, { '--config', 'ui.log-word-wrap=false', 'log', '-T', template }, true)
    local lines, rows, entry = {}, {}, nil
    for line in (output:gsub('\n$', '') .. '\n'):gmatch('(.-)\n') do
      local skip = false
      line = line:gsub('\30(.-)\31', function(marker)
        local clean = plain(marker)
        local id, wc = clean:match('^ENTRY\t(%x+)\t(%a+)$')
        if id then
          entry = { id = id, working_copy = wc == 'true', first = #lines + 1 }
          return ''
        elseif clean == 'END' then
          skip = true
          entry = nil
          return ''
        elseif clean:sub(1, 5) == 'STAT\t' then
          local file = assert(parse_stat(marker), 'Invalid Jujutsu file stats')
          if file.status == ' ' then
            -- The total header comes first and bounds every file's counts.
            -- Size columns independently for each revision's stats block.
            entry.widths = {
              added = file.added == 0 and 0 or #tostring(file.added) + 1,
              removed = file.removed == 0 and 0 or #tostring(file.removed) + 1,
            }
          end
          return stat(file, entry.widths)
        end
        return ''
      end)
      if not skip then
        lines[#lines + 1] = line
        rows[#lines] = entry
      end
    end
    render(buf, table.concat(lines, '\n') .. '\n')
    state.rows = rows
  end

  function state.toggle(buf)
    local entry = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not entry then return end
    local old
    if entry.working_copy then
      old = state.working_copy
      state.working_copy = not old
    else
      old = state.expanded[entry.id]
      state.expanded[entry.id] = not old
    end
    local ok, err = pcall(state.refresh, buf)
    if not ok then
      if entry.working_copy then state.working_copy = old else state.expanded[entry.id] = old end
      error(err, 0)
    end
    vim.api.nvim_win_set_cursor(0, { math.min(entry.first, vim.api.nvim_buf_line_count(buf)), 0 })
  end

  return state
end

return M
