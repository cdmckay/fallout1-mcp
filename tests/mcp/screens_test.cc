#include "mcp/screens.h"

#include <catch2/catch_test_macros.hpp>

using fallout::mcp_screens;
using fallout::McpScreen;

TEST_CASE("McpScreen records a screen for as long as its scope lasts")
{
    REQUIRE(mcp_screens().empty());

    {
        McpScreen options("options");
        REQUIRE(mcp_screens() == std::vector<std::string> { "options" });

        {
            McpScreen save("save");
            REQUIRE(mcp_screens().back() == "save");
        }

        REQUIRE(mcp_screens() == std::vector<std::string> { "options" });
    }

    REQUIRE(mcp_screens().empty());
}

TEST_CASE("Popping a screen removes the innermost one of that name")
{
    fallout::mcp_screen_push("pipboy");
    fallout::mcp_screen_push("help");
    fallout::mcp_screen_push("pipboy");

    fallout::mcp_screen_pop("pipboy");
    REQUIRE(mcp_screens() == std::vector<std::string> { "pipboy", "help" });

    fallout::mcp_screen_pop("pipboy");
    REQUIRE(mcp_screens() == std::vector<std::string> { "help" });

    fallout::mcp_screen_pop("not open");
    REQUIRE(mcp_screens() == std::vector<std::string> { "help" });

    fallout::mcp_screen_pop("help");
    REQUIRE(mcp_screens().empty());
}
