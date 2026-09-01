local Contracts = require("episodes.contracts")
local NavigationContracts = require("__factorio-scv-control__/scripts/navigation/contracts")
local Util = require("episodes.util")

local Runner = {}
local TRACE_LIMIT = 120
local SNAPSHOT_INTERVAL = 30

local function record(run, tick, event_type, details)
  run.trace_sequence = run.trace_sequence + 1
  Util.append_bounded(run.trace, {
    sequence = run.trace_sequence,
    tick = tick,
    event = event_type,
    navigation_state = run.navigation.state,
    details = details
  }, TRACE_LIMIT)
end

local function context_for(run, fixture, services, tick)
  local actor = run.navigation.actor
  return {
    run = run,
    fixture = fixture,
    actor = actor,
    surface = actor and actor.valid and actor.surface or nil,
    tick = tick,
    record = function(event_type, details)
      record(run, tick, event_type, details)
    end,
    predicate_extensions = services.predicate_extensions,
    action_extensions = services.action_extensions,
    assertion_extensions = services.assertion_extensions
  }
end

local function create_metrics()
  return {
    profile_id = false,
    source = false,
    selected_provider_id = false,
    provider_order = {},
    predicted_travel_ticks = false,
    last_predicted_travel_ticks = false,
    actual_travel_ticks = false,
    arrival_error = false,
    path_distance = false,
    action_tick = false,
    revision_tick = false,
    replan_tick = false,
    replan_latency_ticks = false,
    obstacle_distance_at_replan = false,
    route_count = 0,
    replan_count = 0,
    stuck_count = 0,
    recovery_count = 0,
    max_cross_track_error = 0,
    direction_switches = 0,
    movement_started_tick = false,
    route_predictions = {},
    work = {
      setup = {ticks = 0},
      planning = {
        runs = 0,
        requests = 0,
        results = 0,
        ticks = 0,
        run_ticks = 0,
        provider_starts = 0,
        provider_results = 0,
        postprocessors = 0,
        validators = 0,
        cost_scores = 0,
        selections = 0
      },
      following = {ticks = 0},
      predicates = {evaluations = 0},
      actions = {executed = 0},
      assertions = {evaluated = 0}
    }
  }
end

function Runner.start(fixture, world, services, tick)
  local run = {
    schema_version = Contracts.SCHEMA_VERSION,
    fixture_id = fixture.id,
    phase = "running",
    started_tick = tick,
    next_step_index = 1,
    navigation = {
      actor = world.actor,
      state = "setup",
      stuck_retries = 0
    },
    metrics = create_metrics(),
    actions = {},
    obstacle_positions = {},
    trace = {},
    trace_sequence = 0,
    result = nil
  }
  run.metrics.work.setup.ticks = tick - (world.setup_started_tick or tick)
  record(run, tick, "episode-started", {
    fixture_id = fixture.id,
    start = Util.copy_position(fixture.start),
    goal = Util.copy_position(fixture.goal)
  })
  services.navigation.issue(run, fixture, context_for(run, fixture, services, tick))
  return run
end

local function execute_ready_steps(run, fixture, services, tick)
  while true do
    local step = fixture.steps and fixture.steps[run.next_step_index]
    if not step then return end
    local context = context_for(run, fixture, services, tick)
    run.metrics.work.predicates.evaluations = run.metrics.work.predicates.evaluations + 1
    local ready, predicate_details = services.predicates.evaluate(
      step.when,
      context,
      services.predicate_extensions
    )
    if not ready then return end

    local action_result = services.actions.execute(
      step.action,
      context,
      services.action_extensions
    ) or {status = "applied"}
    local action_record = {
      id = step.id,
      type = step.action.type,
      tick = tick,
      revision_tick = action_result.revision_tick == nil
        and false
        or action_result.revision_tick,
      status = action_result.status or "applied",
      predicate = predicate_details,
      details = action_result
    }
    run.actions[#run.actions + 1] = action_record
    run.metrics.work.actions.executed = run.metrics.work.actions.executed + 1
    if run.metrics.action_tick == false then run.metrics.action_tick = tick end
    if action_record.revision_tick ~= false and run.metrics.revision_tick == false then
      run.metrics.revision_tick = action_record.revision_tick
    end
    for _, position in ipairs(action_result.obstacle_positions or {}) do
      run.obstacle_positions[#run.obstacle_positions + 1] = Util.copy_position(position)
    end
    record(run, tick, "world-action", action_record)
    run.next_step_index = run.next_step_index + 1
    if action_record.status ~= "applied" then
      run.navigation.state = "failed"
      run.navigation.terminal_reason = "world-action-failed:" .. step.id
      return
    end
  end
end

local function finalize(run, fixture, services, tick, terminal_state, terminal_reason)
  if run.result then return run.result end
  services.navigation.stop(run)
  local actor = run.navigation.actor
  local final_position = actor and actor.valid and Util.copy_position(actor.position) or false
  run.metrics.arrival_error = final_position and Util.distance(final_position, fixture.goal) or false
  run.metrics.actual_travel_ticks = run.metrics.movement_started_tick ~= false
    and tick - run.metrics.movement_started_tick
    or 0
  record(run, tick, "episode-terminal", {
    state = terminal_state,
    reason = terminal_reason,
    position = final_position
  })

  local navigation_terminal = {
    schema_version = NavigationContracts.VERSION,
    status = terminal_state,
    reason = terminal_reason or terminal_state,
    metrics = {
      schema_version = NavigationContracts.VERSION,
      values = run.metrics
    }
  }
  if run.navigation.route then navigation_terminal.route = run.navigation.route end
  local terminal_valid, terminal_error = NavigationContracts.validate(
    "terminal_result",
    navigation_terminal
  )
  local terminal_contract_error = false
  if not terminal_valid then terminal_contract_error = terminal_error end

  local result = {
    id = fixture.id,
    title = fixture.title,
    category = fixture.category,
    passed = true,
    expected_terminal = fixture.expected_terminal,
    terminal_state = terminal_state,
    terminal_reason = terminal_reason,
    started_tick = run.started_tick,
    completed_tick = tick,
    duration_ticks = tick - run.started_tick,
    start = Util.copy_position(fixture.start),
    goal = Util.copy_position(fixture.goal),
    final_position = final_position,
    profile_id = run.metrics.profile_id,
    source = run.metrics.source,
    selected_provider_id = run.metrics.selected_provider_id,
    provider_order = run.metrics.provider_order,
    metrics = run.metrics,
    actions = run.actions,
    assertions = {},
    navigation_terminal = navigation_terminal,
    terminal_contract_error = terminal_contract_error,
    planning_runs = run.navigation.planning_results or {},
    last_route = run.navigation.route or false,
    last_path = run.navigation.route and Util.copy_path(run.navigation.route.points) or {},
    last_position = final_position,
    last_action = run.actions[#run.actions] or false,
    navigation_state = run.navigation.state,
    trace = run.trace
  }
  if not terminal_valid then result.passed = false end
  for _, specification in ipairs(fixture.assertions) do
    local assertion = services.assertions.evaluate(
      specification,
      result,
      services.assertion_extensions
    )
    result.assertions[#result.assertions + 1] = assertion
    result.metrics.work.assertions.evaluated = result.metrics.work.assertions.evaluated + 1
    if not assertion.passed then result.passed = false end
  end
  if terminal_state ~= fixture.expected_terminal then result.passed = false end
  run.phase = "terminal"
  run.result = result
  return result
end

function Runner.handle_path_result(run, fixture, services, event, tick)
  if run.phase ~= "running" then return false end
  local handled = services.navigation.handle_path_result(
    run,
    fixture,
    event,
    context_for(run, fixture, services, tick)
  )
  if Contracts.TERMINAL_STATES[run.navigation.state] then
    finalize(
      run,
      fixture,
      services,
      tick,
      run.navigation.state,
      run.navigation.terminal_reason
    )
  end
  return handled
end

function Runner.update(run, fixture, services, tick)
  if run.phase ~= "running" then return run.result end
  services.navigation.update(run, fixture, context_for(run, fixture, services, tick))
  if not Contracts.TERMINAL_STATES[run.navigation.state] then
    execute_ready_steps(run, fixture, services, tick)
  end
  local actor = run.navigation.actor
  if actor and actor.valid and tick % SNAPSHOT_INTERVAL == 0 then
    record(run, tick, "navigation-snapshot", {
      position = Util.copy_position(actor.position),
      next_step_index = run.next_step_index,
      waypoint_index = run.navigation.follow_state
        and run.navigation.follow_state.waypoint_index
        or false
    })
  end
  if Contracts.TERMINAL_STATES[run.navigation.state] then
    return finalize(
      run,
      fixture,
      services,
      tick,
      run.navigation.state,
      run.navigation.terminal_reason
    )
  end
  if tick - run.started_tick > fixture.timeout_ticks then
    run.navigation.state = "failed"
    run.navigation.terminal_reason = "timeout-guard"
    return finalize(run, fixture, services, tick, "failed", "timeout-guard")
  end
  return nil
end

return Runner
