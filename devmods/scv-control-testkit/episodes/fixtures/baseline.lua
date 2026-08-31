local Baseline = {}

local function terminal_assertion(expected)
  return {
    id = "terminal-state",
    type = "terminal-state-is",
    expected = expected
  }
end

Baseline.fixtures = {
  {
    id = "straight-arrival",
    title = "Straight arrival",
    category = "baseline",
    start = {x = -12, y = 0},
    goal = {x = 12, y = 0},
    world = {walls = {}},
    steps = {},
    expected_terminal = "arrived",
    timeout_ticks = 1200,
    assertions = {
      terminal_assertion("arrived"),
      {id = "arrival-error", type = "metric-at-most", path = "arrival_error", value = 0.5},
      {id = "route-recorded", type = "metric-at-least", path = "route_count", value = 1}
    }
  },
  {
    id = "unreachable-goal",
    title = "Unreachable goal",
    category = "baseline",
    start = {x = -12, y = 0},
    goal = {x = 8, y = 0},
    world = {
      walls = {
        {from = {x = 5, y = -4}, to = {x = 11, y = -4}},
        {from = {x = 5, y = 4}, to = {x = 11, y = 4}},
        {from = {x = 5, y = -3}, to = {x = 5, y = 3}},
        {from = {x = 11, y = -3}, to = {x = 11, y = 3}}
      }
    },
    steps = {},
    expected_terminal = "no-path",
    timeout_ticks = 1200,
    assertions = {
      terminal_assertion("no-path"),
      {id = "no-route", type = "metric-is", path = "route_count", value = 0},
      {id = "path-requested", type = "metric-at-least", path = "work.planning.requests", value = 1}
    }
  },
  {
    id = "wall-inserted-ahead",
    title = "Wall inserted ahead of moving actor",
    category = "dynamic-world-baseline",
    start = {x = -12, y = 0},
    goal = {x = 12, y = 0},
    world = {walls = {}},
    steps = {
      {
        id = "insert-blocking-wall",
        when = {type = "actor-progress-at-least", distance = 4},
        action = {
          type = "create-wall-line",
          from = {x = 0, y = -8},
          to = {x = 0, y = 8},
          obstacle = true
        }
      }
    },
    expected_terminal = "arrived",
    timeout_ticks = 1800,
    assertions = {
      terminal_assertion("arrived"),
      {id = "wall-created", type = "action-executed", action_id = "insert-blocking-wall"},
      {id = "stuck-observed", type = "metric-at-least", path = "stuck_count", value = 1},
      {id = "replan-observed", type = "metric-at-least", path = "replan_count", value = 1},
      {id = "replan-latency-recorded", type = "metric-at-least", path = "replan_latency_ticks", value = 0}
    }
  }
}

return Baseline
