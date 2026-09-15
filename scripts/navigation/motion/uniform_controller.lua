local Motion = require("scripts.navigation.motion.measured_uniform")
local PathMath = require("scripts.path_math")
local Trajectory = require("scripts.trajectory")
local Controller = {id = "uniform-belt-compensation-v1"}

function Controller.begin(from, to, field, corridor_half_width)
  local edge = Motion.directed_edge(field, from, to)
  if edge.status ~= "feasible" then return nil, edge.reason or edge.status end
  if type(corridor_half_width) ~= "number" or corridor_half_width ~= corridor_half_width
      or corridor_half_width < edge.sufficient_control_band
      or corridor_half_width <= 0 or corridor_half_width == math.huge then
    return nil, "corridor-too-narrow-for-calibrated-controls"
  end
  return {from = PathMath.copy_position(from), to = PathMath.copy_position(to), edge = edge,
    corridor_half_width = corridor_half_width, ticks = 0, switches = 0, max_cross_track_error = 0}
end

-- Keep a primitive while its next measured displacement fits the declared
-- centerline corridor. Switching to the opposite lateral velocity is driven
-- by actual observed error, not by issuing a new desired angle each tick.
-- Arrival/collision checks remain the caller's responsibility. This module
-- cannot claim that stopping walking stops passive belt displacement.
function Controller.step(position, state)
  local error = Trajectory.cross_track_error(position, state.from, state.to)
  if math.abs(error) > state.corridor_half_width + 1e-10 then
    return nil, {status = "outside-corridor", cross_track_error = error}
  end
  local current = state.current and state.edge.controls[state.current]
  local selected = state.current
  if not current or math.abs(error + current.lateral) > state.corridor_half_width + 1e-10 then
    selected = nil
    for index, control in ipairs(state.edge.controls) do
      local next_error = math.abs(error + control.lateral)
      if next_error <= state.corridor_half_width + 1e-10 then
        if not selected or next_error < math.abs(error + state.edge.controls[selected].lateral) then selected = index end
      end
    end
  end
  if not selected then return nil, {status = "no-safe-primitive", cross_track_error = error} end
  if state.current and state.current ~= selected then state.switches = state.switches + 1 end
  state.current, state.ticks = selected, state.ticks + 1
  state.max_cross_track_error = math.max(state.max_cross_track_error, math.abs(error))
  local control = state.edge.controls[selected]
  return control.direction, {status = "moving", cross_track_error = error,
    predicted_cross_track_error = error + control.lateral, switches = state.switches,
    predicted_velocity = control.velocity}
end

return Controller
