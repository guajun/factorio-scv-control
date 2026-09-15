local Fixtures = require("__scv-control-testkit__/calibration/belt_controller/fixtures")
local ModelTests = require("__scv-control-testkit__/calibration/belt_controller/model_tests")
local Motion = require("__factorio-scv-control__/scripts/navigation/motion/measured_uniform")
local Controller = require("__factorio-scv-control__/scripts/navigation/motion/uniform_controller")
local Follower = require("__factorio-scv-control__/scripts/follower")
local Trajectory = require("__factorio-scv-control__/scripts/trajectory")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local Command = require("calibration.belt_controller.command")
local Probe = {}
local SURFACE = "scv-belt-controller"
local function copy(p) return PathMath.copy_position(p) end
local function expect(probe, name, passed, details)
  probe.assertions[#probe.assertions + 1] = {name = name, passed = passed == true, details = details}
end

function Probe.start(fixture)
  local surface = game.get_surface(SURFACE)
  if not surface then
    surface = game.create_surface(SURFACE, {seed = 424242, default_enable_all_autoplace_controls = false,
      autoplace_controls = {}, autoplace_settings = {entity = {treat_missing_as_default = false}}})
    surface.request_to_generate_chunks({0, 0}, 2)
    surface.force_generate_chunk_requests()
    surface.always_day, surface.freeze_daytime, surface.daytime, surface.peaceful_mode = true, true, 0, true
    local tiles = {}
    for x = -20, 19 do for y = -20, 19 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
    surface.set_tiles(tiles, true, false, false, false)
  end
  for _, entity in pairs(surface.find_entities({{-20, -20}, {20, 20}})) do entity.destroy() end
  local count = 0
  for x = -12, 11 do for y = -12, 11 do
    assert(surface.create_entity({name = fixture.belt, position = {x + 0.5, y + 0.5},
      direction = fixture.belt_direction, force = "player"}))
    count = count + 1
  end end
  local actor = assert(surface.create_entity({name = "character", position = {0.5, 0.5}, force = "player"}))
  local spec = ModelTests.spec(fixture.belt, fixture.belt_direction)
  spec.running_speed = actor.character_running_speed
  local field = assert(Motion.field(spec))
  return {surface = surface, actor = actor, fixture = fixture, field = field,
    started_tick = game.tick, samples = 0, timeline = {}, assertions = {},
    metrics = {mode = fixture.mode, relationship = fixture.relationship, pair = fixture.pair,
      belt = fixture.belt, belt_direction = fixture.belt_direction, command_direction = fixture.direction,
      actual_belt_count = count, actor_profile = spec.actor_profile, model_id = Motion.id,
      corridor_half_width = Fixtures.corridor_half_width, actual_distance = 0,
      max_cross_track_error = 0, direction_switches = 0, max_velocity_model_error = 0,
      native_execution = true, production_profile_modified = false}}
end

local function finish(probe, status, reason)
  Follower.stop(probe.actor)
  local m, f = probe.metrics, probe.fixture
  m.actual_travel_ticks, m.final_position = probe.samples, copy(probe.actor.position)
  m.endpoint_error = PathMath.distance(probe.actor.position, probe.goal)
  m.final_cross_track_error = math.abs(Trajectory.cross_track_error(probe.actor.position, probe.start, probe.goal))
  m.arrival_tolerance = Follower.tolerance(probe.actor)
  m.corridor_retained = m.max_cross_track_error <= m.corridor_half_width + 1e-10
  expect(probe, "native-arrival-not-tick-limit", status == "arrived")
  expect(probe, "uniform-field-retained", not probe.left_field)
  expect(probe, "native-velocity-agrees-with-measured-field", m.max_velocity_model_error <= 1e-10,
    "Every tick compares the issued command's measured vector with observed displacement.")
  expect(probe, "endpoint-inside-shared-follower-tolerance", m.endpoint_error <= m.arrival_tolerance + 1e-10)
  if f.mode == "compensated" then
    expect(probe, "declared-centerline-corridor-retained", m.corridor_retained)
    local edge = probe.controller.edge
    local slope = 0
    if #edge.controls == 2 then slope = (edge.controls[1].along - edge.controls[2].along)
      / (edge.controls[1].lateral - edge.controls[2].lateral) end
    m.predicted_travel_ticks = edge.travel_ticks
    m.prediction_tick_error = math.abs(probe.samples - edge.travel_ticks)
    m.prediction_tick_error_bound = (m.arrival_tolerance + math.abs(slope) * m.corridor_half_width)
      / edge.forward_speed + 1
    m.control_mix = edge.controls
    expect(probe, "time-prediction-inside-derived-terminal-and-corridor-bound",
      m.prediction_tick_error <= m.prediction_tick_error_bound)
  else
    expect(probe, "unmodified-follower-exposes-cross-belt-drift", not m.corridor_retained)
  end
  local passed = true
  for _, assertion in ipairs(probe.assertions) do passed = passed and assertion.passed end
  return {id = f.id, passed = passed, terminal_state = status, reason = reason,
    assertions = probe.assertions, metrics = m, timeline = probe.timeline}
end

function Probe.on_tick(probe)
  local actor, f, m = probe.actor, probe.fixture, probe.metrics
  local p = actor.position
  if not probe.start then
    -- Passive belt movement before the first command is excluded from both
    -- paired measurements; the exact command origin is included in the report.
    local command = assert(Command.resolve(f, p, Fixtures.distance, Fixtures.corridor_half_width, probe.saved_command))
    probe.start, probe.goal = command.start, command.goal
    m.corridor_half_width, m.command_source = command.corridor_half_width, command.source
    probe.controller = assert(Controller.begin(probe.start, probe.goal, probe.field, m.corridor_half_width))
    probe.follower = {path = {copy(probe.goal)}, waypoint_index = 1, segment_start = copy(probe.start)}
    m.start_position, m.goal_position = copy(probe.start), copy(probe.goal)
  elseif probe.previous then
    local dx, dy = p.x - probe.previous.x, p.y - probe.previous.y
    probe.samples = probe.samples + 1
    m.actual_distance = m.actual_distance + math.sqrt(dx * dx + dy * dy)
    local error = Trajectory.cross_track_error(p, probe.start, probe.goal)
    m.max_cross_track_error = math.max(m.max_cross_track_error, math.abs(error))
    local v = Motion.physical_velocity(probe.field, probe.previous_direction)
    m.max_velocity_model_error = math.max(m.max_velocity_model_error, math.abs(dx - v.x), math.abs(dy - v.y))
    probe.timeline[#probe.timeline + 1] = {tick = probe.samples, position = copy(p), dx = dx, dy = dy,
      direction = probe.previous_direction, cross_track_error = error}
    if math.abs(p.x) >= 11 or math.abs(p.y) >= 11 then
      probe.left_field = true
      return finish(probe, "failed", "uniform-coverage-guard")
    end
  end
  if game.tick - probe.started_tick > Fixtures.guard_ticks then return finish(probe, "failed", "tick-guard") end
  local direction
  if f.mode == "production-follower" then
    local status, diagnostics = Follower.advance(actor, probe.follower, probe.goal)
    if status ~= "moving" then return finish(probe, status, "unmodified-production-follower-terminal") end
    -- The native getter still exposes the previously applied walking state
    -- during this event. Record the command returned by the shared follower,
    -- so the following tick's displacement is compared with the right input.
    direction = diagnostics.selected_direction
  else
    if PathMath.distance(p, probe.goal) <= Follower.tolerance(actor) then
      return finish(probe, "arrived", "inside-shared-follower-tolerance")
    end
    local diagnostics
    direction, diagnostics = Controller.step(p, probe.controller)
    if not direction then return finish(probe, "failed", diagnostics.status) end
    actor.walking_state = {walking = true, direction = direction}
  end
  if probe.previous_direction and probe.previous_direction ~= direction then
    m.direction_switches = m.direction_switches + 1
  end
  probe.previous, probe.previous_direction = copy(p), direction
end

return Probe
