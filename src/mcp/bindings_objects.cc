#include "mcp/bindings.h"

#include <string.h>

#include <lua.hpp>

#include "game/actions.h"
#include "game/anim.h"
#include "game/combat.h"
#include "game/critter.h"
#include "game/inventry.h"
#include "game/item.h"
#include "game/object.h"
#include "game/protinst.h"
#include "game/proto.h"
#include "game/stat.h"
#include "mcp/lua_fields.h"
#include "mcp/sight.h"
#include "plib/gnw/input.h"

namespace fallout {

// The things on the map a player acts on besides the living: items on the
// ground, bodies, containers, doors and scenery that can be used. Every
// action is the one the game takes when the player clicks the object
// (`gmouse_handle_event`): each walks up to it first, and in combat spends
// AP as the game does. Looting opens the loot screen through the game's own
// script request, so the screen's loop runs it, and taking single items
// goes through the loot screen's INVEN_TAKE_ITEM_CODE.

static const char* item_type_name(int type)
{
    switch (type) {
    case ITEM_TYPE_ARMOR:
        return "armor";
    case ITEM_TYPE_CONTAINER:
        return "container";
    case ITEM_TYPE_DRUG:
        return "drug";
    case ITEM_TYPE_WEAPON:
        return "weapon";
    case ITEM_TYPE_AMMO:
        return "ammo";
    case ITEM_TYPE_KEY:
        return "key";
    default:
        return "misc";
    }
}

static const char* scenery_type_name(Object* obj)
{
    Proto* proto;
    if (proto_ptr(obj->pid, &proto) == -1) {
        return nullptr;
    }

    switch (proto->scenery.type) {
    case SCENERY_TYPE_STAIRS:
        return "stairs";
    case SCENERY_TYPE_ELEVATOR:
        return "elevator";
    case SCENERY_TYPE_LADDER_UP:
        return "ladder up";
    case SCENERY_TYPE_LADDER_DOWN:
        return "ladder down";
    default:
        return nullptr;
    }
}

// What kind of thing `obj` is to a player, by what clicking it does, or null
// for what the views leave out: the living, walls, scenery that does nothing
// and the invisible markers.
static const char* object_kind(Object* obj)
{
    switch (FID_TYPE(obj->fid)) {
    case OBJ_TYPE_ITEM:
        if (item_get_type(obj) == ITEM_TYPE_CONTAINER && !proto_action_can_pickup(obj->pid)) {
            return "container";
        }
        return "item";
    case OBJ_TYPE_CRITTER:
        return obj != obj_dude && critter_is_dead(obj) ? "body" : nullptr;
    case OBJ_TYPE_SCENERY:
        if (obj_is_a_portal(obj)) {
            return "door";
        }
        return proto_action_can_use(obj->pid) ? "scenery" : nullptr;
    default:
        return nullptr;
    }
}

// Pushes `obj` as { id, name, kind, tile, visible, hidden, busy } plus what
// its kind has: an item's type, and quantity for money and ammo; whether a
// door or container is open and locked; a scenery's type.
static void push_object(lua_State* L, Object* obj, const char* kind)
{
    lua_createtable(L, 0, 10);
    set_int(L, "id", obj->id);
    set_string(L, "name", object_name(obj));
    set_string(L, "kind", kind);
    set_int(L, "tile", obj->tile);
    set_bool(L, "visible", mcp_object_visible(obj));
    set_bool(L, "hidden", (obj->flags & OBJECT_HIDDEN) != 0);
    set_bool(L, "busy", anim_busy(obj) != 0);

    if (FID_TYPE(obj->fid) == OBJ_TYPE_ITEM) {
        int type = item_get_type(obj);
        set_string(L, "type", item_type_name(type));
        if (obj->pid == PROTO_ID_MONEY) {
            set_int(L, "quantity", item_caps_get_amount(obj));
        } else if (type == ITEM_TYPE_AMMO) {
            set_int(L, "quantity", item_w_curr_ammo(obj));
        }
    }

    if (obj_is_openable(obj)) {
        set_bool(L, "open", obj_is_open(obj) != 0);
        set_bool(L, "locked", obj_is_locked(obj));
    }

    if (FID_TYPE(obj->fid) == OBJ_TYPE_SCENERY) {
        set_string(L, "type", scenery_type_name(obj));
    }
}

// The object with `id` on the map, on the player's elevation, or null.
static Object* find_on_map(int id)
{
    for (Object* obj = obj_find_first_at(obj_dude->elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj->id == id && obj->tile != -1 && obj != obj_dude) {
            return obj;
        }
    }
    return nullptr;
}

// fo.objects(): every item on the ground, body, container, door and usable
// scenery on the player's elevation, as push_object has them. Exit grids are
// fo.exits. lua/mcp/objects.lua decides which of them a player would see.
static int fo_objects(lua_State* L)
{
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    lua_newtable(L);
    int count = 0;

    for (Object* obj = obj_find_first_at(obj_dude->elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj->tile == -1) {
            continue;
        }

        const char* kind = object_kind(obj);
        if (kind != nullptr) {
            push_object(L, obj, kind);
            lua_rawseti(L, -2, ++count);
        }
    }

    return 1;
}

// fo.object(id): object `id` as fo.objects has it, or nil when it's no
// longer on the map (picked up, say).
static int fo_object(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    Object* obj = find_on_map(id);
    const char* kind = obj != nullptr ? object_kind(obj) : nullptr;
    if (kind == nullptr) {
        lua_pushnil(L);
    } else {
        push_object(L, obj, kind);
    }
    return 1;
}

static int fail(lua_State* L, const char* reason)
{
    lua_pushboolean(L, false);
    lua_pushstring(L, reason);
    return 2;
}

// Why the player can't act on the map now, or null if they can.
static const char* action_blocked()
{
    if (!mcp_in_game()) {
        return "there's no game in progress";
    }

    if (inven_open_screen() != -1) {
        return "an inventory screen is open; close it first (escape)";
    }

    if (isInCombat() && (combat_whose_turn() != obj_dude || (combat_state & COMBAT_STATE_0x02) == 0)) {
        return "it isn't your turn";
    }

    return nullptr;
}

// Finds the target of an action, or explains why there isn't one.
static Object* find_target(int id, const char** why)
{
    *why = action_blocked();
    if (*why != nullptr) {
        return nullptr;
    }

    Object* obj = find_on_map(id);
    if (obj == nullptr) {
        *why = "there's nothing with that id here";
    }
    return obj;
}

// The result of registering an action: true when the game took it, false
// while the player is still finishing something else.
static int registered(lua_State* L, int rc)
{
    if (rc == -1) {
        return fail(L, "busy");
    }

    lua_pushboolean(L, true);
    return 1;
}

// fo.pick_up(id): walks to item `id` and picks it up, as clicking it does
// (`action_get_an_object`). Returns true once the game has taken the
// request, or false and why not.
static int fo_pick_up(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));

    const char* why;
    Object* obj = find_target(id, &why);
    if (obj == nullptr) {
        return fail(L, why);
    }

    const char* kind = object_kind(obj);
    if (kind == nullptr || strcmp(kind, "item") != 0) {
        return fail(L, "that isn't an item you can pick up");
    }

    return registered(L, action_get_an_object(obj_dude, obj));
}

// fo.loot(id): walks to body or container `id` and opens it, as clicking it
// does. The loot screen opens once the player is there. Clicking an open
// container closes it instead, as here. Returns true once the game has
// taken the request, or false and why not.
static int fo_loot(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));

    const char* why;
    Object* obj = find_target(id, &why);
    if (obj == nullptr) {
        return fail(L, why);
    }

    const char* kind = object_kind(obj);
    if (kind != nullptr && strcmp(kind, "body") == 0) {
        return registered(L, action_loot_container(obj_dude, obj));
    }
    if (kind != nullptr && strcmp(kind, "container") == 0) {
        return registered(L, action_get_an_object(obj_dude, obj));
    }
    return fail(L, "that isn't a body or a container");
}

// fo.use_object(id): walks to door or scenery `id` and uses it, as clicking
// it does (`action_use_an_object`): a door opens or closes, a ladder is
// climbed, and anything else does what its script says. Returns true once
// the game has taken the request, or false and why not.
static int fo_use_object(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));

    const char* why;
    Object* obj = find_target(id, &why);
    if (obj == nullptr) {
        return fail(L, why);
    }

    const char* kind = object_kind(obj);
    if (kind == nullptr || (strcmp(kind, "door") != 0 && strcmp(kind, "scenery") != 0)) {
        return fail(L, "that isn't a door or something to use");
    }

    return registered(L, action_use_an_object(obj_dude, obj));
}

// fo.look_at(id): examines anything on the map, critters included, as the
// action menu's look does: its description goes to the message window.
// Returns true, or false and why not.
static int fo_look_at(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    if (!mcp_in_game()) {
        return fail(L, "there's no game in progress");
    }

    Object* obj = find_on_map(id);
    if (obj == nullptr) {
        return fail(L, "there's nothing with that id here");
    }

    if (obj_examine(obj_dude, obj) == -1) {
        obj_look_at(obj_dude, obj);
    }

    lua_pushboolean(L, true);
    return 1;
}

static void push_items(lua_State* L, Object* owner)
{
    Inventory* inventory = &(owner->data.inventory);
    lua_createtable(L, inventory->length, 0);
    for (int index = 0; index < inventory->length; index++) {
        InventoryItem* entry = &(inventory->items[index]);
        Object* item = entry->item;

        lua_createtable(L, 0, 5);
        set_int(L, "id", item->id);
        set_string(L, "name", object_name(item));
        set_string(L, "type", item_type_name(item_get_type(item)));
        set_int(L, "quantity", entry->quantity);
        set_int(L, "weight", item_weight(item));
        lua_rawseti(L, -2, index + 1);
    }
}

// fo.loot_screen(): nil unless the loot screen is open; otherwise what it
// shows: { target = { id, name }, items, weight, capacity }. `items` is what
// the other side holds, as the inventory lists items; `weight` and
// `capacity` are the player's.
static int fo_loot_screen(lua_State* L)
{
    Object* target = mcp_in_game() ? inven_loot_target() : nullptr;
    if (target == nullptr) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 4);

    lua_createtable(L, 0, 2);
    set_int(L, "id", target->id);
    set_string(L, "name", object_name(target));
    lua_setfield(L, -2, "target");

    push_items(L, target);
    lua_setfield(L, -2, "items");

    set_int(L, "weight", item_total_weight(obj_dude));
    set_int(L, "capacity", stat_level(obj_dude, STAT_CARRY_WEIGHT));
    set_int(L, "target_weight", item_total_weight(target));
    return 1;
}

// fo.take(id, quantity): on the loot screen, asks it to move item `id` to
// the player, `quantity` of its stack or all of it (0). fo.take_result says
// how it went once the screen has handled it. Returns false if the input
// queue is full.
static int fo_take(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    lua_Integer quantity = luaL_optinteger(L, 2, 0);
    if (!mcp_in_game() || inven_loot_target() == nullptr) {
        return luaL_error(L, "the loot screen isn't open");
    }

    if (input_buffer_is_full()) {
        lua_pushboolean(L, false);
        return 1;
    }

    inven_take_request.itemId = id;
    inven_take_request.quantity = static_cast<int>(quantity);
    inven_take_request.result = INVEN_TAKE_PENDING;
    GNW_add_input_buffer(INVEN_TAKE_ITEM_CODE);

    lua_pushboolean(L, true);
    return 1;
}

// fo.take_result(): nil until the loot screen has handled fo.take, then
// "taken", "not there", "too heavy" or "stealing".
static int fo_take_result(lua_State* L)
{
    switch (inven_take_request.result) {
    case INVEN_TAKE_DONE:
        lua_pushstring(L, "taken");
        break;
    case INVEN_TAKE_NOT_THERE:
        lua_pushstring(L, "not there");
        break;
    case INVEN_TAKE_TOO_HEAVY:
        lua_pushstring(L, "too heavy");
        break;
    case INVEN_TAKE_STEALING:
        lua_pushstring(L, "stealing");
        break;
    default:
        lua_pushnil(L);
        break;
    }
    return 1;
}

void mcp_register_object_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "objects", fo_objects },
        { "object", fo_object },
        { "pick_up", fo_pick_up },
        { "loot", fo_loot },
        { "use_object", fo_use_object },
        { "look_at", fo_look_at },
        { "loot_screen", fo_loot_screen },
        { "take", fo_take },
        { "take_result", fo_take_result },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
