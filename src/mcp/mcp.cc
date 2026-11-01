#include "mcp/mcp.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>
#include <string>
#include <vector>

#include <SDL.h>
#include <lua.hpp>

#include "mcp/bindings.h"
#include "mcp/lua_host.h"
#include "mcp/socket_server.h"
#include "plib/gnw/debug.h"
#include "plib/gnw/gnw.h"
#include "plib/gnw/input.h"
#include "plib/gnw/winmain.h"

namespace fallout {

static bool gMcpEnabled = false;
static bool gMcpOmniscient = false;

// Whether the view follows the player; FALLOUT_MCP_FOLLOW=0 turns it off.
static bool gMcpFollow = true;
static std::string gMcpScriptDir;
static std::unique_ptr<LuaHost> gMcpLua;
static SocketServer gMcpSocket;

// How deeply `mcp_tick` is nested; see `mcp_tick`.
static int gMcpDepth = 0;

// The request id of a pending `reload`, or -1. Reloading replaces the Lua
// state, so it waits until no Lua code is on the stack.
static long long gMcpReloadId = -1;

static void mcp_log(const char* format, ...)
{
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    fprintf(stderr, "[mcp] %s\n", message);
    debug_printf("[mcp] %s\n", message);
}

// Quotes `value` as a JSON string, for the few replies C++ writes itself.
static std::string json_quote(const std::string& value)
{
    std::string out = "\"";
    for (unsigned char ch : value) {
        switch (ch) {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (ch < 0x20) {
                char escaped[8];
                snprintf(escaped, sizeof(escaped), "\\u%04x", ch);
                out += escaped;
            } else {
                out += static_cast<char>(ch);
            }
        }
    }
    out += "\"";
    return out;
}

// fo.send(line): sends one protocol line to the client. Returns false when no
// client is connected.
static int fo_send(lua_State* L)
{
    size_t length;
    const char* line = luaL_checklstring(L, 1, &length);
    lua_pushboolean(L, gMcpSocket.send(std::string(line, length)));
    return 1;
}

// fo.log(message)
static int fo_log(lua_State* L)
{
    mcp_log("%s", luaL_checkstring(L, 1));
    return 0;
}

// fo.ticks(): milliseconds since the game started.
static int fo_ticks(lua_State* L)
{
    lua_pushinteger(L, static_cast<lua_Integer>(SDL_GetTicks()));
    return 1;
}

// fo.omniscient(): whether the bridge started the game in omniscient mode.
static int fo_omniscient(lua_State* L)
{
    lua_pushboolean(L, gMcpOmniscient);
    return 1;
}

// fo.turbo(): how many times faster than real time the game runs (1 normally).
static int fo_turbo(lua_State* L)
{
    lua_pushinteger(L, get_time_scale());
    return 1;
}

// fo.reload(id): reruns the Lua scripts once the current call returns, then
// answers request `id`.
static int fo_reload(lua_State* L)
{
    gMcpReloadId = luaL_checkinteger(L, 1);
    return 0;
}

static void mcp_register_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "send", fo_send },
        { "log", fo_log },
        { "ticks", fo_ticks },
        { "omniscient", fo_omniscient },
        { "turbo", fo_turbo },
        { "reload", fo_reload },
        { nullptr, nullptr },
    };

    luaL_newlib(L, functions);
    mcp_register_engine_bindings(L);
    lua_setglobal(L, "fo");
}

static void mcp_call(const char* name, const std::string* arg)
{
    std::string error;
    if (!gMcpLua->call(name, arg, error)) {
        mcp_log("lua %s failed: %s", name, error.c_str());
    }
}

// Replaces the Lua state with a fresh one running the current scripts. If the
// new scripts fail to load, the old state keeps running.
static void mcp_reload()
{
    long long id = gMcpReloadId;
    gMcpReloadId = -1;

    std::unique_ptr<LuaHost> fresh(new LuaHost());
    std::string error;
    if (!fresh->start(gMcpScriptDir, mcp_register_bindings, error)) {
        mcp_log("reload failed: %s", error.c_str());
        gMcpSocket.send("{\"id\":" + std::to_string(id) + ",\"error\":{\"message\":" + json_quote("reload failed: " + error) + "}}");
        return;
    }

    gMcpLua = std::move(fresh);
    mcp_log("reloaded %s", gMcpScriptDir.c_str());
    gMcpSocket.send("{\"id\":" + std::to_string(id) + ",\"result\":{\"reloaded\":true}}");

    if (gMcpSocket.hasClient()) {
        mcp_call("on_connect", nullptr);
    }
}

bool mcp_init()
{
    const char* socketPath = getenv("FALLOUT_MCP_SOCKET");
    if (socketPath == nullptr || *socketPath == '\0') {
        return false;
    }

    const char* scriptDir = getenv("FALLOUT_MCP_LUA");
    if (scriptDir == nullptr || *scriptDir == '\0') {
        mcp_log("FALLOUT_MCP_SOCKET is set but FALLOUT_MCP_LUA isn't; MCP stays off");
        return false;
    }

    const char* omniscient = getenv("FALLOUT_MCP_OMNISCIENT");
    gMcpOmniscient = omniscient != nullptr && strcmp(omniscient, "1") == 0;
    gMcpScriptDir = scriptDir;

    std::string error;
    gMcpLua.reset(new LuaHost());
    if (!gMcpLua->start(gMcpScriptDir, mcp_register_bindings, error)) {
        mcp_log("can't start Lua: %s", error.c_str());
        gMcpLua.reset();
        return false;
    }

    if (!gMcpSocket.listen(socketPath, error)) {
        mcp_log("%s", error.c_str());
        gMcpLua.reset();
        return false;
    }

    // Turbo mode, for development: the engine's clock runs this many times
    // faster than real time.
    const char* turbo = getenv("FALLOUT_MCP_TURBO");
    if (turbo != nullptr && *turbo != '\0') {
        int factor = atoi(turbo);
        if (factor >= 1 && factor <= 16) {
            set_time_scale(static_cast<unsigned int>(factor));
        } else {
            mcp_log("FALLOUT_MCP_TURBO must be 1 to 16, not \"%s\"; running at normal speed", turbo);
        }
    }

    const char* follow = getenv("FALLOUT_MCP_FOLLOW");
    gMcpFollow = follow == nullptr || strcmp(follow, "0") != 0;

    // What this game is for, in its window title ("FALLOUT - walking"), so
    // games running side by side can be told apart.
    const char* label = getenv("FALLOUT_MCP_TITLE");
    if (label != nullptr && *label != '\0') {
        char title[sizeof(GNW95_title)];
        snprintf(title, sizeof(title), "%s - %s", GNW95_title, label);
        win_set_minimized_title(title);
        mcp_log("window title: %s", title);
    }

    gMcpEnabled = true;
    mcp_log("%s on %s, %s mode, %ux speed%s", LUA_RELEASE, socketPath, gMcpOmniscient ? "omniscient" : "fair", get_time_scale(), gMcpFollow ? ", following the player" : "");
    return true;
}

void mcp_exit()
{
    if (!gMcpEnabled) {
        return;
    }

    gMcpEnabled = false;
    gMcpSocket.close();
    gMcpLua.reset();
}

bool mcp_is_enabled()
{
    return gMcpEnabled;
}

void mcp_tick()
{
    if (!gMcpEnabled) {
        return;
    }

    // A Lua call can open a screen whose loop calls back in here. That's
    // expected: Lua's tick handles nesting, and a deferred call that opened a
    // screen is how a waiting command gets resumed while the screen is up.
    gMcpDepth++;

    if (gMcpFollow) {
        mcp_follow_player();
    }

    std::vector<std::string> lines;
    SocketEvents events = gMcpSocket.poll(lines);

    if (events.disconnected) {
        mcp_call("on_disconnect", nullptr);
    }

    if (events.connected) {
        mcp_call("on_connect", nullptr);
    }

    if (events.dropped > 0) {
        mcp_log("dropped %d over-long request lines", events.dropped);
    }

    for (const std::string& line : lines) {
        mcp_call("on_line", &line);
    }

    mcp_call("tick", nullptr);

    gMcpDepth--;

    if (gMcpDepth == 0 && gMcpReloadId != -1) {
        mcp_reload();
    }
}

} // namespace fallout
