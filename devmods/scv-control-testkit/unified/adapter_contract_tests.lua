local Comparison = require('comparison.runtime')
local Savebench = require('savebench.runtime')
local PathMath = require('__factorio-scv-control__/scripts/path_math')
local Serializable = require('__factorio-scv-control__/scripts/navigation/serializable')
local Tests = {}
local function copy(value) return assert(Serializable.copy(value)) end

function Tests.run(expect)
  expect('unified.adapters-reject-ordinary-save',
    Comparison.lab_select('open-diagonal').reason == 'unified-lab-required'
    and Savebench.lab_select('same-force-normal-follower').reason == 'unified-lab-required'
    and Comparison.lab_release().reason == 'unified-lab-required'
    and Savebench.lab_release().reason == 'unified-lab-required')
  expect('unified.manual-and-recording-apis-reject-ordinary-save',
    Comparison.lab_suspend().reason == 'unified-lab-required'
    and Savebench.lab_suspend().reason == 'unified-lab-required'
    and Comparison.lab_plan_recording({}, 'grid-astar').reason == 'unified-lab-required')
  local paused, ticks = game.tick_paused, game.ticks_to_run
  local old_comparison, old_savebench = storage.scv_navigation_comparison, storage.scv_navigation_savebench
  local ordinary_surface = game.surfaces[1]
  local original_tiles = ordinary_surface.get_tile(0, 0).name
  remote.add_interface('scv_unified_lab', {active = function() return true end})
  storage.scv_navigation_comparison = {phase = 'idle', surface = ordinary_surface,
    lab_owned_surface_index = ordinary_surface.index}
  storage.scv_navigation_savebench = {phase = 'idle', lab_sequence = 1,
    lab_owned_surface_index = ordinary_surface.index,
    prepared = {surface = ordinary_surface, descriptor = {domain = 'gate-actions'}}}
  expect('unified.cleanup-rejects-ordinary-surface-even-with-forged-index',
    Comparison.lab_release().reason == 'lab-surface-not-owned'
    and Savebench.lab_release().reason == 'lab-surface-not-owned' and ordinary_surface.valid)
  storage.scv_navigation_comparison, storage.scv_navigation_savebench = nil, nil
  local static = Comparison.lab_select('open-diagonal')
  local static_state = storage.scv_navigation_comparison
  local actor, static_surface = Comparison.lab_actor(), static_state.surface
  expect('unified.static-adapter-authors-selected-scene', static.ok and actor and actor.valid
    and static.phase == 'prepared' and static.case_id == 'open-diagonal')
  local origin_hash = static.source_facts_hash
  local record = {id = static.case_id, fixture_version = static.fixture_version,
    source_facts_hash = origin_hash, source_save_sha256 = string.rep('a', 64), algorithms = {
      ['grid-astar'] = {outcome = 'complete', points = {copy(static_state.case.start), copy(static_state.case.goal)},
        predicted_distance = PathMath.distance(static_state.case.start, static_state.case.goal),
        source_snapshot_hash = 'prior-snapshot', source_query_hash = 'prior-query'}}}
  local wrong = copy(record); wrong.source_facts_hash = 'another-source'
  expect('unified.recording-rejects-other-source',
    Comparison.lab_plan_recording(wrong, 'grid-astar').reason == 'recording-source-identity-mismatch')
  local admitted = Comparison.lab_plan_recording(record, 'grid-astar')
  local evidence = Comparison.lab_result()
  expect('unified.recording-goes-through-shared-planning-run', admitted.ok and admitted.phase == 'planned'
    and admitted.planning_outcome == 'success' and evidence and evidence.reference_playback == true
    and evidence.not_fresh_solver == true and evidence.plans[1].result.profile_id == 'interchange-distance-v1'
    and evidence.plans[1].result.selected_source == 'recorded-reference-playback')
  local suspended = Comparison.lab_suspend()
  expect('unified.static-manual-mode-preserves-actor', suspended.ok and suspended.phase == 'manual'
    and Comparison.lab_actor() == actor and actor.valid)
  local reset = Comparison.lab_select('open-diagonal')
  expect('unified.static-reset-restores-facts-with-new-actor', reset.ok and not actor.valid
    and reset.source_facts_hash == origin_hash and Comparison.lab_actor().valid
    and storage.scv_navigation_comparison.surface == static_surface)
  Comparison.lab_select('tight-clearance-corridor')
  local expanded = Comparison.lab_select('open-diagonal')
  expect('unified.cross-scene-reset-restores-native-hidden-substrate', expanded.ok
    and expanded.source_facts_hash == origin_hash
    and static_surface.get_tile(24, 14).hidden_tile == 'grass-1')
  static_state = storage.scv_navigation_comparison
  local original_tile = static_surface.get_tile(0, 0).name
  static_surface.set_tiles({{name = 'grass-1', position = {0, 0}}}, true, false, false, false)
  expect('unified.recording-rejects-native-scene-edit',
    Comparison.lab_plan_recording(record, 'grid-astar').reason == 'source-facts-changed')
  static_surface.set_tiles({{name = original_tile, position = {0, 0}}}, true, false, false, false)
  local wall_scene = Comparison.lab_select('long-wall-return')
  static_state = storage.scv_navigation_comparison
  local unsafe = {id = wall_scene.case_id, fixture_version = wall_scene.fixture_version,
    source_facts_hash = wall_scene.source_facts_hash, source_save_sha256 = string.rep('a', 64), algorithms = {
      ['grid-astar'] = {outcome = 'complete', points = {copy(static_state.case.start), copy(static_state.case.goal)},
        predicted_distance = PathMath.distance(static_state.case.start, static_state.case.goal),
        source_snapshot_hash = 'prior-snapshot', source_query_hash = 'prior-query'}}}
  local rejected = Comparison.lab_plan_recording(unsafe, 'grid-astar')
  expect('unified.recorded-wall-crossing-fails-current-live-validators', rejected.ok
    and rejected.phase == 'planned' and rejected.planning_outcome == 'failed')
  Comparison.lab_release()

  local gate = Savebench.lab_select('same-force-normal-follower')
  local previous = storage.scv_navigation_savebench
  local first_surface, first_actor, sequence = previous.prepared.surface, Savebench.lab_actor(), previous.lab_sequence
  local first_surface_name = first_surface.name
  expect('unified.gate-adapter-authors-selected-scene', gate.ok and gate.state == 'prepared'
    and first_actor and first_actor.valid)
  expect('unified.domain-manual-mode-preserves-actor', Savebench.lab_suspend().state == 'manual'
    and Savebench.lab_actor() == first_actor and first_actor.valid)
  local second = Savebench.lab_select('same-force-fast-follower')
  expect('unified.gate-reset-uses-persisted-sequence-and-queues-owned-surface-removal', second.ok
    and not first_actor.valid and second.cleanup and second.cleanup.gate_surface_deletion_queued
    and second.cleanup.surface_name == first_surface_name
    and storage.scv_navigation_savebench.lab_sequence > sequence)
  local second_surface = storage.scv_navigation_savebench.prepared.surface
  local second_name = second_surface.name
  local released = Savebench.lab_release()
  expect('unified.gate-release-stops-actor-and-queues-surface-removal', released.cleanup
    and released.cleanup.gate_surface_deletion_queued and released.cleanup.surface_name == second_name
    and Savebench.lab_actor() == nil and storage.scv_navigation_savebench.phase == 'idle')
  expect('unified.scene-reset-does-not-touch-ordinary-surface', ordinary_surface.valid
    and ordinary_surface.get_tile(0, 0).name == original_tiles)
  if static_surface.valid then game.delete_surface(static_surface) end
  remote.remove_interface('scv_unified_lab')
  storage.scv_navigation_comparison, storage.scv_navigation_savebench = old_comparison, old_savebench
  game.tick_paused, game.ticks_to_run = paused, ticks
end

return Tests
