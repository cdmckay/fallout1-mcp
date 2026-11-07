#include "mcp/sight_rules.h"

#include <catch2/catch_test_macros.hpp>

using fallout::mcp_enough_shows;
using fallout::mcp_ground_hidden;
using fallout::mcp_target_on_top;
using fallout::McpCover;
using fallout::McpLayer;

static const McpLayer kTarget { true, false, false };
static const McpLayer kWall { false, false, false };
static const McpLayer kFloorItem { false, true, false };
static const McpLayer kWallInEgg { false, false, true };

TEST_CASE("The target shows when nothing is drawn after it")
{
    REQUIRE(mcp_target_on_top({ kTarget }));
    REQUIRE(mcp_target_on_top({ kWall, kTarget }));
}

TEST_CASE("Something drawn after the target hides it")
{
    REQUIRE_FALSE(mcp_target_on_top({ kTarget, kWall }));
    REQUIRE_FALSE(mcp_target_on_top({}));
    REQUIRE_FALSE(mcp_target_on_top({ kWall }));
}

TEST_CASE("Flat objects are drawn before everything else, whatever the order")
{
    // A rat standing on an item listed after it still shows.
    REQUIRE(mcp_target_on_top({ kTarget, kFloorItem }));

    // A flat item under a rock wall listed before it doesn't.
    McpLayer flatTarget { true, true, false };
    REQUIRE_FALSE(mcp_target_on_top({ kWall, flatTarget }));
    REQUIRE(mcp_target_on_top({ kFloorItem, flatTarget }));
    REQUIRE_FALSE(mcp_target_on_top({ flatTarget, kFloorItem }));
}

TEST_CASE("What's behind a see-through wall or translucent thing shows")
{
    REQUIRE(mcp_target_on_top({ kTarget, kWallInEgg }));

    // A translucent target is still seen.
    McpLayer ghost { true, false, true };
    REQUIRE(mcp_target_on_top({ ghost }));
    REQUIRE_FALSE(mcp_target_on_top({ ghost, kWall }));
}

TEST_CASE("Something solid standing in front of a hex hides it")
{
    // A building's front wall, drawn over the floor inside it.
    McpCover frontWall { true, false, false, true };
    REQUIRE(mcp_ground_hidden({ frontWall }));
    REQUIRE(mcp_ground_hidden({ McpCover { false, false, false, true }, frontWall }));
    REQUIRE_FALSE(mcp_ground_hidden({}));
}

TEST_CASE("What stands behind a hex, or on it, doesn't hide it")
{
    // The rubble at a rock face's foot spills onto the floor in front of it.
    REQUIRE_FALSE(mcp_ground_hidden({ McpCover { true, false, false, false } }));
}

TEST_CASE("Critters, flat things and see-through walls don't hide the ground")
{
    // A critter, or brush the player walks through.
    REQUIRE_FALSE(mcp_ground_hidden({ McpCover { false, false, false, true } }));
    // Something lying flat.
    REQUIRE_FALSE(mcp_ground_hidden({ McpCover { true, true, false, true } }));
    // A wall the egg cuts away around the player, or a translucent one.
    REQUIRE_FALSE(mcp_ground_hidden({ McpCover { true, false, true, true } }));
}

TEST_CASE("A quarter of an object has to show")
{
    REQUIRE(mcp_enough_shows(100, 25));
    REQUIRE_FALSE(mcp_enough_shows(100, 24));
    REQUIRE(mcp_enough_shows(3, 1));
    REQUIRE_FALSE(mcp_enough_shows(0, 0));
}
