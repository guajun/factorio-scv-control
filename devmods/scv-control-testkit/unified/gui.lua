-- Presentation only. The marker-gated runtime owns events and every action;
-- this module never creates a surface, moves an actor, or changes the clock.
local Gui = {PANEL_NAME = 'scv_unified_panel'}

local domains = {static = '静态', ['gate-actions'] = '闸门', dynamic = '动态变化',
  ['belt-controller'] = '传送带'}
local phases = {idle = '待选择', prepared = '准备就绪', ready = '准备就绪',
  captured = '已捕获', planning = '规划中', planned = '规划结束', moving = '执行中',
  running = '执行中', paused = '已暂停', complete = '已结束', failed = '失败',
  rejected = '已拒绝', free = '自由右键模式', manual = '自由右键模式'}
local busy_phases = {planning = true, moving = true, running = true, preparing = true,
  loading = true, resetting = true, capturing = true, building = true}

local function panel(player)
  if not player or not player.valid then return nil end
  local element = player.gui.left[Gui.PANEL_NAME]
  return element and element.valid and element or nil
end

local function find(element, name)
  if not element or not element.valid then return nil end
  if element.name == name then return element end
  for _, child in pairs(element.children) do
    local found = find(child, name)
    if found then return found end
  end
end

local function selected(index, count)
  if count == 0 then return 0 end
  if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > count then return 1 end
  return index
end

local function label(parent, name, caption, tooltip)
  local element = parent.add({type = 'label', name = name, caption = caption or '', tooltip = tooltip})
  element.style.single_line = false
  element.style.maximal_width = 350
  return element
end

local function button(parent, name, caption, tooltip)
  return parent.add({type = 'button', name = name, caption = caption, tooltip = tooltip,
    mouse_button_filter = {'left'}})
end

local function algorithm_caption(item)
  local title = item.title or item.id
  if item.id == 'production-v1' then return {'', title, '（实时生产）'} end
  return {'', title, '（离线参考回放）'}
end

local function mode_text(view, item, algorithm)
  if view.free_mode then
    return '自由右键：仅 production-v1 实时规划。下拉框中的离线算法不会接管右键。'
  end
  if item and item.domain ~= 'static' then
    return '领域固定实验：运行保存的命令、控制器与变化序列，不受算法下拉框影响。'
  end
  if algorithm and algorithm.id ~= 'production-v1' then
    return '离线参考回放：仅适用原始起点、终点和地图；不是任意右键位置的实时 solver。'
  end
  return '静态案例：生产规划器实时生成路径，并由真实角色执行。'
end

function Gui.read(player)
  local root = panel(player)
  local cases, algorithms = find(root, 'scv_unified_case'), find(root, 'scv_unified_algorithm')
  return {selected_index = cases and cases.selected_index or 0,
    algorithm_index = algorithms and algorithms.selected_index or 0}
end

function Gui.destroy(player)
  local root = panel(player)
  if not root then return false end
  root.destroy()
  return true
end

function Gui.render(player, view)
  if not player or not player.valid then return nil end
  view = view or {}
  Gui.destroy(player)
  local frame = player.gui.left.add({type = 'frame', name = Gui.PANEL_NAME,
    caption = 'SCV · 统一测试地图', direction = 'vertical'})
  frame.style.maximal_width = 382
  local viewport = frame.add({type = 'scroll-pane', horizontal_scroll_policy = 'never', vertical_scroll_policy = 'auto'})
  viewport.style.maximal_height = math.floor(math.max(240, math.min(700, player.display_resolution.height / player.display_scale - 120)))
  local root = viewport.add({type = 'flow', direction = 'vertical'})
  label(root, 'scv_unified_intro', '选择案例 → 载入案例 → 规划 / 运行',
    '一个存档包含全部静态、闸门、动态变化和传送带案例。完成状态与是否通过验收分别显示。')
  local items = {}
  for index, item in ipairs(view.cases or {}) do
    items[index] = {'', '[', domains[item.domain] or item.domain or '案例', '] ', item.title or item.id}
  end
  local case_list = root.add({type = 'list-box', name = 'scv_unified_case', items = items,
    selected_index = selected(view.selected_index, #items),
    tooltip = '选择列表条目后点击“载入案例”。选择本身不会重置地图或改变正在执行的角色。'})
  case_list.style.width, case_list.style.height = 350, 220
  local select_row = root.add({type = 'flow', direction = 'horizontal'})
  button(select_row, 'scv_unified_select', '载入案例', '进入所选案例并恢复其测试起点；不会覆盖磁盘中的原始存档。')
  button(select_row, 'scv_unified_watch', '返回固定案例（重置）',
    '停止当前运行或自由控制，重置所选固定案例并返回观察模式；不保留当前角色位置。')
  label(root, 'scv_unified_algorithm_title', '静态案例算法')
  local algorithms = {}
  for index, item in ipairs(view.algorithms or {}) do algorithms[index] = algorithm_caption(item) end
  local algorithm_list = root.add({type = 'drop-down', name = 'scv_unified_algorithm', items = algorithms,
    selected_index = selected(view.algorithm_index, #algorithms),
    tooltip = '仅静态案例使用该选择。非生产算法是固定任务的离线参考回放；领域实验运行自己的固定方案。'})
  algorithm_list.style.width = 350
  label(root, 'scv_unified_mode', '')
  local action_row = root.add({type = 'flow', direction = 'horizontal'})
  button(action_row, 'scv_unified_plan', '规划 / 预览', '只请求路径或预览离线参考结果，不把有路径等同于角色已到达。')
  button(action_row, 'scv_unified_run', '运行', '执行当前案例直到真实终态；失败、拒绝和不可达不会自动记为通过。')
  button(action_row, 'scv_unified_pause', '暂停', '暂停当前测试的原生游戏更新；保留当前地图状态。')
  local reset_row = root.add({type = 'flow', direction = 'horizontal'})
  button(reset_row, 'scv_unified_reset', '重置案例', '停止当前运行并恢复该案例的保存状态；不会覆盖原始 ZIP。')
  button(reset_row, 'scv_unified_free', '自由右键（重置场景）',
    '重置当前场景后进入手动角色模式，仅生产规划器响应右键。再次点击也会重置；用“返回固定案例”退出。')
  root.add({type = 'line', direction = 'horizontal'})
  label(root, 'scv_unified_status', '', '状态原样来自测试运行器；“结束”本身不代表断言通过。')
  label(root, 'scv_unified_notice', '', '运行器的结果、拒绝原因或操作提示。')
  return Gui.update(player, view)
end

function Gui.update(player, view)
  local root = panel(player)
  if not root then return Gui.render(player, view) end
  view = view or {}
  local current = Gui.read(player)
  local item = (view.cases or {})[current.selected_index]
  local algorithm = (view.algorithms or {})[current.algorithm_index]
  local phase = view.phase or 'idle'
  local busy, free = busy_phases[phase] == true, view.free_mode == true
  local static = item and item.domain == 'static'
  local has_case = item ~= nil
  -- Do not overwrite pending selector changes during periodic status refresh.
  -- The runtime reads both selectors before handling a click and remains the
  -- authority on legal state transitions; these flags are only UI affordances.
  find(root, 'scv_unified_case').enabled = not busy
  find(root, 'scv_unified_algorithm').enabled = has_case and static and not free and not busy
  find(root, 'scv_unified_select').enabled = has_case and not busy
  find(root, 'scv_unified_plan').enabled = has_case and static and not free and not busy
  find(root, 'scv_unified_run').enabled = has_case and not free and not busy
  find(root, 'scv_unified_pause').enabled = busy or free
  find(root, 'scv_unified_pause').caption = view.paused and '继续' or '暂停'
  find(root, 'scv_unified_reset').enabled = has_case
  find(root, 'scv_unified_free').enabled = has_case and not busy
  find(root, 'scv_unified_free').caption = '自由右键（重置场景）'
  find(root, 'scv_unified_watch').enabled = has_case
  find(root, 'scv_unified_mode').caption = mode_text(view, item, algorithm)
  find(root, 'scv_unified_status').caption = {'', '阶段：', phases[phase] or phase,
    '\n状态：', view.status or '尚未运行；没有验收结果。'}
  local notice = find(root, 'scv_unified_notice')
  notice.caption = view.notice or ''
  notice.visible = view.notice ~= nil and view.notice ~= false and view.notice ~= ''
  return root
end

return Gui
