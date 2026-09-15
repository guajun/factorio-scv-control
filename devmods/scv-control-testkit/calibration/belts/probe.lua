local Fixtures = require("__scv-control-testkit__/calibration/belts/fixtures")
local Probe = {}
local SURFACE = "scv-belt-calibration"
local function copy(p) return {x = p.x, y = p.y} end

function Probe.start(fixture)
  local surface = game.get_surface(SURFACE)
  if not surface then
    surface = game.create_surface(SURFACE, {default_enable_all_autoplace_controls = false,
      autoplace_controls = {}, autoplace_settings = {entity = {treat_missing_as_default = false}}})
    surface.request_to_generate_chunks({0, 0}, 2)
    surface.force_generate_chunk_requests()
    surface.always_day, surface.freeze_daytime, surface.daytime = true, true, 0
    surface.peaceful_mode = true
    local tiles = {}
    for x = -20, 19 do for y = -20, 19 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end end
    surface.set_tiles(tiles, true, false, false, false)
  end
  for _, entity in pairs(surface.find_entities({{-20, -20}, {20, 20}})) do entity.destroy() end
  local count, example = 0
  if fixture.belt ~= "none" then for x = -12, 11 do
    for y = -12, 11 do
      example = surface.create_entity({name = fixture.belt, position = {x + 0.5, y + 0.5},
        direction = fixture.belt_direction, force = "player"})
      if not example then error("belt-calibration: failed to create belt") end
      count = count + 1
    end
  end end
  local actor = surface.create_entity({name = "character", position = {0.5, 0.5}, force = "player"})
  if not actor then error("belt-calibration: failed to create character") end
  local start = copy(actor.position)
  return {actor = actor, surface = surface, fixture = fixture, start = start, previous = copy(start),
    started_tick = game.tick, commanded = false, timeline = {}, assertions = {}, samples = 0,
    metrics = {belt = fixture.belt, belt_direction = fixture.belt_direction,
      command = fixture.command, direction = fixture.direction, start_position = copy(start),
      belt_axis = fixture.belt_axis, command_axis = fixture.command_axis,
      actual_belt_count = count, prototype_belt_speed = example and example.prototype.belt_speed or 0,
      native_running_speed = actor.character_running_speed, armor_equipment = "none",
      belt_immunity_equipment_present = false, actual_distance = 0, max_cross_track_error = 0,
      direction_switches = 0, displacement = {x = 0, y = 0}}}
end

local function expect(probe, name, passed, details)
  probe.assertions[#probe.assertions + 1] = {name = name, passed = passed == true, details = details}
end

local function finish(probe, failed)
  probe.actor.walking_state = {walking = false, direction = probe.fixture.direction}
  local m = probe.metrics
  m.actual_travel_ticks = probe.samples
  m.elapsed_ticks = game.tick - probe.started_tick
  m.final_position = copy(probe.actor.position)
  m.mean_displacement = {x = m.displacement.x / math.max(1, probe.samples),
    y = m.displacement.y / math.max(1, probe.samples)}
  m.mean_command_speed = m.mean_displacement.x * probe.fixture.command_axis.x
    + m.mean_displacement.y * probe.fixture.command_axis.y
  m.mean_belt_axis_speed = m.mean_displacement.x * probe.fixture.belt_axis.x
    + m.mean_displacement.y * probe.fixture.belt_axis.y
  expect(probe, "native-character-and-declared-field", probe.actor.type == "character"
    and m.actual_belt_count == (probe.fixture.belt == "none" and 0 or 576))
  expect(probe, "nonempty-per-tick-displacement", probe.samples > 0 and #probe.timeline == probe.samples)
  expect(probe, "command-progress-plane-reached", not failed)
  expect(probe, "uniform-motion-field-retained", not probe.left_field)
  local passed = true
  for _, assertion in ipairs(probe.assertions) do passed = passed and assertion.passed end
  return {id = probe.fixture.id, passed = passed, terminal_state = failed and "failed" or "progress-plane-crossed",
    reason = failed and "tick-or-coverage-guard" or "native-command-reached-fixed-spatial-plane",
    metrics = m, assertions = probe.assertions, timeline = probe.timeline}
end

function Probe.on_tick(probe)
  local p, f, m = probe.actor.position, probe.fixture, probe.metrics
  if probe.commanded then
    local dx, dy = p.x - probe.previous.x, p.y - probe.previous.y
    probe.samples = probe.samples + 1
    m.actual_distance = m.actual_distance + math.sqrt(dx * dx + dy * dy)
    m.displacement.x, m.displacement.y = m.displacement.x + dx, m.displacement.y + dy
    local cx = p.x - probe.start.x
    local cy = p.y - probe.start.y
    m.max_cross_track_error = math.max(m.max_cross_track_error, math.abs(cx * f.command_axis.y - cy * f.command_axis.x))
    probe.timeline[#probe.timeline + 1] = {tick = game.tick - probe.started_tick, position = copy(p), dx = dx, dy = dy,
      direction = f.direction}
    probe.left_field = math.abs(p.x) >= 11 or math.abs(p.y) >= 11
    if f.belt ~= "none" and not probe.surface.find_entity(f.belt,
        {math.floor(p.x) + 0.5, math.floor(p.y) + 0.5}) then probe.left_field = true end
    if probe.left_field then return finish(probe, true) end
    if cx * f.command_axis.x + cy * f.command_axis.y >= Fixtures.progress_distance then return finish(probe, false) end
  else
    -- Begin the measured interval when the first native walking command is issued.
    -- Passive displacement before that command is retained in the start position.
    probe.start, m.start_position = copy(p), copy(p)
  end
  if game.tick - probe.started_tick > Fixtures.guard_ticks then return finish(probe, true) end
  probe.previous, probe.commanded = copy(p), true
  probe.actor.walking_state = {walking = true, direction = f.direction}
end

return Probe
