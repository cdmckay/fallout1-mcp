#include "mcp/bindings.h"

#include <vector>

#include <lua.hpp>

#include "game/anim.h"
#include "game/map_defs.h"
#include "game/object.h"
#include "game/tile.h"
#include "mcp/lua_fields.h"

namespace fallout {

// What the walking tools need to know about the ground: where the player
// can get to, and what's in the way. Blocking is the game's own
// (`obj_blocking_at`, as `make_path` uses it): critters, walls and scenery
// block, and so do closed doors, which the game never paths the player
// through (`anim_can_use_door`).

// The furthest a search may go, in steps. A direction walk asks for twice
// its distance, which is at most 50.
static const int kMaxReachSteps = 120;

static bool is_critter(Object* obj)
{
    return obj != nullptr && FID_TYPE(obj->fid) == OBJ_TYPE_CRITTER;
}

// fo.reachable(max_steps): every hex the player could walk to in at most
// `max_steps` steps on their elevation, nearest first, as { tile, steps, x,
// y }, where x and y are the hex's offset on the screen from the player's
// hex, in screenshot pixels. A hex a critter stands on is listed too, with
// `critter` (its id) set, but the search doesn't go through it: it shows
// where someone is in the way.
static int fo_reachable(lua_State* L)
{
    lua_Integer maxSteps = luaL_checkinteger(L, 1);
    luaL_argcheck(L, maxSteps >= 1 && maxSteps <= kMaxReachSteps, 1, "max_steps must be 1 to 120");
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int elevation = obj_dude->elevation;
    int from = obj_dude->tile;

    int fromX;
    int fromY;
    tile_coord(from, &fromX, &fromY, elevation);

    std::vector<short> steps(HEX_GRID_SIZE, -1);
    std::vector<int> queue;
    steps[from] = 0;
    queue.push_back(from);

    lua_newtable(L);
    int count = 0;

    for (size_t head = 0; head < queue.size(); head++) {
        int tile = queue[head];
        int next = steps[tile] + 1;
        if (next > maxSteps) {
            continue;
        }

        for (int rotation = 0; rotation < ROTATION_COUNT; rotation++) {
            int neighbor = tile_num_in_direction(tile, rotation, 1);
            if (!hexGridTileIsValid(neighbor) || steps[neighbor] != -1) {
                continue;
            }
            steps[neighbor] = static_cast<short>(next);

            Object* blocker = obj_blocking_at(obj_dude, neighbor, elevation);
            if (blocker != nullptr && !is_critter(blocker)) {
                continue;
            }

            int x;
            int y;
            tile_coord(neighbor, &x, &y, elevation);

            lua_createtable(L, 0, 5);
            set_int(L, "tile", neighbor);
            set_int(L, "steps", next);
            set_int(L, "x", x - fromX);
            set_int(L, "y", y - fromY);
            if (blocker != nullptr) {
                set_int(L, "critter", blocker->id);
            }
            lua_rawseti(L, -2, ++count);

            if (blocker == nullptr) {
                queue.push_back(neighbor);
            }
        }
    }

    return 1;
}

// fo.blocker(tile): what stands on `tile` on the player's elevation and
// would stop them walking onto it, or nil: { critter = id } for a critter,
// { solid = true } for a wall, scenery or a closed door.
static int fo_blocker(lua_State* L)
{
    lua_Integer tile = luaL_checkinteger(L, 1);
    luaL_argcheck(L, hexGridTileIsValid(static_cast<int>(tile)), 1, "not a tile on the map");
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    Object* blocker = obj_blocking_at(obj_dude, static_cast<int>(tile), obj_dude->elevation);
    if (blocker == nullptr) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 1);
    if (is_critter(blocker)) {
        set_int(L, "critter", blocker->id);
    } else {
        set_bool(L, "solid", true);
    }
    return 1;
}

// Blocking as the game paths, except that critters don't block.
static Object* blocking_but_critters(Object* object, int tile, int elevation)
{
    Object* blocker = obj_blocking_at(object, tile, elevation);
    return is_critter(blocker) ? nullptr : blocker;
}

// fo.path_length_past_critters(tile): what fo.path_length would be if
// nobody stood in the way, to tell a way someone blocks from no way at all.
static int fo_path_length_past_critters(lua_State* L)
{
    lua_Integer tile = luaL_checkinteger(L, 1);
    luaL_argcheck(L, hexGridTileIsValid(static_cast<int>(tile)), 1, "not a tile on the map");
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    lua_pushinteger(L, make_path_func(obj_dude, obj_dude->tile, static_cast<int>(tile), nullptr, 0, blocking_but_critters));
    return 1;
}

void mcp_register_walk_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "reachable", fo_reachable },
        { "blocker", fo_blocker },
        { "path_length_past_critters", fo_path_length_past_critters },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
