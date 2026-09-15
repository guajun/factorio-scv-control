-- The companion mod owns handlers and runtime state; this marker enables them
-- only on this isolated developer map (or the explicitly marked GUI test lab).
remote.add_interface("scv_navigation_live", {active = function() return true end})
