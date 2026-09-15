-- Measured in Factorio 2.0.77, base character, no armor/equipment, grass-1.
-- The constants are native displacement, not character_running_speed or a
-- general promise about every belt-connected entity / actor configuration.
local Motion = {id = "measured-uniform-belts-v1", calibration_id = "factorio-native-uniform-belts-v1"}
local ground = {
  [0] = {0, -38}, [2] = {27, -27}, [4] = {38, 0}, [6] = {27, 27},
  [8] = {0, 38}, [10] = {-27, 27}, [12] = {-38, 0}, [14] = {-27, -27}
}
local belt_speed = {none = 0, ["transport-belt"] = 8 / 256,
  ["fast-transport-belt"] = 16 / 256, ["express-transport-belt"] = 24 / 256}
local axes = {[0] = {x = 0, y = -1}, [4] = {x = 1, y = 0},
  [8] = {x = 0, y = 1}, [12] = {x = -1, y = 0}}
local EPSILON = 1e-10 -- Numeric comparison tolerance, not an actor clearance.

function Motion.field(spec)
  if not spec or spec.factorio_version ~= "2.0.77" then return nil, "unmeasured-engine-version" end
  if spec.actor_profile ~= "base-character-unarmored-v1" or spec.running_speed ~= 0.15
      or spec.belt_immunity ~= false then return nil, "unmeasured-actor-profile" end
  if spec.tile ~= "grass-1" or spec.uniform ~= true then return nil, "unmeasured-motion-field" end
  local speed = belt_speed[spec.belt]
  local axis = axes[spec.belt_direction]
  if not speed or not axis then return nil, "unmeasured-belt-kind-or-direction" end
  local field = {id = Motion.id, calibration_id = Motion.calibration_id, spec = spec, controls = {}}
  for direction = 0, 14, 2 do
    field.controls[#field.controls + 1] = {direction = direction,
      velocity = {x = ground[direction][1] / 256 + speed * axis.x,
        y = ground[direction][2] / 256 + speed * axis.y}}
  end
  return field
end

function Motion.physical_velocity(field, direction)
  for _, control in ipairs(field.controls) do
    if control.direction == direction then return {x = control.velocity.x, y = control.velocity.y} end
  end
  return nil, "unmeasured-command"
end

-- Find the maximum forward speed on the zero-lateral-velocity slice of the
-- control-velocity convex hull. In 2-D a vertex of that slice uses at most two
-- controls. This is directed *kinematic* feasibility; collision/corridor safety
-- and realizability with finite switching still need an execution validator.
function Motion.directed_edge(field, from, to)
  if not field then return {status = "unsupported", reason = "missing-measured-field", travel_ticks = math.huge} end
  local dx, dy = to.x - from.x, to.y - from.y
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance <= EPSILON then return {status = "degenerate", reason = "zero-length-edge", travel_ticks = 0} end
  local along, normal = {x = dx / distance, y = dy / distance}, {x = -dy / distance, y = dx / distance}
  local samples = {}
  for _, control in ipairs(field.controls) do
    local v = control.velocity
    samples[#samples + 1] = {direction = control.direction, velocity = v,
      along = v.x * along.x + v.y * along.y, lateral = v.x * normal.x + v.y * normal.y}
  end
  local best
  local function consider(first, second, first_share)
    local speed = first.along * first_share + (second and second.along * (1 - first_share) or 0)
    if speed > EPSILON and (not best or speed > best.forward_speed + EPSILON) then
      best = {status = "feasible", distance = distance, forward_speed = speed,
        travel_ticks = distance / speed, cost = distance / speed, units = "ticks",
        controls = {{direction = first.direction, velocity = first.velocity,
          lateral = first.lateral, along = first.along, share = first_share}},
        sufficient_control_band = math.abs(first.lateral), along = along, normal = normal,
        guarantee = "uniform-field-mean-velocity-only"}
      if second then
        best.controls[2] = {direction = second.direction, velocity = second.velocity,
          lateral = second.lateral, along = second.along, share = 1 - first_share}
        best.sufficient_control_band = math.max(best.sufficient_control_band, math.abs(second.lateral))
      end
    end
  end
  for index, first in ipairs(samples) do
    if math.abs(first.lateral) <= EPSILON then consider(first, nil, 1) end
    for other = index + 1, #samples do
      local second = samples[other]
      if first.lateral * second.lateral < -EPSILON then
        consider(first, second, -second.lateral / (first.lateral - second.lateral))
      end
    end
  end
  return best or {status = "infeasible", reason = "cannot-cancel-lateral-drift-with-positive-progress",
    distance = distance, travel_ticks = math.huge, cost = math.huge, units = "ticks"}
end

return Motion
