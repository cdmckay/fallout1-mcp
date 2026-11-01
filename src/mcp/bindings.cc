#include "mcp/bindings.h"

#include <string>
#include <vector>

#include <SDL.h>
#include <lua.hpp>

#include "game/anim.h"
#include "game/combat.h"
#include "game/config.h"
#include "game/critter.h"
#include "game/editor.h"
#include "game/gconfig.h"
#include "game/gdialog.h"
#include "game/main.h"
#include "game/mainmenu.h"
#include "game/map.h"
#include "game/object.h"
#include "game/perk.h"
#include "game/proto_types.h"
#include "game/scripts.h"
#include "game/select.h"
#include "game/stat.h"
#include "game/tile.h"
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

static bool in_game()
{
    return main_game_is_running() && obj_dude != nullptr;
}

static int check_tile(lua_State* L, int index)
{
    lua_Integer tile = luaL_checkinteger(L, index);
    luaL_argcheck(L, tile >= 0 && tile < HEX_GRID_SIZE, index, "not a tile on the map");
    return static_cast<int>(tile);
}

// fo.walk_to(tile, run): sets the player walking (or running) to `tile`, as a
// click on the ground does in move mode (`dude_move` and `dude_run`, without
// the mouse). In combat it spends AP, including the free move. Returns whether
// the engine took the request.
static int fo_walk_to(lua_State* L)
{
    int tile = check_tile(L, 1);
    bool run = lua_toboolean(L, 2) != 0;

    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int actionPoints = -1;
    if (isInCombat()) {
        actionPoints = combat_free_move + obj_dude->data.critter.combat.ap;
    } else {
        bool interruptWalk;
        configGetBool(&game_config, GAME_CONFIG_SYSTEM_KEY, GAME_CONFIG_INTERRUPT_WALK_KEY, &interruptWalk);
        if (interruptWalk) {
            register_clear(obj_dude);
        }
    }

    if (run && !perk_level(PERK_SILENT_RUNNING)) {
        pc_flag_off(PC_FLAG_SNEAKING);
    }

    register_begin(ANIMATION_REQUEST_RESERVED);
    if (run) {
        register_object_run_to_tile(obj_dude, tile, obj_dude->elevation, actionPoints, 0);
    } else {
        register_object_move_to_tile(obj_dude, tile, obj_dude->elevation, actionPoints, 0);
    }
    lua_pushboolean(L, register_end() == 0);
    return 1;
}

// fo.path_length(tile): hexes on the player's path to `tile`, 0 when there's
// no way there, as the game's own hover check computes it.
static int fo_path_length(lua_State* L)
{
    int tile = check_tile(L, 1);
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }
    lua_pushinteger(L, make_path(obj_dude, obj_dude->tile, tile, nullptr, 0));
    return 1;
}

// fo.player_busy(): whether the player is still animating (walking, using
// something), i.e. hasn't finished the last action.
static int fo_player_busy(lua_State* L)
{
    lua_pushboolean(L, in_game() && anim_busy(obj_dude) != 0);
    return 1;
}

// fo.tile_at(x, y): the tile under screen point (x, y) on the player's
// elevation, in the same coordinates as screenshots, or nil.
static int fo_tile_at(lua_State* L)
{
    int x = static_cast<int>(luaL_checkinteger(L, 1));
    int y = static_cast<int>(luaL_checkinteger(L, 2));
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int tile = tile_num(x, y, obj_dude->elevation);
    if (tile == -1) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, tile);
    }
    return 1;
}

// fo.tile_toward(tile, rotation, distance): the tile `distance` hexes from
// `tile` in direction `rotation` (0 NE, 1 E, 2 SE, 3 SW, 4 W, 5 NW).
static int fo_tile_toward(lua_State* L)
{
    int tile = check_tile(L, 1);
    lua_Integer rotation = luaL_checkinteger(L, 2);
    lua_Integer distance = luaL_checkinteger(L, 3);
    luaL_argcheck(L, rotation >= 0 && rotation < ROTATION_COUNT, 2, "rotation must be 0 to 5");
    luaL_argcheck(L, distance >= 0 && distance <= 200, 3, "distance must be 0 to 200");

    lua_pushinteger(L, tile_num_in_direction(tile, static_cast<int>(rotation), static_cast<int>(distance)));
    return 1;
}

// fo.tile_center(tile): the screen point at the middle of `tile` on the
// player's elevation, or nil when it's off screen.
static int fo_tile_center(lua_State* L)
{
    int tile = check_tile(L, 1);
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int x;
    int y;
    if (tile_coord(tile, &x, &y, obj_dude->elevation) != 0) {
        lua_pushnil(L);
        return 1;
    }

    // tile_coord gives the hex's top-left corner.
    x += 16;
    y += 8;
    if (x < 0 || y < 0 || x >= screenGetWidth() || y >= screenGetHeight()) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushinteger(L, x);
    lua_pushinteger(L, y);
    return 2;
}

// fo.tile_distance(a, b): hexes between two tiles.
static int fo_tile_distance(lua_State* L)
{
    lua_pushinteger(L, tile_dist(check_tile(L, 1), check_tile(L, 2)));
    return 1;
}

// fo.tile_direction(a, b): the rotation (0 NE ... 5 NW) from `a` toward `b`.
static int fo_tile_direction(lua_State* L)
{
    lua_pushinteger(L, tile_dir(check_tile(L, 1), check_tile(L, 2)));
    return 1;
}

// fo.exits(): every exit grid on the player's elevation, as
// { tile, map, seen }. `map` is the destination's index, 0 or less for the
// world map; `seen` is whether the player has seen that tile. Exit grids are
// invisible in play, so lua/mcp/state.lua decides which of them a player
// would know about.
static int fo_exits(lua_State* L)
{
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    lua_newtable(L);
    int count = 0;

    for (Object* obj = obj_find_first_at(obj_dude->elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (FID_TYPE(obj->fid) != OBJ_TYPE_MISC || obj->pid < PROTO_ID_0x5000010 || obj->pid > PROTO_ID_0x5000017) {
            continue;
        }

        lua_createtable(L, 0, 3);
        set_int(L, "tile", obj->tile);
        set_int(L, "map", obj->data.misc.map);
        set_bool(L, "seen", (obj->flags & OBJECT_SEEN) != 0);
        lua_rawseti(L, -2, ++count);
    }

    return 1;
}

// fo.map_name(index): a map's name as the game shows it.
static int fo_map_name(lua_State* L)
{
    lua_Integer index = luaL_checkinteger(L, 1);
    if (index <= 0) {
        lua_pushstring(L, "the world map");
        return 1;
    }

    char* name = map_get_description_idx(static_cast<int>(index));
    if (name == nullptr) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, name);
    }
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
        { "walk_to", fo_walk_to },
        { "path_length", fo_path_length },
        { "player_busy", fo_player_busy },
        { "tile_at", fo_tile_at },
        { "tile_toward", fo_tile_toward },
        { "tile_center", fo_tile_center },
        { "tile_distance", fo_tile_distance },
        { "tile_direction", fo_tile_direction },
        { "exits", fo_exits },
        { "map_name", fo_map_name },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
