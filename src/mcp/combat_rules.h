#ifndef FALLOUT_MCP_COMBAT_RULES_H_
#define FALLOUT_MCP_COMBAT_RULES_H_

namespace fallout {

// The part of the hostility rule (mcp/attacks.h) that doesn't need the
// engine.

// What the game knows about a critter that tells whether it will attack.
struct McpHostility {
    bool dead;
    // On the player's team: a companion.
    bool playerTeam;
    // Taking part in the fight going on, rather than a bystander who hasn't
    // joined it.
    bool combatant;
    // Hit by the player or someone on their side in this fight (its
    // who_hit_me), so it fights back.
    bool hitByPlayerSide;
    // What kind of critter it is, a KILL_TYPE_*.
    int killType;
};

// Whether a player can expect the critter to attack them. It does if it's
// fighting already, or has been hit by the player's side, or if it's a
// creature that attacks on sight: rats, radscorpions and the like, which a
// player knows on sight. Outside a fight, whether people (or brahmin, dogs
// and robots) will turn on the player is up to their scripts, which the
// game doesn't show, so they aren't hostile until they join one.
bool mcp_hostile(const McpHostility& critter);

// Whether critters of kill type `killType` attack on sight.
bool mcp_attacks_on_sight(int killType);

} // namespace fallout

#endif /* FALLOUT_MCP_COMBAT_RULES_H_ */
