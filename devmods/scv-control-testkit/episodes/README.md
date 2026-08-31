# NavigationEpisode TestKit Module

This directory owns the domain-neutral, headless episode state machine. The runner stores only
serializable state and resolves behavior from static services on every event.

## Fixture contract

A fixture module exports `fixtures`, an ordered array. Each fixture declares:

- stable `id`, `title`, and `category` values;
- `start`, `goal`, and initial `world` entity descriptors;
- ordered `steps` with a predicate in `when` and an `action`;
- a semantic `expected_terminal` value: `arrived`, `no-path`, or `failed`;
- assertions evaluated only after a terminal state;
- `timeout_ticks` as a deadlock guard, never a success condition.

Add domain fixture modules to `catalog.lua`. Gate and belt fixtures can use the generic entity
action or provide extension handlers through the runner services without changing `runner.lua`.

## Service contracts

Predicate services implement `evaluate(spec, context, extensions)` and return
`matched, details`. Action services implement `execute(spec, context, extensions)` and return a
serializable action result. Assertion services implement `evaluate(spec, result, extensions)` and
return a structured assertion record.

Navigation adapters implement:

```lua
adapter.issue(run, fixture, context)
adapter.handle_path_result(run, fixture, event, context)
adapter.update(run, fixture, context)
adapter.stop(run)
```

The included `episode-engine-follower-v1` adapter is an executable baseline over Factorio's engine
path request plus the production `PathSmoothing`, `Follower`, and navigation policy modules. Once
the shared `PlanningRun` and `NavigationSession` contracts land, integration replaces this adapter;
the fixture, runner, action, assertion, trace, and report contracts remain unchanged.

## Integration wiring

The standalone scenario is `scv-control-testkit/navigation-episodes`. The integration owner adds an
`episodes` suite to `tools/test.ps1`, launches that scenario with the existing hidden headless server
helper, waits for `SCV_EPISODES_COMPLETE`, validates
`script-output/scv-control/navigation-episodes.json`, and includes it after the benchmark in `all`.
Failed roots remain preserved by the existing test-runner policy.
