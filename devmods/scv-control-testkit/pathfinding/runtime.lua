local Benchmark = require("pathfinding.benchmark")
local Fixtures = require("pathfinding.fixtures")

local Runtime = {}
local SURFACE_NAME = "scv-pathfinding-bench"
local TIMEOUT_TICKS = 3600

local COLORS = {
  engine = {r = 0.2, g = 0.65, b = 1, a = 0.8},
  ["engine-alternate"] = {r = 0.1, g = 0.9, b = 0.9, a = 0.8},
  ["engine-alternate-global"] = {r = 0.2, g = 1, b = 0.35, a = 0.8},
  ["grid-a-star"] = {r = 1, g = 0.85, b = 0.15, a = 0.8},
  ["grid-weighted-a-star-2"] = {r = 1, g = 0.45, b = 0.1, a = 0.8},
  ["grid-theta-star"] = {r = 0.95, g = 0.3, b = 1, a = 0.8},
  ["grid-theta-star-exact"] = {r = 1, g = 1, b = 1, a = 0.9}
}

local function benchmark_mode()
  return remote.interfaces["scv_test_benchmark"] ~= nil
end

local function interactive_mode()
  return remote.interfaces["scv_test_interactive"] ~= nil
    and remote.interfaces["scv_test_runner"] == nil
    and not benchmark_mode()
end

local function ensure_surface()
  local surface = game.get_surface(SURFACE_NAME)
  if not surface then
    surface = game.create_surface(SURFACE_NAME, {
      autoplace_controls = {},
      default_enable_all_autoplace_controls = false
    })
  end
  surface.request_to_generate_chunks({0, 0}, 3)
  surface.force_generate_chunk_requests()
  surface.freeze_daytime = true
  surface.daytime = 0.5
  surface.peaceful_mode = true
  return surface
end

local function draw_fixture(surface, fixture)
  rendering.draw_rectangle({
    color = {r = 0.4, g = 0.7, b = 1, a = 0.8},
    width = 2,
    filled = false,
    left_top = fixture.bounds[1],
    right_bottom = fixture.bounds[2],
    surface = surface,
    draw_on_ground = true
  })
  rendering.draw_circle({
    color = {r = 0.2, g = 1, b = 0.35, a = 0.9},
    radius = 0.45,
    width = 4,
    filled = false,
    target = fixture.start,
    surface = surface,
    draw_on_ground = true
  })
  rendering.draw_circle({
    color = {r = 1, g = 0.25, b = 0.2, a = 0.9},
    radius = 0.45,
    width = 4,
    filled = false,
    target = fixture.goal,
    surface = surface,
    draw_on_ground = true
  })
end

local function draw_result(surface, result)
  if result.status ~= "success" or not result.path then return end
  local previous = result.path[1]
  for index = 2, #result.path do
    local point = result.path[index]
    rendering.draw_line({
      color = COLORS[result.algorithm],
      width = result.algorithm == "grid-theta-star" and 4 or 2,
      from = previous,
      to = point,
      surface = surface,
      draw_on_ground = true
    })
    previous = point
  end
end

local function draw_legend(surface, fixture, results, display_algorithm)
  local row = 0
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    if display_algorithm == "all" or display_algorithm == algorithm then
      local result = results[algorithm]
      local metric = result.status == "success"
        and string.format("%s  %.2f", algorithm, result.distance)
        or algorithm .. "  " .. result.status
      rendering.draw_text({
        text = metric,
        color = COLORS[algorithm],
        surface = surface,
        target = {
          x = fixture.bounds[1][1] + 0.75,
          y = fixture.bounds[1][2] + 0.75 + row * 0.8
        },
        scale = 0.9,
        alignment = "left",
        vertical_alignment = "top",
        draw_on_ground = true
      })
      row = row + 1
    end
  end
end

local function algorithm_summary(results)
  local summary = {}
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    summary[algorithm] = {
      algorithm = algorithm,
      expected_path_cases = 0,
      solved_cases = 0,
      correct_no_path_cases = 0,
      unsafe_paths = 0,
      trajectory_clearance_violations = 0,
      total_distance_ratio = 0,
      ratio_cases = 0,
      max_distance_ratio = 0,
      total_expanded_nodes = 0,
      total_line_checks = 0,
      total_surface_line_checks = 0,
      total_requests = 0,
      total_duration_ticks = 0
    }
  end

  for _, fixture_result in ipairs(results) do
    local best_distance = math.huge
    if fixture_result.expected_path then
      for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
        local result = fixture_result.results[algorithm]
        if result and result.status == "success" then
          best_distance = math.min(best_distance, result.distance)
        end
      end
    end
    for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
      local result = fixture_result.results[algorithm]
      local totals = summary[algorithm]
      if fixture_result.expected_path then totals.expected_path_cases = totals.expected_path_cases + 1 end
      if result then
        if result.status == "success" then
          totals.solved_cases = totals.solved_cases + 1
          if result.actor_collision_safe == false then totals.unsafe_paths = totals.unsafe_paths + 1 end
          if result.trajectory_clearance_safe == false then
            totals.trajectory_clearance_violations = totals.trajectory_clearance_violations + 1
          end
          if best_distance < math.huge then
            result.distance_ratio_to_best = result.distance / best_distance
            totals.total_distance_ratio = totals.total_distance_ratio + result.distance_ratio_to_best
            totals.ratio_cases = totals.ratio_cases + 1
            totals.max_distance_ratio = math.max(
              totals.max_distance_ratio,
              result.distance_ratio_to_best
            )
          end
        elseif not fixture_result.expected_path and result.status == "no-path" then
          totals.correct_no_path_cases = totals.correct_no_path_cases + 1
        end
        totals.total_expanded_nodes = totals.total_expanded_nodes + (result.expanded_nodes or 0)
        totals.total_line_checks = totals.total_line_checks + (result.line_checks or 0)
        totals.total_surface_line_checks = totals.total_surface_line_checks
          + (result.surface_line_checks or 0)
        totals.total_requests = totals.total_requests + (result.request_count or 0)
        totals.total_duration_ticks = totals.total_duration_ticks + (result.duration_ticks or 0)
      end
    end
  end

  for _, totals in pairs(summary) do
    totals.mean_distance_ratio = totals.ratio_cases > 0
      and totals.total_distance_ratio / totals.ratio_cases
      or nil
    totals.total_distance_ratio = nil
    totals.ratio_cases = nil
  end
  return summary
end

local function validate_fixture_result(suite, fixture_result)
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    local result = fixture_result.results[algorithm]
    local passed = result ~= nil
      and ((fixture_result.expected_path
          and result.status == "success"
          and result.actor_collision_safe)
        or (not fixture_result.expected_path and result.status == "no-path"))
    suite.assertions[#suite.assertions + 1] = {
      name = fixture_result.id .. "." .. algorithm,
      passed = passed,
      status = result and result.status or "missing",
      actor_collision_safe = result and result.actor_collision_safe or nil,
      trajectory_clearance_safe = result and result.trajectory_clearance_safe or nil
    }
    if passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
  end
end

local function add_assertion(suite, name, passed, details)
  suite.assertions[#suite.assertions + 1] = {
    name = name,
    passed = passed == true,
    details = details
  }
  if passed then suite.passed = suite.passed + 1 else suite.failed = suite.failed + 1 end
end

local function validate_test_set(suite)
  local results_by_id = {}
  local categories = {}
  for _, result in ipairs(suite.fixture_results) do
    results_by_id[result.id] = result
    categories[result.category] = true
  end
  local required_ids = {
    "open-diagonal",
    "long-wall-return",
    "long-wall-enter",
    "narrow-corridor",
    "u-trap",
    "slalom",
    "gate-open",
    "gate-closed",
    "unreachable-box"
  }
  local complete = #suite.fixture_results == #required_ids
  for _, id in ipairs(required_ids) do complete = complete and results_by_id[id] ~= nil end
  add_assertion(suite, "benchmark.fixture-catalog", complete, {
    fixture_version = Fixtures.VERSION,
    fixture_count = #suite.fixture_results,
    categories = categories
  })

  local gate_open = results_by_id["gate-open"]
  local gate_closed = results_by_id["gate-closed"]
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    local open_result = gate_open and gate_open.results[algorithm]
    local closed_result = gate_closed and gate_closed.results[algorithm]
    add_assertion(
      suite,
      "benchmark.dynamic-static." .. algorithm,
      open_result
        and closed_result
        and open_result.status == "success"
        and closed_result.status == "success"
        and closed_result.distance > open_result.distance + 2,
      {open = open_result and open_result.distance, closed = closed_result and closed_result.distance}
    )
  end

  local captured = results_by_id["long-wall-return"]
  local engine = captured and captured.results.engine
  local global = captured and captured.results["engine-alternate-global"]
  add_assertion(
    suite,
    "benchmark.captured-detour-sensitivity",
    engine
      and global
      and engine.status == "success"
      and global.status == "success"
      and engine.distance > global.distance * 1.5,
    {engine = engine and engine.distance, alternate_global = global and global.distance}
  )
end

local function finish_headless(suite)
  if suite.finished then return end
  validate_test_set(suite)
  suite.finished = true
  local report = {
    schema_version = 1,
    fixture_version = Fixtures.VERSION,
    factorio_version = script.active_mods.base,
    mod_version = script.active_mods["factorio-scv-control"],
    tick = game.tick,
    duration_ticks = game.tick - suite.started_tick,
    fixture_count = #suite.fixture_results,
    algorithm_count = #Benchmark.ALGORITHMS,
    passed = suite.passed,
    failed = suite.failed,
    assertions = suite.assertions,
    fixtures = suite.fixture_results,
    algorithms = algorithm_summary(suite.fixture_results)
  }
  local json = helpers.table_to_json(report)
  helpers.write_file("scv-control/pathfinding-benchmark.json", json, false, 0)
  log("SCV_BENCH_REPORT " .. json)
  log("SCV_BENCH_COMPLETE passed=" .. suite.passed .. " failed=" .. suite.failed)
end

local function start_fixture(suite, fixture, player)
  local surface = ensure_surface()
  if player and player.surface == surface then
    player.teleport({0, 0}, game.surfaces[1])
  end
  Fixtures.build(surface, fixture)
  draw_fixture(surface, fixture)

  local actor
  if player then
    player.teleport(fixture.start, surface)
    actor = player.character
  else
    actor = surface.create_entity({
      name = "character",
      position = fixture.start,
      force = "player"
    })
  end
  suite.active_fixture = fixture
  local selected_algorithm = suite.mode == "interactive"
      and suite.display_algorithm ~= "all"
      and suite.display_algorithm
    or nil
  suite.active_run = Benchmark.start(surface, actor, fixture, selected_algorithm)
end

local function finish_active_fixture(suite)
  local run = suite.active_run
  local fixture = suite.active_fixture
  local fixture_result = {
    id = fixture.id,
    title = fixture.title,
    category = fixture.category,
    expected_path = fixture.expected_path,
    start = fixture.start,
    goal = fixture.goal,
    completed_tick = game.tick,
    duration_ticks = game.tick - run.started_tick,
    results = run.results
  }
  suite.fixture_results[#suite.fixture_results + 1] = fixture_result

  if suite.mode == "headless" then
    validate_fixture_result(suite, fixture_result)
    if run.actor and run.actor.valid then run.actor.destroy() end
    suite.fixture_index = suite.fixture_index + 1
    suite.active_run = nil
    suite.active_fixture = nil
    suite.next_fixture_tick = game.tick + 1
  else
    for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
      if suite.display_algorithm == "all" or suite.display_algorithm == algorithm then
        draw_result(run.surface, run.results[algorithm])
      end
    end
    draw_legend(run.surface, fixture, run.results, suite.display_algorithm)
    local player = game.get_player(suite.player_index)
    if player then
      player.print("Pathfinding benchmark: " .. fixture.id)
      for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
        local result = run.results[algorithm]
        if result and (suite.display_algorithm == "all" or suite.display_algorithm == algorithm) then
          local metric = result.status == "success"
            and string.format("%.2f tiles", result.distance)
            or result.status
          local clearance = result.status == "success"
            and (result.trajectory_clearance_safe and "clearance-safe" or "actor-only")
            or ""
          player.print(string.format("  %-30s %-12s %s", algorithm, metric, clearance))
        end
      end
    end
    suite.active_run = nil
    suite.active_fixture = nil
  end
end

Runtime.on_init = function()
  if benchmark_mode() then
    storage.scv_path_bench = {
      mode = "headless",
      started_tick = game.tick,
      fixture_index = 1,
      fixture_results = {},
      assertions = {},
      passed = 0,
      failed = 0,
      next_fixture_tick = game.tick + 1,
      finished = false
    }
  end
end

Runtime.events = {
  [defines.events.on_script_path_request_finished] = function(event)
    local suite = storage.scv_path_bench
    if suite and suite.active_run then
      Benchmark.handle_path_result(suite.active_run, event)
    end
  end,
  [defines.events.on_tick] = function(event)
    local suite = storage.scv_path_bench
    if not suite or suite.finished then return end
    if suite.active_run and suite.active_run.complete then
      finish_active_fixture(suite)
      return
    end
    if suite.mode == "headless" and not suite.active_run
        and event.tick >= (suite.next_fixture_tick or 0) then
      local fixture = Fixtures.list()[suite.fixture_index]
      if fixture then
        start_fixture(suite, fixture, nil)
      else
        finish_headless(suite)
      end
    end
    if suite.mode == "headless" and event.tick > suite.started_tick + TIMEOUT_TICKS then
      suite.failed = suite.failed + 1
      suite.assertions[#suite.assertions + 1] = {
        name = "benchmark.terminal-completion",
        passed = false,
        status = "timeout"
      }
      finish_headless(suite)
    end
  end
}

Runtime.add_commands = function()
  if not interactive_mode() then return end
  commands.add_command("scv-test-bench", {"scv-test.command-bench-help"}, function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    local parameter = command.parameter or "list"
    local fixture_id, display_algorithm = parameter:match("^(%S+)%s*(%S*)$")
    display_algorithm = display_algorithm ~= ""
      and display_algorithm
      or "engine-alternate-global"
    if fixture_id == "list" then
      local ids = {}
      for _, fixture in ipairs(Fixtures.list()) do ids[#ids + 1] = fixture.id end
      player.print("Pathfinding fixtures: " .. table.concat(ids, ", "))
      player.print("Algorithms: " .. table.concat(Benchmark.ALGORITHMS, ", "))
      return
    end
    local fixture = Fixtures.get(fixture_id)
    if not fixture then
      player.print("Unknown pathfinding fixture: " .. fixture_id)
      return
    end
    local algorithm_known = display_algorithm == "all"
    for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
      algorithm_known = algorithm_known or display_algorithm == algorithm
    end
    if not algorithm_known then
      player.print("Unknown pathfinding algorithm: " .. display_algorithm)
      return
    end
    local suite = storage.scv_path_bench
    if suite and suite.active_run then
      player.print("A pathfinding benchmark is already running.")
      return
    end
    storage.scv_path_bench = {
      mode = "interactive",
      started_tick = game.tick,
      fixture_results = {},
      assertions = {},
      passed = 0,
      failed = 0,
      player_index = command.player_index,
      display_algorithm = display_algorithm,
      finished = false
    }
    start_fixture(storage.scv_path_bench, fixture, player)
  end)
end

return Runtime
