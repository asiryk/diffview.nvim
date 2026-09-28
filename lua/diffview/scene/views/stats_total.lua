local M = {}

---Append the summed line stats of `items`, like GitLab's MR header
---("+1 -94 · net -93"). Items without numstat data (untracked, binary, conflict
---counts) are skipped.
---@param comp RenderComponent
---@param items { stats: GitStats? }[] FileEntry[] or LogEntry[]
function M.render(comp, items)
  local additions, deletions, counted = 0, 0, false

  for _, item in ipairs(items) do
    if item.stats and item.stats.additions then
      additions = additions + item.stats.additions
      deletions = deletions + item.stats.deletions
      counted = true
    end
  end

  if counted then
    comp:add_text(" +" .. additions, "DiffviewFilePanelInsertions")
    comp:add_text(" -" .. deletions, "DiffviewFilePanelDeletions")

    -- The net only says something new when both sides are non-zero.
    if additions > 0 and deletions > 0 then
      local net = additions - deletions
      comp:add_text(" · net ", "DiffviewDim1")
      if net > 0 then
        comp:add_text("+" .. net, "DiffviewFilePanelInsertions")
      elseif net < 0 then
        comp:add_text(tostring(net), "DiffviewFilePanelDeletions")
      else
        comp:add_text("±0", "DiffviewDim1")
      end
    end
  end
end

return M
