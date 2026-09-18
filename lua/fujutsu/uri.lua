local M = {}

local function encode(text, path)
  return (text:gsub(path and '[^%w%-%._~/]' or '[^%w%-%._~]', function(char)
    return ('%%%02X'):format(char:byte())
  end))
end

local function decode(text)
  return (text:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

function M.name(root, kind, id, path, base)
  return ('fujutsu://%s/%s/%s/%s'):format(encode(root), kind,
    id .. (base and '-parents' or ''), encode(path or '', true))
end

function M.parse(name)
  local root, kind, revision, path = name:match('^fujutsu://([^/]+)/([^/]+)/([^/]+)/(.*)$')
  assert(root and ({ log = true, file = true, description = true, tree = true })[kind], 'Invalid Fujutsu URI')
  path = path:gsub('%?buffer=%d+$', '')
  local id = revision:gsub('%-parents$', '')
  assert(kind == 'log' or id:match('^%x+$'), 'Invalid Fujutsu revision')
  return { root = decode(root), kind = kind, id = id, path = decode(path), base = revision ~= id }
end

return M
