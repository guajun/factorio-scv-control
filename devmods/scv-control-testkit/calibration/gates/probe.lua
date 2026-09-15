local Fixtures = require("__scv-control-testkit__/calibration/gates/fixtures")

local Probe = {}

local function position(value)
  return {x = value.x, y = value.y}
end

local function gate_state(gate)
  if not gate or not gate.valid then return "removed" end
  if gate.is_opened() then return "opened" end
  if gate.is_opening() then return "opening" end
  if gate.is_closing() then return "closing" end
  if gate.is_closed() then return "closed" end
  return "unknown"
end

local function trace(probe, event, details)
  probe.timeline[#probe.timeline + 1] = {
    tick = game.tick - probe.started_tick,
    event = event,
    actor_position = position(probe.actor.position),
    gate_state = gate_state(probe.gate),
    details = details
  }
end

local function expect(probe, name, passed, details)
  probe.assertions[#probe.assertions + 1] = {name = name, passed = passed == true, details = details}
end

local function create_gate(surface, where, force)
  local gate = surface.create_entity({name = "gate", position = where, force = force,
    direction = defines.direction.north})
  if not gate then error("gate-calibration: cannot create gate") end
  gate.destructible = false
  return gate
end

function Probe.start(fixture, index)
  local surface = game.create_surface("scv-gate-calibration-" .. index, {
    seed = Fixtures.surface_seed,
    default_enable_all_autoplace_controls = false,
    autoplace_controls = {},
    autoplace_settings = {entity = {treat_missing_as_default = false}}
  })
  surface.request_to_generate_chunks({0, 0}, 2)
  surface.force_generate_chunk_requests()
  surface.always_day = true
  surface.freeze_daytime = true
  surface.daytime = 0
  surface.peaceful_mode = true
  for _, entity in pairs(surface.find_entities({{-24, -20}, {24, 20}})) do entity.destroy() end
  local tiles = {}
  for x = -24, 23 do
    for y = -20, 19 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles, true, false, false, false)
  for y = -6, 6 do
    if y ~= 0 then
      local wall = surface.create_entity({name = "stone-wall", position = {0.5, y + 0.5}, force = fixture.gate_force})
      if not wall then error("gate-calibration: cannot create wall") end
      wall.destructible = false
    end
  end
  local gate = create_gate(surface, Fixtures.gate, fixture.gate_force)
  local actor = surface.create_entity({name = "character", position = Fixtures.start, force = "player"})
  if not actor then error("gate-calibration: cannot create character") end
  actor.destructible = false
  actor.character_running_speed_modifier = fixture.speed_modifier
  local probe = {
    fixture = fixture, surface = surface, gate = gate, actor = actor,
    started_tick = game.tick, previous_position = position(actor.position),
    timeline = {}, assertions = {}, phase = "approach",
    metrics = {speed_modifier = fixture.speed_modifier, running_speed = actor.character_running_speed,
      gate_force = fixture.gate_force, actor_force = "player", mode = fixture.mode,
      actual_distance = 0, stationary_command_ticks = 0, slowed_command_ticks = 0,
      max_lateral_error = 0, gate_requests = 0, opening_tick = -1, opened_tick = -1,
      closing_tick = -1, reclosed_tick = -1, closed_after_crossing_tick = -1, crossed_tick = -1,
      gate_cleared_tick = -1, clear_center_observed_tick = -1,
      first_contact_tick = -1, first_contact_x = 0, removal_tick = -1},
    last_gate_state = gate_state(gate)
  }
  expect(probe, "real-gate-starts-closed", gate.type == "gate" and gate.is_closed(), {type = gate.type})
  expect(probe, "closed-gate-blocks-character-center", not surface.can_place_entity({
    name = "character", position = Fixtures.gate, force = "player", build_check_type = defines.build_check_type.manual
  }))
  trace(probe, "setup", {start = position(Fixtures.start), gate = position(Fixtures.gate),
    goal_x = Fixtures.goal_x, actor_force = actor.force.name, gate_force = gate.force.name,
    gate_collision_box = gate.prototype.collision_box, actor_collision_box = actor.prototype.collision_box})
  if fixture.mode == "explicit" then
    -- Force-incompatible calls throw in 2.0.77; they are not silent no-ops.
    local ok, error_message = pcall(function() gate.request_to_open(actor.force, Fixtures.explicit_hold_ticks) end)
    probe.metrics.gate_requests = 1
    probe.metrics.request_outcome = ok and "accepted" or "rejected-error"
    probe.metrics.request_error = ok and "" or tostring(error_message)
    expect(probe, "request-obeys-force-relation", ok == (fixture.gate_force == "player"),
      {outcome = probe.metrics.request_outcome, error = probe.metrics.request_error})
    if fixture.gate_force == "enemy" then
      expect(probe, "rejection-identifies-force-incompatibility", not ok and
        string.find(probe.metrics.request_error, "player force can't open gate with enemy force", 1, true) ~= nil)
    end
    trace(probe, "request-to-open", {force = actor.force.name, extra_time = Fixtures.explicit_hold_ticks,
      outcome = probe.metrics.request_outcome, error = probe.metrics.request_error})
  end
  actor.walking_state = {walking = true, direction = defines.direction.east}
  probe.commanded = true
  return probe
end

local function finish(probe, terminal_state, reason)
  probe.actor.walking_state = {walking = false, direction = defines.direction.east}
  probe.finished = true
  trace(probe, "terminal", {terminal_state = terminal_state, reason = reason})
  local passed = true
  for _, assertion in ipairs(probe.assertions) do if not assertion.passed then passed = false end end
  probe.metrics.elapsed_ticks = game.tick - probe.started_tick
  probe.metrics.final_position = position(probe.actor.position)
  probe.result = {id = probe.fixture.id, passed = passed, terminal_state = terminal_state,
    reason = reason, assertions = probe.assertions, metrics = probe.metrics, timeline = probe.timeline}
  return probe.result
end

local function observe(probe)
  local actor, metrics = probe.actor, probe.metrics
  local dx = actor.position.x - probe.previous_position.x
  local dy = actor.position.y - probe.previous_position.y
  metrics.actual_distance = metrics.actual_distance + math.sqrt(dx * dx + dy * dy)
  metrics.max_lateral_error = math.max(metrics.max_lateral_error, math.abs(actor.position.y - Fixtures.start.y))
  if probe.commanded then
    -- 1/256 tile is the native fixed-point position quantum, not a stuck timeout.
    if dx < 1 / 256 then metrics.stationary_command_ticks = metrics.stationary_command_ticks + 1 end
    if dx + 1 / 256 < actor.character_running_speed then
      metrics.slowed_command_ticks = metrics.slowed_command_ticks + 1
      if metrics.first_contact_tick < 0 and math.abs(actor.position.x - Fixtures.gate.x) < 2 then
        metrics.first_contact_tick = game.tick - probe.started_tick
        metrics.first_contact_x = actor.position.x
        trace(probe, "native-motion-constrained", {dx = dx, requested_speed = actor.character_running_speed})
      end
    end
  end
  probe.previous_position = position(actor.position)
  local elapsed = game.tick - probe.started_tick
  local actor_box = actor.prototype.collision_box
  local gate_box = probe.gate.valid and probe.gate.prototype.collision_box
  if gate_box and metrics.gate_cleared_tick < 0
    and actor.position.x + actor_box.left_top.x > Fixtures.gate.x + gate_box.right_bottom.x then
    metrics.gate_cleared_tick = elapsed
    trace(probe, "actor-collision-box-cleared-gate-plane")
  end
  -- Avoid mistaking the actor's own body for gate collision while probing the
  -- center. Close approaches remain explicitly unsampled instead of inferred.
  if probe.gate.valid and metrics.clear_center_observed_tick < 0
    and math.abs(actor.position.x - Fixtures.gate.x) > 1
    and probe.surface.can_place_entity({name = "character", position = Fixtures.gate,
      force = "player", build_check_type = defines.build_check_type.manual}) then
    metrics.clear_center_observed_tick = elapsed
    trace(probe, "unoccupied-gate-center-is-collision-free")
  end
  local state = gate_state(probe.gate)
  if state ~= probe.last_gate_state then
    trace(probe, "gate-state", {previous = probe.last_gate_state, current = state})
    probe.last_gate_state = state
    if state == "opening" and metrics.opening_tick < 0 then metrics.opening_tick = elapsed end
    if state == "opened" and metrics.opened_tick < 0 then metrics.opened_tick = elapsed end
    if state == "closing" and metrics.closing_tick < 0 then metrics.closing_tick = elapsed end
    if state == "closed" and metrics.opened_tick >= 0 and metrics.reclosed_tick < 0 then metrics.reclosed_tick = elapsed end
    if probe.fixture.gate_force == "enemy" and state ~= "closed" and state ~= "removed" then
      probe.hostile_opened = true
    end
  end
end

function Probe.on_tick(probe)
  if probe.finished then return probe.result end
  observe(probe)
  local metrics, actor = probe.metrics, probe.actor
  local elapsed = game.tick - probe.started_tick
  if elapsed > Fixtures.guard_ticks then
    expect(probe, "semantic-terminal-before-failure-guard", false, {phase = probe.phase, elapsed_ticks = elapsed})
    return finish(probe, "failed", "tick-guard-exceeded")
  end
  if probe.fixture.gate_force == "player" then
    if probe.phase == "approach" and actor.position.x >= Fixtures.goal_x then
      metrics.crossed_tick = elapsed
      trace(probe, "crossed-and-left-activation-range")
      probe.phase = "wait-for-close"
      expect(probe, "gate-opened-before-crossing", metrics.opening_tick >= 0 and metrics.opened_tick >= 0)
      expect(probe, "native-east-crossing-without-lateral-detour", metrics.max_lateral_error <= 1 / 256)
      if probe.fixture.mode == "explicit" then
        expect(probe, "proactive-request-avoids-contact", metrics.first_contact_tick < 0,
          {contact_tick = metrics.first_contact_tick, slowed_ticks = metrics.slowed_command_ticks})
      elseif probe.fixture.speed_modifier == 4 then
        expect(probe, "fast-passive-control-exposes-contact-delay", metrics.first_contact_tick >= 0
          and metrics.slowed_command_ticks > 0, {contact_tick = metrics.first_contact_tick,
            slowed_ticks = metrics.slowed_command_ticks})
      else
        expect(probe, "normal-passive-control-crosses-without-contact", metrics.first_contact_tick < 0)
      end
    end
    if probe.phase == "wait-for-close" and probe.gate.is_closed() then
      metrics.closed_after_crossing_tick = elapsed
      expect(probe, "observed-open-close-cycle", metrics.closing_tick >= metrics.opened_tick and metrics.opened_tick >= 0)
      expect(probe, "closed-gate-again-blocks-character-center", not probe.surface.can_place_entity({
        name = "character", position = Fixtures.gate, force = "player", build_check_type = defines.build_check_type.manual
      }))
      return finish(probe, "closed-after-crossing", "native-character-crossed-real-gate-and-gate-reclosed")
    end
  else
    -- A blocked claim needs both native contact and a semantic positive-control cycle.
    -- Elapsed time alone never proves that the enemy gate rejects the actor force.
    if probe.phase == "approach" and metrics.first_contact_tick >= 0 then
      probe.control_gate = create_gate(probe.surface, Fixtures.control_gate, "player")
      probe.control_gate.request_to_open(actor.force, Fixtures.control_hold_ticks)
      probe.phase = "control-cycle"
      trace(probe, "positive-control-request", {gate_position = position(Fixtures.control_gate),
        extra_time = Fixtures.control_hold_ticks})
    end
    if probe.phase == "control-cycle" then
      if probe.control_gate.is_opened() and not probe.control_opened then
        probe.control_opened = true
        trace(probe, "positive-control-opened")
      end
      if probe.control_opened and probe.control_gate.is_closed() then
        trace(probe, "positive-control-reclosed")
        expect(probe, "actor-remains-on-near-side", actor.position.x < Fixtures.gate.x)
        expect(probe, "hostile-gate-stays-closed-through-control-cycle", not probe.hostile_opened and probe.gate.is_closed())
        expect(probe, "native-command-is-physically-blocked", metrics.stationary_command_ticks > 0)
        -- Remove only the gate: the character must now cross, proving this entity
        -- caused the blockage rather than a stopped controller or hidden terrain.
        probe.gate.destroy()
        metrics.removal_tick = elapsed
        trace(probe, "remove-blocker-counterfactual")
        probe.phase = "counterfactual-crossing"
      end
    end
    if probe.phase == "counterfactual-crossing" and actor.position.x >= Fixtures.goal_x then
      metrics.crossed_tick = elapsed
      expect(probe, "removing-only-gate-restores-native-crossing", metrics.removal_tick >= 0 and metrics.crossed_tick > metrics.removal_tick)
      expect(probe, "counterfactual-has-no-lateral-detour", metrics.max_lateral_error <= 1 / 256)
      return finish(probe, "blocked-by-force-gate", "contact-and-friendly-control-cycle-plus-gate-removal-prove-local-blocker")
    end
  end
  probe.commanded = probe.phase ~= "wait-for-close"
  actor.walking_state = {walking = probe.commanded, direction = defines.direction.east}
end

return Probe
