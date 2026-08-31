local TEST_AREA = {{-52, -34}, {52, 100}}
local SPAWN = {x = 0, y = 0}
local TEST_LAB_VERSION = 3

local function automated_runner_active()
  return remote.interfaces["scv_test_runner"] ~= nil
end

local function interactive_test_active()
  return remote.interfaces["scv_test_interactive"] ~= nil and not automated_runner_active()
end

local ZONES = {
  {
    name = {"scv-test.zone-straight"},
    chart_text = "1 Straight",
    position = {x = 24, y = -22},
    area = {{5, -27}, {43, -17}},
    targets = {{x = 8, y = -22}, {x = 40, y = -22}}
  },
  {
    name = {"scv-test.zone-slalom"},
    chart_text = "2 Slalom",
    position = {x = 24, y = -7},
    area = {{5, -14}, {43, 1}},
    targets = {{x = 8, y = -7}, {x = 40, y = -7}}
  },
  {
    name = {"scv-test.zone-corridor"},
    chart_text = "3 Corridor",
    position = {x = -25, y = -9},
    area = {{-43, -14}, {-7, -4}},
    targets = {{x = -40, y = -9}, {x = -10, y = -9}}
  },
  {
    name = {"scv-test.zone-queue"},
    chart_text = "4 Queue",
    position = {x = -25, y = 20},
    area = {{-43, 6}, {-7, 33}},
    targets = {
      {x = -39, y = 10},
      {x = -11, y = 10},
      {x = -11, y = 29},
      {x = -39, y = 29}
    }
  },
  {
    name = {"scv-test.zone-unreachable"},
    chart_text = "5 Unreachable",
    position = {x = 33, y = 25},
    area = {{24, 16}, {42, 34}},
    targets = {{x = 33, y = 25}}
  },
  {
    name = {"scv-test.zone-context"},
    chart_text = "6 Context",
    position = {x = 9, y = 23},
    area = {{-2, 14}, {20, 33}},
    targets = {}
  },
  {
    name = {"scv-test.zone-strict-detours"},
    chart_text = "7 Strict detours",
    position = {x = 0, y = 68},
    area = {{-52, 38}, {52, 98}},
    targets = {}
  }
}

local function each_tile(area, callback)
  for x = area[1][1], area[2][1] - 1 do
    for y = area[1][2], area[2][2] - 1 do
      callback(x, y)
    end
  end
end

local function set_tiles(surface, area, name)
  local tiles = {}
  each_tile(area, function(x, y)
    tiles[#tiles + 1] = {name = name, position = {x, y}}
  end)
  surface.set_tiles(tiles, true, false, false, false)
end

local function create_entity(surface, properties)
  local entity = surface.create_entity(properties)
  if entity then
    entity.minable = false
    entity.destructible = false
  end
  return entity
end

local function create_wall(surface, x, y)
  create_entity(surface, {
    name = "stone-wall",
    position = {x = x, y = y},
    force = "neutral"
  })
end

local function draw_zone(surface, zone)
  rendering.draw_rectangle({
    color = {r = 0.25, g = 0.65, b = 1, a = 0.8},
    width = 2,
    filled = false,
    left_top = zone.area[1],
    right_bottom = zone.area[2],
    surface = surface,
    draw_on_ground = true
  })
  rendering.draw_text({
    text = zone.name,
    surface = surface,
    target = {x = zone.area[1][1] + 0.5, y = zone.area[1][2] + 0.5},
    color = {r = 0.85, g = 0.95, b = 1},
    scale = 1.1,
    alignment = "left",
    vertical_alignment = "top",
    scale_with_zoom = false,
    draw_on_ground = true
  })

  for index, target in ipairs(zone.targets) do
    rendering.draw_circle({
      color = {r = 0.2, g = 1, b = 0.35, a = 0.9},
      radius = 0.55,
      width = 4,
      filled = false,
      target = target,
      surface = surface,
      draw_on_ground = true
    })
    rendering.draw_text({
      text = tostring(index),
      surface = surface,
      target = target,
      target_offset = {0, -0.1},
      color = {r = 1, g = 1, b = 1},
      scale = 1,
      alignment = "center",
      vertical_alignment = "middle",
      scale_with_zoom = false,
      draw_on_ground = true
    })
  end
end

local function create_slalom(surface)
  for x = 12, 36, 6 do
    local gap_at_top = x % 12 == 0
    for y = -12, -2 do
      local in_gap = gap_at_top and y <= -10 or (not gap_at_top and y >= -4)
      if not in_gap then
        create_wall(surface, x, y)
      end
    end
  end
end

local function create_corridor(surface)
  for x = -42, -8 do
    create_wall(surface, x, -12)
    create_wall(surface, x, -6)
  end
end

local function create_unreachable_target(surface)
  for x = 28, 38 do
    create_wall(surface, x, 20)
    create_wall(surface, x, 30)
  end
  for y = 21, 29 do
    create_wall(surface, 28, y)
    create_wall(surface, 38, y)
  end
end

local function create_context_yard(surface)
  for x = 1, 5 do
    for y = 20, 24 do
      create_entity(surface, {
        name = "iron-ore",
        position = {x = x, y = y},
        amount = 5000
      })
    end
  end

  local assembler = create_entity(surface, {
    name = "assembling-machine-1",
    position = {x = 11, y = 22},
    force = "player"
  })
  if assembler then
    assembler.health = assembler.max_health * 0.35
  end

  create_entity(surface, {
    name = "wooden-chest",
    position = {x = 16, y = 22},
    force = "player"
  })
end

local function clear_test_area(surface)
  for _, entity in pairs(surface.find_entities(TEST_AREA)) do
    if entity.valid and entity.type ~= "character" then
      entity.destroy()
    end
  end
  surface.destroy_decoratives({area = TEST_AREA})
  for _, tag in pairs(game.forces.player.find_chart_tags(surface, TEST_AREA)) do
    tag.destroy()
  end
  rendering.clear()
end

local function build_test_lab()
  local surface = game.surfaces[1]
  surface.request_to_generate_chunks(SPAWN, 4)
  surface.force_generate_chunk_requests()
  clear_test_area(surface)

  set_tiles(surface, TEST_AREA, "refined-concrete")
  set_tiles(surface, {{-3, -3}, {4, 4}}, "refined-hazard-concrete-left")

  create_slalom(surface)
  create_corridor(surface)
  create_unreachable_target(surface)
  create_context_yard(surface)

  for _, zone in ipairs(ZONES) do
    draw_zone(surface, zone)
  end
  local preview = remote.interfaces["scv_pathfinding_preview"]
  if preview and preview.build_strict_test_zones then
    remote.call("scv_pathfinding_preview", "build_strict_test_zones", surface.index)
  end

  game.forces.player.set_spawn_position(SPAWN, surface)
  game.forces.player.chart(surface, TEST_AREA)
  for _, zone in ipairs(ZONES) do
    game.forces.player.add_chart_tag(surface, {
      position = zone.position,
      text = zone.chart_text
    })
  end

  surface.freeze_daytime = true
  surface.daytime = 0
  surface.always_day = true
  surface.peaceful_mode = true
  storage.scv_test_lab_built = true
  storage.scv_test_lab_version = TEST_LAB_VERSION
end

local function prepare_player(player)
  if player.controller_type ~= defines.controllers.character or not player.character then
    player.create_character()
  end
  player.teleport(SPAWN, game.surfaces[1])
  player.set_goal_description({"scv-test.goal"})
  player.clear_console()
  player.print({"scv-test.welcome"})
end

local test_lab = {}

test_lab.add_remote_interface = function()
  if not interactive_test_active() then return end
  if not remote.interfaces["scv_test_lab"] then
    remote.add_interface("scv_test_lab", {
      planner_logging_enabled = function()
        return true
      end,
      follower_trace_enabled = function()
        return true
      end
    })
  end
end

test_lab.on_init = function()
  if not interactive_test_active() then return end
  remote.call("freeplay", "set_disable_crashsite", true)
  remote.call("freeplay", "set_skip_intro", true)
  remote.call("freeplay", "set_created_items", {})
  build_test_lab()
end

test_lab.on_configuration_changed = function()
  if not interactive_test_active() then return end
  local surface = game.surfaces[1]
  surface.daytime = 0
  surface.freeze_daytime = true
  surface.always_day = true
  if storage.scv_test_lab_version ~= TEST_LAB_VERSION then
    build_test_lab()
  end
end

test_lab.events = {
  [defines.events.on_player_created] = function(event)
    if not interactive_test_active() then return end
    prepare_player(game.get_player(event.player_index))
  end
}

test_lab.on_nth_tick = {
  [1] = function()
    if not interactive_test_active() then return end
    if storage.scv_test_lab_version ~= TEST_LAB_VERSION then
      build_test_lab()
    end
    if game.is_multiplayer()
        and #game.connected_players == 0
        and not storage.scv_test_seed_save_created then
      storage.scv_test_seed_save_created = true
      game.server_save("SCV Control Test")
    end
  end
}

test_lab.add_commands = function()
  if not interactive_test_active() then return end
  commands.add_command("scv-test-reset", {"scv-test.command-reset-help"}, function(command)
    if command.player_index then
      game.get_player(command.player_index).teleport(SPAWN, game.surfaces[1])
    end
    build_test_lab()
    if command.player_index then
      prepare_player(game.get_player(command.player_index))
    end
    game.print({"scv-test.reset-complete"})
  end)

  commands.add_command("scv-test-home", {"scv-test.command-home-help"}, function(command)
    if command.player_index then
      prepare_player(game.get_player(command.player_index))
    end
  end)

  commands.add_command("scv-test-clear-log", {"scv-test.command-clear-log-help"}, function(command)
    if command.player_index then
      helpers.write_file("scv-control/planner.jsonl", "", false, command.player_index)
      helpers.write_file("scv-control/follower.jsonl", "", false, command.player_index)
      helpers.write_file("scv-control/live-preview.jsonl", "", false, command.player_index)
      game.get_player(command.player_index).print({"scv-test.log-cleared"})
    end
  end)
end

return test_lab
