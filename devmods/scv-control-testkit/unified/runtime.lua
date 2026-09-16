local Static = require('comparison.runtime')
local Domains = require('savebench.runtime')
local StaticCatalog = require('comparison.catalog')
local DomainCatalog = require('savebench.catalog')
local References = require('unified.reference_paths')
local Gui = require('unified.gui')
local GuiTests = require('unified.gui_tests')
local WireJson = require('__factorio-scv-control__/scripts/navigation/wire_json')

local Lab = {PROTOCOL = 'scv-unified-lab/1'}
local function enabled() return remote.interfaces.scv_unified_lab ~= nil end
local function state() return storage.scv_unified_lab end
local function json(value) return assert(WireJson.encode(value)) end
local function error_reply(reason) return {ok = false, reason = reason, protocol = Lab.PROTOCOL} end
local function point(p) return {x = p.x, y = p.y} end
local STATIC_TITLES = {
  ['open-diagonal'] = '空地斜行', ['long-wall-return'] = '长墙：返回',
  ['long-wall-enter'] = '长墙：进入', ['narrow-corridor'] = '直线窄通道',
  ['tight-clearance-corridor'] = '紧贴净空的小道', ['u-trap'] = 'U 形陷阱',
  ['slalom'] = '交错绕墙', ['captured-slalom-return'] = '反向交错绕墙',
  ['gate-open'] = '墙体缺口（非自动闸门）', ['gate-closed'] = '缺口封闭（非自动闸门）',
  ['unreachable-box'] = '不可达目标'
}
local DOMAIN_TITLES = {
  ['same-force-normal-follower'] = '友方闸门 · 正常速度',
  ['same-force-fast-follower'] = '友方闸门 · 5 倍速度',
  ['fast-near-gate-waits-before-contact'] = '近距离高速接近 · 等待开门',
  ['hostile-rejected-without-open-request'] = '敌方闸门 · 应拒绝',
  ['configured-circuit-rejected'] = '电路控制闸门 · 应拒绝',
  ['gate-chain-explicitly-unsupported'] = '连锁闸门 · 明确不支持',
  ['force-changed-during-approach'] = '接近中变更阵营 · 应失效停止',
  ['circuit-configured-during-approach'] = '接近中添加电路 · 应失效停止',
  ['gate-rotated-during-approach'] = '接近中旋转门 · 应失效停止',
  ['gate-removed-during-approach'] = '接近中拆门 · 应失效停止',
  ['wall-built-on-remaining-route'] = '前路造墙 · 停下重算',
  ['wall-built-off-route'] = '路线外造墙 · 继续行走',
  ['wall-built-behind-actor'] = '身后造墙 · 继续行走',
  ['wall-removed-keeps-accepted-detour'] = '拆除墙体 · 保留有效绕路',
  ['forward-belt-edit-notifies-without-replan'] = '前路新增传送带 · 通知变化'
}
local function domain_title(case)
  if DOMAIN_TITLES[case.id] then return DOMAIN_TITLES[case.id] end
  local tier, direction = case.id:match('^(.+)%-([a-z]+)%-cross%-production%-follower$')
  local action = tier and '横穿 · 原 follower（横漂对照）'
  if not tier then
    local mode
    tier, direction, mode = case.id:match('^(.+)%-([a-z]+)%-([a-z]+)%-compensated$')
    action = ({cross = '横穿 · 补偿控制', with = '顺行 · 补偿控制', against = '逆行 · 补偿控制'})[mode]
  end
  if not tier or not action then return case.id end
  return (({['transport-belt'] = '黄带', ['fast-transport-belt'] = '红带', ['express-transport-belt'] = '蓝带'})[tier] or tier)
    .. '朝' .. (({east = '东', south = '南', west = '西', north = '北'})[direction] or direction) .. ' · ' .. action
end
local ALGORITHMS = {{id = 'production-v1', title = '生产方案 · 现场规划'},
  {id = 'grid-astar', title = '栅格 A* · 离线参考回放'},
  {id = 'grid-dijkstra', title = 'Dijkstra · 离线参考回放'},
  {id = 'source-polygons', title = '源多边形 · 离线参考回放'}}
local function catalog()
  local result = {}
  for _, case in ipairs(StaticCatalog.describe()) do
    result[#result + 1] = {id = case.id, domain = 'static', title = STATIC_TITLES[case.id] or case.title}
  end
  for _, case in ipairs(DomainCatalog.describe()) do
    result[#result + 1] = {id = case.id, domain = case.domain, title = domain_title(case)}
  end
  return result
end
local CASES = catalog()
local function adapter(s) return s.domain == 'static' and Static or Domains end
local function child_status(s)
  return adapter(s).dispatch({operation = 'status', protocol = s.domain == 'static' and Static.PROTOCOL or Domains.PROTOCOL})
end
local function status()
  local s = state()
  if not s then return {ok = true, protocol = Lab.PROTOCOL, phase = 'idle', cases = #CASES} end
  local child = s.case_id and child_status(s) or {}
  local gate_surfaces = 0
  for _, surface in pairs(game.surfaces) do
    if surface.name:match('^scv%-gate%-actions%-%d+$') then gate_surfaces = gate_surfaces + 1 end
  end
  return {ok = true, protocol = Lab.PROTOCOL, case_id = s.case_id or false, domain = s.domain or false,
    selected_index = s.selected_index or 5, algorithm_index = s.algorithm_index or 1,
    algorithm = ALGORITHMS[s.algorithm_index or 1].id, phase = s.free_mode and 'manual' or child.phase or child.state or 'idle',
    free_mode = s.free_mode == true, free_player_index = s.free_player_index or false,
    paused = game.tick_paused, tick = game.tick, selection_count = s.selection_count or 0,
    case_count = #CASES, reference_case_count = #References.cases, gate_surface_count = gate_surfaces,
    result = s.case_id and adapter(s).lab_result() or false,
    child = child, message = s.message or false}
end
local function view()
  local s, value = state(), status()
  local notice = value.domain == 'static'
    and '生产方案现场规划；其余三项重放已验证的固定起终点路径，不是实时外部求解。'
    or '固定领域实验：闸门动作 / 动态事件 / 带面补偿。自由右键仍使用普通生产 planner。'
  local summary = (value.case_id or '选择案例') .. '\n状态：' .. value.phase
    .. (value.paused and ' · 已暂停' or ' · 运行中')
  if value.result and value.result.native then
    local n = value.result.native
    summary = summary .. '\n结果：' .. tostring(n.outcome) .. ' · tick ' .. tostring(n.actual_travel_ticks or 0)
  elseif value.result and value.result.terminal_state then
    summary = summary .. '\n结果：' .. tostring(value.result.terminal_state)
  end
  if value.result and (value.phase == 'complete' or value.phase == 'failed') then
    summary = summary .. (value.result.passed and '\n案例断言：通过' or '\n案例断言：失败')
  end
  if s and s.message then summary = summary .. '\n' .. s.message end
  return {cases = CASES, selected_index = value.selected_index, algorithms = ALGORITHMS,
    algorithm_index = value.algorithm_index, domain = value.domain, phase = value.phase,
    free_mode = value.free_mode, paused = value.paused, status = summary, notice = notice}
end
local function refresh(rebuild)
  local model = view()
  for _, player in pairs(game.players) do
    if rebuild then Gui.render(player, model) else Gui.update(player, model) end
  end
end
local function evacuate()
  -- Teleport triggers production's existing surface-change cancellation.
  for _, player in pairs(game.players) do
    player.set_controller({type = defines.controllers.spectator})
    player.teleport({0, 0}, game.surfaces[1])
  end
end
local function watch_all()
  local s = state()
  local actor = s.case_id and adapter(s).lab_actor()
  if not actor or not actor.valid then return end
  for _, player in pairs(game.players) do
    player.set_controller({type = defines.controllers.spectator})
    player.teleport(actor.position, actor.surface)
    player.zoom = 0.8
    player.force.chart(actor.surface, {{actor.position.x - 64, actor.position.y - 48},
      {actor.position.x + 64, actor.position.y + 48}})
  end
end
local function select_case(index, algorithm_index)
  if type(index) ~= 'number' or index % 1 ~= 0 or not CASES[index] then return error_reply('unknown-case') end
  if type(algorithm_index) ~= 'number' or not ALGORITHMS[algorithm_index] then return error_reply('unknown-algorithm') end
  game.tick_paused, game.ticks_to_run = true, 0
  evacuate()
  local released = Static.lab_release()
  if not released.ok then return released end
  released = Domains.lab_release()
  if not released.ok then return released end
  local s, case = state(), CASES[index]
  s.case_id, s.domain, s.selected_index = case.id, case.domain, index
  s.algorithm_index = case.domain == 'static' and algorithm_index or 1
  s.free_mode, s.free_player_index, s.message, s.auto_run, s.last_phase = false, nil, nil, false, nil
  s.selection_count = (s.selection_count or 0) + 1
  local reply = adapter(s).lab_select(case.id)
  watch_all()
  refresh(true)
  return reply.ok and status() or reply
end
local function plan()
  local s = state()
  if s.free_mode then return error_reply('reset-required-after-free-play') end
  if s.domain ~= 'static' then return error_reply('domain-experiment-uses-run-button') end
  local current = child_status(s)
  if current.phase == 'planned' then return status() end
  if current.phase == 'complete' or current.phase == 'failed' then
    local reset = select_case(s.selected_index, s.algorithm_index)
    if not reset.ok then return reset end
    current = child_status(s)
  end
  if current.phase ~= 'prepared' then return error_reply('reset-required-before-new-plan') end
  local algorithm = ALGORITHMS[s.algorithm_index].id
  local reply
  if algorithm == 'production-v1' then
    reply = Static.dispatch({protocol = Static.PROTOCOL, operation = 'capture', include_graph = false})
    if reply.ok then reply = Static.dispatch({protocol = Static.PROTOCOL, operation = 'plan', algorithm = algorithm, pass = 'cold'}) end
  else
    local record
    for _, candidate in ipairs(References.cases) do if candidate.id == s.case_id then record = candidate end end
    if not record then return error_reply('offline-recording-not-packaged') end
    reply = Static.lab_plan_recording(record, algorithm)
  end
  refresh(false)
  return reply.ok and status() or reply
end
local function run()
  local s = state()
  if s.free_mode then return error_reply('free-mode-uses-right-click') end
  local child = child_status(s)
  local phase = child.phase or child.state
  if phase == 'complete' or phase == 'failed' then
    local reset = select_case(s.selected_index, s.algorithm_index)
    if not reset.ok then return reset end
    return run()
  end
  if phase == 'moving' or phase == 'running' or phase == 'planning' then
    game.tick_paused = false; refresh(false); return status()
  end
  if s.domain ~= 'static' then
    local reply = Domains.dispatch({operation = 'run'})
    refresh(false); return reply.ok and status() or reply
  end
  if phase == 'prepared' then
    s.auto_run = true
    local reply = plan()
    if not reply.ok then s.auto_run = false; return reply end
    if child_status(s).phase ~= 'planned' then return status() end
  end
  s.auto_run = false
  local reply = Static.dispatch({protocol = Static.PROTOCOL, operation = 'execute'})
  refresh(false); return reply.ok and status() or reply
end
local function free_play(player_index)
  local player = player_index and game.get_player(player_index)
  if not player then return error_reply('free-play-requires-real-player') end
  local s = state()
  -- Always restore the selected fixture; pending plans/old imported paths cannot
  -- keep controlling a character handed to the production input adapter.
  local selected = select_case(s.selected_index, 1)
  if not selected.ok then return selected end
  adapter(s).lab_suspend()
  local actor = adapter(s).lab_actor()
  player.set_controller({type = defines.controllers.character, character = actor})
  s.free_mode, s.free_player_index, s.auto_run = true, player.index, false
  s.message = '右键移动；Shift+右键排队；S 停止。自由测试没有固定案例通过判定。'
  game.speed, game.tick_paused = 1, false
  refresh(true)
  return status()
end
function Lab.dispatch(message, player_index)
  if not enabled() then return error_reply('unified-lab-save-required') end
  if type(message) ~= 'table' or message.protocol and message.protocol ~= Lab.PROTOCOL then return error_reply('invalid-protocol') end
  local op, s = message.operation, state()
  if op == 'catalog' then return {ok = true, cases = CASES, algorithms = ALGORITHMS, reference_case_count = #References.cases} end
  if op == 'status' then return status() end
  if op == 'test-ui' then return GuiTests.run(Lab) end
  if not s then return error_reply('not-initialized') end
  if op == 'select' then
    local index = message.index
    if message.id then for i, case in ipairs(CASES) do if case.id == message.id then index = i end end end
    return select_case(index, message.algorithm_index or s.algorithm_index or 1)
  end
  if op == 'reset' or op == 'watch' then return select_case(s.selected_index, s.algorithm_index) end
  if op == 'plan' then return plan() end
  if op == 'run' then return run() end
  if op == 'free' then return free_play(player_index) end
  if op == 'pause' then game.tick_paused = not game.tick_paused; refresh(false); return status() end
  if op == 'save' then
    if s.free_mode or not game.tick_paused or (child_status(s).phase or child_status(s).state) ~= 'prepared' then
      return error_reply('save-requires-paused-prepared-lab')
    end
    if type(message.name) ~= 'string' or not message.name:match('^[%w_-]+$') then return error_reply('invalid-save-name') end
    game.server_save(message.name)
    return {ok = true, filename = message.name .. '.zip'}
  end
  return error_reply('unknown-operation')
end
local function safe_dispatch(message, player_index)
  local ok, reply = pcall(Lab.dispatch, message, player_index)
  if not ok then reply = error_reply(tostring(reply)) end
  if not reply.ok and state() then state().message = reply.reason; refresh(false) end
  return reply
end
function Lab.on_init()
  if not enabled() then return end
  storage.scv_unified_lab = {schema_version = 1, selected_index = 5, algorithm_index = 1}
  select_case(5, 1)
end
function Lab.add_commands()
  if not enabled() then return end
  commands.add_command('scv-lab-agent', 'Headless unified lab protocol.', function(command)
    if command.player_index then return end
    local ok, message = pcall(helpers.json_to_table, command.parameter or '')
    rcon.print(json(ok and safe_dispatch(message) or error_reply('invalid-json')))
  end)
  commands.add_command('scv-lab', 'menu | run | reset | plan | free | watch | pause | status', function(command)
    if not command.player_index then return end
    local op = command.parameter or 'menu'
    if op == 'menu' then refresh(true); return end
    local reply = safe_dispatch({operation = op}, command.player_index)
    if not reply.ok then game.get_player(command.player_index).print(reply.reason) end
  end)
end
local function completed()
  if not enabled() or not state() or not state().case_id or state().free_mode then return end
  local s, child = state(), child_status(state())
  if s.auto_run and child.phase == 'planned' then run(); return end
  local phase = child.phase or child.state
  if phase ~= s.last_phase then s.last_phase = phase; refresh(false) end
  if (phase == 'moving' or phase == 'running') and game.tick % 6 == 0 then
    local actor = adapter(s).lab_actor()
    if actor and actor.valid then
      for _, player in pairs(game.connected_players) do
        if player.controller_type == defines.controllers.spectator then player.teleport(actor.position, actor.surface) end
      end
    end
  end
end
local function joined(event)
  if not enabled() then return end
  local s, player = state(), game.get_player(event.player_index)
  if s.free_mode and s.free_player_index == player.index then
    local actor = adapter(s).lab_actor()
    if actor and actor.valid then player.set_controller({type = defines.controllers.character, character = actor}) end
  else
    local actor = adapter(s).lab_actor()
    player.set_controller({type = defines.controllers.spectator})
    if actor and actor.valid then player.teleport(actor.position, actor.surface); player.zoom = 0.8 end
    if actor and actor.valid then player.force.chart(actor.surface, {{actor.position.x - 64, actor.position.y - 48},
      {actor.position.x + 64, actor.position.y + 48}}) end
  end
  Gui.render(player, view())
end
local function clicked(event)
  if not enabled() or not event.element or not event.element.valid then return end
  local op = event.element.name:match('^scv_unified_(%w+)$')
  if not op then return end
  local player = game.get_player(event.player_index)
  if op == 'select' then
    local chosen = Gui.read(player)
    safe_dispatch({operation = 'select', index = chosen.selected_index, algorithm_index = chosen.algorithm_index}, player.index)
  elseif op == 'plan' or op == 'run' then
    local chosen, s = Gui.read(player), state()
    if chosen.selected_index ~= s.selected_index or chosen.algorithm_index ~= s.algorithm_index then
      local reply = safe_dispatch({operation = 'select', index = chosen.selected_index, algorithm_index = chosen.algorithm_index}, player.index)
      if not reply.ok then return end
    end
    safe_dispatch({operation = op}, player.index)
  elseif op == 'pause' or op == 'reset' or op == 'free' or op == 'watch' then safe_dispatch({operation = op}, player.index) end
end
Lab.events = {
  [defines.events.on_gui_click] = clicked,
  [defines.events.on_gui_selection_state_changed] = function(event)
    if not enabled() or not event.element or not event.element.valid then return end
    if event.element.name == 'scv_unified_case' or event.element.name == 'scv_unified_algorithm' then
      Gui.update(game.get_player(event.player_index), view())
    end
  end,
  [defines.events.on_player_created] = joined,
  [defines.events.on_player_joined_game] = joined,
  [defines.events.on_tick] = completed,
  [defines.events.on_script_path_request_finished] = completed
}
return Lab
