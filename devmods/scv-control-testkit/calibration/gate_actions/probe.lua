local Fixtures = require("__scv-control-testkit__/calibration/gate_actions/fixtures")
local Action = require("__factorio-scv-control__/scripts/navigation/gates/action")
local Semantics = require("__factorio-scv-control__/scripts/navigation/gates/semantics")
local Follower = require("__factorio-scv-control__/scripts/follower")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Probe = {}

local function copy(p) return {x = p.x, y = p.y} end
local function assert_case(p, name, passed, details)
  p.assertions[#p.assertions + 1] = {name = name, passed = passed == true, details = details}
end
local function trace(p, event, details)
  p.timeline[#p.timeline + 1] = {tick = game.tick - p.started_tick, event = event,
    actor_position = copy(p.actor.position), details = details}
end
local function circuit(wall)
  local behavior = wall.get_or_create_control_behavior()
  behavior.open_gate = true
  behavior.circuit_condition = {condition = {first_signal = {type = "virtual", name = "signal-A"}, comparator = ">", constant = 0}}
end

function Probe.start(fixture, index)
  local surface = game.create_surface("scv-gate-actions-" .. index, {
    seed = Fixtures.seed, default_enable_all_autoplace_controls = false,
    autoplace_controls = {}, autoplace_settings = {entity = {treat_missing_as_default = false}}})
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities({{-24, -20}, {24, 20}})) do entity.destroy() end
  local tiles = {}
  for x = -24, 23 do for y = -20, 19 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
  surface.set_tiles(tiles, true, false, false, false)
  surface.always_day, surface.freeze_daytime = true, true
  local wall
  for y = -6, 6 do
    if y ~= 0 then
      local entity = surface.create_entity({name = fixture.gate_chain and y == 1 and "gate" or "stone-wall",
        position = {0.5, y + 0.5}, force = fixture.gate_force or "player"})
      if y == -1 then wall = entity end
    end
  end
  local gate = surface.create_entity({name = "gate", position = {0.5, 0.5}, force = fixture.gate_force or "player"})
  local start, goal = {x = fixture.start_x or -12.5, y = 0.5}, {x = 12.5, y = 0.5}
  local actor = surface.create_entity({name = "character", position = start, force = "player"})
  actor.destructible = false
  actor.character_running_speed_modifier = fixture.speed_modifier
  if fixture.circuit then circuit(wall) end
  local p = {fixture = fixture, actor = actor, gate = gate, wall = wall, surface = surface,
    start = start, goal = goal, started_tick = game.tick, previous_position = copy(actor.position),
    follower = {path = {goal}, waypoint_index = 1, segment_start = copy(start)},
    assertions = {}, timeline = {}, metrics = {running_speed = actor.character_running_speed,
      stationary_command_ticks = 0, slowed_command_ticks = 0, actual_distance = 0,
      max_lateral_error = 0, follower_replans = 0, action_replans = 0, opened_tick = -1,
      first_movement_tick = -1, mutation_tick = -1, invalidation_tick = -1}}
  assert_case(p, "real-closed-gate", gate.valid and gate.type == "gate" and gate.is_closed())
  assert_case(p, "production-validator-remains-conservative-on-closed-gate",
    not PathSmoothing.path_is_clear(surface, actor, start, {goal}, 0))
  local neighbours = {}
  for direction, entity in pairs(gate.neighbours or {}) do
    neighbours[#neighbours + 1] = {direction = direction, type = entity.type,
      position = copy(entity.position), same_entity = entity == gate}
  end
  trace(p, "setup", {start = start, goal = goal, opening_calibration = Fixtures.opening,
    gate_box = gate.bounding_box, actor_box = actor.prototype.collision_box,
    neighbours = neighbours, route_source = "authored-action-fixture-not-PlanningRun"})
  p.action, p.rejection = Action.new(gate, actor, start, goal, Fixtures.opening)
  return p
end

local function finish(p, terminal, reason)
  Follower.stop(p.actor)
  p.finished = true
  local m, a = p.metrics, p.action
  m.elapsed_ticks, m.final_position = game.tick - p.started_tick, copy(p.actor.position)
  m.action_requests = a and a.requests or 0
  m.waiting_ticks = a and a.waiting_ticks or 0
  m.first_request_tick = a and a.first_request_tick and a.first_request_tick - p.started_tick or -1
  m.first_request_distance = a and a.first_request_distance or -1
  m.max_extra_time = a and a.max_extra_time or 0
  m.expected_delay_ticks = a and a.expected_delay_ticks or 0
  trace(p, "terminal", {terminal_state = terminal, reason = reason})
  local passed = true
  for _, assertion in ipairs(p.assertions) do if not assertion.passed then passed = false end end
  p.result = {id = p.fixture.id, passed = passed, terminal_state = terminal, reason = reason,
    assertions = p.assertions, metrics = m, timeline = p.timeline}
  return p.result
end

function Probe.on_tick(p)
  if p.finished then return p.result end
  local actor, m, elapsed = p.actor, p.metrics, game.tick - p.started_tick
  local dx = actor.position.x - p.previous_position.x
  m.actual_distance = m.actual_distance + math.abs(dx)
  m.max_lateral_error = math.max(m.max_lateral_error, math.abs(actor.position.y - p.start.y))
  if dx > 0 and m.first_movement_tick < 0 then m.first_movement_tick = elapsed end
  if p.commanded then
    if dx < 1 / 256 then m.stationary_command_ticks = m.stationary_command_ticks + 1 end
    if dx + 1 / 256 < actor.character_running_speed then m.slowed_command_ticks = m.slowed_command_ticks + 1 end
  end
  p.previous_position = copy(actor.position)
  if p.pending_invalidation then
    assert_case(p, "native-motion-stops-after-invalidation", math.abs(dx) <= 1 / 256)
    return finish(p, "replan-required", p.pending_invalidation)
  end
  if elapsed > Fixtures.guard_ticks then
    assert_case(p, "terminal-before-guard", false)
    return finish(p, "failed", "tick-guard-exceeded")
  end
  if p.fixture.rejection then
    assert_case(p, "explicit-semantic-rejection", not p.action and p.rejection == p.fixture.rejection,
      {reason = p.rejection})
    assert_case(p, "no-native-motion-or-open-request", not p.action and m.actual_distance == 0 and p.gate.is_closed())
    return finish(p, "rejected", p.rejection or "unexpected-action")
  end
  if not p.action then assert_case(p, "action-created", false); return finish(p, "failed", p.rejection) end
  if p.fixture.change and not p.changed and actor.position.x > p.start.x then
    if p.fixture.change == "force" then p.gate.force = "enemy"
    elseif p.fixture.change == "circuit" then circuit(p.wall)
    elseif p.fixture.change == "rotate" then p.gate.direction = defines.direction.east
    else p.gate.destroy() end
    p.changed, m.mutation_tick = true, elapsed
    trace(p, "eligibility-change", {kind = p.fixture.change})
  end
  if p.gate.valid and p.gate.is_opened() and m.opened_tick < 0 then
    m.opened_tick = elapsed
    -- Current validator uses the prototype's closed mask even when open. Keep
    -- that integration blocker visible; these are action tests, not accepted
    -- planner paths or an alternative route-admission pipeline.
    assert_case(p, "production-validator-still-rejects-open-gate",
      not PathSmoothing.path_is_clear(p.surface, actor, actor.position, {p.goal}, 0))
    assert_case(p, "opened-state-is-transient-conditional", Semantics.classify(p.gate, actor).revision_kind == "transient")
    local opened_action = Action.new(p.gate, actor, actor.position, p.goal, Fixtures.opening)
    assert_case(p, "already-open-gate-predicts-no-opening-delay", opened_action and opened_action.expected_delay_ticks == 0)
    trace(p, "gate-opened")
  end
  local action_status, reason = Action.step(actor, p.action)
  if action_status ~= p.last_action_status then trace(p, "action-state", {state = action_status, reason = reason}); p.last_action_status = action_status end
  p.commanded = false
  if action_status == "replan" then
    m.action_replans, m.invalidation_tick = m.action_replans + 1, elapsed
    assert_case(p, "expected-eligibility-invalidation", p.changed and reason == p.fixture.invalidation, {reason = reason})
    assert_case(p, "stop-on-same-tick-before-gate", m.invalidation_tick == m.mutation_tick
      and actor.position.x < p.action.entry)
    assert_case(p, "no-contact-before-invalidation", m.slowed_command_ticks == 0)
    p.pending_invalidation = reason
    return
  end
  if action_status == "waiting" then return end
  local status = Follower.advance(actor, p.follower, p.goal)
  p.commanded = status == "moving"
  if status == "replan" then
    m.follower_replans = m.follower_replans + 1
    assert_case(p, "follower-does-not-replan", false)
    return finish(p, "failed", "follower-replan")
  end
  if status == "arrived" then
    local error = math.sqrt((actor.position.x - p.goal.x)^2 + (actor.position.y - p.goal.y)^2)
    m.arrival_error, m.arrival_bound = error, Follower.tolerance(actor)
    assert_case(p, "native-follower-arrived", error <= m.arrival_bound)
    assert_case(p, "opened-and-cleared-transition", m.opened_tick >= 0 and p.action.phase == "complete")
    assert_case(p, "no-contact-or-stuck-replan", m.slowed_command_ticks == 0 and m.follower_replans == 0)
    assert_case(p, "no-lateral-detour", m.max_lateral_error <= 1 / 256)
    assert_case(p, "bounded-proactive-requests", p.action.requests > 0 and p.action.max_extra_time > 0)
    if p.fixture.start_x then
      assert_case(p, "near-fast-actor-waits-safely", p.action.waiting_ticks > 0)
      assert_case(p, "opening-delay-prediction-matches-native-wait", p.action.waiting_ticks == p.action.expected_delay_ticks)
    end
    return finish(p, "arrived", "native-follower-through-real-gate")
  end
end

return Probe
