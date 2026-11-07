#include "mcp/talk_rules.h"

#include <catch2/catch_test_macros.hpp>

#include "game/proto_types.h"

using fallout::mcp_can_talk;
using fallout::McpTalker;

// A living critter with a script: offered, scripted, talk_p_proc, kind.
static McpTalker scripted(int killType, bool talkProc)
{
    return McpTalker { true, true, talkProc, killType };
}

// Issue #33: in play test 4 every rat, mole rat and radscorpion said it could
// be talked to. The cave rats' script has no talk_p_proc.
TEST_CASE("Creatures without a talk_p_proc don't answer")
{
    REQUIRE_FALSE(mcp_can_talk(scripted(fallout::KILL_TYPE_RAT, false)));
    REQUIRE_FALSE(mcp_can_talk(scripted(fallout::KILL_TYPE_RADSCORPION, false)));
    REQUIRE_FALSE(mcp_can_talk(scripted(fallout::KILL_TYPE_DOG, false)));
}

TEST_CASE("Anyone with a talk_p_proc answers")
{
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_MAN, true)));
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_CHILD, true)));
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_ROBOT, true)));
}

// Aradesh's and Tandi's scripts answer from `start`.
TEST_CASE("A scripted person answers even without a talk_p_proc")
{
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_MAN, false)));
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_WOMAN, false)));
    REQUIRE(mcp_can_talk(scripted(fallout::KILL_TYPE_GHOUL, false)));
}

TEST_CASE("Nothing answers without a script, or when the game doesn't offer Talk")
{
    McpTalker unscripted { true, false, false, fallout::KILL_TYPE_MAN };
    REQUIRE_FALSE(mcp_can_talk(unscripted));

    McpTalker dead = scripted(fallout::KILL_TYPE_MAN, true);
    dead.offered = false;
    REQUIRE_FALSE(mcp_can_talk(dead));
}
