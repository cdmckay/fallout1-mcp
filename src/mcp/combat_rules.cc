#include "mcp/combat_rules.h"

#include "game/proto_types.h"

namespace fallout {

bool mcp_attacks_on_sight(int killType)
{
    switch (killType) {
    case KILL_TYPE_RADSCORPION:
    case KILL_TYPE_RAT:
    case KILL_TYPE_FLOATER:
    case KILL_TYPE_CENTAUR:
    case KILL_TYPE_MANTIS:
    case KILL_TYPE_DEATH_CLAW:
    case KILL_TYPE_PLANT:
        return true;
    default:
        return false;
    }
}

bool mcp_hostile(const McpHostility& critter)
{
    if (critter.dead || critter.playerTeam) {
        return false;
    }

    return critter.combatant || critter.hitByPlayerSide || mcp_attacks_on_sight(critter.killType);
}

} // namespace fallout
