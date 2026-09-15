local Fixtures = {version = 1}

local function fixture(id, line, expected_replans, progress)
  return {
    id = id, title = id, category = "corridor-execution",
    start = {x = -12, y = 0}, goal = {x = 12, y = 0}, world = {walls = {}},
    corridor_budget = {groups = 2, segment_tests = 8, pending_groups = 32},
    steps = {{id = "world-edit", when = {type = "actor-progress-at-least", distance = progress or 4},
      action = {type = "raise-wall-line", from = line.from, to = line.to, obstacle = true}}},
    expected_terminal = "arrived", timeout_ticks = 1800,
    assertions = {
      {id = "arrival", type = "terminal-state-is", expected = "arrived"},
      {id = "arrival-error", type = "metric-at-most", path = "arrival_error", value = 0.5},
      {id = "edit-applied", type = "action-executed", action_id = "world-edit"},
      {id = "replan-count", type = "metric-is", path = "replan_count", value = expected_replans},
      {id = "stop-count", type = "metric-is", path = "dynamic.immediate_stops", value = expected_replans},
      {id = "no-stuck", type = "metric-is", path = "stuck_count", value = 0},
      {id = "group-budget", type = "metric-at-most", path = "dynamic.max_groups_per_update", value = 2},
      {id = "segment-budget", type = "metric-at-most", path = "dynamic.max_segment_tests_per_update", value = 8},
      {id = "event-budget", type = "metric-at-most", path = "dynamic.max_immediate_checks_per_event", value = 8},
      {id = "no-unneeded-hold", type = "metric-is", path = "dynamic.immediate_budget_holds", value = 0},
      {id = "no-surface-scan", type = "metric-is", path = "dynamic.world.full_surface_rescans", value = 0}
    }
  }
end

local blocking = fixture("wall-built-on-remaining-route", {from = {x = 0, y = -3}, to = {x = 0, y = 3}}, 1)
blocking.assertions[#blocking.assertions + 1] = {
  id = "before-contact", type = "metric-at-least", path = "obstacle_distance_at_replan", value = 6
}
blocking.assertions[#blocking.assertions + 1] = {
  id = "bounded-latency", type = "metric-at-most", path = "replan_latency_ticks", value = 1
}
blocking.assertions[#blocking.assertions + 1] = {
  id = "stopped-in-event", type = "metric-is", path = "dynamic.stop_latency_ticks", value = 0
}
blocking.assertions[#blocking.assertions + 1] = {
  id = "no-native-step-after-stop", type = "metric-is", path = "dynamic.max_stop_drift", value = 0
}
blocking.assertions[#blocking.assertions + 1] = {
  id = "stop-verified-next-tick", type = "metric-is", path = "dynamic.stop_observed_next_tick", value = true
}
blocking.assertions[#blocking.assertions + 1] = {
  id = "burst-coalesced", type = "metric-at-least", path = "dynamic.coalesced", value = 5
}

Fixtures.cases = {
  blocking,
  fixture("wall-built-off-route", {from = {x = 0, y = 8}, to = {x = 0, y = 11}}, 0),
  fixture("wall-built-behind-actor", {from = {x = -12, y = -3}, to = {x = -12, y = 3}}, 0, 8)
}

local removal = fixture("wall-removed-keeps-accepted-detour", {from = {x = 0, y = -3}, to = {x = 0, y = 3}}, 0)
removal.world.walls = {{from = {x = 0, y = -3}, to = {x = 0, y = 3}}}
removal.steps[1].action.type = "raise-remove-walls"
removal.assertions[#removal.assertions + 1] = {
  id = "accepted-detour-retained", type = "metric-at-least", path = "path_distance", value = 24.5
}
removal.assertions[#removal.assertions + 1] = {
  id = "only-original-route", type = "metric-is", path = "route_count", value = 1
}
removal.assertions[#removal.assertions + 1] = {
  id = "removal-does-not-pause", type = "metric-is", path = "dynamic.safety_hold_ticks", value = 0
}
Fixtures.cases[#Fixtures.cases + 1] = removal

local motion = fixture("forward-belt-edit-notifies-without-replan", {from = {x = 0, y = 0}, to = {x = 3, y = 0}}, 0)
motion.start.y, motion.goal.y = 0.5, 0.5
motion.steps[1].action.type = "raise-forward-belts"
motion.assertions[#motion.assertions + 1] = {
  id = "motion-notification", type = "metric-at-least", path = "dynamic.motion_refreshes", value = 1
}
motion.assertions[#motion.assertions + 1] = {
  id = "motion-only-revision", type = "metric-is", path = "dynamic.world.revision_changes.topology", value = 0
}
Fixtures.cases[#Fixtures.cases + 1] = motion
return Fixtures
