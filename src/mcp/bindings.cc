#include "mcp/bindings.h"

#include <string>
#include <vector>

#include <SDL.h>
#include <lua.hpp>

#include "game/combat.h"
#include "game/critter.h"
#include "game/editor.h"
#include "game/gdialog.h"
#include "game/main.h"
#include "game/mainmenu.h"
#include "game/map.h"
#include "game/object.h"
#include "game/scripts.h"
#include "game/select.h"
#include "game/stat.h"
#include "game/worldmap.h"
#include "int/movie.h"
#include "mcp/png.h"
#include "plib/gnw/input.h"
#include "plib/gnw/svga.h"

namespace fallout {

static void set_bool(lua_State* L, const char* key, bool value)
{
    lua_pushboolean(L, value);
    lua_setfield(L, -2, key);
}

static void set_int(lua_State* L, const char* key, lua_Integer value)
{
    lua_pushinteger(L, value);
    lua_setfield(L, -2, key);
}

static void set_string(lua_State* L, const char* key, const char* value)
{
    if (value != nullptr) {
        lua_pushstring(L, value);
        lua_setfield(L, -2, key);
    }
}

// fo.window_focused(): whether the game window has keyboard focus. With MCP
// on, the game keeps running either way.
static int fo_window_focused(lua_State* L)
{
    bool focused = gSdlWindow != nullptr && (SDL_GetWindowFlags(gSdlWindow) & SDL_WINDOW_INPUT_FOCUS) != 0;
    lua_pushboolean(L, focused);
    return 1;
}

// fo.flags(): the raw "which screen is up" flags. lua/mcp/state.lua turns
// them into a mode, since several can be set at once.
static int fo_flags(lua_State* L)
{
    lua_createtable(L, 0, 8);
    set_bool(L, "movie", moviePlaying() != 0);
    set_bool(L, "main_menu", in_main_menu);
    set_bool(L, "character_select", select_window_id != -1);
    set_bool(L, "character_editor", editor_is_open());
    set_bool(L, "in_game", main_game_is_running());
    set_bool(L, "world_map", world_map_is_open());
    set_bool(L, "dialog", dialog_active());
    set_bool(L, "combat", isInCombat());
    return 1;
}

// fo.player(): what the player sees of their own character and situation, or
// nil when no game is in progress.
static int fo_player(lua_State* L)
{
    if (!main_game_is_running() || obj_dude == nullptr) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 8);
    set_string(L, "name", critter_name(obj_dude));
    set_int(L, "level", stat_pc_get(PC_STAT_LEVEL));
    set_int(L, "hp", stat_level(obj_dude, STAT_CURRENT_HIT_POINTS));
    set_int(L, "max_hp", stat_level(obj_dude, STAT_MAXIMUM_HIT_POINTS));
    set_int(L, "tile", obj_dude->tile);
    set_int(L, "elevation", obj_dude->elevation);

    lua_createtable(L, 0, 2);
    set_string(L, "file", map_data.name);
    set_string(L, "name", map_get_description());
    lua_setfield(L, -2, "map");

    int month;
    int day;
    int year;
    game_time_date(&month, &day, &year);
    lua_createtable(L, 0, 4);
    set_int(L, "year", year);
    set_int(L, "month", month);
    set_int(L, "day", day);
    set_string(L, "time", game_time_hour_str());
    lua_setfield(L, -2, "date");

    return 1;
}

// fo.screenshot(): the current frame as a base64 PNG, plus its width and
// height. The frame is the game's logical resolution whatever the window's
// scale, and the coordinates match the game's own.
static int fo_screenshot(lua_State* L)
{
    std::vector<unsigned char> png;
    if (!mcp_encode_png(gSdlTextureSurface, png)) {
        return luaL_error(L, "can't capture the screen: %s", SDL_GetError());
    }

    std::string encoded = mcp_base64(png.data(), png.size());
    lua_pushlstring(L, encoded.data(), encoded.size());
    lua_pushinteger(L, gSdlTextureSurface->w);
    lua_pushinteger(L, gSdlTextureSurface->h);
    return 3;
}

// fo.inject(code): queues a key or button event code for the screen in front,
// as if the player had pressed it. Returns false if the queue is full.
static int fo_inject(lua_State* L)
{
    lua_Integer code = luaL_checkinteger(L, 1);
    if (input_buffer_is_full()) {
        lua_pushboolean(L, false);
        return 1;
    }

    GNW_add_input_buffer(static_cast<int>(code));
    lua_pushboolean(L, true);
    return 1;
}

// fo.input_pending(): whether injected input is still waiting to be read.
static int fo_input_pending(lua_State* L)
{
    lua_pushboolean(L, !input_buffer_is_empty());
    return 1;
}

void mcp_register_engine_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "window_focused", fo_window_focused },
        { "flags", fo_flags },
        { "player", fo_player },
        { "screenshot", fo_screenshot },
        { "inject", fo_inject },
        { "input_pending", fo_input_pending },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
