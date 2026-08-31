local Benchmark = require("pathfinding.benchmark")
local Fixtures = require("pathfinding.fixtures")
local PathMath = require("__factorio-scv-control__/scripts/path_math")
local PathSmoothing = require("__factorio-scv-control__/scripts/path_smoothing")
local Policy = require("__factorio-scv-control__/scripts/navigation_policy")

local Runtime = {}
local SURFACE_NAME = "scv-pathfinding-bench"
local TIMEOUT_TICKS = 3600
local PREVIEW_INTERFACE = "scv_pathfinding_preview"
local PREVIEW_GUI_NAME = "scv_pathfinding_preview_frame"
local PREVIEW_CLOSE_NAME = "scv_pathfinding_preview_close"
local STRICT_LAB_PLACEMENTS = {
  {id = "captured-slalom-return", offset = {x = -54, y = 56}},
  {id = "long-wall-return", offset = {x = 49, y = 56}},
  {id = "u-trap", offset = {x = -4, y = 82}},
  {id = "tight-clearance-corridor", offset = {x = 25, y = 82}}
}

local COLORS = {
  production = {r = 0.15, g = 0.55, b = 1, a = 0.95},
  engine = {r = 0.2, g = 0.65, b = 1, a = 0.8},
  ["production-local"] = {r = 0.95, g = 0.2, b = 0.75, a = 0.95},
  ["engine-inflated"] = {r = 0.15, g = 0.9, b = 0.55, a = 0.85},
  ["engine-alternate"] = {r = 0.1, g = 0.9, b = 0.9, a = 0.8},
  ["engine-alternate-global"] = {r = 0.2, g = 1, b = 0.35, a = 0.8},
  ["grid-a-star"] = {r = 1, g = 0.85, b = 0.15, a = 0.8},
  ["grid-weighted-a-star-2"] = {r = 1, g = 0.45, b = 0.1, a = 0.8},
  ["grid-theta-star"] = {r = 0.95, g = 0.3, b = 1, a = 0.8},
  ["grid-theta-star-exact"] = {r = 1, g = 1, b = 1, a = 0.9},
  ["safe-hybrid"] = {r = 1, g = 0.25, b = 0.55, a = 0.95}
}

local LINE_STYLES = {
  production = {width = 5},
  engine = {width = 2},
  ["production-local"] = {width = 5, dash_length = 2.8, gap_length = 0.25},
  ["engine-inflated"] = {width = 3, dash_length = 1.4, gap_length = 0.25},
  ["engine-alternate"] = {width = 2, dash_length = 0.8, gap_length = 0.35},
  ["engine-alternate-global"] = {width = 4, dash_length = 1.6, gap_length = 0.4},
  ["grid-a-star"] = {width = 2, dash_length = 0.45, gap_length = 0.3},
  ["grid-weighted-a-star-2"] = {width = 2, dash_length = 1.2, gap_length = 0.6},
  ["grid-theta-star"] = {width = 3, dash_length = 2.2, gap_length = 0.45},
  ["grid-theta-star-exact"] = {width = 3, dash_length = 0.25, gap_length = 0.25},
  ["safe-hybrid"] = {width = 5, dash_length = 2.4, gap_length = 0.3}
}

local function visual_algorithms()
  local algorithms = {"production"}
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    algorithms[#algorithms + 1] = algorithm
  end
  return algorithms
end

local function benchmark_mode()
  return remote.interfaces["scv_test_benchmark"] ~= nil
end

local function interactive_mode()
  return remote.interfaces["scv_test_interactive"] ~= nil
    and remote.interfaces["scv_test_runner"] == nil
    and not benchmark_mode()
end

local function ensure_live_preview_storage()
  storage.scv_live_preview = storage.scv_live_preview or {
    players = {},
    renderings = {}
  }
  return storage.scv_live_preview
end

local function player_preview_settings(player_index)
  local preview = ensure_live_preview_storage()
  local settings = preview.players[player_index]
  if settings then return settings end

  local algorithms = {}
  for _, algorithm in ipairs(visual_algorithms()) do algorithms[algorithm] = true end
  settings = {enabled = true, algorithms = algorithms}
  preview.players[player_index] = settings
  return settings
end

local function clear_player_renderings(player_index)
  local preview = ensure_live_preview_storage()
  for _, objects in pairs(preview.renderings[player_index] or {}) do
    for _, object in pairs(objects) do
      if object.valid then object.destroy() end
    end
  end
  preview.renderings[player_index] = {}
end

local function include_position(bounds, position)
  bounds.min_x = math.min(bounds.min_x, position.x)
  bounds.max_x = math.max(bounds.max_x, position.x)
  bounds.min_y = math.min(bounds.min_y, position.y)
  bounds.max_y = math.max(bounds.max_y, position.y)
end

local function include_mirrored_path(bounds, start_position, goal_position, path)
  local dx = goal_position.x - start_position.x
  local dy = goal_position.y - start_position.y
  local length_squared = dx * dx + dy * dy
  for _, point in ipairs(path or {}) do
    include_position(bounds, point)
    if length_squared > Policy.diagnostics.position_epsilon then
      local relative_x = point.x - start_position.x
      local relative_y = point.y - start_position.y
      local projection = (relative_x * dx + relative_y * dy) / length_squared
      local projected = {
        x = start_position.x + projection * dx,
        y = start_position.y + projection * dy
      }
      include_position(bounds, {
        x = projected.x * 2 - point.x,
        y = projected.y * 2 - point.y
      })
    end
  end
end

local function live_fixture(actor, payload)
  local start_position = payload.start_position
  local goal_position = payload.goal_position
  local bounds = {
    min_x = math.min(start_position.x, goal_position.x),
    max_x = math.max(start_position.x, goal_position.x),
    min_y = math.min(start_position.y, goal_position.y),
    max_y = math.max(start_position.y, goal_position.y)
  }
  include_mirrored_path(
    bounds,
    start_position,
    goal_position,
    payload.production_path
  )

  local padding = Policy.optimization.alternate_snap_radius
    + PathSmoothing.clearance_margin(actor)
  bounds.min_x = math.floor(bounds.min_x - padding)
  bounds.max_x = math.ceil(bounds.max_x + padding)
  bounds.min_y = math.floor(bounds.min_y - padding)
  bounds.max_y = math.ceil(bounds.max_y + padding)

  local width = math.max(1, bounds.max_x - bounds.min_x)
  local height = math.max(1, bounds.max_y - bounds.min_y)
  local resolution = Benchmark.GRID_RESOLUTION
  local estimated_nodes = (width / resolution + 1) * (height / resolution + 1)
  if estimated_nodes > Policy.grid.max_local_nodes then
    local required = math.sqrt(width * height / Policy.grid.max_local_nodes)
    resolution = math.ceil(required / Benchmark.GRID_RESOLUTION)
      * Benchmark.GRID_RESOLUTION
  end

  return {
    id = "live-command-" .. payload.command_id,
    title = "Live command " .. payload.command_id,
    category = "live-preview",
    bounds = {{bounds.min_x, bounds.min_y}, {bounds.max_x, bounds.max_y}},
    start = PathMath.copy_position(start_position),
    goal = PathMath.copy_position(goal_position),
    expected_path = payload.production_status == "success",
    grid_resolution = resolution,
    walls = {}
  }
end

local function production_result(surface, actor, fixture, payload)
  local path = payload.production_path
  if not path then return {algorithm = "production", status = payload.production_status} end
  return {
    algorithm = "production",
    status = "success",
    path = path,
    distance = PathMath.polyline_distance(fixture.start, path),
    direct_distance = PathMath.distance(fixture.start, fixture.goal),
    waypoint_count = #path,
    turns = PathMath.turn_metrics(path),
    actor_collision_safe = PathSmoothing.path_is_clear(
      surface,
      actor,
      fixture.start,
      path,
      0
    ),
    trajectory_clearance_safe = PathSmoothing.path_is_clear(
      surface,
      actor,
      fixture.start,
      path
    )
  }
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
  surface.daytime = 0
  surface.always_day = true
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

local function draw_result(surface, result, player_index)
  if not result or result.status ~= "success" or not result.path then return {} end
  local style = LINE_STYLES[result.algorithm] or {width = 2}
  local objects = {}
  local previous = result.path[1]
  for index = 2, #result.path do
    local point = result.path[index]
    local properties = {
      color = COLORS[result.algorithm],
      width = style.width,
      from = previous,
      to = point,
      surface = surface,
      players = player_index and {player_index} or nil,
      draw_on_ground = true
    }
    if style.dash_length then
      properties.dash_length = style.dash_length
      properties.gap_length = style.gap_length
    end
    objects[#objects + 1] = rendering.draw_line(properties)
    previous = point
  end
  return objects
end

local function draw_legend(surface, fixture, results, display_algorithm)
  local row = 0
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    if display_algorithm == "all" or display_algorithm == algorithm then
      local result = results[algorithm]
      local metric = result and result.status == "success"
        and string.format("%s  %.2f", algorithm, result.distance)
        or algorithm .. "  " .. (result and result.status or "not-run")
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

local function set_algorithm_visibility(player_index, algorithm, visible)
  local preview = ensure_live_preview_storage()
  local objects = preview.renderings[player_index]
    and preview.renderings[player_index][algorithm]
    or {}
  for _, object in pairs(objects) do
    if object.valid then object.visible = visible end
  end
end

local function result_metric(result)
  if not result then return "not run" end
  if result.status ~= "success" then return result.status end
  local clearance = result.trajectory_clearance_safe and "clear" or "actor only"
  return string.format("%.2f tiles, %d points, %s", result.distance, result.waypoint_count, clearance)
end

local function rebuild_preview_gui(player, suite)
  local old = player.gui.screen[PREVIEW_GUI_NAME]
  if old then old.destroy() end

  local frame = player.gui.screen.add({
    type = "frame",
    name = PREVIEW_GUI_NAME,
    direction = "vertical"
  })
  frame.location = {24, 120}
  local titlebar = frame.add({type = "flow", direction = "horizontal"})
  titlebar.drag_target = frame
  local title = titlebar.add({
    type = "label",
    caption = "Plan comparison: " .. suite.active_result.id,
    style = "frame_title"
  })
  title.drag_target = frame
  local dragger = titlebar.add({type = "empty-widget", style = "draggable_space_header"})
  dragger.style.horizontally_stretchable = true
  dragger.style.height = 24
  dragger.drag_target = frame
  titlebar.add({
    type = "sprite-button",
    name = PREVIEW_CLOSE_NAME,
    sprite = "utility/close",
    style = "frame_action_button",
    tooltip = "Close plan comparison"
  })

  local settings = player_preview_settings(player.index)
  frame.add({
    type = "checkbox",
    state = settings.enabled,
    caption = "Preview every completed plan",
    tags = {scv_preview_enabled = true}
  })
  frame.add({type = "line"})

  for _, algorithm in ipairs(visual_algorithms()) do
    local row = frame.add({type = "flow", direction = "horizontal"})
    row.style.vertical_align = "center"
    local checkbox = row.add({
      type = "checkbox",
      name = "scv_preview_algorithm_" .. algorithm:gsub("%-", "_"),
      state = settings.algorithms[algorithm] ~= false,
      tags = {scv_preview_algorithm = algorithm}
    })
    checkbox.tooltip = algorithm == "grid-theta-star-exact"
      and "Exact Factorio geometry checks; high cost"
      or "Show now and include in future live comparisons"
    local result = suite.active_result.results[algorithm]
    local label = row.add({
      type = "label",
      caption = algorithm .. "  " .. result_metric(result)
    })
    label.style.font_color = COLORS[algorithm]
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
      total_safe_distance_ratio = 0,
      safe_ratio_cases = 0,
      max_safe_distance_ratio = 0,
      total_expanded_nodes = 0,
      total_line_checks = 0,
      total_surface_line_checks = 0,
      total_requests = 0,
      total_duration_ticks = 0
    }
  end

  for _, fixture_result in ipairs(results) do
    local best_distance = math.huge
    local best_safe_distance = math.huge
    if fixture_result.expected_path then
      for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
        local result = fixture_result.results[algorithm]
        if result and result.status == "success" then
          best_distance = math.min(best_distance, result.distance)
          if result.trajectory_clearance_safe then
            best_safe_distance = math.min(best_safe_distance, result.distance)
          end
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
          if result.trajectory_clearance_safe and best_safe_distance < math.huge then
            result.distance_ratio_to_best_safe = result.distance / best_safe_distance
            totals.total_safe_distance_ratio = totals.total_safe_distance_ratio
              + result.distance_ratio_to_best_safe
            totals.safe_ratio_cases = totals.safe_ratio_cases + 1
            totals.max_safe_distance_ratio = math.max(
              totals.max_safe_distance_ratio,
              result.distance_ratio_to_best_safe
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
    totals.mean_safe_distance_ratio = totals.safe_ratio_cases > 0
      and totals.total_safe_distance_ratio / totals.safe_ratio_cases
      or nil
    totals.total_distance_ratio = nil
    totals.ratio_cases = nil
    totals.total_safe_distance_ratio = nil
    totals.safe_ratio_cases = nil
  end
  return summary
end

local function validate_fixture_result(suite, fixture_result)
  local must_be_trajectory_safe = {
    ["production-local"] = true,
    ["engine-inflated"] = true,
    ["grid-a-star"] = true,
    ["grid-weighted-a-star-2"] = true,
    ["grid-theta-star"] = true,
    ["grid-theta-star-exact"] = true,
    ["safe-hybrid"] = true
  }
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    local result = fixture_result.results[algorithm]
    local passed = result ~= nil
      and ((fixture_result.expected_path
          and result.status == "success"
          and result.actor_collision_safe
          and (not must_be_trajectory_safe[algorithm] or result.trajectory_clearance_safe))
        or (fixture_result.expected_path
          and fixture_result.allowed_no_path
          and fixture_result.allowed_no_path[algorithm]
          and result.status == "no-path")
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
    "tight-clearance-corridor",
    "u-trap",
    "slalom",
    "captured-slalom-return",
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

  local captured_slalom = results_by_id["captured-slalom-return"]
  local slalom_engine = captured_slalom and captured_slalom.results.engine
  local slalom_best = captured_slalom and captured_slalom.results["grid-a-star"]
  add_assertion(
    suite,
    "benchmark.captured-slalom-portal-choice",
    slalom_engine
      and slalom_best
      and slalom_engine.status == "success"
      and slalom_best.status == "success"
      and slalom_engine.distance > slalom_best.distance * 1.05,
    {
      engine = slalom_engine and slalom_engine.distance,
      grid_a_star = slalom_best and slalom_best.distance
    }
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
  if suite.production_result then run.results.production = suite.production_result end
  local fixture_result = {
    id = fixture.id,
    title = fixture.title,
    category = fixture.category,
    expected_path = fixture.expected_path,
    allowed_no_path = fixture.allowed_no_path,
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
    local player = game.get_player(suite.player_index)
    if player then
      if suite.mode == "live" then
        helpers.write_file(
          "scv-control/live-preview.jsonl",
          helpers.table_to_json(fixture_result) .. "\n",
          true,
          player.index
        )
      end
      clear_player_renderings(player.index)
      local preview = ensure_live_preview_storage()
      local settings = player_preview_settings(player.index)
      local renderings = preview.renderings[player.index]
      for _, algorithm in ipairs(visual_algorithms()) do
        local result = run.results[algorithm]
        local should_draw = suite.mode == "live"
          or suite.display_algorithm == "all"
          or suite.display_algorithm == algorithm
        if result and should_draw then
          renderings[algorithm] = draw_result(run.surface, result, player.index)
          set_algorithm_visibility(
            player.index,
            algorithm,
            settings.algorithms[algorithm] ~= false
          )
        end
      end
      if suite.mode == "interactive" then
        draw_legend(run.surface, fixture, run.results, suite.display_algorithm)
      end
      player.print("Pathfinding benchmark: " .. fixture.id)
      for _, algorithm in ipairs(visual_algorithms()) do
        local result = run.results[algorithm]
        if result and (suite.mode == "live"
            or suite.display_algorithm == "all"
            or suite.display_algorithm == algorithm) then
          local metric = result.status == "success"
            and string.format("%.2f tiles", result.distance)
            or result.status
          local clearance = result.status == "success"
            and (result.trajectory_clearance_safe and "clearance-safe" or "actor-only")
            or ""
          player.print(string.format("  %-30s %-12s %s", algorithm, metric, clearance))
        end
      end
      suite.active_result = fixture_result
      rebuild_preview_gui(player, suite)
    end
    suite.active_run = nil
    suite.active_fixture = nil
  end
end

local function start_live_preview(player_index, payload)
  if not interactive_mode() then return false end
  local player = game.get_player(player_index)
  local surface = game.get_surface(payload.surface_index)
  if not player or not surface or not player.character or not player.character.valid then return false end

  local settings = player_preview_settings(player_index)
  if not settings.enabled then return false end
  clear_player_renderings(player_index)

  local fixture = live_fixture(player.character, payload)
  local selected_algorithms = {}
  for _, algorithm in ipairs(Benchmark.ALGORITHMS) do
    if settings.algorithms[algorithm] ~= false then selected_algorithms[algorithm] = true end
  end
  local suite = {
    mode = "live",
    started_tick = game.tick,
    fixture_results = {},
    assertions = {},
    passed = 0,
    failed = 0,
    player_index = player_index,
    display_algorithm = "all",
    selected_algorithms = selected_algorithms,
    production_result = production_result(surface, player.character, fixture, payload),
    active_fixture = fixture,
    finished = false
  }
  suite.active_run = Benchmark.start(
    surface,
    player.character,
    fixture,
    selected_algorithms
  )
  storage.scv_path_bench = suite
  return true
end

Runtime.on_init = function()
  if interactive_mode() then ensure_live_preview_storage() end
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

Runtime.on_configuration_changed = function()
  if interactive_mode() then ensure_live_preview_storage() end
end

Runtime.add_remote_interface = function()
  if not interactive_mode() or remote.interfaces[PREVIEW_INTERFACE] then return end
  remote.add_interface(PREVIEW_INTERFACE, {
    preview_plan = start_live_preview,
    build_strict_test_zones = function(surface_index)
      local surface = game.get_surface(surface_index)
      if not surface then return false end
      for _, placement in ipairs(STRICT_LAB_PLACEMENTS) do
        Fixtures.build_at(surface, Fixtures.get(placement.id), placement.offset, true)
      end
      surface.daytime = 0
      surface.freeze_daytime = true
      surface.always_day = true
      return true
    end
  })
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
  end,
  [defines.events.on_gui_checked_state_changed] = function(event)
    if not interactive_mode() or not event.element.valid then return end
    local tags = event.element.tags
    if tags.scv_preview_enabled then
      player_preview_settings(event.player_index).enabled = event.element.state
      return
    end
    local algorithm = tags.scv_preview_algorithm
    if algorithm then
      player_preview_settings(event.player_index).algorithms[algorithm] = event.element.state
      set_algorithm_visibility(event.player_index, algorithm, event.element.state)
    end
  end,
  [defines.events.on_gui_click] = function(event)
    if not interactive_mode() or not event.element.valid then return end
    if event.element.name == PREVIEW_CLOSE_NAME then
      local frame = game.get_player(event.player_index).gui.screen[PREVIEW_GUI_NAME]
      if frame then frame.destroy() end
    end
  end
}

Runtime.add_commands = function()
  if not interactive_mode() then return end
  commands.add_command("scv-test-preview", {"scv-test.command-preview-help"}, function(command)
    if not command.player_index then return end
    local player = game.get_player(command.player_index)
    local settings = player_preview_settings(command.player_index)
    local parameter = command.parameter or "show"
    if parameter == "on" then
      settings.enabled = true
      player.print("Live plan comparison enabled.")
    elseif parameter == "off" then
      settings.enabled = false
      clear_player_renderings(command.player_index)
      local frame = player.gui.screen[PREVIEW_GUI_NAME]
      if frame then frame.destroy() end
      player.print("Live plan comparison disabled.")
    elseif parameter == "clear" then
      clear_player_renderings(command.player_index)
    elseif parameter == "show" then
      local suite = storage.scv_path_bench
      if suite and suite.active_result and suite.player_index == command.player_index then
        rebuild_preview_gui(player, suite)
      else
        player.print("No completed plan comparison is available.")
      end
    else
      player.print("Usage: /scv-test-preview [on|off|show|clear]")
    end
  end)

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
