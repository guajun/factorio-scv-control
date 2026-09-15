local Geometry = require("scripts.navigation.world.geometry")

-- Serializable, actor-agnostic invalidation policy. No planner, event subscription,
-- or Factorio entity is retained here. Callers stop movement while work is pending.
local Corridor = {}

local function point(value) return {x = value.x, y = value.y} end

local function expanded(bounds, envelope)
  bounds = Geometry.bounds(bounds)
  return {
    left_top = {x = bounds.left_top.x - envelope.right_bottom.x,
      y = bounds.left_top.y - envelope.right_bottom.y},
    right_bottom = {x = bounds.right_bottom.x - envelope.left_top.x,
      y = bounds.right_bottom.y - envelope.left_top.y}
  }
end

-- Segment versus Minkowski-expanded obstacle, rather than segment AABB overlap.
function Corridor.intersects(from, to, bounds, envelope)
  local box = expanded(bounds, envelope)
  local near, far = 0, 1
  for _, axis in ipairs({"x", "y"}) do
    local delta = to[axis] - from[axis]
    if delta == 0 then
      if from[axis] < box.left_top[axis] or from[axis] > box.right_bottom[axis] then
        return false
      end
    else
      local a = (box.left_top[axis] - from[axis]) / delta
      local b = (box.right_bottom[axis] - from[axis]) / delta
      near, far = math.max(near, math.min(a, b)), math.min(far, math.max(a, b))
      if near > far then return false end
    end
  end
  return true
end

function Corridor.new(surface_index, actor_box, margin, options)
  options = options or {}
  local box = Geometry.bounds(actor_box)
  return {
    schema_version = 1, surface_index = surface_index,
    envelope = {
      left_top = {x = box.left_top.x - margin, y = box.left_top.y - margin},
      right_bottom = {x = box.right_bottom.x + margin, y = box.right_bottom.y + margin}
    },
    limits = {groups = options.groups or 8, segment_tests = options.segment_tests or 64,
      pending_groups = options.pending_groups or 64, region_size = options.region_size or 16,
      bounds_per_group = options.bounds_per_group or 64},
    pending = {}, keys = {}, points = {}, generation = 0,
    metrics = {events = 0, coalesced = 0, groups = 0, segment_tests = 0,
      max_groups_per_update = 0, max_segment_tests_per_update = 0,
      invalidations = 0, off_corridor = 0, preserved_removals = 0,
      motion_refreshes = 0, transient_notifications = 0, overflows = 0}
  }
end

function Corridor.attach(state, route, start, world)
  state.points = {}
  for _, position in ipairs(route.points) do state.points[#state.points + 1] = point(position) end
  state.generation = state.generation + 1
  state.scan_index, state.scan_box_index = nil, nil
  route.corridor = {}
  local seen, previous = {}, start
  for _, dependency in ipairs(route.dependencies) do
    seen[dependency.kind .. ":" .. tostring(dependency.region_key or dependency.unit_number)] = true
  end
  for index, position in ipairs(state.points) do
    local bounds = {
      left_top = {x = math.min(previous.x, position.x) + state.envelope.left_top.x,
        y = math.min(previous.y, position.y) + state.envelope.left_top.y},
      right_bottom = {x = math.max(previous.x, position.x) + state.envelope.right_bottom.x,
        y = math.max(previous.y, position.y) + state.envelope.right_bottom.y}
    }
    route.corridor[#route.corridor + 1] = {
      kind = "inflated-polyline-segment", to_point_index = index,
      from = point(previous), to = point(position), bounds = bounds
    }
    if world then
      for _, dependency in ipairs(world:region_dependencies(state.surface_index, bounds)) do
        local key = dependency.kind .. ":" .. dependency.region_key
        if not seen[key] then
          dependency.schema_version = 1
          route.dependencies[#route.dependencies + 1] = dependency
          seen[key] = true
        end
      end
    end
    previous = position
  end
  if world then
    route.world_revisions = world:revision_snapshot(state.surface_index,
      Geometry.point_bounds(start)).surface
  end
end

function Corridor.effect(mutation)
  local categories = mutation.categories or {}
  -- Only an explicitly identified entity removal guarantees relaxed topology.
  -- Tile replacement, teleport and unknown edits are conservatively revalidated.
  if categories.topology then return mutation.remove_entity_key and "remove" or "block" end
  if categories.motion then return "motion" end
  if categories.transient then return "transient" end
  return "irrelevant"
end

function Corridor.enqueue(state, mutation, tick, revisions)
  if mutation.surface_index ~= state.surface_index then return false end
  local effect = Corridor.effect(mutation)
  if effect == "irrelevant" then return false end
  state.metrics.events = state.metrics.events + 1
  local bounds = Geometry.bounds(mutation.bounds)
  local rx, ry = Geometry.region_coordinates(bounds.left_top, state.limits.region_size)
  local key = effect .. ":" .. rx .. "," .. ry
  local box_key = bounds.left_top.x .. ":" .. bounds.left_top.y .. ":"
    .. bounds.right_bottom.x .. ":" .. bounds.right_bottom.y
  local group = state.keys[key]
  if group then
    group.bounds = Geometry.union(group.bounds, bounds)
    group.events = group.events + 1
    group.revisions = revisions
    state.metrics.coalesced = state.metrics.coalesced + 1
    if not group.box_keys[box_key] then
      if #group.boxes >= state.limits.bounds_per_group then
        state.overflow = true
        state.metrics.overflows = state.metrics.overflows + 1
      else
        group.boxes[#group.boxes + 1] = bounds
        group.box_keys[box_key] = true
        -- Only new geometry in the actively scanned group invalidates its
        -- cursor. Duplicate or non-head events must not starve bounded scans.
        if group == state.pending[1] then state.scan_index, state.scan_box_index = nil, nil end
      end
    end
  elseif #state.pending >= state.limits.pending_groups then
    state.overflow = true
    state.metrics.overflows = state.metrics.overflows + 1
  else
    group = {key = key, effect = effect, bounds = bounds, tick = tick,
      revisions = revisions, source = mutation.source, events = 1,
      boxes = {bounds}, box_keys = {[box_key] = true}}
    state.pending[#state.pending + 1] = group
    state.keys[key] = group
  end
  return true
end

function Corridor.has_pending(state) return state.overflow or #state.pending > 0 end

function Corridor.has_blocking_pending(state)
  if state.overflow then return true end
  for _, group in ipairs(state.pending) do
    if group.effect == "block" then return true end
  end
  return false
end

function Corridor.immediate_check(state, position, waypoint_index, bounds, budget)
  local checks = 0
  for index = waypoint_index or 1, #state.points do
    if checks >= budget then return "budget-hold", checks end
    local from = index == (waypoint_index or 1) and position or state.points[index - 1]
    checks = checks + 1
    if Corridor.intersects(from, state.points[index], bounds, state.envelope) then
      return "blocked", checks
    end
  end
  return "clear", checks
end

local function clear(state)
  state.pending, state.keys, state.scan_index, state.scan_box_index, state.overflow = {}, {}, nil, nil, nil
end

function Corridor.advance(state, position, waypoint_index, tick)
  local output = {action = "continue", notifications = {}, groups = 0, segment_tests = 0}
  if state.overflow then
    clear(state)
    state.metrics.invalidations = state.metrics.invalidations + 1
    output.action, output.reason = "replan", "dirty-budget-overflow"
    return output
  end
  while #state.pending > 0 and output.groups < state.limits.groups do
    local group = state.pending[1]
    local hit = false
    local index = math.max(waypoint_index or 1, state.scan_index or 1)
    local box_index = state.scan_box_index or 1
    while index <= #state.points and output.segment_tests < state.limits.segment_tests do
      local from = index == (waypoint_index or 1) and position or state.points[index - 1]
      -- Keep exact member boxes: a union of two off-route edits may cover the
      -- route even though neither obstacle intersects it.
      hit = Corridor.intersects(from, state.points[index], group.boxes[box_index], state.envelope)
      output.segment_tests = output.segment_tests + 1
      if hit then break end
      box_index = box_index + 1
      if box_index > #group.boxes then index, box_index = index + 1, 1 end
    end
    if not hit and index <= #state.points then
      state.scan_index, state.scan_box_index = index, box_index
      break
    end
    output.groups = output.groups + 1
    table.remove(state.pending, 1)
    state.keys[group.key], state.scan_index, state.scan_box_index = nil, nil, nil
    if hit then
      if group.effect == "block" then
        output.action, output.reason, output.dirty = "replan", "remaining-corridor-topology", group
        output.latency_ticks = tick - group.tick
        state.metrics.invalidations = state.metrics.invalidations + 1
        -- A new shared PlanningRun validates the current live world, including
        -- the rest of this same burst. Changes during that run remain queued.
        clear(state)
        break
      elseif group.effect == "remove" then
        state.metrics.preserved_removals = state.metrics.preserved_removals + 1
      elseif group.effect == "motion" then
        state.metrics.motion_refreshes = state.metrics.motion_refreshes + 1
      elseif group.effect == "transient" then
        state.metrics.transient_notifications = state.metrics.transient_notifications + 1
      end
      output.notifications[#output.notifications + 1] = {kind = group.effect, dirty = group}
    else
      state.metrics.off_corridor = state.metrics.off_corridor + 1
    end
  end
  state.metrics.groups = state.metrics.groups + output.groups
  state.metrics.segment_tests = state.metrics.segment_tests + output.segment_tests
  state.metrics.max_groups_per_update = math.max(state.metrics.max_groups_per_update, output.groups)
  state.metrics.max_segment_tests_per_update = math.max(
    state.metrics.max_segment_tests_per_update, output.segment_tests)
  if output.action ~= "replan" and Corridor.has_blocking_pending(state) then output.action = "hold" end
  return output
end

return Corridor
