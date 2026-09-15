-- One deliberately conservative eligibility rule for the calibrated gate slice.
-- This module describes a conditional transition; it never overrides collision.
local Semantics = {}

local function denied(reason)
  return {status = "unsupported", traversable = false, reason = reason}
end

function Semantics.classify(gate, actor)
  if not gate or not gate.valid then return denied("gate-removed") end
  if gate.type ~= "gate" then return denied("not-a-gate") end
  if not actor or not actor.valid or actor.type ~= "character" then return denied("unsupported-actor") end
  if gate.surface.index ~= actor.surface.index then return denied("different-surface") end
  if gate.force.index ~= actor.force.index then
    return {status = "blocked", traversable = false, reason = "different-force"}
  end
  -- Gate control lives on a neighbouring wall. A gate chain can relay control
  -- from a remote wall; v1 rejects chains rather than assuming the first cell is
  -- independent or scanning an unbounded wall network every movement tick.
  for _, neighbour in pairs(gate.neighbours or {}) do
    -- In 2.0.77 the gate itself appears as the two perpendicular neighbours.
    if neighbour ~= gate then
      if not neighbour.valid then return denied("unknown-neighbour") end
      if neighbour.type == "gate" then return denied("connected-gate-chain") end
      if neighbour.type ~= "wall" then return denied("unknown-neighbour") end
      if neighbour.get_control_behavior() then return denied("wall-control-configured") end
    end
  end
  local state = gate.is_opened() and "opened" or gate.is_opening() and "opening"
    or gate.is_closed() and "closed" or gate.is_closing() and "closing" or "unknown"
  if state == "unknown" then return denied("unknown-gate-state") end
  return {status = "conditional", traversable = true, condition = "same-force-automatic-gate",
    gate_state = state, dependency = {kind = "gate", unit_number = gate.unit_number},
    action = {type = "request-gate-open", unit_number = gate.unit_number},
    revision_kind = "transient"}
end

return Semantics
