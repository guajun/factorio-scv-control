local Policy = {
  path_request = {
    arrival_radius = 0.25,
    busy_retry_ticks = 30
  },
  optimization = {
    detour_ratio = 2,
    selection_epsilon = 0.01,
    alternate_lateral_fractions = {0.5, 0.75},
    alternate_min_direct_distance = 1,
    alternate_min_excursion = 2,
    alternate_snap_radius = 2,
    alternate_snap_precision = 0.25,
    alternate_dedup_distance = 0.5
  },
  smoothing = {
    sample_distance = 0.25,
    max_lookahead_waypoints = 96
  },
  grid = {
    resolution = 0.5,
    line_samples_per_cell = 2,
    max_local_nodes = 12000
  },
  follower = {
    min_waypoint_distance = 0.3,
    speed_distance_multiplier = 1.5,
    max_waypoint_recoveries = 1,
    stuck_check_interval = 30,
    stuck_distance = 0.05,
    max_stuck_retries = 3
  },
  trajectory = {
    min_cross_track_band = 0.15,
    speed_band_multiplier = 1.25,
    clearance_speed_multiplier = 0.5,
    clearance_padding = 0.05
  },
  diagnostics = {
    position_epsilon = 0.000001,
    corner_degrees = 1,
    reversal_degrees = 90
  }
}

return Policy
