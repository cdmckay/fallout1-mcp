#ifndef FALLOUT_MCP_LUA_FIELDS_H_
#define FALLOUT_MCP_LUA_FIELDS_H_

#include <lua.hpp>

namespace fallout {

// Setters for a field of the table on top of the Lua stack, for the bindings.

inline void set_bool(lua_State* L, const char* key, bool value)
{
    lua_pushboolean(L, value);
    lua_setfield(L, -2, key);
}

inline void set_int(lua_State* L, const char* key, lua_Integer value)
{
    lua_pushinteger(L, value);
    lua_setfield(L, -2, key);
}

// Leaves the field unset when `value` is null.
inline void set_string(lua_State* L, const char* key, const char* value)
{
    if (value != nullptr) {
        lua_pushstring(L, value);
        lua_setfield(L, -2, key);
    }
}

} // namespace fallout

#endif /* FALLOUT_MCP_LUA_FIELDS_H_ */
