#include "mcp/bindings.h"

#include <cstring>
#include <unordered_map>
#include <vector>

#include <lua.hpp>

#include "game/art.h"
#include "game/intface.h"
#include "game/map.h"
#include "game/object.h"
#include "game/protinst.h"
#include "game/proto.h"
#include "game/tile.h"
#include "mcp/lua_fields.h"
#include "mcp/sight.h"
#include "plib/gnw/svga.h"

namespace fallout {

// The hexes on screen, for the text map (lua/mcp/map.lua). Each comes with
// what's there and whether a player can see it (mcp/sight.h); the Lua side
// decides what to draw.

// On screen, hex centres sit in rows 12 pixels apart and 32 pixels apart
// along a row, and each row is offset half a hex from the next.
static constexpr int kHalfHexWidth = 16;
static constexpr int kRowHeight = 12;

// What lies on a hex besides the ground and critters.
struct HexObjects {
    bool door = false;
    bool exit = false;
    std::vector<Object*> items;
};

static int floor_div(int a, int b)
{
    return a >= 0 ? a / b : -((-a + b - 1) / b);
}

static bool is_exit(Object* obj)
{
    return FID_TYPE(obj->fid) == OBJ_TYPE_MISC && obj->pid >= PROTO_ID_0x5000010 && obj->pid <= PROTO_ID_0x5000017;
}

// What the ground at `tile` is, as far as walking goes: a wall (or scenery
// that blocks, a cave's rock face included), floor, or nothing drawn at all.
static const char* terrain_at(int tile, int elevation)
{
    Object* blocker = obj_blocking_at(nullptr, tile, elevation);
    if (blocker != nullptr && FID_TYPE(blocker->fid) != OBJ_TYPE_CRITTER) {
        return "wall";
    }

    // The floor is drawn in squares of two by two hexes.
    int square = (tile % HEX_GRID_WIDTH) / 2 + SQUARE_GRID_WIDTH * (tile / HEX_GRID_WIDTH / 2);
    int floor = square_data[elevation].field_0[square] & 0xFFF;
    if (art_id(OBJ_TYPE_TILE, floor, 0, 0, 0) == art_id(OBJ_TYPE_TILE, 1, 0, 0, 0)) {
        return "none";
    }

    return "floor";
}

// Which hexes the player can walk to, as the game tells a player who points
// at one: the move cursor shows an X over a hex `make_path` finds no way to.
// This walks out from the player the way make_path goes, past anything that
// doesn't block, and closed doors block the player there too. Critters
// don't count, since they move. An exit grid is as far as a walk goes:
// stepping onto one leaves the map, so what lies past it, often the dark
// beyond a map's edge, is out of reach.
std::vector<bool> mcp_reachable_tiles(int elevation, bool throughDoors)
{
    std::vector<bool> exits(HEX_GRID_SIZE, false);
    for (Object* obj = obj_find_first_at(elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj->tile != -1 && is_exit(obj)) {
            exits[obj->tile] = true;
        }
    }

    std::vector<bool> reachable(HEX_GRID_SIZE, false);
    std::vector<int> queue { obj_dude->tile };
    reachable[obj_dude->tile] = true;

    for (size_t index = 0; index < queue.size(); index++) {
        for (int rotation = 0; rotation < ROTATION_COUNT; rotation++) {
            int next = tile_num_in_direction(queue[index], rotation, 1);
            if (next < 0 || next >= HEX_GRID_SIZE || reachable[next]) {
                continue;
            }

            Object* blocker = obj_blocking_at(obj_dude, next, elevation);
            if (blocker != nullptr
                && FID_TYPE(blocker->fid) != OBJ_TYPE_CRITTER
                && !(throughDoors && FID_TYPE(blocker->fid) == OBJ_TYPE_SCENERY && obj_is_a_portal(blocker))) {
                continue;
            }

            reachable[next] = true;
            if (!exits[next]) {
                queue.push_back(next);
            }
        }
    }

    return reachable;
}

// fo.hexes(): every hex whose centre is in the map view, as
// { tile, x, y, visible, terrain, reachable, exit, item, item_visible }.
// `x` and `y` place it relative to the player's hex, x in half hexes to the
// right and y in rows down. `visible` is whether a player can see the hex
// (mcp_hex_visible); `terrain` is "wall", "door", "floor" or "none", and
// `reachable` whether the player can walk there. `exit` is whether there's
// an exit grid a player could walk into, opening doors on the way if need
// be. `item` is whether an item lies there, and `item_visible` whether a
// player can see one. Critters come from fo.critters.
static int fo_hexes(lua_State* L)
{
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int elevation = obj_dude->elevation;

    std::unordered_map<int, HexObjects> objects;
    for (Object* obj = obj_find_first_at(elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj->tile == -1) {
            continue;
        }
        if (is_exit(obj)) {
            objects[obj->tile].exit = true;
        } else if ((obj->flags & OBJECT_HIDDEN) != 0) {
            continue;
        } else if (FID_TYPE(obj->fid) == OBJ_TYPE_ITEM) {
            objects[obj->tile].items.push_back(obj);
        } else if (FID_TYPE(obj->fid) == OBJ_TYPE_SCENERY && obj_is_a_portal(obj)) {
            objects[obj->tile].door = true;
        }
    }

    std::vector<bool> reachable = mcp_reachable_tiles(elevation, false);
    std::vector<bool> pastDoors = mcp_reachable_tiles(elevation, true);

    int playerX;
    int playerY;
    tile_coord(obj_dude->tile, &playerX, &playerY, elevation);
    playerX += 16;
    playerY += 8;

    int width = screenGetWidth();
    int height = screenGetHeight() - INTERFACE_BAR_HEIGHT;

    // The rows and half-hex columns on screen, counted from the player's.
    int firstRow = -floor_div(playerY, kRowHeight);
    int lastRow = floor_div(height - 1 - playerY, kRowHeight);
    int firstColumn = -floor_div(playerX, kHalfHexWidth);
    int lastColumn = floor_div(width - 1 - playerX, kHalfHexWidth);

    lua_newtable(L);
    int count = 0;

    for (int row = firstRow; row <= lastRow; row++) {
        for (int column = firstColumn; column <= lastColumn; column++) {
            // A hex sits where the row and column are both even or both odd.
            if (((row + column) & 1) != 0) {
                continue;
            }

            int x = playerX + column * kHalfHexWidth;
            int y = playerY + row * kRowHeight;
            int tile = tile_num(x, y, elevation);
            if (tile == -1) {
                continue;
            }

            const char* terrain = terrain_at(tile, elevation);
            bool exit = false;
            bool item = false;
            bool itemVisible = false;

            auto found = objects.find(tile);
            if (found != objects.end()) {
                if (found->second.door) {
                    terrain = "door";
                }
                exit = found->second.exit && pastDoors[tile];
                item = !found->second.items.empty();
                for (Object* obj : found->second.items) {
                    if (mcp_object_visible(obj)) {
                        itemVisible = true;
                        break;
                    }
                }
            }

            lua_createtable(L, 0, 9);
            set_int(L, "tile", tile);
            set_int(L, "x", column);
            set_int(L, "y", row);
            // A wall's segments are drawn over one another along its length,
            // and over what's behind it, but a player sees wall there all the
            // same. Only a roof hides one.
            bool solid = strcmp(terrain, "wall") == 0 || strcmp(terrain, "door") == 0;
            set_bool(L, "visible", solid ? mcp_point_visible(x, y) : mcp_hex_visible(tile, x, y));
            set_string(L, "terrain", terrain);
            set_bool(L, "reachable", reachable[tile]);
            set_bool(L, "exit", exit);
            set_bool(L, "item", item);
            set_bool(L, "item_visible", itemVisible);
            lua_rawseti(L, -2, ++count);
        }
    }

    return 1;
}

void mcp_register_map_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "hexes", fo_hexes },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
