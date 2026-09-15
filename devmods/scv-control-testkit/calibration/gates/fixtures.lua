-- Frozen, physical gate probes. These are calibration controls, not planner profiles.
return {
  version = 1,
  surface_seed = 82451,
  guard_ticks = 1800,
  start = {x = -12.5, y = 0.5},
  goal_x = 12.5,
  gate = {x = 0.5, y = 0.5},
  control_gate = {x = 0.5, y = 12.5},
  explicit_hold_ticks = 120,
  control_hold_ticks = 30,
  cases = {
    {id = "friendly-normal-passive", speed_modifier = 0, gate_force = "player", mode = "passive"},
    {id = "friendly-normal-explicit", speed_modifier = 0, gate_force = "player", mode = "explicit"},
    {id = "friendly-fast-passive", speed_modifier = 4, gate_force = "player", mode = "passive"},
    {id = "friendly-fast-explicit", speed_modifier = 4, gate_force = "player", mode = "explicit"},
    {id = "hostile-normal-passive", speed_modifier = 0, gate_force = "enemy", mode = "passive"},
    {id = "hostile-normal-explicit", speed_modifier = 0, gate_force = "enemy", mode = "explicit"}
  }
}
