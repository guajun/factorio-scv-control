local GateProbe = require("calibration.gate_actions.probe")
local BeltProbe = require("calibration.belt_controller.probe")
local World = require("episodes.world")
local Runner = require("episodes.runner")
local Services = require("episodes.corridor_services")

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
    -- Recreate evidence as well as algorithm state. Persisted passing booleans
    -- and model/calibration metadata are not evidence about the current code.
    -- No entity creation, teleport, tile mutation or geometry factory is
    -- permitted in this replay path; arm only reads the saved native objects.
    if prepared.descriptor.domain == "gate-actions" then
      prepared.probe = GateProbe.arm(probe, tick,
        {start = prepared.descriptor.start, goal = prepared.descriptor.goal})
    else
      local case = prepared.descriptor
      local constraints = case.scope.execution_constraints
      prepared.probe = BeltProbe.arm(probe, tick, {start = case.start, goal = case.goal,
        -- The first experimental corpus already saved this exact constraint in
        -- its probe metrics. New sources bind it in the native facts metadata.
        corridor_half_width = constraints and constraints.corridor_half_width or probe.metrics.corridor_half_width})
    end
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
