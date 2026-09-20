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
  local used = total > 0 and 5 or 0
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
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      local cursor = vim.api.nvim_win_get_cursor(win)
      cursors[win] = { row = state.rows[cursor[1]], cursor = cursor }
    end
    state.effective_query = state.query and state.query ~= '' and state.query
      or vim.trim(jj(root, { 'config', 'get', 'revsets.log' }))
    local lines, rows = require('fujutsu.log_ui').header(state, root, jj)
    -- Expansion follows uniquely visible changes across rewrites, not obsolete
    -- commit hashes. Working-copy expansion retains its special @ identity.
    for _, row in pairs(state.rows) do
      local entry = row.entry or row
      local latest = entry.change and state.catalog[entry.change]
      if latest and latest ~= entry.id then
        if state.expanded[entry.id] ~= nil then
          state.expanded[latest], state.expanded[entry.id] = state.expanded[entry.id], nil
        end
        if state.files[entry.id] then
          state.files[latest], state.files[entry.id] = state.files[entry.id], nil
        end
      end
    end
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
    local template = '"\x1eENTRY\t" ++ commit_id ++ "\t" ++ change_id ++ "\t" ++ current_working_copy ++ "\x1f" ++ ('
      .. configured .. ') ++ if(!stringify(' .. configured .. ').ends_with("\n"), "\n") ++ if('
      .. '(' .. predicate .. ') && diff.stat().files().len() > 0, '
      .. '"\n\x1eSTAT\t \t" ++ diff.stat().total_added() ++ "\t" ++ diff.stat().total_removed()'
      .. ' ++ "\t" ++ json("") ++ "\t" ++ json("") ++ "\x1f\n" ++ '
      .. 'diff.stat().files().map(|f| "\x1eSTAT\t" ++ separate("\t", '
      .. 'f.status_char(), f.lines_added(), f.lines_removed(), json(f.display_diff_path()), json(f.path()))'
      .. ' ++ "\x1f\n"' .. diffs .. ').join("") ++ "\x1eMARGIN\x1f\n") ++ "\x1eEND\x1f\n"'
    -- Wrapping must happen in the editor, not through our metadata markers.
    local args = { '--config', 'ui.log-word-wrap=false', 'log', '-r', state.effective_query, '-T', template }
    if state.limit then vim.list_extend(args, { '-n', state.limit }) end
    local output = jj(root, args, true)
    vim.b[buf].fujutsu_query, vim.b[buf].fujutsu_limit = state.query, state.limit
    local uri = require('fujutsu.uri')
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match('^fujutsu://') then
      local updated = uri.log_name(root, state.query, state.limit)
      if name ~= updated then vim.api.nvim_buf_set_name(buf, updated) end
    end
    table.insert(lines, 1, 'Query: ' .. vim.fn.strtrans(state.effective_query) .. (state.limit and '  [limit ' .. state.limit .. ']' or ''))
    table.insert(rows, 1, { kind = 'query' })
    local entry
    local file_row, diff_row, in_hunk, old_line, new_line
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
        local id, change, wc = clean:match('^ENTRY\t(%x+)\t([k-z]+)\t(%a+)$')
        if id then
          entry = { id = id, change = change, working_copy = wc == 'true', first = #lines + 1 }
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
            old_line, new_line = patch:match('^@@ %-(%d+),?%d* %+(%d+)')
            old_line, new_line = tonumber(old_line), tonumber(new_line)
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
          if in_hunk and old_line then
            row = vim.tbl_extend('force', {}, diff_row, {
              old_line = old_line, new_line = new_line,
              old_side = patch:sub(1, 1) == '-', hunk = patch:match('^@@') ~= nil, patch = patch,
            })
            local prefix = patch:sub(1, 1)
            if prefix == '-' or prefix == ' ' then old_line = old_line + 1 end
            if prefix == '+' or prefix == ' ' then new_line = new_line + 1 end
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
            file_row = { entry = entry, path = file.target, status = file.status, deleted = file.status == 'D', first = #lines + 1 }
            row = file_row
          end
          stat_text, stat_spans = stat(file, entry.widths)
          return stat_text
        end
        return ''
      end)
      if group ~= 'FujutsuDiffAdd' and group ~= 'FujutsuDiffDelete' then flush_words() end
      if skip then
        -- Template sentinels and omitted patch headers can share a physical
        -- line with jj's graph transitions. Drop only our content, never edges.
        local graph = patch and line:sub(1, #line - #patch) or line
        local edges = plain(graph):gsub('│', ''):gsub('┃', ''):gsub('┆', ''):gsub('┊', '')
          :gsub('╎', ''):gsub('╏', ''):gsub('[|:%s]', '')
        if edges ~= '' then
          lines[#lines + 1] = graph
          rows[#lines] = { kind = 'graph' }
        end
      end
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
    for win, saved in pairs(cursors) do
      if vim.api.nvim_win_is_valid(win) and saved.row then
        local old = saved.row
        local owner = old.entry or old
        local best
        for i, row in pairs(rows) do
          local entry = row.entry or row
          if old.kind and old.kind == row.kind and old.register == row.register then best = i; break end
          if owner.change and owner.change == entry.change then
            if i == entry.first and not best then best = i end
            if old.path == row.path and old.patch == row.patch and old.new_line == row.new_line
              and old.old_line == row.old_line and (old.path or i == entry.first) then best = i; break end
          end
        end
        if best then
          local col = old.kind == 'marks' and math.min(saved.cursor[2], #lines[best]) or 0
          vim.api.nvim_win_set_cursor(win, { best, col })
        end
      end
    end
    require('fujutsu.log_ui').draw(state, buf)
  end

  function state.move(kind, direction, count)
    local targets = {}
    for index, row in pairs(state.rows) do
      local entry = row.entry or row
      local revision = index == entry.first
      local file = row.path and index == row.first
      if (kind == 'revision' and revision) or (kind == 'file' and file)
        or (kind == 'hunk' and row.hunk) or (kind == 'item' and (file or row.hunk)) then
        targets[#targets + 1] = index
      end
    end
    table.sort(targets, function(a, b) return direction > 0 and a < b or direction < 0 and a > b end)
    local current = vim.api.nvim_win_get_cursor(0)[1]
    local remaining = count or 1
    for _, target in ipairs(targets) do
      if (target - current) * direction > 0 then
        current = target
        remaining = remaining - 1
        if remaining == 0 then break end
      end
    end
    vim.api.nvim_win_set_cursor(0, { current, 0 })
  end

  function state.selection(buf)
    local index = vim.api.nvim_win_get_cursor(0)[1]
    local previous = state.rows[index]
    state.refresh(buf) -- Snapshot external edits before trusting coordinates.
    local row = state.rows[index]
    if not previous or not row or not vim.deep_equal(previous, row) then
      error('Log changed; select the destination again', 0)
    end
    return row
  end

  function state.visit(buf, command)
    command = command or 'edit'
    local current = state.rows[vim.fn.line('.')]
    if current and current.kind == 'query' then
      require('fujutsu.log_ui').edit_query(state, buf)
      return
    elseif current and current.kind == 'marks' then
      require('fujutsu.log_ui').pin(state, buf)
      return
    end
    local row = state.selection(buf)
    local file = require('fujutsu.file')
    assert(row.id or row.entry, 'Select a commit or file')
    if not row.path then
      file.open(root, row.id, 'description', { description = true, readonly = false, explicit = true,
        command = command })
      return
    end
    local old = row.old_side or row.deleted
    local id, path, base = row.entry.id, row.path, false
    if old then
      local entries = jj(root, { '--ignore-working-copy', 'diff', '-r', id, '-T',
        'json(source.path()) ++ "\\t" ++ json(target.path()) ++ "\\n"' })
      for source, target in entries:gmatch('([^\n]+)\t([^\n]+)\n') do
        if vim.json.decode(target) == path then path = vim.json.decode(source); break end
      end
      local parents = vim.split(vim.trim(jj(root, { '--ignore-working-copy', 'log', '--no-graph',
        '-r', 'parents(' .. id .. ')', '-T', 'commit_id ++ "\\n"' })), '\n')
      if #parents == 1 then id = parents[1] else base = true end
    end
    file.open(root, id, path, { base = base, explicit = true, workspace = not old and row.entry.working_copy,
      command = command, line = old and row.old_line or row.new_line })
  end

  function state.focus(id)
    for i, row in pairs(state.rows) do
      if row.id == id and i == row.first then vim.api.nvim_win_set_cursor(0, { i, 0 }); return true end
    end
    return false
  end

  function state.head(buf)
    state.refresh(buf)
    for _, entry in ipairs(state.catalog.entries) do
      if entry.working_copy then state.focus(entry.id); return end
    end
    require('fujutsu.diagnostics').notice('Working-copy revision @ is excluded by this query')
  end

  function state.toggle_all(buf)
    local row = state.rows[vim.fn.line('.')]
    local old = { expanded = vim.deepcopy(state.expanded), files = vim.deepcopy(state.files), working_copy = state.working_copy }
    if row and (row.id or row.entry) then
      local entry = row.entry or row
      local meta = state.catalog.by_id[entry.id]
      local key = entry.working_copy and '@' or entry.id
      local files = state.files[key] or {}
      local expand = false
      for _, path in ipairs(meta.paths) do if not files[path] then expand = true end end
      for _, path in ipairs(meta.paths) do files[path] = expand end
      state.files[key] = files
      if entry.working_copy then state.working_copy = true else state.expanded[entry.id] = true end
    else
      local expand = false
      for _, entry in ipairs(state.catalog.entries) do
        if #entry.paths > 0 and not (entry.working_copy and state.working_copy
          or not entry.working_copy and state.expanded[entry.id]) then expand = true end
      end
      for _, entry in ipairs(state.catalog.entries) do
        if entry.working_copy then state.working_copy = expand else state.expanded[entry.id] = expand end
      end
    end
    local ok, err = pcall(state.refresh, buf)
    if not ok then
      state.expanded, state.files, state.working_copy = old.expanded, old.files, old.working_copy
      error(err, 0)
    end
  end

  function state.toggle(buf)
    local row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (not row.id and not row.entry) then return end
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
