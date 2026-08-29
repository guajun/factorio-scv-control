local Follower = require("__factorio-scv-control__/scripts/follower")
local Input = require("__factorio-scv-control__/scripts/input")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local Queue = require("__factorio-scv-control__/scripts/queue")

local START = {x = -28.80078125, y = -3.85546875}
local GOAL = {x = -28.8828125, y = -7.3125}
local TEST_TIMEOUT_TICKS = 1200

remote.add_interface("scv_test_runner", {
  active = function() return true end
})

local function record(name, passed, details)
  local suite = storage.scv_testkit
  suite.results[#suite.results + 1] = {
    name = name,
    passed = passed,
    details = details
  }
  if passed then
    suite.passed = suite.passed + 1
  else
    suite.failed = suite.failed + 1
  end
end

local function expect(name, condition, details)
  record(name, condition == true, details)
end

local function create_wall(surface, x, y)
  local wall = surface.create_entity({
    name = "stone-wall",
    position = {x = x, y = y},
    force = "neutral"
  })
  wall.destructible = false
  wall.minable = false
end

local function request_path(name, start_position, goal_position, character, expected_no_path)
  local surface = game.surfaces[1]
  local prototype = prototypes.entity.character
  local id = surface.request_path({
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = start_position,
    goal = goal_position,
    force = "player",
    radius = PathMath.ARRIVAL_DISTANCE,
    pathfind_flags = {prefer_straight_paths = false, cache = false},
    can_open_gates = true,
    entity_to_ignore = character
  })
  storage.scv_testkit.requests[id] = {
    name = name,
    start_position = PathMath.copy_position(start_position),
    goal_position = PathMath.copy_position(goal_position),
    expected_no_path = expected_no_path == true
  }
end

local function finish_if_complete()
  local suite = storage.scv_testkit
  if suite.finished
      or not suite.follower_done
      or not suite.straight_done
      or not suite.corridor_done
      or not suite.unreachable_done then
    return
  end

  suite.finished = true
  local report = {
    schema_version = 1,
    factorio_version = script.active_mods.base,
    mod_version = script.active_mods["factorio-scv-control"],
    tick = game.tick,
    passed = suite.passed,
    failed = suite.failed,
    results = suite.results
  }
  local json = helpers.table_to_json(report)
  helpers.write_file("scv-control/test-results.json", json, false, 0)
  log("SCV_TESTKIT_REPORT " .. json)
  log("SCV_TESTKIT_COMPLETE passed=" .. suite.passed .. " failed=" .. suite.failed)
end

local function run_unit_tests()
  expect("path_math.distance", PathMath.distance({x = 0, y = 0}, {x = 3, y = 4}) == 5)

  local combined = PathMath.combine_paths(
    {{x = 0, y = 0}, {x = 1, y = 0}},
    {{x = 1, y = 0}, {x = 2, y = 0}}
  )
  expect("path_math.combine_deduplicates", #combined == 3, {count = #combined})

  local queue_state = {queue = {}, active = nil}
  Queue.push(queue_state, {id = 1})
  Queue.push(queue_state, {id = 2})
  local first = Queue.pop(queue_state)
  local second = Queue.pop(queue_state)
  expect("queue.fifo", first.id == 1 and second.id == 2 and Queue.depth(queue_state) == 0)

  local input_state = {next_command_id = 7}
  local command = Input.command_from_cursor(input_state, {x = 12.25, y = -3.5}, 4)
  expect("input.cursor_contract", command.id == 7
    and command.position.x == 12.25
    and command.position.y == -3.5
    and command.surface_index == 4
    and input_state.next_command_id == 8,
    {command = command, next_command_id = input_state.next_command_id})
end

script.on_init(function()
  storage.scv_testkit = {
    started_tick = game.tick,
    requests = {},
    results = {},
    passed = 0,
    failed = 0,
    requests_started = false,
    follower_done = false,
    straight_done = false,
    corridor_done = false,
    unreachable_done = false,
    corridor = {segments = {}}
  }

  local surface = game.surfaces[1]
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities({{-52, -34}, {52, 36}})) do
    entity.destroy()
  end

  local tiles = {}
  for x = -52, 51 do
    for y = -34, 35 do
      tiles[#tiles + 1] = {name = "refined-concrete", position = {x, y}}
    end
  end
  surface.set_tiles(tiles, true, false, false, false)
  for x = -42, -8 do
    create_wall(surface, x, -12)
    create_wall(surface, x, -6)
  end
  for x = 28, 38 do
    create_wall(surface, x, 20)
    create_wall(surface, x, 30)
  end
  for y = 21, 29 do
    create_wall(surface, 28, y)
    create_wall(surface, 38, y)
  end

  storage.scv_testkit.path_character = surface.create_entity({
    name = "character",
    position = START,
    force = "player"
  })
  local follower_character = surface.create_entity({
    name = "character",
    position = {x = 0, y = 10},
    force = "player"
  })
  storage.scv_testkit.follower_character = follower_character
  storage.scv_testkit.follower_state = {
    path = {{x = 0, y = 10}, {x = 12, y = 10}},
    waypoint_index = 1,
    segment_start = {x = 0, y = 10}
  }
  storage.scv_testkit.follower_goal = {x = 12, y = 10}
  run_unit_tests()
end)

script.on_event(defines.events.on_script_path_request_finished, function(event)
  local suite = storage.scv_testkit
  local request = suite.requests[event.id]
  suite.requests[event.id] = nil
  if not request then return end

  if event.try_again_later or not event.path then
    local expected_failure = request.expected_no_path and not event.try_again_later
    record(request.name, expected_failure, {
      status = event.try_again_later and "busy" or "no-path"
    })
    if request.name == "straight" then suite.straight_done = true end
    if request.name:find("corridor", 1, true) then suite.corridor_done = true end
    if request.name == "planner.unreachable_reports_no_path" then suite.unreachable_done = true end
    finish_if_complete()
    return
  end

  if request.expected_no_path then
    record(request.name, false, {status = "unexpected-path"})
    suite.unreachable_done = true
    finish_if_complete()
    return
  end

  local path = PathMath.path_from_event(event, request.goal_position)
  local path_distance = PathMath.polyline_distance(request.start_position, path)
  if request.name == "straight" then
    local direct = PathMath.distance(request.start_position, request.goal_position)
    expect("planner.straight_is_near_direct", path_distance / direct <= 1.15, {
      path_distance = path_distance,
      direct_distance = direct
    })
    suite.straight_done = true
  elseif request.name == "corridor-baseline" then
    suite.corridor.baseline_path = path
    suite.corridor.baseline_distance = path_distance
    local via = PathMath.alternate_via(
      game.surfaces[1],
      suite.path_character.name,
      START,
      GOAL,
      path
    )
    suite.corridor.via = via
    if not via then
      record("planner.corridor_finds_alternate_via", false)
      suite.corridor_done = true
    else
      request_path("corridor-via-first", START, via, suite.path_character)
      request_path("corridor-via-second", via, GOAL, suite.path_character)
    end
  elseif request.name == "corridor-via-first" then
    suite.corridor.segments[1] = path
  elseif request.name == "corridor-via-second" then
    suite.corridor.segments[2] = path
  end

  if suite.corridor.segments[1] and suite.corridor.segments[2] and not suite.corridor_done then
    local candidate = PathMath.combine_paths(suite.corridor.segments[1], suite.corridor.segments[2])
    local candidate_distance = PathMath.polyline_distance(START, candidate)
    local baseline_distance = suite.corridor.baseline_distance
    expect("planner.corridor_selects_shorter_side", candidate_distance < baseline_distance * 0.85, {
      baseline_distance = baseline_distance,
      candidate_distance = candidate_distance,
      via = suite.corridor.via
    })
    expect("planner.corridor_candidate_bound", candidate_distance < 38, {
      candidate_distance = candidate_distance
    })
    suite.corridor_done = true
  end
  finish_if_complete()
end)

script.on_event(defines.events.on_tick, function(event)
  local suite = storage.scv_testkit
  if suite.finished then return end

  if not suite.requests_started and event.tick >= suite.started_tick + 60 then
    suite.requests_started = true
    request_path("straight", {x = 0, y = 0}, {x = 20, y = 0}, nil)
    request_path("corridor-baseline", START, GOAL, suite.path_character)
    request_path("planner.unreachable_reports_no_path", {x = 24, y = 25}, {x = 33, y = 25}, nil, true)
  end

  if not suite.follower_done then
    local character = suite.follower_character
    local status = Follower.advance(character, suite.follower_state, suite.follower_goal)
    if status == "arrived" then
      local error_distance = PathMath.distance(character.position, suite.follower_goal)
      expect("follower.reaches_goal", error_distance <= Follower.tolerance(character), {
        position = PathMath.copy_position(character.position),
        error_distance = error_distance
      })
      suite.follower_done = true
    elseif status == "replan" then
      record("follower.reaches_goal", false, {status = "unexpected-replan"})
      suite.follower_done = true
    end
  end

  if event.tick > suite.started_tick + TEST_TIMEOUT_TICKS then
    if not suite.follower_done then record("follower.reaches_goal", false, {status = "timeout"}) end
    if not suite.straight_done then record("planner.straight_is_near_direct", false, {status = "timeout"}) end
    if not suite.corridor_done then record("planner.corridor_selects_shorter_side", false, {status = "timeout"}) end
    if not suite.unreachable_done then record("planner.unreachable_reports_no_path", false, {status = "timeout"}) end
    suite.follower_done = true
    suite.straight_done = true
    suite.corridor_done = true
    suite.unreachable_done = true
    finish_if_complete()
  end
end)
