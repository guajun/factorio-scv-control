-- Native headless lifecycle tests. GUI assertions need an actual persisted
-- LuaPlayer: Factorio 2.0.77 has no documented LuaGameScript.create_player.
-- No fake GUI/player objects and no main-menu simulation substitute for that.
local Gui = require('unified.gui')
local Static = require('comparison.runtime')
local Domains = require('savebench.runtime')

local Tests = {}

local function find(element, name)
  if not element or not element.valid then return nil end
  if element.name == name then return element end
  for _, child in pairs(element.children) do
    local found = find(child, name)
    if found then return found end
  end
end

local function characters()
  local count = 0
  for _, surface in pairs(game.surfaces) do
    count = count + surface.count_entities_filtered({type = 'character'})
  end
  return count
end

local function owns_surface(surface_index)
  local static = storage.scv_navigation_comparison
  if static and static.lab_owned_surface_index == surface_index then return true end
  local domain = storage.scv_navigation_savebench
  if domain and domain.lab_owned_surface_index == surface_index then return true end
  for _, index in pairs(domain and domain.lab_owned_surfaces or {}) do
    if index == surface_index then return true end
  end
  return false
end

function Tests.run(Lab)
  if not remote.interfaces.scv_unified_lab then
    return {ok = false, reason = 'unified-lab-save-required', assertions = {}}
  end
  for _, player in pairs(game.connected_players) do
    if player.valid then
      return {ok = false, reason = 'headless-ui-test-refuses-connected-player', assertions = {}}
    end
  end
  local result = {ok = true, assertions = {}, gui_exercised = false,
    gui_status = 'unsupported-no-native-player', native_actor_lifecycle_exercised = false,
    right_click_movement_exercised = false, scope = 'native-controller-and-GUI-lifecycle-not-connected-input-or-arrival',
    gui_unavailable_reason = 'Factorio 2.0.77 exposes no LuaGameScript.create_player; a persisted player is required.'}
  local function check(name, passed, detail)
    result.assertions[#result.assertions + 1] = {name = name, passed = passed == true, detail = detail or ''}
    return passed == true
  end
  local function require_check(name, passed, detail)
    if not check(name, passed, detail) then error('assertion-failed:' .. name, 0) end
  end
  local function dispatch(operation, fields, player_index)
    fields = fields or {}; fields.operation = operation
    local reply = Lab.dispatch(fields, player_index)
    require_check('dispatch-' .. operation, type(reply) == 'table' and reply.ok == true,
      type(reply) == 'table' and tostring(reply.reason or '') or 'no-response')
    return reply
  end
  local previous = Lab.dispatch({operation = 'status'})
  local native_player
  for _, player in pairs(game.players) do if player.valid then native_player = player; break end end
  local function click(name)
    local panel = native_player.gui.left[Gui.PANEL_NAME]
    local element = find(panel, 'scv_unified_' .. name)
    require_check('native-button-' .. name, element and element.valid and element.enabled == true)
    Lab.events[defines.events.on_gui_click]({name = defines.events.on_gui_click,
      tick = game.tick, player_index = native_player.index, element = element, button = defines.mouse_button_type.left})
    return Lab.dispatch({operation = 'status'})
  end
  local ok, reason = pcall(function()
    local catalog = dispatch('catalog')
    require_check('all-56-cases-present', #catalog.cases == 56)
    require_check('all-four-static-configurations-present', #catalog.algorithms == 4)
    local open_index, wall_index, gate_index
    for index, case in ipairs(catalog.cases) do
      if case.id == 'open-diagonal' then open_index = index end
      if case.id == 'long-wall-return' then wall_index = index end
      if case.id == 'same-force-normal-follower' then gate_index = index end
    end
    require_check('native-lifecycle-case-identities-present', open_index and wall_index and gate_index and true)
    dispatch('select', {index = open_index, algorithm_index = 1})
    local baseline_characters = characters()
    if native_player then
      result.gui_exercised, result.gui_status, result.gui_unavailable_reason = true, 'running', nil
      local panel = native_player.gui.left[Gui.PANEL_NAME]
      require_check('native-GUI-panel-created', panel and panel.valid and panel.type == 'frame')
      local case_list, algorithm_list = find(panel, 'scv_unified_case'), find(panel, 'scv_unified_algorithm')
      require_check('native-case-and-algorithm-widgets', case_list and algorithm_list
        and #case_list.items == 56 and #algorithm_list.items == 4)
      local before = dispatch('status')
      case_list.selected_index, algorithm_list.selected_index = wall_index, 2
      Gui.update(native_player, {cases = catalog.cases, algorithms = catalog.algorithms,
        selected_index = open_index, algorithm_index = 1, phase = before.phase,
        free_mode = false, status = 'native GUI pending-selection assertion'})
      local chosen, unchanged = Gui.read(native_player), dispatch('status')
      check('pending-selectors-survive-status-update', chosen.selected_index == wall_index and chosen.algorithm_index == 2)
      check('pending-selectors-do-not-reset-map', unchanged.case_id == before.case_id
        and unchanged.selection_count == before.selection_count)
      algorithm_list.selected_index = 1
      local selected = click('select')
      require_check('native-select-button-uses-pending-choice', selected.selected_index == wall_index
        and selected.algorithm_index == 1 and selected.phase == 'prepared')
    else
      dispatch('select', {index = wall_index, algorithm_index = 1})
    end
    local old_actor = Static.lab_actor()
    require_check('source-static-actor-present', old_actor and old_actor.valid)
    local running = native_player and click('run') or dispatch('run')
    check('run-requests-native-planning-or-movement', running.phase == 'planning' or running.phase == 'moving'
      or running.phase == 'planned')
    local old_run = storage.scv_navigation_comparison.planning_run
    local was_pending = old_run and old_run.status == 'running'
    if native_player then click('reset') else dispatch('reset') end
    local reset = dispatch('status')
    require_check('reset-stops-active-case', reset.phase == 'prepared' and reset.paused == true
      and reset.free_mode == false)
    check('reset-destroys-previous-static-actor', not old_actor.valid)
    if was_pending then check('reset-cancels-shared-pending-planning-run', old_run.status == 'cancelled') end
    check('static-reset-does-not-leak-characters', characters() == baseline_characters)
    result.native_actor_lifecycle_exercised = true

    dispatch('select', {index = gate_index, algorithm_index = 1})
    local gate_actor = Domains.lab_actor()
    require_check('source-gate-actor-present', gate_actor and gate_actor.valid)
    local gate_surface, gate_surface_index = gate_actor.surface, gate_actor.surface.index
    require_check('gate-surface-owned-by-lab', owns_surface(gate_surface_index))
    if native_player then
      check('player-observes-native-gate-map', native_player.surface.index == gate_surface_index
        and native_player.controller_type == defines.controllers.spectator)
      local denied = Domains.lab_release()
      check('gate-release-refuses-present-player', denied.ok == false and denied.reason == 'lab-scene-has-player')
      check('refused-gate-release-keeps-actor-intact', gate_actor.valid == true)
    end
    local gate_running = native_player and click('run') or dispatch('run')
    check('gate-run-starts-native-probe', gate_running.phase == 'running')
    if native_player then click('reset') else dispatch('reset') end
    local after_gate_reset = dispatch('status')
    check('gate-reset-returns-prepared', after_gate_reset.phase == 'prepared' and after_gate_reset.paused == true)
    check('gate-reset-destroys-old-actor', not gate_actor.valid)
    check('gate-reset-no-character-leak', characters() == baseline_characters)
    if native_player then
      local new_gate_actor = Domains.lab_actor()
      check('gate-reset-evacuates-player-before-release', native_player.surface.index == new_gate_actor.surface.index
        and native_player.surface.index ~= gate_surface_index)
      local entered = click('free')
      local manual_actor = Domains.lab_actor()
      require_check('free-mode-attaches-native-character-controller', entered.free_mode == true
        and entered.free_player_index == native_player.index
        and native_player.controller_type == defines.controllers.character)
      check('free-mode-is-production-only', entered.algorithm == 'production-v1')
      check('manual-domain-probe-is-suspended', entered.child.state == 'manual')
      -- An offline LuaPlayer.character may be nil by documented API contract.
      -- Controller type/state are tested; connected input/movement is not.
      local returned = click('watch')
      check('watch-button-returns-to-case-observation', returned.free_mode == false
        and returned.phase == 'prepared' and native_player.controller_type == defines.controllers.spectator)
      check('free-return-destroys-detached-old-actor', not manual_actor.valid)
      check('free-return-no-character-leak', characters() == baseline_characters)
      click('free')
      local before_reset_actor = Domains.lab_actor()
      local reset_free = click('reset')
      check('reset-ends-manual-controller-mode', reset_free.free_mode == false
        and native_player.controller_type == defines.controllers.spectator and not before_reset_actor.valid)
      check('manual-reset-no-character-leak', characters() == baseline_characters)
    end
    dispatch('select', {index = open_index, algorithm_index = 1})
    local released_gate_actor = Domains.lab_actor()
    check('switching-domain-removes-domain-actor', released_gate_actor == nil)
    check('case-switch-no-character-leak', characters() == baseline_characters)
    -- Surface deletion is queued by Factorio until an update; never claim the
    -- prior gate surface is already invalid while this RPC is still paused.
    result.gate_surface_deletion_scope = 'release-requested-old-actor-destroyed-native-delete-completion-not-stepped'
    if native_player then result.gui_status = 'complete' end
  end)
  if not ok then
    check('native-ui-test-completed-without-exception', false, tostring(reason))
    if result.gui_exercised then result.gui_status = 'failed' end
  end
  local restored, restore = pcall(Lab.dispatch, {operation = 'select',
    index = previous.selected_index or 5, algorithm_index = previous.algorithm_index or 1})
  check('restore-paused-prepared-case', restored and restore and restore.ok == true
    and restore.phase == 'prepared' and restore.paused == true,
    restored and type(restore) == 'table' and tostring(restore.reason or '') or tostring(restore))
  result.passed, result.failed = 0, 0
  for _, assertion in ipairs(result.assertions) do
    if assertion.passed then result.passed = result.passed + 1 else result.failed = result.failed + 1 end
  end
  result.native_assertions_passed = result.failed == 0
  -- Keep capability coverage separate from native assertion success: no-player
  -- headless runs cannot be described as GUI/controller acceptance.
  result.gui_acceptance_passed = result.gui_exercised and result.gui_status == 'complete' and result.failed == 0
  return result
end

return Tests
