#include "mcp/combat_rules.h"

#include <catch2/catch_test_macros.hpp>

#include "game/proto_types.h"

using fallout::mcp_hostile;
using fallout::McpHostility;

// A critter at peace, outside any fight: dead, team, combatant, hit, kind.
static McpHostility peaceful(int killType)
{
    return McpHostility { false, false, false, false, killType };
}

TEST_CASE("Creatures that attack on sight are hostile before any fight")
{
    REQUIRE(mcp_hostile(peaceful(fallout::KILL_TYPE_RAT)));
    REQUIRE(mcp_hostile(peaceful(fallout::KILL_TYPE_RADSCORPION)));
    REQUIRE(mcp_hostile(peaceful(fallout::KILL_TYPE_DEATH_CLAW)));
}

TEST_CASE("People, brahmin and dogs aren't hostile until they fight")
{
    REQUIRE_FALSE(mcp_hostile(peaceful(fallout::KILL_TYPE_MAN)));
    REQUIRE_FALSE(mcp_hostile(peaceful(fallout::KILL_TYPE_BRAHMIN)));
    REQUIRE_FALSE(mcp_hostile(peaceful(fallout::KILL_TYPE_DOG)));

    McpHostility fighting = peaceful(fallout::KILL_TYPE_MAN);
    fighting.combatant = true;
    REQUIRE(mcp_hostile(fighting));

    McpHostility hit = peaceful(fallout::KILL_TYPE_WOMAN);
    hit.hitByPlayerSide = true;
    REQUIRE(mcp_hostile(hit));
}

TEST_CASE("Companions and the dead are never hostile")
{
    McpHostility companion = peaceful(fallout::KILL_TYPE_DOG);
    companion.playerTeam = true;
    companion.combatant = true;
    REQUIRE_FALSE(mcp_hostile(companion));

    McpHostility dead = peaceful(fallout::KILL_TYPE_RAT);
    dead.dead = true;
    REQUIRE_FALSE(mcp_hostile(dead));
}
