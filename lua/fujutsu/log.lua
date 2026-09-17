local M = {}
local ansi = require('fujutsu.ansi')
local render = ansi.render
local word_spans = require('fujutsu.diff').word_spans

local function plain(text)
  return (text:gsub('\27%[[%d;]*m', ''))
end

local function parse_stat(text)
  local status, added, removed, path, target = plain(text):match('^STAT\t([%u ])\t(%d+)\t(%d+)\t(.*)\t(.*)$')
  if not status then return end
  return { status = status, added = tonumber(added), removed = tonumber(removed),
    path = vim.json.decode(path), target = vim.json.decode(target) }
end

local function count(value, sign, width)
  local text = value == 0 and '' or sign .. value
  return string.rep(' ', width - #text) .. text
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
  local text, spans = '', {}
  local function append(chunk, kind)
    if kind and #chunk > 0 then
      spans[#spans + 1] = { #text, #text + #chunk, 'FujutsuStat' .. kind }
    end
    text = text .. chunk
  end
  append(status, status == 'A' and 'Add' or status == 'D' and 'Delete' or 'Change')
  append(' ')
  append(string.rep('■', green), 'Add')
  append(string.rep('■', used - green), 'Delete')
  append(string.rep('■', 5 - used), 'Neutral')
  append(' ')
  append(count(added, '+', widths.added), 'Add')
  append(' ')
  append(count(removed, '-', widths.removed), 'Delete')
  append(path == '' and '' or ' ' .. path)
  return text, spans
end

function M.new(root, jj)
  local state = { expanded = {}, files = {}, working_copy = true, rows = {} }

  local function hunk_context(file, start)
    if start <= 1 then return '' end
    if not file.context then
      -- Read the rendered revision, never the on-disk working copy. Cache only
      -- for this refresh so snapshot changes cannot leave stale section names.
      local ok, content = pcall(jj, root, { '--ignore-working-copy', 'file', 'show',
        '-r', file.entry.id, '--', 'root-file:' .. vim.json.encode(file.path) })
      file.context = {}
      local previous = ''
      if ok then
        for index, line in ipairs(vim.split(content, '\n', { plain = true })) do
          file.context[index] = previous
          -- Git's default section heuristic: an unindented line beginning
          -- with a letter, underscore, or dollar sign.
          if line:match('^[%a_$]') then
            previous = vim.fn.strcharpart(line:gsub('%s+$', ''), 0, 80)
          end
        end
      end
    end
    return file.context[start] or ''
  end

  function state.refresh(buf)
    local predicate = state.working_copy and 'current_working_copy' or 'false'
    for id, expanded in pairs(state.expanded) do
      if expanded then
        predicate = predicate .. ' || (!current_working_copy && stringify(commit_id) == "' .. id .. '")'
      end
    end
    local diffs = ''
    for id, files in pairs(state.files) do
      local owner = id == '@' and 'current_working_copy'
        or '(!current_working_copy && stringify(commit_id) == "' .. id .. '")'
      for path, expanded in pairs(files) do
        if expanded then
          -- Both the fileset and template string need their own quoting. Exact
          -- root-relative paths avoid glob/fileset syntax in real filenames.
          local fileset = 'root-file:' .. vim.json.encode(path)
          diffs = diffs .. ' ++ if(' .. owner .. ' && stringify(f.path()) == ' .. vim.json.encode(path)
            .. ', "\x1eDIFF\x1f\n" ++ stringify(self.diff(' .. vim.json.encode(fileset)
            .. ').git()).lines().map(|line| "\x1ePATCH\t" ++ json(line) ++ "\x1f\n").join("")'
            .. ' ++ "\x1eENDDIFF\x1f\n")'
        end
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
      .. ' ++ "\t" ++ json("") ++ "\t" ++ json("") ++ "\x1f\n" ++ '
      .. 'diff.stat().files().map(|f| "\x1eSTAT\t" ++ separate("\t", '
      .. 'f.status_char(), f.lines_added(), f.lines_removed(), json(f.display_diff_path()), json(f.path()))'
      .. ' ++ "\x1f\n"' .. diffs .. ').join("") ++ "\x1eMARGIN\x1f\n") ++ "\x1eEND\x1f\n"'
    -- Wrapping must happen in the editor, not through our metadata markers.
    local output = jj(root, { '--config', 'ui.log-word-wrap=false', 'log', '-T', template }, true)
    local lines, rows, entry = {}, {}, nil
    local file_row, diff_row, in_hunk
    local highlights, words = {}, {}
    local removed, added = {}, {}
    local function flush_words()
      vim.list_extend(words, word_spans(removed, added))
      removed, added = {}, {}
    end
    local margin = false
    for line in (output:gsub('\n$', '') .. '\n'):gmatch('(.-)\n') do
      local skip, row, patch, group, hunk_length = false, nil, nil, nil, nil
      local stat_text, stat_spans
      local previous_margin = margin
      margin = false
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
        elseif clean == 'DIFF' then
          skip, diff_row, in_hunk = true, file_row, false
          return ''
        elseif clean == 'ENDDIFF' then
          diff_row, margin = nil, true
          return ''
        elseif clean == 'MARGIN' then
          skip = previous_margin
          return ''
        elseif clean:sub(1, 6) == 'PATCH\t' then
          patch = vim.json.decode(clean:sub(7))
          if patch:match('^@@') then
            in_hunk, group = true, 'FujutsuDiffHunk'
            local header, start, context = patch:match('^(@@ %-%d+,?%d* %+(%d+),?%d* @@)(.*)$')
            if header then
              hunk_length = #header
              if context == '' then
                context = hunk_context(diff_row, tonumber(start))
                if context ~= '' then patch = header .. ' ' .. context end
              end
            end
          elseif not in_hunk then
            -- The file row already supplies the path. Retain meaningful
            -- metadata (binary, rename, mode changes), not Git's preamble.
            skip = patch:match('^diff %-%-git ') ~= nil or patch:match('^index ') ~= nil
              or patch:match('^%-%-%- ') ~= nil or patch:match('^%+%+%+ ') ~= nil
          elseif patch:sub(1, 1) == '+' then
            group = 'FujutsuDiffAdd'
          elseif patch:sub(1, 1) == '-' then
            group = 'FujutsuDiffDelete'
          end
          return patch
        elseif clean:sub(1, 5) == 'STAT\t' then
          local file = assert(parse_stat(marker), 'Invalid Jujutsu file stats')
          if file.status == ' ' then
            -- The total header comes first and bounds every file's counts.
            -- Size columns independently for each revision's stats block.
            entry.widths = {
              added = file.added == 0 and 0 or #tostring(file.added) + 1,
              removed = file.removed == 0 and 0 or #tostring(file.removed) + 1,
            }
          else
            file_row = { entry = entry, path = file.target, first = #lines + 1 }
            row = file_row
          end
          stat_text, stat_spans = stat(file, entry.widths)
          return stat_text
        end
        return ''
      end)
      if group ~= 'FujutsuDiffAdd' and group ~= 'FujutsuDiffDelete' then flush_words() end
      if not skip then
        lines[#lines + 1] = line
        rows[#lines] = row or diff_row or entry
        if stat_spans then
          local first = #plain(line) - #stat_text
          for _, span in ipairs(stat_spans) do
            highlights[#highlights + 1] = { #lines - 1, first + span[1], first + span[2], span[3] }
          end
        end
        if group then
          local length = #plain(line)
          local first = length - #patch
          if group == 'FujutsuDiffAdd' or group == 'FujutsuDiffDelete' then
            local block = group == 'FujutsuDiffAdd' and added or removed
            block[#block + 1] = { row = #lines - 1, col = first + 1, text = patch:sub(2) }
          end
          highlights[#highlights + 1] = { #lines - 1, first, hunk_length and first + hunk_length or length, group }
          if hunk_length and #patch > hunk_length then
            highlights[#highlights + 1] = { #lines - 1, first + hunk_length + 1, length, 'FujutsuDiffContext' }
          end
        end
      end
    end
    flush_words()
    render(buf, table.concat(lines, '\n') .. '\n')
    require('fujutsu.highlights').refresh()
    for _, span in ipairs(highlights) do
      vim.api.nvim_buf_set_extmark(buf, ansi.namespace, span[1], span[2], {
        end_col = span[3], hl_group = span[4], priority = 110,
      })
    end
    for _, span in ipairs(words) do
      vim.api.nvim_buf_set_extmark(buf, ansi.namespace, span[1], span[2], {
        end_col = span[3], hl_group = span[4], priority = 120,
      })
    end
    state.rows = rows
  end

  function state.toggle(buf)
    local row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row then return end
    local entry = row.entry or row
    local old, files
    if row.path then
      local key = entry.working_copy and '@' or entry.id
      state.files[key] = state.files[key] or {}
      files = state.files[key]
      old = files[row.path]
      files[row.path] = not old
    elseif entry.working_copy then
      old = state.working_copy
      state.working_copy = not old
    else
      old = state.expanded[entry.id]
      state.expanded[entry.id] = not old
    end
    local ok, err = pcall(state.refresh, buf)
    if not ok then
      if files then files[row.path] = old
      elseif entry.working_copy then state.working_copy = old
      else state.expanded[entry.id] = old end
      error(err, 0)
    end
    vim.api.nvim_win_set_cursor(0, { math.min(row.first, vim.api.nvim_buf_line_count(buf)), 0 })
  end

  return state
end

return M
