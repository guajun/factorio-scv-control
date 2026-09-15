local Semantics = require("scripts.navigation.gates.semantics")
local Follower = require("scripts.follower")

local Action = {}
local QUANTUM = 1 / 256 -- Factorio position representation, not a route tuning knob.

local function reject(reason) return nil, reason end

-- A single straight, cardinal transition. Geometry is the real gate bounding
-- box inflated by the actor body. Callers supply measured opening latency with
-- engine/prototype provenance because 2.0.77 does not expose it at runtime.
function Action.new(gate, actor, start, goal, calibration)
  local semantic = Semantics.classify(gate, actor)
  if not semantic.traversable then return reject(semantic.reason) end
  if not calibration or calibration.factorio_version ~= script.active_mods.base
      or calibration.prototype ~= gate.name or type(calibration.opening_ticks) ~= "number"
      or calibration.opening_ticks <= 0 or calibration.opening_ticks % 1 ~= 0 then
    return reject("missing-matching-opening-calibration")
  end
  if actor.character_running_speed <= 0 then return reject("non-positive-speed") end
  local dx, dy = goal.x - start.x, goal.y - start.y
  if (dx == 0) == (dy == 0) then return reject("only-cardinal-segments-supported") end
  local axis, cross = dx ~= 0 and "x" or "y", dx ~= 0 and "y" or "x"
  local sign = goal[axis] > start[axis] and 1 or -1
  local body, box = actor.prototype.collision_box, gate.bounding_box
  local lo = box.left_top[axis] - body.right_bottom[axis]
  local hi = box.right_bottom[axis] - body.left_top[axis]
  local cross_lo = box.left_top[cross] - body.right_bottom[cross]
  local cross_hi = box.right_bottom[cross] - body.left_top[cross]
  if start[cross] <= cross_lo or start[cross] >= cross_hi then return reject("segment-misses-gate") end
  local entry = sign == 1 and lo or hi
  local exit = sign == 1 and hi or lo
  if sign * (entry - start[axis]) <= 0 or sign * (goal[axis] - exit) <= 0 then
    return reject("segment-does-not-cross-entire-gate")
  end
  return {gate = gate, gate_unit = gate.unit_number, axis = axis, cross = cross,
    bounds = {left_top = {x = box.left_top.x, y = box.left_top.y},
      right_bottom = {x = box.right_bottom.x, y = box.right_bottom.y}},
    sign = sign, line = start[cross], entry = entry, exit = exit,
    opening_ticks = calibration.opening_ticks, requests = 0, waiting_ticks = 0,
    phase = "approaching", first_request_tick = nil, first_request_distance = nil,
    max_extra_time = 0, expected_delay_ticks = gate.is_opened() and 0 or math.max(0, calibration.opening_ticks
      - math.floor(sign * (entry - actor.position[axis]) / actor.character_running_speed))}
end

function Action.step(actor, state)
  if state.phase == "complete" then return "complete" end
  local semantic = Semantics.classify(state.gate, actor)
  if not semantic.traversable or state.gate.unit_number ~= state.gate_unit then
    Follower.stop(actor)
    state.phase = "invalidated"
    return "replan", semantic.reason or "gate-identity-changed"
  end
  local box = state.gate.bounding_box
  if box.left_top.x ~= state.bounds.left_top.x or box.left_top.y ~= state.bounds.left_top.y
      or box.right_bottom.x ~= state.bounds.right_bottom.x or box.right_bottom.y ~= state.bounds.right_bottom.y then
    Follower.stop(actor)
    return "replan", "gate-geometry-changed"
  end
  if math.abs(actor.position[state.cross] - state.line) > QUANTUM then
    Follower.stop(actor)
    return "replan", "left-calibrated-cardinal-segment"
  end
  local speed = actor.character_running_speed
  if speed <= 0 then Follower.stop(actor); return "replan", "non-positive-speed" end
  local remaining = state.sign * (state.entry - actor.position[state.axis])
  local remaining_exit = state.sign * (state.exit - actor.position[state.axis])
  if remaining_exit < -QUANTUM then state.phase = "complete"; return "complete" end
  -- One movement tick plus a position quantum is the stopping margin. A caller
  -- must invoke this before Follower.advance on every tick; it is not a timer.
  local lead = speed * (state.opening_ticks + 1) + QUANTUM
  if remaining <= lead then
    local extra_time = math.max(1, math.ceil(math.max(0, remaining_exit) / speed) + state.opening_ticks + 1)
    local ok = pcall(function() state.gate.request_to_open(actor.force, extra_time) end)
    if not ok then Follower.stop(actor); return "replan", "gate-open-request-rejected" end
    state.requests = state.requests + 1
    state.max_extra_time = math.max(state.max_extra_time, extra_time)
    if not state.first_request_tick then
      state.first_request_tick, state.first_request_distance = game.tick, remaining
    end
  end
  if not state.gate.is_opened() and remaining <= speed + QUANTUM then
    Follower.stop(actor)
    state.phase = "waiting-for-open"
    state.waiting_ticks = state.waiting_ticks + 1
    if state.first_request_tick and game.tick - state.first_request_tick > state.opening_ticks then
      return "replan", "opening-exceeded-calibrated-bound"
    end
    return "waiting"
  end
  state.phase = remaining < 0 and "crossing" or "approaching"
  return "moving"
end

return Action
