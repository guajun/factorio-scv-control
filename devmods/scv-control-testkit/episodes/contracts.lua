local Contracts = {}

Contracts.SCHEMA_VERSION = 1
Contracts.FIXTURE_VERSION = 1
Contracts.REPORT_PATH = "scv-control/navigation-episodes.json"
Contracts.COMPLETE_MARKER = "SCV_EPISODES_COMPLETE"
Contracts.TERMINAL_STATES = {
  arrived = true,
  ["no-path"] = true,
  failed = true
}

local function require_field(errors, value, path, expected_type)
  if type(value) ~= expected_type then
    errors[#errors + 1] = path .. " must be " .. expected_type
  end
end

function Contracts.validate_fixture(fixture)
  local errors = {}
  require_field(errors, fixture, "fixture", "table")
  if #errors > 0 then return false, errors end

  require_field(errors, fixture.id, "fixture.id", "string")
  require_field(errors, fixture.title, "fixture.title", "string")
  require_field(errors, fixture.start, "fixture.start", "table")
  require_field(errors, fixture.goal, "fixture.goal", "table")
  require_field(errors, fixture.expected_terminal, "fixture.expected_terminal", "string")
  require_field(errors, fixture.assertions, "fixture.assertions", "table")
  if fixture.expected_terminal
      and not Contracts.TERMINAL_STATES[fixture.expected_terminal] then
    errors[#errors + 1] = "fixture.expected_terminal is not a terminal state"
  end
  for index, step in ipairs(fixture.steps or {}) do
    require_field(errors, step.id, "fixture.steps[" .. index .. "].id", "string")
    require_field(errors, step.when, "fixture.steps[" .. index .. "].when", "table")
    require_field(errors, step.action, "fixture.steps[" .. index .. "].action", "table")
  end
  for index, assertion in ipairs(fixture.assertions or {}) do
    require_field(
      errors,
      assertion.id,
      "fixture.assertions[" .. index .. "].id",
      "string"
    )
    require_field(
      errors,
      assertion.type,
      "fixture.assertions[" .. index .. "].type",
      "string"
    )
  end
  return #errors == 0, errors
end

function Contracts.validate_catalog(fixtures)
  local errors = {}
  local ids = {}
  for index, fixture in ipairs(fixtures) do
    local valid, fixture_errors = Contracts.validate_fixture(fixture)
    if not valid then
      for _, message in ipairs(fixture_errors) do
        errors[#errors + 1] = "fixture[" .. index .. "]: " .. message
      end
    end
    if fixture.id and ids[fixture.id] then
      errors[#errors + 1] = "duplicate fixture id: " .. fixture.id
    end
    ids[fixture.id] = true
  end
  return #errors == 0, errors
end

function Contracts.validate_report(report)
  local errors = {}
  if report.schema_version ~= Contracts.SCHEMA_VERSION then
    errors[#errors + 1] = "unsupported report schema_version"
  end
  if report.fixture_version ~= Contracts.FIXTURE_VERSION then
    errors[#errors + 1] = "unsupported fixture_version"
  end
  if type(report.episodes) ~= "table" then
    errors[#errors + 1] = "report.episodes must be table"
  elseif report.episode_count ~= #report.episodes then
    errors[#errors + 1] = "report.episode_count does not match episodes"
  else
    for index, episode in ipairs(report.episodes) do
      local prefix = "report.episodes[" .. index .. "]"
      require_field(errors, episode.id, prefix .. ".id", "string")
      require_field(errors, episode.passed, prefix .. ".passed", "boolean")
      require_field(errors, episode.terminal_state, prefix .. ".terminal_state", "string")
      require_field(errors, episode.metrics, prefix .. ".metrics", "table")
      require_field(errors, episode.actions, prefix .. ".actions", "table")
      require_field(errors, episode.assertions, prefix .. ".assertions", "table")
      require_field(errors, episode.trace, prefix .. ".trace", "table")
      if episode.terminal_state
          and not Contracts.TERMINAL_STATES[episode.terminal_state] then
        errors[#errors + 1] = prefix .. ".terminal_state is not terminal"
      end
      if episode.last_position == nil or episode.last_route == nil
          or episode.last_action == nil or episode.navigation_state == nil then
        errors[#errors + 1] = prefix .. " is missing terminal diagnostics"
      end
    end
  end
  if type(report.passed) ~= "number" or type(report.failed) ~= "number" then
    errors[#errors + 1] = "report pass counts must be numbers"
  elseif report.passed + report.failed ~= report.episode_count then
    errors[#errors + 1] = "report pass counts do not match episode_count"
  end
  return #errors == 0, errors
end

return Contracts
