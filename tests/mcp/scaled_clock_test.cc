#include "plib/gnw/scaled_clock.h"

#include <catch2/catch_test_macros.hpp>

using fallout::ScaledClock;

TEST_CASE("ScaledClock is real time until it's sped up")
{
    ScaledClock clock;

    REQUIRE(clock.factor() == 1);
    REQUIRE(clock.at(0) == 0);
    REQUIRE(clock.at(12345) == 12345);
}

TEST_CASE("ScaledClock carries on from the same time when the factor changes")
{
    ScaledClock clock;

    clock.setFactor(8, 1000);

    REQUIRE(clock.at(1000) == 1000);
    REQUIRE(clock.at(1001) == 1008);
    REQUIRE(clock.at(1500) == 1000 + 500 * 8);
}

TEST_CASE("ScaledClock changes speed again without jumping")
{
    ScaledClock clock;
    clock.setFactor(4, 0);
    unsigned int before = clock.at(100); // 400

    clock.setFactor(2, 100);

    REQUIRE(clock.at(100) == before);
    REQUIRE(clock.at(110) == before + 20);

    clock.setFactor(1, 110);
    REQUIRE(clock.at(115) == before + 25);
}

TEST_CASE("ScaledClock never runs backwards across a speed-up")
{
    ScaledClock clock;
    unsigned int last = 0;

    for (unsigned int now = 0; now < 5000; now += 7) {
        if (now == 2002) {
            clock.setFactor(16, now);
        }
        REQUIRE(clock.at(now) >= last);
        last = clock.at(now);
    }
}
