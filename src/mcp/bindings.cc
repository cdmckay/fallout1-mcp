#include "mcp/bindings.h"

#include <SDL.h>
#include <lua.hpp>

#include "plib/gnw/svga.h"

namespace fallout {

// fo.window_focused(): whether the game window has keyboard focus. With MCP
// on, the game keeps running either way.
static int fo_window_focused(lua_State* L)
{
    bool focused = gSdlWindow != nullptr && (SDL_GetWindowFlags(gSdlWindow) & SDL_WINDOW_INPUT_FOCUS) != 0;
    lua_pushboolean(L, focused);
    return 1;
}

void mcp_register_engine_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "window_focused", fo_window_focused },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
