# Native belt calibration v1

This measures an unassociated real `character` using native `walking_state` on
grass-1. It does not implement a planner, follower adapter or production cost.

`tools/navigation/calibrate.py --domain belts` launches the headless scenario
twice with seed 424242 and compares every case assertion, metric and per-tick
sample. Default automation never launches a GUI. Enabled mods are base, SCV
Control and TestKit; DLC is explicitly disabled for this calibration profile.

## Fixed cases

The first eight cases measure unobstructed ground motion in native directions
0, 2, 4, 6, 8, 10, 12 and 14. The following 48 cases combine three belt tiers,
four cardinal belt directions and commands with/against/across/diagonally to
the belt. The same native direction's measured ground displacement is the
control, not its prototype running speed.

Each belt case creates 576 real belts centered at `(x+0.5,y+0.5)`, integer
`x,y=-12..11`. A newly created unarmored character starts at `(0.5,0.5)`;
the measured interval starts with its first native walking command. Passive
movement before that command is reflected in the recorded start position.
The terminal condition is six tiles of progress along the command direction.
Leaving the known uniform field or exceeding 1,200 ticks fails; elapsed time
never establishes success. Game speed 8 accelerates wall-clock execution only.

The versioned `scv-control/calibration/belts.json` contains raw per-tick
positions/displacement, actual ticks/distance, cross-track drift, directions,
prototype belt speed, measured ground control, measured belt effect, and the
residual against a simple additive prototype-speed model. That residual is
measurement output, not a fitted production rule. Native 1/256-tile resolution
bounds the direction/effect assertions.

## Limitations

No belt immunity equipment is installed; absence is an input condition, not a
calibration of immunity behavior. No entry/exit transition, turning belt,
splitter, follower correction, favorable detour search, circuit control,
mid-route build/remove/rotate, armor, exoskeleton or GUI-player equivalence is
claimed. These remain in issue #10 before cost-model integration in issue #2.
Consumers must match engine/mod versions, actor configuration, surface and
field semantics; the distributable mod must not require generated artifacts.

Repeated deterministic measurements do not prove a globally valid motion law.
The next experiments must cover controller feasibility and changing fields.
