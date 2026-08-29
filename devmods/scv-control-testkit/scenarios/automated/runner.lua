local Follower = require("__factorio-scv-control__/scripts/follower")
local Input = require("__factorio-scv-control__/scripts/input")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Queue = require("__factorio-scv-control__/scripts/queue")

local START = {x = -28.80078125, y = -3.85546875}
local GOAL = {x = -28.8828125, y = -7.3125}
local OPEN_START = {x = -37.44921875, y = -19.66015625}
local OPEN_GOAL = {x = -27.09765625, y = -30.76171875}
local TEST_TIMEOUT_TICKS = 1200

remote.add_interface("scv_test_runner", {
  active = function() return true end
})

local function record(name, passed, details)
  local suite = storage.scv_testkit
  suite.results[#suite.results + 1] = {
    name = name,
    passed = passed,
    details = details,
    completed_tick = game.tick,
    elapsed_ticks = game.tick - suite.started_tick
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
    expected_no_path = expected_no_path == true,
    character = character
  }
end

local function finish_if_complete()
  local suite = storage.scv_testkit
  if suite.finished
      or not suite.follower_done
      or not suite.straight_done
      or not suite.corridor_done
      or not suite.unreachable_done
      or not suite.queue_done
      or not suite.open_done then
    return
  end

  suite.finished = true
  local report = {
    schema_version = 1,
    factorio_version = script.active_mods.base,
    mod_version = script.active_mods["factorio-scv-control"],
    tick = game.tick,
    duration_ticks = game.tick - suite.started_tick,
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
    queue_done = false,
    open_done = false,
    corridor = {segments = {}},
    movement_queue = {queue = {}, active = nil, completed = {}}
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
  storage.scv_testkit.straight_character = surface.create_entity({
    name = "character",
    position = {x = 0, y = 0},
    force = "player"
  })
  storage.scv_testkit.open_character = surface.create_entity({
    name = "character",
    position = OPEN_START,
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

  local queue_character = surface.create_entity({
    name = "character",
    position = {x = 0, y = 15},
    force = "player"
  })
  storage.scv_testkit.queue_character = queue_character
  Queue.push(storage.scv_testkit.movement_queue, {id = 1, position = {x = 4, y = 15}})
  Queue.push(storage.scv_testkit.movement_queue, {id = 2, position = {x = 8, y = 15}})
  Queue.push(storage.scv_testkit.movement_queue, {id = 3, position = {x = 12, y = 15}})
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
    if request.name == "planner.open_path_smoothing" then suite.open_done = true end
    finish_if_complete()
    return
  end

  if request.expected_no_path then
    record(request.name, false, {status = "unexpected-path"})
    suite.unreachable_done = true
    finish_if_complete()
    return
  end

  local engine_path = PathMath.path_from_event(event)
  local path = PathSmoothing.simplify(
    game.surfaces[1],
    request.character,
    engine_path,
    request.goal_position
  )
  local path_distance = PathMath.polyline_distance(request.start_position, path)
  if request.name == "straight" then
    local direct = PathMath.distance(request.start_position, request.goal_position)
    expect("planner.straight_is_near_direct", path_distance / direct <= 1.15, {
      path_distance = path_distance,
      direct_distance = direct,
      engine_waypoints = #engine_path,
      smoothed_waypoints = #path
    })
    expect("planner.straight_removes_grid_corners", #path <= 2, {
      engine_waypoints = #engine_path,
      smoothed_waypoints = #path
    })
    suite.straight_done = true
  elseif request.name == "planner.open_path_smoothing" then
    local direct = PathMath.distance(request.start_position, request.goal_position)
    local engine_distance = PathMath.polyline_distance(request.start_position, engine_path)
    expect("planner.open_path_smoothing", path_distance / direct <= 1.02 and #path <= 2, {
      direct_distance = direct,
      engine_path_distance = engine_distance,
      smoothed_path_distance = path_distance,
      engine_waypoints = #engine_path,
      smoothed_waypoints = #path
    })
    local turn_metrics = PathMath.turn_metrics(path)
    expect("planner.open_path_has_no_reversal", turn_metrics.reversal_count == 0, turn_metrics)
    suite.open_done = true
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
      record("planner.corridor_finds_alternate_via", false, {
        baseline_path = path,
        baseline_distance = path_distance,
        engine_path = engine_path,
        engine_path_distance = PathMath.polyline_distance(START, engine_path)
      })
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
    local selected_path = candidate_distance < baseline_distance
      and candidate
      or suite.corridor.baseline_path
    suite.corridor.follow_state = {
      path = selected_path,
      waypoint_index = 1,
      segment_start = PathMath.copy_position(START)
    }
    suite.corridor.movement_started_tick = game.tick
  end
  finish_if_complete()
end)

script.on_event(defines.events.on_tick, function(event)
  local suite = storage.scv_testkit
  if suite.finished then return end

  if not suite.requests_started and event.tick >= suite.started_tick + 60 then
    suite.requests_started = true
    request_path("straight", {x = 0, y = 0}, {x = 20, y = 0}, suite.straight_character)
    request_path("corridor-baseline", START, GOAL, suite.path_character)
    request_path("planner.unreachable_reports_no_path", {x = 24, y = 25}, {x = 33, y = 25}, nil, true)
    request_path("planner.open_path_smoothing", OPEN_START, OPEN_GOAL, suite.open_character)
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

  if suite.corridor.follow_state and not suite.corridor_done then
    local character = suite.path_character
    local status = Follower.advance(character, suite.corridor.follow_state, GOAL)
    if status == "arrived" then
      local error_distance = PathMath.distance(character.position, GOAL)
      expect("planner.corridor_character_reaches_goal",
        error_distance <= Follower.tolerance(character), {
          position = PathMath.copy_position(character.position),
          error_distance = error_distance,
          movement_ticks = game.tick - suite.corridor.movement_started_tick
        })
      suite.corridor_done = true
    elseif status == "replan" then
      record("planner.corridor_character_reaches_goal", false, {
        status = "unexpected-replan",
        position = PathMath.copy_position(character.position)
      })
      suite.corridor_done = true
    end
  end

  if not suite.queue_done then
    local queue_state = suite.movement_queue
    local character = suite.queue_character
    if not queue_state.active then
      queue_state.active = Queue.pop(queue_state)
      if queue_state.active then
        queue_state.follow_state = {
          path = {
            PathMath.copy_position(character.position),
            PathMath.copy_position(queue_state.active.position)
          },
          waypoint_index = 1,
          segment_start = PathMath.copy_position(character.position)
        }
      else
        local completed = queue_state.completed
        expect("queue.executes_all_commands",
          #completed == 3
            and completed[1] == 1
            and completed[2] == 2
            and completed[3] == 3,
          {
            completed = completed,
            position = PathMath.copy_position(character.position)
          })
        suite.queue_done = true
      end
    end

    if queue_state.active then
      local status = Follower.advance(character, queue_state.follow_state, queue_state.active.position)
      if status == "arrived" then
        queue_state.completed[#queue_state.completed + 1] = queue_state.active.id
        queue_state.active = nil
        queue_state.follow_state = nil
      elseif status == "replan" then
        record("queue.executes_all_commands", false, {
          status = "unexpected-replan",
          command_id = queue_state.active.id
        })
        suite.queue_done = true
      end
    end
  end

  finish_if_complete()
  if suite.finished then return end

  if event.tick > suite.started_tick + TEST_TIMEOUT_TICKS then
    if not suite.follower_done then record("follower.reaches_goal", false, {status = "timeout"}) end
    if not suite.straight_done then record("planner.straight_is_near_direct", false, {status = "timeout"}) end
    if not suite.corridor_done then
      local name = suite.corridor.follow_state
        and "planner.corridor_character_reaches_goal"
        or "planner.corridor_selects_shorter_side"
      record(name, false, {status = "timeout"})
    end
    if not suite.unreachable_done then record("planner.unreachable_reports_no_path", false, {status = "timeout"}) end
    if not suite.queue_done then record("queue.executes_all_commands", false, {status = "timeout"}) end
    if not suite.open_done then record("planner.open_path_smoothing", false, {status = "timeout"}) end
    suite.follower_done = true
    suite.straight_done = true
    suite.corridor_done = true
    suite.unreachable_done = true
    suite.queue_done = true
    suite.open_done = true
    finish_if_complete()
  end
end)
