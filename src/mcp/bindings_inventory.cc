#include "mcp/bindings.h"

#include <string.h>

#include <lua.hpp>

#include "game/combat.h"
#include "game/gsound.h"
#include "game/intface.h"
#include "game/inventry.h"
#include "game/item.h"
#include "game/object.h"
#include "game/perk.h"
#include "game/protinst.h"
#include "game/proto.h"
#include "game/stat.h"
#include "mcp/lua_fields.h"

namespace fallout {

// What the player carries, and the tools to equip and use it without the
// inventory screen. Everything here is something the engine already does
// outside that screen for scripts (op_wield_obj_critter) or the screen does
// itself (inven_action_cursor's "use"), and equipped items stay in the
// inventory list, flagged.

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

static const char* slot_name(Object* item)
{
    if ((item->flags & OBJECT_WORN) != 0) {
        return "armor";
    }
    if ((item->flags & OBJECT_IN_RIGHT_HAND) != 0) {
        return "right_hand";
    }
    if ((item->flags & OBJECT_IN_LEFT_HAND) != 0) {
        return "left_hand";
    }
    return nullptr;
}

static const char* hand_name(int hand)
{
    return hand == HAND_LEFT ? "left" : "right";
}

// The player's own items, top level only: equipping from inside a bag isn't
// something the game allows either.
static InventoryItem* find_carried(int id)
{
    Inventory* inventory = &(obj_dude->data.inventory);
    for (int index = 0; index < inventory->length; index++) {
        if (inventory->items[index].item->id == id) {
            return &(inventory->items[index]);
        }
    }
    return nullptr;
}

// What opening the inventory costs in combat (handle_inventory), so doing it
// through these tools costs the same.
static int inventory_ap_cost()
{
    return isInCombat() ? 4 - perk_level(PERK_QUICK_POCKETS) : 0;
}

// Why the player can't act on their inventory now, or null if they can.
static const char* inventory_blocked()
{
    if (!mcp_in_game()) {
        return "there's no game in progress";
    }

    if (inven_open_screen() != -1) {
        return "an inventory screen is open; close it first (escape)";
    }

    if (isInCombat()) {
        if (combat_whose_turn() != obj_dude || (combat_state & COMBAT_STATE_0x02) == 0) {
            return "it isn't your turn";
        }

        int cost = inventory_ap_cost();
        if (cost > 0 && cost > obj_dude->data.critter.combat.ap) {
            return "not enough AP: using the inventory in combat costs 4";
        }
    }

    return nullptr;
}

static void charge_inventory_ap()
{
    int cost = inventory_ap_cost();
    if (cost > 0) {
        obj_dude->data.critter.combat.ap -= cost;
        intface_update_move_points(obj_dude->data.critter.combat.ap, combat_free_move);
    }
}

static int fail(lua_State* L, const char* reason)
{
    lua_pushboolean(L, false);
    lua_pushstring(L, reason);
    return 2;
}

static void push_item_ref(lua_State* L, Object* item)
{
    lua_createtable(L, 0, 2);
    set_int(L, "id", item->id);
    set_string(L, "name", object_name(item));
}

// fo.inventory(): everything the player carries, as { items, weight,
// capacity, caps, active_hand, screen_open }. Each item has id, name, type,
// quantity, weight, the slot it's in, and for weapons the ammo loaded.
static int fo_inventory(lua_State* L)
{
    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    Inventory* inventory = &(obj_dude->data.inventory);

    lua_createtable(L, 0, 6);
    lua_createtable(L, inventory->length, 0);
    for (int index = 0; index < inventory->length; index++) {
        InventoryItem* entry = &(inventory->items[index]);
        Object* item = entry->item;
        int type = item_get_type(item);

        lua_createtable(L, 0, 7);
        set_int(L, "id", item->id);
        set_string(L, "name", object_name(item));
        set_string(L, "type", item_type_name(type));
        set_int(L, "quantity", entry->quantity);
        set_int(L, "weight", item_weight(item));
        set_string(L, "slot", slot_name(item));

        if (type == ITEM_TYPE_WEAPON && item_w_max_ammo(item) > 0) {
            lua_createtable(L, 0, 3);
            set_int(L, "loaded", item_w_curr_ammo(item));
            set_int(L, "capacity", item_w_max_ammo(item));
            int ammoPid = item_w_ammo_pid(item);
            if (ammoPid != -1) {
                set_string(L, "type", proto_name(ammoPid));
            }
            lua_setfield(L, -2, "ammo");
        }

        lua_rawseti(L, -2, index + 1);
    }
    lua_setfield(L, -2, "items");

    set_int(L, "weight", item_total_weight(obj_dude));
    set_int(L, "capacity", stat_level(obj_dude, STAT_CARRY_WEIGHT));
    set_int(L, "caps", item_caps_total(obj_dude));
    set_string(L, "active_hand", hand_name(intface_is_item_right_hand()));
    set_bool(L, "screen_open", inven_open_screen() != -1);
    return 1;
}

// fo.equipped(): the player's hands and armor, as { active_hand, left_hand,
// right_hand, armor }, each item as { id, name }.
static int fo_equipped(lua_State* L)
{
    if (!mcp_in_game()) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 4);
    set_string(L, "active_hand", hand_name(intface_is_item_right_hand()));

    Object* left = inven_left_hand(obj_dude);
    if (left != nullptr) {
        push_item_ref(L, left);
        lua_setfield(L, -2, "left_hand");
    }

    Object* right = inven_right_hand(obj_dude);
    if (right != nullptr) {
        push_item_ref(L, right);
        lua_setfield(L, -2, "right_hand");
    }

    Object* armor = inven_worn(obj_dude);
    if (armor != nullptr) {
        push_item_ref(L, armor);
        lua_setfield(L, -2, "armor");
    }

    return 1;
}

// Reads an optional hand argument: "left", "right", or nil for the hand the
// interface has active.
static int check_hand(lua_State* L, int index)
{
    if (lua_isnoneornil(L, index)) {
        return intface_is_item_right_hand();
    }

    const char* name = luaL_checkstring(L, index);
    if (strcmp(name, "left") == 0) {
        return HAND_LEFT;
    }
    if (strcmp(name, "right") == 0) {
        return HAND_RIGHT;
    }
    return luaL_argerror(L, index, "hand must be \"left\" or \"right\"");
}

// fo.equip(id, hand): armor goes on the body; anything else into `hand`, or
// the active hand. Returns true, or false and why not.
static int fo_equip(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    int hand = check_hand(L, 2);

    const char* blocked = inventory_blocked();
    if (blocked != nullptr) {
        return fail(L, blocked);
    }

    InventoryItem* entry = find_carried(id);
    if (entry == nullptr) {
        return fail(L, "you're not carrying that item");
    }

    Object* item = entry->item;
    if (item_get_type(item) == ITEM_TYPE_ARMOR) {
        Object* oldArmor = inven_worn(obj_dude);
        if (oldArmor == item) {
            return fail(L, "you're already wearing it");
        }

        inven_wield(obj_dude, item, HAND_RIGHT);
        adjust_ac(obj_dude, oldArmor, item);
        intface_update_ac(false);
    } else {
        if (entry->quantity > 1) {
            return fail(L, "holding one item from a stack isn't supported yet");
        }

        int flag = hand == HAND_LEFT ? OBJECT_IN_LEFT_HAND : OBJECT_IN_RIGHT_HAND;
        if ((item->flags & flag) != 0) {
            return fail(L, "it's already in that hand");
        }

        // Moving between hands: the item leaves the other one.
        item->flags &= ~OBJECT_IN_ANY_HAND;

        if (inven_wield(obj_dude, item, hand) == -1) {
            return fail(L, "you can't hold that");
        }
        intface_update_items(false);
    }

    charge_inventory_ap();
    lua_pushboolean(L, true);
    return 1;
}

// fo.unequip(hand): empties `hand`, or the active hand. Returns true, or
// false and why not.
static int fo_unequip(lua_State* L)
{
    int hand = check_hand(L, 1);

    const char* blocked = inventory_blocked();
    if (blocked != nullptr) {
        return fail(L, blocked);
    }

    Object* item = hand == HAND_LEFT ? inven_left_hand(obj_dude) : inven_right_hand(obj_dude);
    if (item == nullptr) {
        return fail(L, "that hand is already empty");
    }

    inven_unwield(obj_dude, hand);
    intface_update_items(false);

    charge_inventory_ap();
    lua_pushboolean(L, true);
    return 1;
}

// fo.use_item(id): takes a drug (a stimpak, say), as the inventory's "use"
// does. Returns true, or false and why not.
static int fo_use_item(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));

    const char* blocked = inventory_blocked();
    if (blocked != nullptr) {
        return fail(L, blocked);
    }

    InventoryItem* entry = find_carried(id);
    if (entry == nullptr) {
        return fail(L, "you're not carrying that item");
    }

    Object* item = entry->item;
    if (item_get_type(item) != ITEM_TYPE_DRUG) {
        return fail(L, "only drugs, such as stimpaks, can be used this way so far");
    }

    if (item_d_take_drug(obj_dude, item) != 1) {
        return fail(L, "it had no effect");
    }

    // One from the stack is used up. item_remove_mult leaves the rest of the
    // stack in a copy, so destroying this one is safe.
    item_remove_mult(obj_dude, item, 1);
    obj_connect(item, obj_dude->tile, obj_dude->elevation, nullptr);
    obj_destroy(item);
    intface_update_hit_points(true);

    charge_inventory_ap();
    lua_pushboolean(L, true);
    return 1;
}

// fo.reload_weapon(hand): fills the weapon in `hand` (or the active hand) from the
// ammo carried, as the interface bar's reload does: as many boxes as it
// takes. In combat it costs the weapon's reload AP. Returns true and the
// rounds now loaded, or false and why not.
static int fo_reload_weapon(lua_State* L)
{
    int hand = check_hand(L, 1);

    if (!mcp_in_game()) {
        return fail(L, "there's no game in progress");
    }

    if (inven_open_screen() != -1) {
        return fail(L, "an inventory screen is open; close it first (escape)");
    }

    Object* weapon = hand == HAND_LEFT ? inven_left_hand(obj_dude) : inven_right_hand(obj_dude);
    if (weapon == nullptr || item_get_type(weapon) != ITEM_TYPE_WEAPON || item_w_max_ammo(weapon) <= 0) {
        return fail(L, "there's no weapon that takes ammo in that hand");
    }

    if (item_w_curr_ammo(weapon) == item_w_max_ammo(weapon)) {
        return fail(L, "it's already fully loaded");
    }

    int cost = 0;
    if (isInCombat()) {
        if (combat_whose_turn() != obj_dude || (combat_state & COMBAT_STATE_0x02) == 0) {
            return fail(L, "it isn't your turn");
        }

        cost = item_mp_cost(obj_dude, hand == HAND_LEFT ? HIT_MODE_LEFT_WEAPON_RELOAD : HIT_MODE_RIGHT_WEAPON_RELOAD, false);
        if (cost > obj_dude->data.critter.combat.ap) {
            return fail(L, "not enough AP to reload");
        }
    }

    bool loaded = false;
    while (item_w_try_reload(obj_dude, weapon) != -1) {
        loaded = true;
    }

    if (!loaded) {
        return fail(L, "you have no ammo that fits it");
    }

    intface_update_items(false);
    gsound_play_sfx_file(gsnd_build_weapon_sfx_name(WEAPON_SOUND_EFFECT_READY, weapon, HIT_MODE_RIGHT_WEAPON_PRIMARY, nullptr));

    if (cost > 0) {
        obj_dude->data.critter.combat.ap -= cost;
        intface_update_move_points(obj_dude->data.critter.combat.ap, combat_free_move);
    }

    lua_pushboolean(L, true);
    lua_pushinteger(L, item_w_curr_ammo(weapon));
    return 2;
}

void mcp_register_inventory_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "inventory", fo_inventory },
        { "equipped", fo_equipped },
        { "equip", fo_equip },
        { "unequip", fo_unequip },
        { "use_item", fo_use_item },
        { "reload_weapon", fo_reload_weapon },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
