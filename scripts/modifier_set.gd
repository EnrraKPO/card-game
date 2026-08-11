class_name ModifierSet
extends RefCounted

# The run-scope effect-container collection: the aggregate of everything the run's
# containers (owned profile upgrades, run relics) contribute, with owner attribution so
# presentation can cue the contributing container (glint the right relic chip).
#
# RAZED to the shell (targeting-cleanup, 2026-08-11): the old Effect cargo and its kind
# routing were deleted with the effect layer, and the stripped content contributes nothing
# to collect. The class survives because its ROLE does — run-scope containers hold the
# rebuilt structures (TARGETING_DESIGN.md §1: relics/upgrades are plain holders; §5: their
# allegiance anchor is the player). NEEDS, for the rebuild:
#   · collection from owned upgrade nodes + run relics into one set (from_profile/for_run
#     signatures kept — every construction site already routes through them);
#   · owner attribution per held structure (the {kind, id} record) for presentation;
#   · enumeration by structure kind: passive contributions to the fold, interceptors to
#     the Resolver's gate, triggered effects to event dispatch;
#   · global registry-number contributions (GameData.value_f's total_add).


# Gathers what a profile's OWNED upgrade nodes contribute. Nothing today: upgrade content
# was stripped (the content strip, 2026-08-11) and the carrier structures don't exist yet.
static func from_profile(_profile: ProfileData) -> ModifierSet:
	return ModifierSet.new()


# The full active set for a live run: the profile's owned upgrades PLUS the run's relics.
static func for_run(profile: ProfileData, _run: RunData) -> ModifierSet:
	return from_profile(profile)


# Summed delta of all global registry-number contributions for a key. The resolver
# (GameData.value_f) adds this to the registry default. 0 is the current truth: no
# authored content exists to contribute.
func total_add(_key: String) -> float:
	return 0.0
