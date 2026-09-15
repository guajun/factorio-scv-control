-- Debug-only simulation clock. Factorio 2.0.77 owns exact stepping through
-- ticks_to_run; no Lua on_tick countdown or wall-clock scheduling is involved.
-- Callers must restrict this global-world operation to an isolated test map.
local Clock = {MAX_STEP_TICKS = 3600}

function Clock.status(actor)
  local value = {tick = game.tick, ticks_played = game.ticks_played,
    paused = game.tick_paused, ticks_to_run = game.ticks_to_run,
    mode = game.tick_paused and "debug-stepped" or "realtime"}
  if actor and actor.valid then
    value.actor_position = {x = actor.position.x, y = actor.position.y}
    value.actor_unit_number = actor.unit_number
  end
  return value
end

function Clock.dispatch(message, actor)
  local action = message.action or "status"
  if action == "pause" then
    game.ticks_to_run, game.tick_paused = 0, true
  elseif action == "resume" then
    game.ticks_to_run, game.tick_paused = 0, false
  elseif action == "step" then
    local ticks = message.ticks
    if type(ticks) ~= "number" or ticks % 1 ~= 0 or ticks < 1 or ticks > Clock.MAX_STEP_TICKS then
      return {ok = false, reason = "invalid-step-ticks"}
    end
    if not game.tick_paused then return {ok = false, reason = "step-requires-paused-clock"} end
    if game.ticks_to_run ~= 0 then return {ok = false, reason = "step-already-running"} end
    game.ticks_to_run = ticks
  elseif action ~= "status" then
    return {ok = false, reason = "unknown-clock-action"}
  end
  return {ok = true, clock = Clock.status(actor)}
end

return Clock
