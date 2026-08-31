local Follower = require("__factorio-scv-control__/scripts/follower")
local Input = require("__factorio-scv-control__/scripts/input")
local LocalPlanner = require("__factorio-scv-control__/scripts/local_planner")
local NavigationContractTests = require("navigation_contract_tests")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Queue = require("__factorio-scv-control__/scripts/queue")
local Trajectory = require("__factorio-scv-control__/scripts/trajectory")
local WorldTests = require("world_tests")

local START = {x = -28.55078125, y = -0.12109375}
local GOAL = {x = -30.12109375, y = -9.07421875}
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
      or not suite.open_done
      or not suite.trajectory_done
      or not suite.calibration_done
      or not suite.world_movement_done then
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

local function run_unit_tests(surface)
  NavigationContractTests.run(expect)

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

  for _, result in ipairs(WorldTests.run(surface)) do
    expect(result.name, result.passed, result.details)
  end
  storage.scv_testkit.world_movement_test = WorldTests.start_movement(surface)
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
    trajectory_done = false,
    calibration_done = false,
    world_movement_done = false,
    corridor = {},
    movement_queue = {queue = {}, active = nil, completed = {}},
    trajectory_test = {
      cases = {
        {name = "east-half-step", goal = {x = 12, y = 22.386}},
        {name = "west-half-step", goal = {x = 0, y = 24.772}},
        {name = "southeast-half-step", goal = {x = 10, y = 31.454}}
      },
      index = 1,
      total_ticks = 0,
      total_switches = 0,
      large_switches = 0,
      min_run_ticks = nil,
      max_cross_track_error = 0,
      distance_increases = 0,
      recoveries = 0,
      completed = {},
      history = {}
    },
    motion_calibration = {actors = {}, movement_ticks = 12}
  }

  local surface = game.surfaces[1]
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities({{-52, -34}, {52, 52}})) do
    entity.destroy()
  end

  local tiles = {}
  for x = -52, 51 do
    for y = -34, 51 do
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

  storage.scv_testkit.trajectory_character = surface.create_entity({
    name = "character",
    position = {x = 0, y = 20},
    force = "player"
  })
  for direction = 0, 15 do
    local start = {x = -45 + direction * 6, y = 45}
    local character = surface.create_entity({
      name = "character",
      position = start,
      force = "player"
    })
    storage.scv_testkit.motion_calibration.actors[#storage.scv_testkit.motion_calibration.actors + 1] = {
      direction = direction,
      character = character,
      start = start
    }
  end
  run_unit_tests(surface)
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
    local comparison = LocalPlanner.compare(
      game.surfaces[1],
      suite.path_character,
      START,
      GOAL,
      path
    )
    expect("planner.corridor_local_path_is_safe",
      comparison.grid_safe and comparison.source == "grid-a-star", {
        source = comparison.source,
        grid_safe = comparison.grid_safe,
        grid_path = comparison.grid_path
      })
    expect("planner.corridor_selects_shorter_side",
      comparison.distance < path_distance * 0.7, {
      baseline_path = path,
      baseline_distance = path_distance,
      selected_distance = comparison.distance,
      selected_path = comparison.path,
      expanded_nodes = comparison.expanded_nodes
    })
    suite.corridor.follow_state = {
      path = comparison.path,
      waypoint_index = 1,
      segment_start = PathMath.copy_position(START)
    }
    suite.corridor.movement_started_tick = game.tick
  end
  finish_if_complete()
end)

local function start_trajectory_case(suite)
  local trajectory_test = suite.trajectory_test
  local case = trajectory_test.cases[trajectory_test.index]
  if not case then return false end
  local position = PathMath.copy_position(suite.trajectory_character.position)
  trajectory_test.follow_state = {
    path = {position, PathMath.copy_position(case.goal)},
    waypoint_index = 1,
    segment_start = position
  }
  trajectory_test.last_distance = nil
  trajectory_test.last_primitive = nil
  trajectory_test.last_recovery_attempt = 0
  trajectory_test.case_started_tick = game.tick
  return true
end

local function update_trajectory_test(suite)
  if suite.trajectory_done then return end
  local trajectory_test = suite.trajectory_test
  local case = trajectory_test.cases[trajectory_test.index]
  if not case then
    local switch_rate = trajectory_test.total_ticks > 0
      and trajectory_test.total_switches / trajectory_test.total_ticks
      or 0
    expect("trajectory.vector_decomposition_multi_angle",
      #trajectory_test.completed == #trajectory_test.cases
        and (trajectory_test.min_run_ticks or 0) >= 2
        and trajectory_test.max_cross_track_error <= 0.45
        and trajectory_test.large_switches == 0
        and trajectory_test.distance_increases <= 3
        and switch_rate <= 0.35,
      {
        completed = trajectory_test.completed,
        total_ticks = trajectory_test.total_ticks,
        total_switches = trajectory_test.total_switches,
        switch_rate = switch_rate,
        min_run_ticks = trajectory_test.min_run_ticks,
        max_cross_track_error = trajectory_test.max_cross_track_error,
        large_switches = trajectory_test.large_switches,
        distance_increases = trajectory_test.distance_increases,
        recoveries = trajectory_test.recoveries
      })
    suite.trajectory_done = true
    return
  end

  if not trajectory_test.follow_state then start_trajectory_case(suite) end
  local character = suite.trajectory_character
  local distance_before = PathMath.distance(character.position, case.goal)
  if trajectory_test.last_distance and distance_before > trajectory_test.last_distance + 0.02 then
    trajectory_test.distance_increases = trajectory_test.distance_increases + 1
  end
  trajectory_test.last_distance = distance_before

  local status, diagnostics = Follower.advance(character, trajectory_test.follow_state, case.goal)
  if status == "moving" then
    trajectory_test.total_ticks = trajectory_test.total_ticks + 1
    trajectory_test.max_cross_track_error = math.max(
      trajectory_test.max_cross_track_error,
      math.abs(diagnostics.cross_track_error or 0)
    )
    if diagnostics.switched then
      trajectory_test.total_switches = trajectory_test.total_switches + 1
      local previous = trajectory_test.last_primitive
      if previous ~= nil then
        local delta = math.abs(diagnostics.selected_primitive - previous)
        delta = math.min(delta, 8 - delta)
        if delta > 1 then trajectory_test.large_switches = trajectory_test.large_switches + 1 end
      end
    end
    trajectory_test.last_primitive = diagnostics.selected_primitive
    trajectory_test.history[#trajectory_test.history + 1] = {
      tick = game.tick,
      case = case.name,
      position = PathMath.copy_position(character.position),
      direction = diagnostics.selected_direction,
      primitive = diagnostics.selected_primitive,
      switched = diagnostics.switched,
      cross_track_error = diagnostics.cross_track_error,
      band = diagnostics.cross_track_band
    }
    if #trajectory_test.history > 40 then table.remove(trajectory_test.history, 1) end
    local run_ticks = diagnostics.min_run_ticks
    if run_ticks then
      trajectory_test.min_run_ticks = trajectory_test.min_run_ticks
        and math.min(trajectory_test.min_run_ticks, run_ticks)
        or run_ticks
    end
    local recovery_attempt = diagnostics.recovery_attempt or 0
    if recovery_attempt > trajectory_test.last_recovery_attempt then
      trajectory_test.recoveries = trajectory_test.recoveries + 1
      trajectory_test.last_recovery_attempt = recovery_attempt
    end
  elseif status == "arrived" then
    local error_distance = PathMath.distance(character.position, case.goal)
    local completed_trajectory = trajectory_test.follow_state.trajectory
    if completed_trajectory then
      local run_ticks = completed_trajectory.min_run_ticks
        and math.min(completed_trajectory.min_run_ticks, completed_trajectory.current_run_ticks)
        or completed_trajectory.current_run_ticks
      trajectory_test.min_run_ticks = trajectory_test.min_run_ticks
        and math.min(trajectory_test.min_run_ticks, run_ticks)
        or run_ticks
    end
    trajectory_test.completed[#trajectory_test.completed + 1] = {
      name = case.name,
      ticks = game.tick - trajectory_test.case_started_tick,
      error_distance = error_distance
    }
    trajectory_test.index = trajectory_test.index + 1
    trajectory_test.follow_state = nil
  else
    record("trajectory.vector_decomposition_multi_angle", false, {
      status = status,
      case = case.name,
      position = PathMath.copy_position(character.position),
      diagnostics = diagnostics,
      history = trajectory_test.history
    })
    suite.trajectory_done = true
  end
end

script.on_event(defines.events.on_tick, function(event)
  local suite = storage.scv_testkit
  if suite.finished then return end
  local surface = game.surfaces[1]

  local calibration = suite.motion_calibration
  local elapsed = event.tick - suite.started_tick
  if not suite.calibration_done and elapsed <= calibration.movement_ticks then
    for _, actor in ipairs(calibration.actors) do
      actor.character.walking_state = {walking = true, direction = actor.direction}
    end
  elseif not suite.calibration_done then
    local measured = {}
    for _, actor in ipairs(calibration.actors) do
      local displacement = {
        x = actor.character.position.x - actor.start.x,
        y = actor.character.position.y - actor.start.y
      }
      measured[#measured + 1] = {
        direction = actor.direction,
        displacement = displacement,
        per_tick = {
          x = displacement.x / calibration.movement_ticks,
          y = displacement.y / calibration.movement_ticks
        },
        distance = math.sqrt(displacement.x * displacement.x + displacement.y * displacement.y)
      }
      Follower.stop(actor.character)
    end
    local min_alignment = 1
    for _, sample in ipairs(measured) do
      local expected = Trajectory.direction_vector(sample.direction)
      local actual = {
        x = sample.displacement.x / sample.distance,
        y = sample.displacement.y / sample.distance
      }
      sample.expected = expected
      sample.alignment = actual.x * expected.x + actual.y * expected.y
      min_alignment = math.min(min_alignment, sample.alignment)
    end
    expect("trajectory.direction_calibration", min_alignment >= 0.999, {
      min_alignment = min_alignment,
      measured = measured
    })
    suite.calibration_done = true
  end

  if not suite.world_movement_done then
    local result = WorldTests.update_movement(surface, suite.world_movement_test)
    if result then
      expect(result.name, result.passed, result.details)
      suite.world_movement_done = true
      suite.world_movement_test = nil
    end
  end

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
    local status, diagnostics = Follower.advance(character, suite.corridor.follow_state, GOAL)
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
        position = PathMath.copy_position(character.position),
        diagnostics = diagnostics,
        path = suite.corridor.follow_state.path
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

  update_trajectory_test(suite)

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
    if not suite.trajectory_done then record("trajectory.vector_decomposition_multi_angle", false, {status = "timeout"}) end
    if not suite.calibration_done then record("trajectory.direction_calibration", false, {status = "timeout"}) end
    if not suite.world_movement_done then
      record("navigation_world.live_transients_follow_ordinary_movement", false, {status = "timeout"})
    end
    suite.follower_done = true
    suite.straight_done = true
    suite.corridor_done = true
    suite.unreachable_done = true
    suite.queue_done = true
    suite.open_done = true
    suite.trajectory_done = true
    suite.calibration_done = true
    suite.world_movement_done = true
    finish_if_complete()
  end
end)
