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

The included `planning-run-follower-v1` adapter executes the shared `production-v1` `PlanningRun`,
then advances the accepted shared route through the production `Follower` and navigation policy.
Each episode report embeds the versioned shared route and `terminal_result` contracts as well as the
provider order and trace for every planning run.

## Integration wiring

The standalone scenario is `scv-control-testkit/navigation-episodes`. `tools/test.ps1 -Suite
episodes` launches it through a hidden headless server, waits for `SCV_EPISODES_COMPLETE`, and
validates `script-output/scv-control/navigation-episodes.json`. The `all` suite runs episodes after
the planning benchmark. Failed roots remain preserved by the existing test-runner policy.
