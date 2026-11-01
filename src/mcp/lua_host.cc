#include "mcp/lua_host.h"

#include <lua.hpp>

namespace fallout {

// Message handler for `lua_pcall`: adds a traceback to string errors.
static int traceback(lua_State* L)
{
    const char* message = lua_tostring(L, 1);
    if (message == nullptr) {
        message = luaL_tolstring(L, 1, nullptr);
    }
    luaL_traceback(L, L, message, 1);
    return 1;
}

static bool pcall_with_traceback(lua_State* L, int nargs, int nresults, std::string& error)
{
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, traceback);
    lua_insert(L, base);

    int rc = lua_pcall(L, nargs, nresults, base);
    lua_remove(L, base);

    if (rc != LUA_OK) {
        const char* message = lua_tostring(L, -1);
        error = message != nullptr ? message : "(error object is not a string)";
        lua_pop(L, 1);
        return false;
    }

    return true;
}

LuaHost::LuaHost()
    : _state(nullptr)
    , _moduleRef(LUA_NOREF)
{
}

LuaHost::~LuaHost()
{
    stop();
}

bool LuaHost::start(const std::string& scriptDir, RegisterBindings* registerBindings, std::string& error)
{
    stop();

    lua_State* L = luaL_newstate();
    if (L == nullptr) {
        error = "can't create a Lua state";
        return false;
    }

    luaL_openlibs(L);

    if (registerBindings != nullptr) {
        registerBindings(L);
    }

    // `require("a.b")` resolves to scriptDir/a/b.lua or scriptDir/a/b/init.lua.
    lua_getglobal(L, "package");
    std::string path = scriptDir + "/?.lua;" + scriptDir + "/?/init.lua";
    lua_pushstring(L, path.c_str());
    lua_setfield(L, -2, "path");
    lua_pushstring(L, "");
    lua_setfield(L, -2, "cpath");
    lua_pop(L, 1);

    std::string entry = scriptDir + "/main.lua";
    if (luaL_loadfile(L, entry.c_str()) != LUA_OK) {
        error = lua_tostring(L, -1);
        lua_close(L);
        return false;
    }

    if (!pcall_with_traceback(L, 0, 1, error)) {
        lua_close(L);
        return false;
    }

    if (!lua_istable(L, -1)) {
        error = entry + " must return a table";
        lua_close(L);
        return false;
    }

    _moduleRef = luaL_ref(L, LUA_REGISTRYINDEX);
    _state = L;
    return true;
}

void LuaHost::stop()
{
    if (_state != nullptr) {
        lua_close(_state);
        _state = nullptr;
    }
    _moduleRef = LUA_NOREF;
}

bool LuaHost::isRunning() const
{
    return _state != nullptr;
}

bool LuaHost::call(const char* name, const std::string* arg, std::string& error)
{
    if (_state == nullptr) {
        error = "Lua isn't running";
        return false;
    }

    lua_State* L = _state;
    lua_rawgeti(L, LUA_REGISTRYINDEX, _moduleRef);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);

    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        return true;
    }

    int nargs = 0;
    if (arg != nullptr) {
        lua_pushlstring(L, arg->data(), arg->size());
        nargs = 1;
    }

    return pcall_with_traceback(L, nargs, 0, error);
}

lua_State* LuaHost::state() const
{
    return _state;
}

} // namespace fallout
