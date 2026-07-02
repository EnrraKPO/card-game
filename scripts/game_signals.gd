extends Node

# Pure signal bus (autoload) — the intermediate layer between game data (RunData/ProfileData) and
# any UI that wants to react live. Neither side references the other: the model emits here when a
# value changes (via property setters or explicit calls), interested UI connects here and updates
# itself. No state, no logic — just the wires. See [[header-system]] for why (self-pulling header
# fields were snapshots, taken once at mount, so e.g. King HP never ticked down during a fight).

signal gold_changed(value: int)
signal hp_changed(current: int, max_hp: int)
signal act_changed(act: int)
signal relics_changed()
signal exp_changed()
