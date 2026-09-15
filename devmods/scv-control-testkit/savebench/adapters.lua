local GateProbe = require("calibration.gate_actions.probe")
local BeltProbe = require("calibration.belt_controller.probe")
local World = require("episodes.world")
local Runner = require("episodes.runner")
local Services = require("episodes.corridor_services")
local GateAction = require("__factorio-scv-control__/scripts/navigation/gates/action")
local GateFixtures = require("calibration.gate_actions.fixtures")
local Motion = require("__factorio-scv-control__/scripts/navigation/motion/measured_uniform")
local MotionSpecs = require("calibration.belt_controller.model_tests")

local Adapters = {}

-- Build is deliberately separate from run. Only the corpus authoring command
-- may call setup/start factories. Replaying a .zip keeps its LuaEntity objects,
-- surface geometry, initial probe state and saved action schedule intact.
function Adapters.prepare(case, sequence)
  local prepared = {descriptor = case}
  if case.domain == "dynamic" then
    prepared.world = World.setup(case.fixture)
    prepared.actor, prepared.surface = prepared.world.actor, prepared.world.surface
  else
    prepared.probe = case.domain == "gate-actions"
      and GateProbe.start(case.fixture, sequence) or BeltProbe.start(case.fixture)
    prepared.actor, prepared.surface = prepared.probe.actor, prepared.probe.surface
  end
  return prepared
end

function Adapters.begin(prepared, tick)
  prepared.derived_compile_calls = (prepared.derived_compile_calls or 0) + 1
  if prepared.descriptor.domain == "dynamic" then
    -- No World.setup here: this is the exact saved surface and actor.
    prepared.run = Runner.start(prepared.descriptor.fixture, prepared.world, Services, tick)
  else
    local probe = prepared.probe
    -- Recompile algorithm state with the current implementation against the
    -- saved real entities. A source map must not pin an obsolete Action.new or
    -- motion-field implementation inside a previously serialized probe.
    if prepared.descriptor.domain == "gate-actions" then
      probe.action, probe.rejection = GateAction.new(probe.gate, probe.actor,
        probe.start, probe.goal, GateFixtures.opening)
    else
      local spec = MotionSpecs.spec(probe.fixture.belt, probe.fixture.belt_direction)
      spec.running_speed = probe.actor.character_running_speed
      probe.field = assert(Motion.field(spec))
    end
    -- Clock reset is command state only. No entity creation, teleport, tile
    -- mutation or geometry factory is permitted in this replay path.
    probe.started_tick = tick
  end
end

function Adapters.update(prepared, tick)
  local domain = prepared.descriptor.domain
  if domain == "dynamic" then
    local result = Runner.update(prepared.run, prepared.descriptor.fixture, Services, tick)
    if result then return Services.result(result) end
  elseif domain == "gate-actions" then
    return GateProbe.on_tick(prepared.probe)
  else
    return BeltProbe.on_tick(prepared.probe)
  end
end

function Adapters.path_result(prepared, event)
  if prepared.descriptor.domain ~= "dynamic" or not prepared.run then return end
  Runner.handle_path_result(prepared.run, prepared.descriptor.fixture, Services, event, game.tick)
  if prepared.run.result then return Services.result(prepared.run.result) end
end

function Adapters.entity_event(prepared, name, event)
  if prepared.descriptor.domain == "dynamic" and prepared.run then
    Services.navigation.on_entity_event(prepared.run, name, event)
  end
end

function Adapters.stop(prepared)
  if prepared.run then Services.navigation.stop(prepared.run)
  elseif prepared.actor and prepared.actor.valid then
    prepared.actor.walking_state = {walking = false, direction = defines.direction.north}
  end
end

return Adapters
