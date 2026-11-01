#include "mcp/message_log.h"

#include <catch2/catch_test_macros.hpp>

using fallout::MessageLog;

TEST_CASE("MessageLog numbers lines from 1 and returns what's new")
{
    MessageLog log(10);
    REQUIRE(log.latest() == 0);

    log.add("You were hit for 4 hit points.");
    log.add("You hit the Rat for 6 hit points.");

    REQUIRE(log.latest() == 2);
    auto all = log.since(0);
    REQUIRE(all.size() == 2);
    REQUIRE(all[0].first == 1);
    REQUIRE(all[0].second == "You were hit for 4 hit points.");

    auto newer = log.since(1);
    REQUIRE(newer.size() == 1);
    REQUIRE(newer[0].second == "You hit the Rat for 6 hit points.");

    REQUIRE(log.since(2).empty());
}

TEST_CASE("MessageLog keeps only the most recent lines but keeps counting")
{
    MessageLog log(2);

    log.add("one");
    log.add("two");
    log.add("three");

    auto lines = log.since(0);
    REQUIRE(lines.size() == 2);
    REQUIRE(lines[0].first == 2);
    REQUIRE(lines[1].second == "three");
    REQUIRE(log.latest() == 3);
}
