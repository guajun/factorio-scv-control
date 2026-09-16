-- One single-player save; scene geometry remains in shared TestKit fixtures.
remote.add_interface('scv_unified_lab', {active = function() return true end})
remote.add_interface('scv_navigation_comparison', {active = function() return true end})
remote.add_interface('scv_navigation_savebench', {active = function() return true end})
-- Enable the production logger without activating the old interactive world's
-- builder or its player lifecycle handlers.
remote.add_interface('scv_test_lab', {
  planner_logging_enabled = function() return true end,
  follower_trace_enabled = function() return true end
})
