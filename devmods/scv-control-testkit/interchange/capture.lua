local Boundary = require("__factorio-scv-control__/scripts/navigation/solver_boundary")
local Canonical = require("__factorio-scv-control__/scripts/navigation/canonical")
local WireJson = require("__factorio-scv-control__/scripts/navigation/wire_json")
local NavigationData = require("__factorio-scv-control__/scripts/navigation/navigation_data")
local NavigationGrid = require("__factorio-scv-control__/scripts/navigation_grid")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Fixtures = require("__scv-control-testkit__/pathfinding/fixtures")
local Follower = require("__factorio-scv-control__/scripts/follower")

local Capture = {PROTOCOL = "scv-navigation/1", VERSION = 1}
local MAX_TILES, MAX_NODES, MAX_ENTITIES = 8192, 8192, 2048
local SURFACE = "scv-navigation-capture"
local BLOCKED_SEMANTICS = {
  gate = true, ["transport-belt"] = true, ["underground-belt"] = true,
  splitter = true, unit = true, character = true, car = true,
  locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true,
  ["artillery-wagon"] = true, ["spider-vehicle"] = true
}

function Capture.supports_entity_type(entity_type)
  return not BLOCKED_SEMANTICS[entity_type]
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function failure(code, message)
  return nil, {code = code, message = message}
end

local function position(point)
  return {x = point.x or point[1], y = point.y or point[2]}
end

local function bounds_table(bounds)
  return {
    left_top = position(bounds.left_top or bounds[1]),
    right_bottom = position(bounds.right_bottom or bounds[2])
  }
end

local function covered(point, bounds, box, margin)
  return point.x + box.left_top.x - margin >= bounds.left_top.x
    and point.y + box.left_top.y - margin >= bounds.left_top.y
    and point.x + box.right_bottom.x + margin <= bounds.right_bottom.x
    and point.y + box.right_bottom.y + margin <= bounds.right_bottom.y
end

function Capture.ensure_surface(name)
  name = name or SURFACE
  local surface = game.get_surface(name)
  if not surface then
    surface = game.create_surface(name, {
      autoplace_controls = {}, default_enable_all_autoplace_controls = false
    })
  end
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  surface.daytime, surface.freeze_daytime, surface.always_day = 0, true, true
  surface.peaceful_mode = true
  return surface
end

local function capture_graph(surface, actor, bounds, start, goal, resolution)
  local estimated = (math.floor((bounds.right_bottom.x - bounds.left_top.x) / resolution) + 1)
    * (math.floor((bounds.right_bottom.y - bounds.left_top.y) / resolution) + 1)
  if estimated > MAX_NODES then
    return failure("capture-node-limit", "Use smaller bounds or an explicit coarser grid resolution.")
  end
  local grid = NavigationGrid.capture(surface, actor, {
    {bounds.left_top.x, bounds.left_top.y}, {bounds.right_bottom.x, bounds.right_bottom.y}
  }, resolution)
  local graph = {nodes = {}, edges = {}, representation = {
    id = "factorio-conservative-grid-v1", resolution = resolution,
    clearance_margin = PathSmoothing.clearance_margin(actor),
    cell_inflation = resolution * math.sqrt(2) / 2,
    connectivity = 8, endpoint_policy = "exact-with-local-validated-connectors",
    unknown = "blocked"
  }}
  local cells = {}
  local box, margin = actor.prototype.collision_box, PathSmoothing.clearance_margin(actor)
  local function key(ix, iy) return tostring(ix) .. "," .. tostring(iy) end
  local function edge(from, to)
    graph.edges[#graph.edges + 1] = {
      from = from.id, to = to.id,
      distance = PathMath.distance(from.position, to.position)
    }
  end
  for ix = grid.min_ix, grid.max_ix do
    for iy = grid.min_iy, grid.max_iy do
      local point = grid:position(ix, iy)
      if not grid:is_blocked(ix, iy) and covered(point, bounds, box, margin) then
        local node = {id = "cell:" .. key(ix, iy), position = point}
        cells[key(ix, iy)] = node
        graph.nodes[#graph.nodes + 1] = node
      end
    end
  end
  for ix = grid.min_ix, grid.max_ix do
    for iy = grid.min_iy, grid.max_iy do
      local first = cells[key(ix, iy)]
      if first then
        for _, step in ipairs({{1, 0}, {0, 1}, {1, 1}, {1, -1}}) do
          local nx, ny = ix + step[1], iy + step[2]
          local second = cells[key(nx, ny)]
          local diagonal_clear = step[1] == 0 or step[2] == 0
            or (cells[key(nx, iy)] and cells[key(ix, ny)])
          if second and diagonal_clear then edge(first, second); edge(second, first) end
        end
      end
    end
  end
  local endpoints = {{id = "start", position = copy(start)}, {id = "goal", position = copy(goal)}}
  local regular_node_count = #graph.nodes
  for _, endpoint in ipairs(endpoints) do
    if not covered(endpoint.position, bounds, box, margin) then
      return failure("endpoint-outside-coverage", "Actor envelope at endpoint exceeds captured bounds.")
    end
    if not PathSmoothing.position_is_clear(surface, actor, endpoint.position) then
      return failure("endpoint-blocked", "Exact endpoint does not have trajectory clearance.")
    end
    for index = 1, regular_node_count do
      local node = graph.nodes[index]
      if PathMath.distance(endpoint.position, node.position) <= resolution * 2
          and PathSmoothing.segment_is_clear(surface, actor, endpoint.position, node.position) then
        edge(endpoint, node); edge(node, endpoint)
      end
    end
    graph.nodes[#graph.nodes + 1] = endpoint
  end
  if PathSmoothing.segment_is_clear(surface, actor, start, goal) then
    edge(endpoints[1], endpoints[2]); edge(endpoints[2], endpoints[1])
  end
  return graph
end

function Capture.live(surface, actor, start, goal, input_bounds, options)
  options = options or {}
  if not surface or not surface.valid or not actor or not actor.valid then
    return failure("invalid-capture-world", "Capture needs a live surface and character.")
  end
  local bounds = bounds_table(input_bounds)
  local width = math.ceil(bounds.right_bottom.x) - math.floor(bounds.left_top.x)
  local height = math.ceil(bounds.right_bottom.y) - math.floor(bounds.left_top.y)
  if width <= 0 or height <= 0 or width * height > MAX_TILES then
    return failure("capture-tile-limit", "Capture must be a nonempty bounded area of at most 8192 tiles.")
  end
  local resolution = options.resolution or 0.5
  if resolution < 0.25 or resolution > 4 then
    return failure("invalid-resolution", "Capture grid resolution must be between 0.25 and 4 tiles.")
  end
  for cx = math.floor(bounds.left_top.x / 32), math.floor((bounds.right_bottom.x - 0.0001) / 32) do
    for cy = math.floor(bounds.left_top.y / 32), math.floor((bounds.right_bottom.y - 0.0001) / 32) do
      if not surface.is_chunk_generated({x = cx, y = cy}) then
        return failure("unknown-chunk", "Capture requires already generated world geometry throughout its bounds.")
      end
    end
  end
  local entities = {}
  for _, entity in pairs(surface.find_entities_filtered({area = bounds})) do
    if entity ~= actor and entity.valid then
      if BLOCKED_SEMANTICS[entity.type] then
        return failure("unsupported-world-semantics", "Bounded static capture cannot model " .. entity.type .. ".")
      end
      entities[#entities + 1] = {
        name = entity.name, type = entity.type, position = position(entity.position),
        direction = entity.direction, force = entity.force.name,
        collision_box = copy(entity.prototype.collision_box),
        collision_mask = copy(entity.prototype.collision_mask),
        bounding_box = copy(entity.bounding_box),
        representation = "prototype-and-instance-bounds"
      }
    end
  end
  if #entities > MAX_ENTITIES then return failure("capture-entity-limit", "Too many source entities.") end
  table.sort(entities, function(a, b)
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    if a.position.y ~= b.position.y then return a.position.y < b.position.y end
    if a.name ~= b.name then return a.name < b.name end
    return a.direction < b.direction
  end)
  for index, entity in ipairs(entities) do entity.id = "entity:" .. tostring(index) end
  local tiles = {}
  for x = math.floor(bounds.left_top.x), math.ceil(bounds.right_bottom.x) - 1 do
    for y = math.floor(bounds.left_top.y), math.ceil(bounds.right_bottom.y) - 1 do
      local tile = surface.get_tile(x, y)
      tiles[#tiles + 1] = {
        id = "tile:" .. tostring(x) .. "," .. tostring(y), name = tile.name, position = {x = x, y = y},
        collision_mask = copy(tile.prototype.collision_mask),
        walking_speed_modifier = tile.prototype.walking_speed_modifier
      }
    end
  end
  local session_id = options.session_id or ("capture:" .. tostring(game.tick))
  local snapshot_id = options.snapshot_id or (session_id .. ":snapshot")
  local snapshot = {
    protocol = Capture.PROTOCOL, kind = "world-snapshot", snapshot_id = snapshot_id,
    world_id = options.world_id or session_id, surface_id = tostring(surface.index),
    captured_tick = game.tick, actor = Boundary.actor_descriptor(actor),
    revisions = copy(options.revisions or {topology = 0, motion = 0}),
    coverage = {bounds = bounds, unknown = "blocked"},
    geometry = {entities = entities, tiles = tiles},
    exporter = {id = "factorio-static-capture", version = Capture.VERSION,
      factorio_version = script.active_mods.base,
      mod_version = script.active_mods["factorio-scv-control"],
      semantics = "bounded-static-distance", source_geometry_preserved = true}
  }
  snapshot.fixture = options.fixture and copy(options.fixture) or nil
  if options.include_graph ~= false then
    local graph, graph_error = capture_graph(surface, actor, bounds, start, goal, resolution)
    if not graph then return nil, graph_error end
    snapshot.graph = graph
  end
  local backend, backend_error = NavigationData.new({
    backend_id = snapshot.graph and "factorio-captured-grid-v1" or "factorio-source-geometry-v1",
    backend_version = "1", session_id = options.backend_session_id or session_id,
    config = snapshot.graph and snapshot.graph.representation or {source = "geometry"}
  })
  if not backend then return nil, backend_error end
  local data_ref, data_error = NavigationData.load_world(backend, snapshot)
  if not data_ref then return nil, data_error end
  local query = {
    protocol = Capture.PROTOCOL, kind = "navigation-query",
    query_id = options.query_id or (session_id .. ":query"), session_id = session_id,
    command_id = options.command_id or "1", attempt_id = options.attempt_id or "1",
    snapshot_id = snapshot_id, data_ref = data_ref,
    start = copy(start), goal = copy(goal),
    start_node = snapshot.graph and "start" or nil, goal_node = snapshot.graph and "goal" or nil,
    goal_tolerance = options.goal_tolerance or PathMath.ARRIVAL_DISTANCE,
    execution = {controller_id = "native-follower-v1", arrival_tolerance = Follower.tolerance(actor)},
    objective = {id = "distance", units = "tiles"},
    required_capabilities = snapshot.graph and {"directed-graph-v1", "distance", "finite-bounds"}
      or {"distance", "finite-bounds"},
    budget = {max_expansions = MAX_NODES + 2, max_points = MAX_NODES + 2}
  }
  query.query_hash = assert(Boundary.hash_query(query))
  return snapshot, query
end

function Capture.fixture(fixture_id, options)
  log("SCV_CAPTURE_BEGIN " .. tostring(fixture_id))
  options = copy(options or {})
  local fixture = Fixtures.get(fixture_id)
  if not fixture then return failure("unknown-fixture", tostring(fixture_id)) end
  local surface = Capture.ensure_surface(options.surface_name)
  Fixtures.build(surface, fixture)
  log("SCV_CAPTURE_WORLD " .. fixture_id)
  local actor = surface.create_entity({name = "character", position = fixture.start, force = "player"})
  if not actor then return failure("actor-creation-failed", fixture_id) end
  options.session_id = options.session_id or ("fixture-v4:" .. fixture_id .. ":" .. game.tick)
  options.snapshot_id = options.snapshot_id or (options.session_id .. ":snapshot")
  options.fixture = {version = Fixtures.VERSION, id = fixture.id, category = fixture.category,
    expected_path = fixture.expected_path, original_walls = copy(fixture.walls)}
  local snapshot, query = Capture.live(surface, actor, fixture.start, fixture.goal, fixture.bounds, options)
  log("SCV_CAPTURE_DATA " .. fixture_id)
  if not options.keep_actor or not snapshot then actor.destroy() end
  if not snapshot then return nil, query end
  -- Source metadata was included before the single committed generation was built.
  log("SCV_CAPTURE_COMPLETE " .. fixture_id)
  return snapshot, query, options.keep_actor and actor or nil
end

function Capture.bundle(fixture_ids, options)
  local bundle = {protocol = Capture.PROTOCOL, kind = "capture-bundle", cases = {}, errors = {}}
  local ids = fixture_ids or {}
  if not fixture_ids then
    for _, fixture in ipairs(Fixtures.list()) do ids[#ids + 1] = fixture.id end
  end
  for _, fixture_id in ipairs(ids) do
    local snapshot, query = Capture.fixture(fixture_id, options)
    if snapshot then
      bundle.cases[#bundle.cases + 1] = {id = fixture_id, snapshot = snapshot, query = query}
    else
      bundle.errors[#bundle.errors + 1] = {id = fixture_id, error = query}
    end
  end
  return bundle
end

function Capture.write(bundle, name, player_index, encoded)
  name = name or "fixture-v4-capture"
  if not name:match("^[%w_-]+$") then return failure("invalid-artifact-name", "Use letters, digits, underscore or hyphen.") end
  local path = "scv-control/navigation/" .. name .. ".json"
  local encode_error
  if not encoded then encoded, encode_error = WireJson.encode(bundle) end
  if not encoded then return nil, encode_error end
  helpers.write_file(path, encoded, false, player_index or 0)
  return path
end

Capture.hash = Canonical.hash
return Capture
