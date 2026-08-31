local Actions = require("episodes.actions")
local Adapter = require("episodes.adapters.engine_follower")
local Assertions = require("episodes.assertions")
local Catalog = require("episodes.catalog")
local Contracts = require("episodes.contracts")
local Predicates = require("episodes.predicates")
local Runner = require("episodes.runner")
local World = require("episodes.world")

local Runtime = {}
local STORAGE_KEY = "scv_navigation_episodes"

local services = {
  navigation = Adapter,
  predicates = Predicates,
  actions = Actions,
  assertions = Assertions
}

local function suite_state()
  return storage[STORAGE_KEY]
end

local function write_report(suite)
  if suite.finished then return end
  suite.finished = true
  local report = {
    schema_version = Contracts.SCHEMA_VERSION,
    fixture_version = Contracts.FIXTURE_VERSION,
    factorio_version = script.active_mods.base,
    mod_version = script.active_mods["factorio-scv-control"],
    testkit_version = script.active_mods["scv-control-testkit"],
    adapter_id = Adapter.ID,
    tick = game.tick,
    duration_ticks = game.tick - suite.started_tick,
    episode_count = #suite.episodes,
    passed = suite.passed,
    failed = suite.failed,
    episodes = suite.episodes
  }
  local valid, errors = Contracts.validate_report(report)
  if not valid then
    report.report_contract_errors = errors
    log("SCV_EPISODES_REPORT_CONTRACT_ERROR " .. table.concat(errors, "; "))
  end
  local json = helpers.table_to_json(report)
  helpers.write_file(Contracts.REPORT_PATH, json, false, 0)
  log("SCV_EPISODES_REPORT " .. json)
  log(Contracts.COMPLETE_MARKER
    .. " passed=" .. suite.passed
    .. " failed=" .. suite.failed)
end

local function start_next_episode(suite)
  local fixture = Catalog.list()[suite.fixture_index]
  if not fixture then
    write_report(suite)
    return
  end
  local setup_started_tick = game.tick
  local world = World.setup(fixture)
  world.setup_started_tick = setup_started_tick
  suite.active_fixture_id = fixture.id
  suite.active_run = Runner.start(fixture, world, services, game.tick)
end

local function collect_active_result(suite)
  local run = suite.active_run
  if not run or not run.result then return false end
  suite.episodes[#suite.episodes + 1] = run.result
  if run.result.passed then
    suite.passed = suite.passed + 1
  else
    suite.failed = suite.failed + 1
  end
  suite.fixture_index = suite.fixture_index + 1
  suite.active_fixture_id = nil
  suite.active_run = nil
  suite.next_fixture_tick = game.tick + 1
  return true
end

function Runtime.on_init()
  local fixtures = Catalog.list()
  local valid, errors = Contracts.validate_catalog(fixtures)
  local catalog_errors
  if not valid then catalog_errors = errors end
  storage[STORAGE_KEY] = {
    started_tick = game.tick,
    fixture_index = 1,
    next_fixture_tick = game.tick + 1,
    active_fixture_id = nil,
    active_run = nil,
    episodes = {},
    passed = 0,
    failed = 0,
    finished = false,
    catalog_errors = catalog_errors
  }
end

function Runtime.on_tick(event)
  local suite = suite_state()
  if not suite or suite.finished then return end
  if suite.catalog_errors then
    suite.failed = 1
    suite.episodes[1] = {
      id = "catalog-validation",
      passed = false,
      terminal_state = "failed",
      terminal_reason = "invalid-fixture-catalog",
      errors = suite.catalog_errors
    }
    write_report(suite)
    return
  end
  if collect_active_result(suite) then return end
  if not suite.active_run and event.tick >= suite.next_fixture_tick then
    start_next_episode(suite)
    return
  end
  if suite.active_run then
    local fixture = Catalog.get(suite.active_fixture_id)
    Runner.update(suite.active_run, fixture, services, event.tick)
  end
end

function Runtime.on_path_result(event)
  local suite = suite_state()
  if not suite or suite.finished or not suite.active_run then return end
  local fixture = Catalog.get(suite.active_fixture_id)
  Runner.handle_path_result(suite.active_run, fixture, services, event, game.tick)
end

function Runtime.register()
  remote.add_interface("scv_test_episodes", {
    active = function() return true end
  })
  script.on_init(Runtime.on_init)
  script.on_event(defines.events.on_tick, Runtime.on_tick)
  script.on_event(defines.events.on_script_path_request_finished, Runtime.on_path_result)
end

return Runtime
