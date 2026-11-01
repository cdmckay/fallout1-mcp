#include "mcp/lua_host.h"

#include <catch2/catch_test_macros.hpp>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <string>
#include <vector>

#include <lua.hpp>

using fallout::LuaHost;

namespace {

// What the fake bindings saw.
std::vector<std::string> sent;
long long reloadId = -1;

int fake_send(lua_State* L)
{
    sent.push_back(luaL_checkstring(L, 1));
    lua_pushboolean(L, 1);
    return 1;
}

int fake_log(lua_State* L)
{
    return 0;
}

int fake_ticks(lua_State* L)
{
    lua_pushinteger(L, 0);
    return 1;
}

int fake_omniscient(lua_State* L)
{
    lua_pushboolean(L, 0);
    return 1;
}

int fake_reload(lua_State* L)
{
    reloadId = luaL_checkinteger(L, 1);
    return 0;
}

int fake_window_focused(lua_State* L)
{
    lua_pushboolean(L, 0);
    return 1;
}

int fake_turbo(lua_State* L)
{
    lua_pushinteger(L, 1);
    return 1;
}

// The `fo` table the engine installs, with fakes for the engine state.
void register_fake_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "send", fake_send },
        { "log", fake_log },
        { "ticks", fake_ticks },
        { "omniscient", fake_omniscient },
        { "reload", fake_reload },
        { "window_focused", fake_window_focused },
        { "turbo", fake_turbo },
        { nullptr, nullptr },
    };
    luaL_newlib(L, functions);
    lua_setglobal(L, "fo");
}

// A directory holding one main.lua with the given source.
struct ScriptDir {
    std::string path;

    explicit ScriptDir(const std::string& source)
    {
        char pattern[] = "/tmp/fo-lua-XXXXXX";
        REQUIRE(mkdtemp(pattern) != nullptr);
        path = pattern;

        FILE* file = fopen((path + "/main.lua").c_str(), "w");
        REQUIRE(file != nullptr);
        fputs(source.c_str(), file);
        fclose(file);
    }

    ~ScriptDir()
    {
        unlink((path + "/main.lua").c_str());
        rmdir(path.c_str());
    }
};

} // namespace

TEST_CASE("LuaHost runs the real scripts and answers a list request")
{
    sent.clear();
    LuaHost host;
    std::string error;

    REQUIRE(host.start(MCP_LUA_DIR, register_fake_bindings, error));
    INFO(error);

    std::string request = "{\"id\":1,\"op\":\"list\"}";
    REQUIRE(host.call("on_line", &request, error));

    REQUIRE(sent.size() == 1);
    REQUIRE(sent[0].find("\"id\":1") != std::string::npos);
    REQUIRE(sent[0].find("\"name\":\"ping\"") != std::string::npos);
}

TEST_CASE("LuaHost runs a ping through the real scheduler")
{
    sent.clear();
    LuaHost host;
    std::string error;
    REQUIRE(host.start(MCP_LUA_DIR, register_fake_bindings, error));

    std::string request = "{\"id\":2,\"op\":\"call\",\"tool\":\"ping\",\"args\":{}}";
    REQUIRE(host.call("on_line", &request, error));
    REQUIRE(sent.empty());

    REQUIRE(host.call("tick", nullptr, error));

    REQUIRE(sent.size() == 1);
    REQUIRE(sent[0].find("\"id\":2") != std::string::npos);
    REQUIRE(sent[0].find("pong") != std::string::npos);
}

TEST_CASE("LuaHost reports a missing entry script")
{
    LuaHost host;
    std::string error;

    REQUIRE_FALSE(host.start("/nonexistent", register_fake_bindings, error));
    REQUIRE(error.find("main.lua") != std::string::npos);
    REQUIRE_FALSE(host.isRunning());
}

TEST_CASE("LuaHost requires the entry script to return a table")
{
    ScriptDir dir("return 42\n");
    LuaHost host;
    std::string error;

    REQUIRE_FALSE(host.start(dir.path, register_fake_bindings, error));
    REQUIRE(error.find("must return a table") != std::string::npos);
}

TEST_CASE("LuaHost reports an error in the entry script with a traceback")
{
    ScriptDir dir("local t = nil\nreturn t.x\n");
    LuaHost host;
    std::string error;

    REQUIRE_FALSE(host.start(dir.path, register_fake_bindings, error));
    REQUIRE(error.find("attempt to index") != std::string::npos);
    REQUIRE(error.find("stack traceback") != std::string::npos);
}

TEST_CASE("LuaHost call ignores functions the module doesn't define")
{
    ScriptDir dir("return {}\n");
    LuaHost host;
    std::string error;
    REQUIRE(host.start(dir.path, register_fake_bindings, error));

    REQUIRE(host.call("on_connect", nullptr, error));
}

TEST_CASE("LuaHost call reports a raised error and stays usable")
{
    ScriptDir dir(
        "local m = {}\n"
        "function m.boom() error('kaboom') end\n"
        "function m.fine(x) fo.send('got ' .. x) end\n"
        "return m\n");
    sent.clear();
    LuaHost host;
    std::string error;
    REQUIRE(host.start(dir.path, register_fake_bindings, error));

    REQUIRE_FALSE(host.call("boom", nullptr, error));
    REQUIRE(error.find("kaboom") != std::string::npos);
    REQUIRE(error.find("stack traceback") != std::string::npos);

    std::string arg = "this";
    REQUIRE(host.call("fine", &arg, error));
    REQUIRE(sent == std::vector<std::string> { "got this" });
}

TEST_CASE("LuaHost leaves C modules unloadable")
{
    ScriptDir dir("return { cpath = package.cpath }\n");
    LuaHost host;
    std::string error;
    REQUIRE(host.start(dir.path, register_fake_bindings, error));

    lua_State* L = host.state();
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "cpath");
    REQUIRE(std::string(lua_tostring(L, -1)).empty());
    lua_pop(L, 2);
}
