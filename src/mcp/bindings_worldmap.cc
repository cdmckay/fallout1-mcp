#include "mcp/bindings.h"

#include <stdio.h>

#include <lua.hpp>

#include "game/game.h"
#include "game/map.h"
#include "game/message.h"
#include "game/scripts.h"
#include "game/worldmap.h"
#include "mcp/lua_fields.h"
#include "platform_compat.h"
#include "plib/gnw/input.h"

namespace fallout {

// The world map and town map, as the player sees them, and what the agent
// needs to travel and go in without the mouse. Moving the player stays the
// map's own job: travelling to a point and entering where they stand are
// command codes its loop handles (worldmap.h), and the town and place
// buttons already have codes of their own.

// The world map's text (worldmap.msg), for the names of where the player
// stands. The engine only loads its copy while a map screen is up, so this
// keeps one of its own.
static MessageList worldmap_messages;
static bool worldmap_messages_loaded = false;

static const char* worldmap_message(int number)
{
    if (!worldmap_messages_loaded) {
        char path[COMPAT_MAX_PATH];
        snprintf(path, sizeof(path), "%s%s", msg_path, "worldmap.msg");
        if (!message_init(&worldmap_messages) || !message_load(&worldmap_messages, path)) {
            return nullptr;
        }
        worldmap_messages_loaded = true;
    }

    MessageListItem item;
    item.num = number;
    return message_search(&worldmap_messages, &item) ? item.text : nullptr;
}

// A town's name, as its marker's label gives it.
static const char* town_name(int town)
{
    MessageListItem item;
    item.num = 500 + town;
    return message_search(&map_msg_file, &item) ? item.text : nullptr;
}

static const char* terrain_name(int terrain)
{
    switch (terrain) {
    case TERRAIN_TYPE_DESERT:
        return "desert";
    case TERRAIN_TYPE_MOUNTAIN:
        return "mountain";
    case TERRAIN_TYPE_CITY:
        return "city";
    default:
        return "coast";
    }
}

static const char* exit_name(int exit)
{
    switch (exit) {
    case WORLDMAP_EXIT_TERRAIN:
        return "terrain";
    case WORLDMAP_EXIT_TOWN:
        return "town";
    case WORLDMAP_EXIT_ENCOUNTER:
        return "encounter";
    case WORLDMAP_EXIT_SPECIAL_ENCOUNTER:
        return "special_encounter";
    default:
        return nullptr;
    }
}

static void push_point(lua_State* L, int x, int y)
{
    lua_createtable(L, 0, 2);
    set_int(L, "x", x);
    set_int(L, "y", y);
}

// fo.world_map(): what the world map shows, or nil when neither it nor a
// town map is up. Positions are world-map pixels, 50 to a square. `here` is
// the name the player's marker shows: the town's when the map names it,
// otherwise the ground's. `known` is the towns the map's list names, with
// where their buttons head. `town_map` is the town map's place buttons, in
// the order of their codes (514 on), when it's up.
static int fo_world_map(lua_State* L)
{
    if (!mcp_in_game() || !world_map_is_open()) {
        lua_pushnil(L);
        return 1;
    }

    WorldMapStatus status;
    worldmap_status(&status);

    lua_createtable(L, 0, 12);
    set_int(L, "x", status.x);
    set_int(L, "y", status.y);
    set_bool(L, "moving", status.moving != 0);
    if (status.moving) {
        push_point(L, status.target_x, status.target_y);
        lua_setfield(L, -2, "target");
    }
    set_bool(L, "can_enter", status.can_enter != 0);
    set_string(L, "terrain", terrain_name(status.terrain));
    if (status.town_known) {
        set_int(L, "town", status.town);
        set_string(L, "here", town_name(status.town));
    } else if (status.town != -1) {
        set_string(L, "here", worldmap_message(1004));
    } else {
        set_string(L, "here", worldmap_message(1000 + status.terrain));
    }

    lua_newtable(L);
    int count = 0;
    for (int town = 0; town < TOWN_COUNT; town++) {
        if ((status.known_towns & (1 << town)) == 0) {
            continue;
        }

        int x;
        int y;
        worldmap_town_position(town, &x, &y);
        lua_createtable(L, 0, 4);
        set_int(L, "id", town);
        set_string(L, "name", town_name(town));
        set_int(L, "x", x);
        set_int(L, "y", y);
        lua_rawseti(L, -2, ++count);
    }
    lua_setfield(L, -2, "known");

    int town;
    const char* places[7];
    int places_count = worldmap_town_map(&town, places, 7);
    if (places_count > 0) {
        lua_createtable(L, 0, 3);
        set_int(L, "town", town);
        set_string(L, "name", town_name(town));
        lua_createtable(L, places_count, 0);
        for (int index = 0; index < places_count; index++) {
            lua_pushstring(L, places[index]);
            lua_rawseti(L, -2, index + 1);
        }
        lua_setfield(L, -2, "places");
        lua_setfield(L, -2, "town_map");
    }

    return 1;
}

// fo.world_map_exit(): how the world map was last left, once it has closed:
// "encounter", "special_encounter", "terrain" (into the open ground where the
// player stood), "town", or nil.
static int fo_world_map_exit(lua_State* L)
{
    WorldMapStatus status;
    worldmap_status(&status);
    const char* name = exit_name(status.last_exit);
    if (name == nullptr) {
        lua_pushnil(L);
    } else {
        lua_pushstring(L, name);
    }
    return 1;
}

// fo.game_time(): the game's clock, in tenths of a second.
static int fo_game_time(lua_State* L)
{
    lua_pushinteger(L, game_time());
    return 1;
}

// fo.world_map_travel(x, y): on the world map, sets the player travelling to
// point (x, y), in world-map pixels, as clicking the map there does, by
// queueing the map's command code. Returns false if the input queue is full.
static int fo_world_map_travel(lua_State* L)
{
    lua_Integer x = luaL_checkinteger(L, 1);
    lua_Integer y = luaL_checkinteger(L, 2);
    luaL_argcheck(L, x >= 0 && x < 28 * 50, 1, "not on the world map");
    luaL_argcheck(L, y >= 0 && y < 30 * 50, 2, "not on the world map");

    if (!world_map_is_open()) {
        return luaL_error(L, "the world map isn't open");
    }

    if (input_buffer_is_full()) {
        lua_pushboolean(L, false);
        return 1;
    }

    worldmap_set_travel_target(static_cast<int>(x), static_cast<int>(y));
    GNW_add_input_buffer(WORLDMAP_TRAVEL_CODE);
    lua_pushboolean(L, true);
    return 1;
}

// fo.world_map_enter(): on the world map, goes into the place the player
// stands on, as clicking their marker does, by queueing the map's command
// code. Like the marker, the map ignores it while they're moving. Returns
// false if the input queue is full.
static int fo_world_map_enter(lua_State* L)
{
    if (!world_map_is_open()) {
        return luaL_error(L, "the world map isn't open");
    }

    if (input_buffer_is_full()) {
        lua_pushboolean(L, false);
        return 1;
    }

    GNW_add_input_buffer(WORLDMAP_ENTER_CODE);
    lua_pushboolean(L, true);
    return 1;
}

void mcp_register_worldmap_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "world_map", fo_world_map },
        { "world_map_exit", fo_world_map_exit },
        { "game_time", fo_game_time },
        { "world_map_travel", fo_world_map_travel },
        { "world_map_enter", fo_world_map_enter },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
