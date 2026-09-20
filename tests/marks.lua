vim.opt.runtimepath:prepend(vim.fn.getcwd())
local marks = require('fujutsu.marks')
local a, b = string.rep('k', 32), string.rep('z', 32)
local ca, cb = string.rep('a', 40), string.rep('b', 40)
local catalog = { [a] = ca, [b] = cb, short = { [a] = 'kkkkkkkk', [b] = 'zzzzzzzz' },
  symbols = { kkkkkkkk = ca, zzzzzzzz = cb, main = ca, [ca] = ca, ['quoted name'] = cb },
  by_id = { [ca] = { change = a }, [cb] = { change = b } } }
local function eq(x, y) assert(vim.deep_equal(x, y), vim.inspect({ x, y })) end
marks.modify('a', 'replace', { a }, catalog)
eq('a', marks.linked()); eq('kkkkkkkk', vim.fn.getreg('"'))
marks.modify('"', 'append', { b }, catalog)
eq('kkkkkkkk | zzzzzzzz', vim.fn.getreg('a')); eq('a', marks.linked())
marks.modify('A', 'replace', { a }, catalog)
eq({ a, b }, marks.get('a', catalog))
marks.modify('"', 'remove', { a }, catalog)
eq('zzzzzzzz', vim.fn.getreg('a')); eq('a', marks.linked())
marks.modify('"', 'replace', { a }, catalog)
eq(nil, marks.linked()); eq('zzzzzzzz', vim.fn.getreg('a'))
eq('kkkkkkkk', vim.fn.getreg('"'))
marks.modify('a', 'append', { a }, catalog)
vim.fn.setreg('a', 'main')
eq(nil, marks.linked()) -- External register changes break our weak association.
eq({ a }, marks.get('a', catalog))
vim.fn.setreg('a', 'main | "quoted name"')
eq({ a, b }, marks.get('a', catalog))
vim.fn.setreg('a', ca); eq({ a }, marks.get('a', catalog))
vim.fn.setreg('a', 'mine()'); eq(nil, marks.get('a', catalog))
vim.fn.setreg('a', 'main | missing'); eq(nil, marks.get('a', catalog))
vim.fn.setreg('a', 'kkkkkkkk'); eq(nil, marks.get('a', { symbols = {} }))
local function lookup(_, _) return ca .. '\n' end
eq({ ca }, marks.resolve('a', catalog, '/unused', lookup))
assert(not pcall(marks.resolve, 'a', catalog, '/unused', function() return cb .. '\n' end))
local divergent = { [a] = false, short = { [a] = 'kkkkkkkk' },
  symbols = { aaaaaaaa = ca, bbbbbbbb = cb },
  by_id = { [ca] = { change = a, commit_short = 'aaaaaaaa' }, [cb] = { change = a, commit_short = 'bbbbbbbb' } } }
marks.modify('a', 'replace', { ca, cb }, divergent)
eq('aaaaaaaa | bbbbbbbb', vim.fn.getreg('a'))
marks.modify('"', 'remove', { ca }, divergent)
eq('bbbbbbbb', vim.fn.getreg('a'))
print('PASS: short symbol unions, weak aliases, native register edits, buffer scope, divergence and revalidation')
vim.cmd.qa({ bang = true })
