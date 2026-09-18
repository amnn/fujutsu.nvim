-- Keep lualine's branch options, formatting, and Git fallback, but use the
-- buffer's jj identity when it has one. No repository commands run on redraw.
local branch = require('lualine.components.branch')
local M = branch:extend()

function M.init(self, options)
  self.fujutsu_custom_icon = options and options.icon ~= nil
  branch.init(self, options)
end

function M.update_status(self, is_focused)
  local label = require('fujutsu.status').label()
  self.fujutsu_revision = label ~= ''
  if self.fujutsu_revision then return label end
  return branch.update_status(self, is_focused)
end

function M.apply_icon(self)
  -- The jj label already has its version marker. Keep Git's default branch
  -- icon for Git fallback only, while respecting an explicitly configured icon.
  if self.fujutsu_revision and not self.fujutsu_custom_icon then return end
  branch.apply_icon(self)
end

return M
