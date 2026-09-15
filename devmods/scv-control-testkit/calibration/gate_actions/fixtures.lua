return {
  version = 1, seed = 82451, guard_ticks = 1800,
  opening = {factorio_version = "2.0.77", prototype = "gate", opening_ticks = 16},
  cases = {
    {id = "same-force-normal-follower", speed_modifier = 0},
    {id = "same-force-fast-follower", speed_modifier = 4},
    {id = "fast-near-gate-waits-before-contact", speed_modifier = 4, start_x = -1.5},
    {id = "hostile-rejected-without-open-request", speed_modifier = 0, gate_force = "enemy", rejection = "different-force"},
    {id = "configured-circuit-rejected", speed_modifier = 0, circuit = true, rejection = "wall-control-configured"},
    {id = "gate-chain-explicitly-unsupported", speed_modifier = 0, gate_chain = true, rejection = "connected-gate-chain"},
    {id = "force-changed-during-approach", speed_modifier = 4, change = "force", invalidation = "different-force"},
    {id = "circuit-configured-during-approach", speed_modifier = 4, change = "circuit", invalidation = "wall-control-configured"},
    {id = "gate-rotated-during-approach", speed_modifier = 4, change = "rotate", invalidation = "gate-geometry-changed"},
    {id = "gate-removed-during-approach", speed_modifier = 4, change = "remove", invalidation = "gate-removed"}
  }
}
