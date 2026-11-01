#include "mcp/sight_rules.h"

#include <catch2/catch_test_macros.hpp>

using fallout::mcp_enough_shows;
using fallout::mcp_target_on_top;
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

TEST_CASE("A quarter of an object has to show")
{
    REQUIRE(mcp_enough_shows(100, 25));
    REQUIRE_FALSE(mcp_enough_shows(100, 24));
    REQUIRE(mcp_enough_shows(3, 1));
    REQUIRE_FALSE(mcp_enough_shows(0, 0));
}
