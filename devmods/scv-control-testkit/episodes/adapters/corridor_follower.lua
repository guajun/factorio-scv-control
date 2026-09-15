local Base = require("episodes.adapters.planning_run_follower")
local Corridor = require("__factorio-scv-control__/scripts/navigation/execution/corridor")
local World = require("__factorio-scv-control__/scripts/navigation/world/navigation_world")
local Events = require("__factorio-scv-control__/scripts/navigation/world/events")
local Classification = require("__factorio-scv-control__/scripts/navigation/world/classification")
local Follower = require("__factorio-scv-control__/scripts/follower")
local Trajectory = require("__factorio-scv-control__/scripts/trajectory")

local Adapter = {ID = "corridor-planning-run-follower-v1"}

local function world_for(run)
  return World.new(run.navigation.world_state, {
    actor_collision_mask = run.navigation.actor.prototype.collision_mask
  })
end

function Adapter.issue(run, fixture, context)
  run.metrics.native_execution = true
  local actor = context.actor
  run.navigation.world_state = World.new_state()
  run.navigation.corridor_state = Corridor.new(actor.surface.index, actor.prototype.collision_box,
    Trajectory.clearance_margin(actor.character_running_speed), fixture.corridor_budget)
  run.metrics.dynamic = run.navigation.corridor_state.metrics
  run.metrics.dynamic.immediate_stops = 0
  run.metrics.dynamic.immediate_segment_checks = 0
  run.metrics.dynamic.max_immediate_checks_per_event = 0
  run.metrics.dynamic.immediate_budget_holds = 0
  run.metrics.dynamic.stop_tick = false
  run.metrics.dynamic.stop_latency_ticks = false
  run.metrics.dynamic.max_stop_drift = 0
  run.metrics.dynamic.stop_observed_next_tick = false
  run.metrics.dynamic.safety_hold_ticks = 0
  return Base.issue(run, fixture, context)
end

function Adapter.on_entity_event(run, event_name, event)
  local actor = run.navigation.actor
  if not actor or not actor.valid or run.phase ~= "running" then return end
  local world = world_for(run)
  local report = world:handle_event(event_name, event)
  local normalized = Events.normalize(event_name, event, {
    classify_entity = function(entity)
      return Classification.entity(entity, {actor_collision_mask = actor.prototype.collision_mask})
    end
  })
  for _, mutation in ipairs(normalized.mutations) do
    local revisions
    for _, surface in ipairs(report.surfaces) do
      if surface.surface_index == mutation.surface_index then revisions = surface.revisions end
    end
    if Corridor.enqueue(run.navigation.corridor_state, mutation, game.tick, revisions)
        and Corridor.effect(mutation) == "block" and run.navigation.state == "moving" then
      -- Scan remaining segments within a declared event budget. If work cannot
      -- finish, hold conservatively until the budgeted tick scan completes.
      local follow = run.navigation.follow_state
      local state = run.navigation.corridor_state
      local decision, checks = Corridor.immediate_check(state, actor.position,
        follow.waypoint_index, mutation.bounds, state.limits.segment_tests)
      run.metrics.dynamic.immediate_segment_checks = run.metrics.dynamic.immediate_segment_checks + checks
      run.metrics.dynamic.max_immediate_checks_per_event = math.max(
        run.metrics.dynamic.max_immediate_checks_per_event, checks)
      if decision == "budget-hold" then
        run.metrics.dynamic.immediate_budget_holds = run.metrics.dynamic.immediate_budget_holds + 1
      end
      if decision ~= "clear" and run.navigation.stop_event_tick ~= game.tick then
        Follower.stop(actor)
        run.navigation.stop_event_tick = game.tick
        run.navigation.stop_position = {x = actor.position.x, y = actor.position.y}
        run.metrics.dynamic.immediate_stops = run.metrics.dynamic.immediate_stops + 1
        run.metrics.dynamic.stop_tick = game.tick
        run.metrics.dynamic.stop_latency_ticks = 0
      end
    end
  end
  run.metrics.dynamic.world = world:metrics()
end

local function attach_route(run)
  local navigation = run.navigation
  if navigation.state == "moving" and navigation.corridor_route_count ~= run.metrics.route_count then
    Corridor.attach(navigation.corridor_state, navigation.route, navigation.actor.position, world_for(run))
    navigation.corridor_route_count = run.metrics.route_count
  end
end

function Adapter.update(run, fixture, context)
  attach_route(run)
  local navigation = run.navigation
  if navigation.stop_position and context.tick > navigation.stop_event_tick then
    local position = navigation.actor.position
    local dx, dy = position.x - navigation.stop_position.x, position.y - navigation.stop_position.y
    run.metrics.dynamic.max_stop_drift = math.max(run.metrics.dynamic.max_stop_drift, math.sqrt(dx * dx + dy * dy))
    run.metrics.dynamic.stop_observed_next_tick = context.tick - navigation.stop_event_tick == 1
    navigation.stop_position = nil
  end
  if navigation.state == "moving" and Corridor.has_pending(navigation.corridor_state) then
    local decision = Corridor.advance(navigation.corridor_state, navigation.actor.position,
      navigation.follow_state.waypoint_index, context.tick)
    context.record("corridor-decision", decision)
    if decision.action == "replan" then
      return Base.replan(run, fixture, context, decision.reason)
    elseif decision.action == "hold" then
      Follower.stop(navigation.actor)
      run.metrics.dynamic.safety_hold_ticks = run.metrics.dynamic.safety_hold_ticks + 1
      return
    end
  end
  Base.update(run, fixture, context)
end

function Adapter.handle_path_result(run, fixture, event, context)
  local handled = Base.handle_path_result(run, fixture, event, context)
  attach_route(run)
  return handled
end

Adapter.stop = Base.stop
return Adapter
