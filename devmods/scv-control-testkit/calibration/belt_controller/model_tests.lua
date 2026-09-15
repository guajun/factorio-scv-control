local Motion = require("__factorio-scv-control__/scripts/navigation/motion/measured_uniform")
local Controller = require("__factorio-scv-control__/scripts/navigation/motion/uniform_controller")
local Command = require("calibration.belt_controller.command")
local Tests = {}

function Tests.spec(belt, direction)
  return {factorio_version = script.active_mods.base, actor_profile = "base-character-unarmored-v1",
    running_speed = 0.15, belt_immunity = false, tile = "grass-1", uniform = true,
    belt = belt, belt_direction = direction}
end

function Tests.run()
  local cases = {}
  local function record(id, assertions, metrics)
    local passed = true
    for _, assertion in ipairs(assertions) do passed = passed and assertion.passed end
    cases[#cases + 1] = {id = id, passed = passed, terminal_state = "model-checked",
      reason = "pure-model-assertions-not-native-arrival", assertions = assertions, metrics = metrics,
      timeline = {{tick = 0, event = "model-checked"}}}
  end
  local field = assert(Motion.field(Tests.spec("express-transport-belt", 4)))
  local with = Motion.directed_edge(field, {x = 0, y = 0}, {x = 8, y = 0})
  local against = Motion.directed_edge(field, {x = 8, y = 0}, {x = 0, y = 0})
  local cross = Motion.directed_edge(field, {x = 0, y = 0}, {x = 0, y = 8})
  local lateral, forward = 0, 0
  for _, control in ipairs(cross.controls) do
    lateral = lateral + control.share * control.lateral
    forward = forward + control.share * control.along
  end
  record("model-directed-velocity-and-cost", {
    {name = "direction-asymmetry-uses-native-velocities", passed = with.travel_ticks < against.travel_ticks
      and math.abs(with.forward_speed - 62 / 256) < 1e-10 and math.abs(against.forward_speed - 14 / 256) < 1e-10},
    {name = "cross-edge-cancels-physical-lateral-drift", passed = #cross.controls == 2 and math.abs(lateral) < 1e-10 and forward > 0},
    {name = "reported-cost-is-directed-travel-ticks", passed = cross.units == "ticks" and math.abs(cross.cost * forward - 8) < 1e-10}
  }, {native_execution = false, with_ticks = with.travel_ticks, against_ticks = against.travel_ticks,
    cross_ticks = cross.travel_ticks, cross_controls = cross.controls})

  -- Synthetic excessive drift lies outside the actuator velocity hull. A
  -- favorable forward projection alone must never assign a finite edge cost.
  local impossible = {controls = {{direction = 8, velocity = {x = 0.2, y = 0.15}},
    {direction = 10, velocity = {x = 0.05, y = 0.1}}}}
  local infeasible = Motion.directed_edge(impossible, {x = 0, y = 0}, {x = 0, y = 8})
  local narrow, narrow_reason = Controller.begin({x = 0, y = 0}, {x = 0, y = 8}, field, 1 / 256)
  local unsupported = {}
  for _, change in ipairs({{belt_immunity = true}, {actor_profile = "armored"}, {uniform = false},
      {belt = "splitter"}, {belt_direction = 2}, {factorio_version = "2.0.78"}, {running_speed = 0.3}}) do
    local spec = Tests.spec("express-transport-belt", 4)
    for key, value in pairs(change) do spec[key] = value end
    local result, reason = Motion.field(spec)
    unsupported[#unsupported + 1] = {reason = reason, rejected = result == nil}
  end
  local rejected = true
  for _, result in ipairs(unsupported) do rejected = rejected and result.rejected end
  record("model-infeasible-and-unsupported", {
    {name = "uncancellable-drift-has-infinite-cost", passed = infeasible.status == "infeasible" and infeasible.travel_ticks == math.huge},
    {name = "mean-feasible-is-not-finite-corridor-guarantee", passed = narrow == nil and narrow_reason == "corridor-too-narrow-for-calibrated-controls"},
    {name = "unmeasured-domains-are-explicitly-unsupported", passed = rejected}
  }, {native_execution = false, infeasible_reason = infeasible.reason, cost = "infinite", unsupported = unsupported})

  -- This is only a cost-law check on a complete enumerated two-route graph.
  -- It does not claim actual entry/exit, turning belt execution or a planner.
  local ground = assert(Motion.field(Tests.spec("none", 4)))
  local short = Motion.directed_edge(ground, {x = 0, y = 0}, {x = 8, y = 0})
  local segments = {{from = {x = 0, y = 0}, to = {x = 0, y = -2}, direction = 0},
    {from = {x = 0, y = -2}, to = {x = 8, y = -2}, direction = 4},
    {from = {x = 8, y = -2}, to = {x = 8, y = 0}, direction = 8}}
  local longer_cost, reverse_cost, longer_distance = 0, 0, 0
  for _, segment in ipairs(segments) do
    local segment_field = assert(Motion.field(Tests.spec("express-transport-belt", segment.direction)))
    local edge = Motion.directed_edge(segment_field, segment.from, segment.to)
    longer_cost, longer_distance = longer_cost + edge.cost, longer_distance + edge.distance
    reverse_cost = reverse_cost + Motion.directed_edge(segment_field, segment.to, segment.from).cost
  end
  record("model-shorter-versus-faster-enumerated-routes", {
    {name = "longer-favorable-route-has-lower-time-cost", passed = longer_distance > short.distance and longer_cost < short.cost},
    {name = "same-detour-in-reverse-loses-its-benefit", passed = reverse_cost > short.cost}
  }, {native_execution = false, graph_routes_enumerated = 2, search_implemented = false,
    ground_distance = short.distance, ground_ticks = short.cost,
    detour_distance = longer_distance, detour_ticks = longer_cost, reverse_detour_ticks = reverse_cost})

  local saved = {start = {x = 0.5, y = 0.5}, goal = {x = 0.5, y = 3.5}, corridor_half_width = 0.3}
  local original = assert(Command.resolve({direction = 8}, saved.start, 8, 0.25, saved))
  -- Deliberately change every generated-probe default. The same saved task
  -- still asks for the old endpoint and width, rather than accepting a run to
  -- some newly selected destination under the original snapshot hash.
  local changed = assert(Command.resolve({direction = 4}, saved.start, 17, 0.75, saved))
  local mismatch, reason = Command.resolve({direction = 8}, {x = 0.75, y = 0.5}, 8, 0.25, saved)
  local generated = assert(Command.resolve({direction = 4}, saved.start, 8, 0.25))
  record("saved-map-command-remains-the-task", {
    {name = "saved-goal-survives-changed-distance-and-direction-defaults",
      passed = changed.goal.x == original.goal.x and changed.goal.y == original.goal.y
        and changed.goal.x == saved.goal.x and changed.goal.y == saved.goal.y},
    {name = "saved-corridor-controls-admission-and-measurement",
      passed = changed.corridor_half_width == saved.corridor_half_width
        and original.corridor_half_width == saved.corridor_half_width},
    {name = "saved-command-refuses-a-drifted-actor-origin",
      passed = mismatch == nil and reason == "saved-command-origin-mismatch"},
    {name = "unsaved-probes-retain-current-generated-defaults",
      passed = generated.goal.x == 8.5 and generated.goal.y == 0.5 and generated.corridor_half_width == 0.25}
  }, {native_execution = false, saved_goal = saved.goal, generated_goal = generated.goal,
    saved_corridor_half_width = saved.corridor_half_width})
  return cases
end

return Tests
