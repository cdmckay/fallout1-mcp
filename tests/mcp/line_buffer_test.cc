#include "mcp/line_buffer.h"

#include <catch2/catch_test_macros.hpp>

#include <cstring>

using fallout::LineBuffer;

static int feed(LineBuffer& buffer, const char* text, std::vector<std::string>& lines)
{
    return buffer.append(text, strlen(text), lines);
}

TEST_CASE("LineBuffer splits complete lines")
{
    LineBuffer buffer(100);
    std::vector<std::string> lines;

    REQUIRE(feed(buffer, "one\ntwo\n", lines) == 0);

    REQUIRE(lines == std::vector<std::string> { "one", "two" });
}

TEST_CASE("LineBuffer holds a partial line until its newline arrives")
{
    LineBuffer buffer(100);
    std::vector<std::string> lines;

    feed(buffer, "{\"id\":", lines);
    REQUIRE(lines.empty());

    feed(buffer, "1}\n{\"id\"", lines);
    REQUIRE(lines == std::vector<std::string> { "{\"id\":1}" });

    feed(buffer, ":2}\n", lines);
    REQUIRE(lines == std::vector<std::string> { "{\"id\":1}", "{\"id\":2}" });
}

TEST_CASE("LineBuffer strips a carriage return before the newline")
{
    LineBuffer buffer(100);
    std::vector<std::string> lines;

    feed(buffer, "ping\r\n", lines);

    REQUIRE(lines == std::vector<std::string> { "ping" });
}

TEST_CASE("LineBuffer drops an over-long line whole and keeps going")
{
    LineBuffer buffer(5);
    std::vector<std::string> lines;

    // The long line arrives in two pieces; neither half may leak through.
    REQUIRE(feed(buffer, "abcdefgh", lines) == 1);
    REQUIRE(feed(buffer, "ijk\nok\n", lines) == 0);

    REQUIRE(lines == std::vector<std::string> { "ok" });
}

TEST_CASE("LineBuffer keeps a line of exactly the limit")
{
    LineBuffer buffer(5);
    std::vector<std::string> lines;

    feed(buffer, "12345\n", lines);

    REQUIRE(lines == std::vector<std::string> { "12345" });
}

TEST_CASE("LineBuffer clear discards a partial line")
{
    LineBuffer buffer(100);
    std::vector<std::string> lines;

    feed(buffer, "stale", lines);
    buffer.clear();
    feed(buffer, "fresh\n", lines);

    REQUIRE(lines == std::vector<std::string> { "fresh" });
}
