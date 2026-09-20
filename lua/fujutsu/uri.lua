local M = {}
local function encode(text)
  return (text:gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end))
end
local function decode(text)
  return (text:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Log paths are literal and end in /. Only the optional parameter values are
-- percent-encoded (including /), so the final slash is an unambiguous boundary.
function M.log_name(root, query, limit)
  local name = 'fujutsu://' .. root .. '/log/'
  local params = {}
  if query and query ~= '' then params[#params + 1] = 'revset=' .. encode(query) end
  if limit then params[#params + 1] = 'limit=' .. encode(tostring(limit)) end
  return name .. (#params > 0 and '?' .. table.concat(params, '&') or '')
end

function M.name(root, kind, id, path, base)
  if kind == 'log' then return M.log_name(root) end
  -- A double separator delimits the canonical repository path from revision
  -- data. Relative revision paths use standard escaping for delimiter safety.
  return ('fujutsu://%s//%s/%s/%s'):format(root, kind, id .. (base and '-parents' or ''),
    ((path or ''):gsub('[^%w%-%._~/]', function(c) return ('%%%02X'):format(c:byte()) end)))
end

function M.parse(name)
  local root, kind, revision, path = name:match('^fujutsu://(.-)//([^/]+)/([^/]+)/(.*)$')
  if not root then
    -- Continue to read historical names and old log names from jump lists.
    root, kind, revision, path = name:match('^fujutsu://([^/]+)/([^/]+)/([^/]+)/(.*)$')
    if root then root = decode(root) end
  end
  if not root then
    local before, params = name:match('^fujutsu://(.*)/log/(.*)$')
    if before and (params == '' or params:sub(1, 1) == '?') and not params:find('/', 1, true) then
      local result = { root = before, kind = 'log', path = '', query = '' }
      for key, value in params:gmatch('[?&]([^=&]+)=([^&]*)') do
        assert(key == 'revset' or key == 'limit', 'Unknown log URI parameter')
        if key == 'revset' then result.query = decode(value)
        else result.limit = decode(value); assert(result.limit:match('^%d+$'), 'Invalid log limit') end
      end
      return result
    end
  end
  assert(root and ({ log = true, file = true, description = true, tree = true })[kind], 'Invalid Fujutsu URI')
  path = path:gsub('%?buffer=%d+$', '')
  local id = revision:gsub('%-parents$', '')
  assert(kind == 'log' or id:match('^%x+$'), 'Invalid Fujutsu revision')
  local result = { root = root, kind = kind, id = id, path = decode(path), base = revision ~= id }
  if kind == 'log' then
    local saved = result.path ~= '' and vim.json.decode(result.path) or {}
    result.query, result.limit = saved.query or '', saved.limit
  end
  return result
end
return M
