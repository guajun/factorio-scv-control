local Corridor = require("__factorio-scv-control__/scripts/navigation/execution/corridor")

local Tests = {}
local function fresh(options, points)
  local state = Corridor.new(1, {{-0.2, -0.2}, {0.2, 0.2}}, 0.3, options)
  Corridor.attach(state, {points = points or {{x = 10, y = 0}}, corridor = {},
    dependencies = {}, world_revisions = {}}, {x = 0, y = 0})
  return state
end
local function mutation(x, y, categories, remove)
  return {surface_index = 1, bounds = {{x, y}, {x + 0.25, y + 0.25}},
    categories = categories or {topology = true}, remove_entity_key = remove,
    source = remove and "script_raised_destroy" or "script_raised_built"}
end
local function check(condition, message) assert(condition, message) end

local cases = {
  {id = "removal-preserves-route", run = function()
    local state = fresh()
    Corridor.enqueue(state, mutation(5, 0, {topology = true}, "unit:1"), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "continue" and state.metrics.preserved_removals == 1,
      "removing topology must not invalidate the accepted route")
    return state, result
  end},
  {id = "motion-refresh-without-topology-invalidation", run = function()
    local state = fresh()
    Corridor.enqueue(state, mutation(5, 0, {motion = true}), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "continue" and state.metrics.motion_refreshes == 1
      and result.notifications[1].kind == "motion", "motion must notify cost/control refresh")
    return state, result
  end},
  {id = "transient-notification-without-global-replan", run = function()
    local state = fresh()
    Corridor.enqueue(state, mutation(5, 0, {transient = true}), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "continue" and result.notifications[1].kind == "transient",
      "transient needs a local-response consumer, not topology invalidation")
    return state, result
  end},
  {id = "remaining-segment-excludes-traversed-prefix", run = function()
    local state = fresh()
    Corridor.enqueue(state, mutation(2, 0), 1)
    local result = Corridor.advance(state, {x = 7, y = 0}, 1, 2)
    check(result.action == "continue" and state.metrics.off_corridor == 1,
      "event behind actor must not invalidate its remaining segment")
    return state, result
  end},
  {id = "diagonal-corridor-is-not-its-aabb", run = function()
    local state = fresh(nil, {{x = 10, y = 10}})
    Corridor.enqueue(state, mutation(2, 8), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "continue", "diagonal broad-phase box must not cause false invalidation")
    return state, result
  end},
  {id = "trajectory-envelope-catches-near-line-edit", run = function()
    local state = fresh()
    Corridor.enqueue(state, mutation(5, 0.4), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "replan", "actor plus trajectory envelope must cover lateral execution")
    return state, result
  end},
  {id = "coalesced-off-route-edits-do-not-create-a-false-obstacle", run = function()
    local state = fresh(nil, {{x = 10, y = 10}})
    Corridor.enqueue(state, mutation(2, 4), 1)
    Corridor.enqueue(state, mutation(4, 2), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "continue" and state.metrics.coalesced == 1,
      "coalescing must retain exact member boxes, not make their union a collision")
    return state, result
  end},
  {id = "immediate-scan-covers-future-segment-and-holds-on-budget", run = function()
    local state = fresh(nil, {{x = 5, y = 0}, {x = 5, y = 5}})
    local edit = mutation(5, 3)
    local action, checks = Corridor.immediate_check(state, {x = 0, y = 0}, 1, edit.bounds, 2)
    check(action == "blocked" and checks == 2, "later remaining segment requires immediate stop")
    local bounded, bounded_checks = Corridor.immediate_check(state, {x = 0, y = 0}, 1, edit.bounds, 1)
    check(bounded == "budget-hold" and bounded_checks == 1, "unexamined segments require safe hold")
    return state, {action = action, checks = checks, bounded = bounded}
  end},
  {id = "burst-and-segment-work-budget", run = function()
    local points = {}
    for index = 1, 10 do points[index] = {x = index, y = 0} end
    local state = fresh({groups = 1, segment_tests = 2}, points)
    for index = 1, 100 do Corridor.enqueue(state, mutation(5, 8), 1) end
    local result, updates
    updates = 0
    repeat
      result = Corridor.advance(state, {x = 0, y = 0}, 1, updates + 2)
      updates = updates + 1
      check(result.segment_tests <= 2 and result.groups <= 1, "per-update work exceeds budget")
      check(result.action ~= "replan", "off-route burst cannot trigger a replan")
      check(updates <= 10, "test work-drain guard exhausted")
    until not Corridor.has_pending(state)
    check(state.metrics.coalesced == 99 and updates == 5, "burst must coalesce and resume bounded scans")
    return state, result
  end},
  {id = "overflow-fails-closed", run = function()
    local state = fresh({pending_groups = 1})
    Corridor.enqueue(state, mutation(1, 0), 1)
    Corridor.enqueue(state, mutation(100, 0), 1)
    local result = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(result.action == "replan" and result.reason == "dirty-budget-overflow",
      "never discard unexamined dirty topology and keep walking")
    return state, result
  end},
  {id = "pending-removal-notifications-never-hold-movement", run = function()
    local state = fresh({groups = 1, segment_tests = 1}, {{x = 5, y = 0}, {x = 10, y = 0}})
    Corridor.enqueue(state, mutation(8, 0, {topology = true}, "unit:1"), 1)
    local first = Corridor.advance(state, {x = 0, y = 0}, 1, 2)
    check(first.action == "continue" and Corridor.has_pending(state), "deferred removal work must not pause actor")
    local result = Corridor.advance(state, {x = 1, y = 0}, 1, 3)
    check(result.action == "continue" and state.metrics.preserved_removals == 1, "deferred removal must still be reported")
    return state, result
  end},
  {id = "duplicate-events-during-scan-cannot-starve-progress", run = function()
    local points = {}
    for index = 1, 10 do points[index] = {x = index, y = 0} end
    local state = fresh({groups = 1, segment_tests = 2}, points)
    local result, updates
    updates = 0
    repeat
      Corridor.enqueue(state, mutation(5, 8), updates + 1)
      result = Corridor.advance(state, {x = 0, y = 0}, 1, updates + 2)
      updates = updates + 1
      check(updates <= 5, "identical events restarted the active scan")
    until not Corridor.has_pending(state)
    check(state.metrics.segment_tests == 10 and result.action == "continue", "duplicate work was rechecked")
    return state, result
  end},
  {id = "non-head-events-do-not-reset-active-scan", run = function()
    local points = {}
    for index = 1, 10 do points[index] = {x = index, y = 0} end
    local state = fresh({groups = 1, segment_tests = 2}, points)
    Corridor.enqueue(state, mutation(5, 8), 1)
    Corridor.enqueue(state, mutation(32, 8), 1)
    local result
    for update = 1, 5 do
      -- Duplicate and genuinely new geometry in a later group must not reset
      -- the first group's unrelated cursor.
      Corridor.enqueue(state, mutation(32, 8), update)
      Corridor.enqueue(state, mutation(32 + update / 10, 8), update)
      result = Corridor.advance(state, {x = 0, y = 0}, 1, update + 1)
    end
    check(state.metrics.groups == 1 and state.pending[1].bounds.left_top.x == 32,
      "non-head geometry starved the first group")
    return state, result
  end}
}

function Tests.run()
  local results = {}
  for _, specification in ipairs(cases) do
    local ok, state, decision = pcall(specification.run)
    if ok then state.metrics.native_execution = false end
    results[#results + 1] = {
      id = specification.id, passed = ok, terminal_state = ok and "verified" or "failed",
      reason = ok and "policy-assertions-complete" or tostring(state),
      assertions = {{id = specification.id, passed = ok}},
      metrics = ok and state.metrics or {},
      timeline = {{event = "policy-verification", decision = ok and decision or false}}
    }
  end
  return results
end
return Tests
