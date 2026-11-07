#include "mcp/sight.h"

#include <vector>

#include "game/art.h"
#include "game/gmouse.h"
#include "game/intface.h"
#include "game/object.h"
#include "game/tile.h"
#include "mcp/sight_rules.h"
#include "plib/gnw/svga.h"

namespace fallout {

// Large sprites are sampled every other pixel each way, which is plenty to
// tell a quarter showing from none.
static constexpr int kDenseSpriteArea = 1024;

// The flags `obj_intersects_with` sets for a point on an object.
static constexpr int kPointOpaque = 0x01;
static constexpr int kPointTranslucent = 0x02;
static constexpr int kPointInEgg = 0x04;

bool mcp_point_visible(int x, int y)
{
    if (x < 0 || y < 0 || x >= screenGetWidth() || y >= screenGetHeight() - INTERFACE_BAR_HEIGHT) {
        return false;
    }

    // As `object_under_mouse` has it: a roof covers the point, except where
    // the egg, the hole the game cuts around the player, takes it away.
    int elevation = obj_dude->elevation;
    if (square_num_roof(x, y, elevation) != -1
        && square_roof_intersect(x, y, elevation)
        && obj_intersects_with(obj_egg, x, y) == 0) {
        return false;
    }

    return true;
}

// Whether `object` is what's drawn at screen point (x, y).
static bool drawn_on_top(Object* object, int x, int y)
{
    ObjectWithFlags* entries;
    int count = obj_create_intersect_list(x, y, object->elevation, -1, &entries);

    std::vector<McpLayer> layers;
    layers.reserve(count);
    for (int index = 0; index < count; index++) {
        Object* candidate = entries[index].object;
        int flags = entries[index].flags;
        if ((flags & kPointOpaque) == 0 || candidate == obj_mouse || candidate == obj_mouse_flat) {
            continue;
        }

        McpLayer layer;
        layer.target = candidate == object;
        layer.flat = (candidate->flags & OBJECT_FLAT) != 0;
        layer.seeThrough = (flags & (kPointTranslucent | kPointInEgg)) != 0;
        layers.push_back(layer);
    }

    if (count != 0) {
        obj_delete_intersect_list(&entries);
    }

    return mcp_target_on_top(layers);
}

bool mcp_hex_visible(int tile, int x, int y)
{
    if (!mcp_point_visible(x, y)) {
        return false;
    }

    // Where the hex sits on screen, to tell what stands in front of it.
    int hexX;
    int hexY;
    tile_coord(tile, &hexX, &hexY, obj_dude->elevation);

    ObjectWithFlags* entries;
    int count = obj_create_intersect_list(x, y, obj_dude->elevation, -1, &entries);

    std::vector<McpCover> covers;
    covers.reserve(count);
    for (int index = 0; index < count; index++) {
        Object* object = entries[index].object;
        int flags = entries[index].flags;
        if ((flags & kPointOpaque) == 0) {
            continue;
        }

        int type = FID_TYPE(object->fid);
        McpCover cover;
        cover.solid = type == OBJ_TYPE_WALL
            || (type == OBJ_TYPE_SCENERY && (object->flags & OBJECT_NO_BLOCK) == 0);
        cover.flat = (object->flags & OBJECT_FLAT) != 0;
        cover.seeThrough = (flags & (kPointTranslucent | kPointInEgg)) != 0;

        int objectX;
        int objectY;
        tile_coord(object->tile, &objectX, &objectY, object->elevation);
        cover.inFront = objectY > hexY;
        covers.push_back(cover);
    }

    if (count != 0) {
        obj_delete_intersect_list(&entries);
    }

    return !mcp_ground_hidden(covers);
}

bool mcp_object_visible(Object* object)
{
    if (object == nullptr
        || object->tile == -1
        || object->elevation != obj_dude->elevation
        || (object->flags & OBJECT_HIDDEN) != 0) {
        return false;
    }

    CacheEntry* handle;
    Art* art = art_ptr_lock(object->fid, &handle);
    if (art == nullptr) {
        return false;
    }

    int width = art_frame_width(art, object->frame, object->rotation);
    int height = art_frame_length(art, object->frame, object->rotation);
    unsigned char* data = art_frame_data(art, object->frame, object->rotation);

    // Where `obj_intersects_with` places the frame: centred on the hex and
    // standing on it.
    int x;
    int y;
    tile_coord(object->tile, &x, &y, object->elevation);
    x += 16 + art->xOffsets[object->rotation] + object->x;
    y += 8 + art->yOffsets[object->rotation] + object->y;
    int left = x - width / 2;
    int top = y - height + 1;

    int step = width * height > kDenseSpriteArea ? 2 : 1;

    int own = 0;
    if (data != nullptr) {
        for (int row = 0; row < height; row += step) {
            for (int column = 0; column < width; column += step) {
                if (data[width * row + column] != 0) {
                    own++;
                }
            }
        }
    }

    int needed = mcp_pixels_needed(own);
    int shown = 0;
    for (int row = 0; own > 0 && row < height && shown < needed; row += step) {
        for (int column = 0; column < width && shown < needed; column += step) {
            int px = left + column;
            int py = top + row;
            if (data[width * row + column] != 0 && mcp_point_visible(px, py) && drawn_on_top(object, px, py)) {
                shown++;
            }
        }
    }

    art_ptr_unlock(handle);
    return mcp_enough_shows(own, shown);
}

} // namespace fallout
