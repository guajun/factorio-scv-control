local PathMath = require("scripts.path_math")

local GridSearch = {}

local NEIGHBORS = {
  {x = 0, y = -1},
  {x = 1, y = -1},
  {x = 1, y = 0},
  {x = 1, y = 1},
  {x = 0, y = 1},
  {x = -1, y = 1},
  {x = -1, y = 0},
  {x = -1, y = -1}
}

local function node_key(ix, iy)
  return ix .. "," .. iy
end

local function heap_push(heap, item)
  local index = #heap + 1
  heap[index] = item
  while index > 1 do
    local parent = math.floor(index / 2)
    if heap[parent].priority <= item.priority then break end
    heap[index] = heap[parent]
    index = parent
  end
  heap[index] = item
end

local function heap_pop(heap)
  if #heap == 0 then return nil end
  local root = heap[1]
  local tail = table.remove(heap)
  if #heap == 0 then return root end

  local index = 1
  while true do
    local left = index * 2
    if left > #heap then break end
    local right = left + 1
    local child = right <= #heap and heap[right].priority < heap[left].priority and right or left
    if heap[child].priority >= tail.priority then break end
    heap[index] = heap[child]
    index = child
  end
  heap[index] = tail
  return root
end

local function heuristic(first, second, resolution)
  local dx = (first.ix - second.ix) * resolution
  local dy = (first.iy - second.iy) * resolution
  return math.sqrt(dx * dx + dy * dy)
end

local function reconstruct(nodes, parents, goal_key)
  local reversed = {}
  local current_key = goal_key
  while current_key do
    local node = nodes[current_key]
    reversed[#reversed + 1] = node
    current_key = parents[current_key]
  end

  local path = {}
  for index = #reversed, 1, -1 do path[#path + 1] = reversed[index] end
  return path
end

function GridSearch.search(grid, start_position, goal_position, options)
  options = options or {}
  local weight = options.heuristic_weight or 1
  local any_angle = options.any_angle == true
  local start = grid:nearest_free(start_position)
  local goal = grid:nearest_free(goal_position)
  local metrics = {
    expanded_nodes = 0,
    generated_nodes = 0,
    reopened_nodes = 0,
    sampled_nodes = grid.sampled_nodes,
    line_checks_before = grid.line_checks,
    surface_line_checks_before = grid.surface_line_checks
  }
  if not start or not goal then
    metrics.line_checks = grid.line_checks - metrics.line_checks_before
    metrics.surface_line_checks = grid.surface_line_checks - metrics.surface_line_checks_before
    return nil, metrics
  end

  local start_key = node_key(start.ix, start.iy)
  local goal_key = node_key(goal.ix, goal.iy)
  local nodes = {[start_key] = start, [goal_key] = goal}
  local parents = {}
  local g_score = {[start_key] = 0}
  local closed = {}
  local heap = {}
  heap_push(heap, {
    key = start_key,
    g = 0,
    priority = weight * heuristic(start, goal, grid.resolution)
  })
  metrics.generated_nodes = 1

  while #heap > 0 do
    local item = heap_pop(heap)
    local current_key = item.key
    if not closed[current_key]
        and item.g <= (g_score[current_key] or math.huge) + 0.000001 then
      local current = nodes[current_key]
      closed[current_key] = true
      metrics.expanded_nodes = metrics.expanded_nodes + 1
      if current_key == goal_key then
        local node_path = reconstruct(nodes, parents, goal_key)
        local path = {PathMath.copy_position(start_position)}
        for _, node in ipairs(node_path) do
          PathMath.append_unique_point(path, grid:position(node.ix, node.iy))
        end
        PathMath.append_unique_point(path, goal_position)
        metrics.line_checks = grid.line_checks - metrics.line_checks_before
        metrics.surface_line_checks = grid.surface_line_checks - metrics.surface_line_checks_before
        return path, metrics
      end

      for _, offset in ipairs(NEIGHBORS) do
        local neighbor_ix = current.ix + offset.x
        local neighbor_iy = current.iy + offset.y
        if not grid:is_blocked(neighbor_ix, neighbor_iy)
            and grid:line_is_clear(current.ix, current.iy, neighbor_ix, neighbor_iy) then
          local neighbor_key = node_key(neighbor_ix, neighbor_iy)
          local neighbor = nodes[neighbor_key]
          if not neighbor then
            neighbor = {ix = neighbor_ix, iy = neighbor_iy}
            nodes[neighbor_key] = neighbor
          end

          local predecessor = current
          local predecessor_key = current_key
          local current_parent_key = parents[current_key]
          if any_angle and current_parent_key then
            local current_parent = nodes[current_parent_key]
            if grid:line_is_clear(
              current_parent.ix,
              current_parent.iy,
              neighbor_ix,
              neighbor_iy
            ) then
              predecessor = current_parent
              predecessor_key = current_parent_key
            end
          end

          local tentative = g_score[predecessor_key]
            + heuristic(predecessor, neighbor, grid.resolution)
          if tentative + 0.000001 < (g_score[neighbor_key] or math.huge) then
            if closed[neighbor_key] then
              closed[neighbor_key] = nil
              metrics.reopened_nodes = metrics.reopened_nodes + 1
            end
            parents[neighbor_key] = predecessor_key
            g_score[neighbor_key] = tentative
            heap_push(heap, {
              key = neighbor_key,
              g = tentative,
              priority = tentative + weight * heuristic(neighbor, goal, grid.resolution)
            })
            metrics.generated_nodes = metrics.generated_nodes + 1
          end
        end
      end
    end
  end

  metrics.line_checks = grid.line_checks - metrics.line_checks_before
  metrics.surface_line_checks = grid.surface_line_checks - metrics.surface_line_checks_before
  return nil, metrics
end

return GridSearch
