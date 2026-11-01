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
#include "game/intface.h"
#include "game/inventry.h"
#include "game/item.h"
#include "game/main.h"
#include "game/mainmenu.h"
#include "game/map.h"
#include "game/message.h"
#include "game/object.h"
#include "game/perk.h"
#include "game/proto.h"
#include "game/proto_types.h"
#include "game/scripts.h"
#include "game/select.h"
#include "game/skill.h"
#include "game/stat.h"
#include "game/tile.h"
#include "game/trait.h"
#include "game/worldmap.h"
#include "int/movie.h"
#include "mcp/lua_fields.h"
#include "mcp/mcp.h"
#include "mcp/message_log.h"
#include "mcp/png.h"
#include "mcp/screens.h"
#include "mcp/sight.h"
#include "plib/gnw/input.h"
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

static const char* inventory_screen_name(int type)
{
    switch (type) {
    case INVENTORY_WINDOW_TYPE_NORMAL:
        return "inventory";
    case INVENTORY_WINDOW_TYPE_USE_ITEM_ON:
        return "use_item_on";
    case INVENTORY_WINDOW_TYPE_LOOT:
        return "loot";
    case INVENTORY_WINDOW_TYPE_TRADE:
        return "barter";
    default:
        return nullptr;
    }
}

// fo.flags(): the raw "which screen is up" flags. lua/mcp/state.lua turns
// them into a mode, since several can be set at once. `screen` is the
// innermost screen from the registry (mcp/screens.h), and `inventory_screen`
// the open inventory-family screen, if any.
static int fo_flags(lua_State* L)
{
    lua_createtable(L, 0, 10);
    set_bool(L, "movie", moviePlaying() != 0);
    set_bool(L, "main_menu", in_main_menu);
    set_bool(L, "character_select", select_window_id != -1);
    set_bool(L, "character_editor", editor_is_open());
    set_bool(L, "in_game", main_game_is_running());
    set_bool(L, "world_map", world_map_is_open());
    set_bool(L, "dialog", dialog_active());
    set_bool(L, "combat", isInCombat());
    set_string(L, "inventory_screen", inventory_screen_name(inven_open_screen()));

    const std::vector<std::string>& screens = mcp_screens();
    if (!screens.empty()) {
        set_string(L, "screen", screens.back().c_str());
    }
    return 1;
}

// fo.premade(): the character on the character select screen, as that screen
// shows it, or nil when it isn't up. The premade is loaded into the player
// object while it's on screen (`select_update_display`).
static int fo_premade(lua_State* L)
{
    if (select_window_id == -1 || obj_dude == nullptr) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 8);
    set_string(L, "name", object_name(obj_dude));
    set_int(L, "hp", stat_level(obj_dude, STAT_MAXIMUM_HIT_POINTS));
    set_int(L, "ac", stat_level(obj_dude, STAT_ARMOR_CLASS));
    set_int(L, "ap", stat_level(obj_dude, STAT_MAXIMUM_ACTION_POINTS));

    static const char* const kSpecial[] = { "strength", "perception", "endurance", "charisma", "intelligence", "agility", "luck" };
    lua_createtable(L, 0, 7);
    for (int stat = STAT_STRENGTH; stat <= STAT_LUCK; stat++) {
        set_int(L, kSpecial[stat - STAT_STRENGTH], stat_level(obj_dude, stat));
    }
    lua_setfield(L, -2, "special");

    int traits[2];
    trait_get(&traits[0], &traits[1]);
    lua_newtable(L);
    int count = 0;
    for (int trait : traits) {
        if (trait != -1) {
            lua_pushstring(L, trait_name(trait));
            lua_rawseti(L, -2, ++count);
        }
    }
    lua_setfield(L, -2, "traits");

    int tagged[NUM_TAGGED_SKILLS];
    skill_get_tags(tagged, NUM_TAGGED_SKILLS);
    lua_newtable(L);
    count = 0;
    for (int skill : tagged) {
        if (skill != -1) {
            lua_createtable(L, 0, 2);
            set_string(L, "name", skill_name(skill));
            set_int(L, "percent", skill_level(obj_dude, skill));
            lua_rawseti(L, -2, ++count);
        }
    }
    lua_setfield(L, -2, "tagged_skills");

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

// fo.screenshot(gamma): the current frame as a base64 PNG, plus its width and
// height. The frame is the game's logical resolution whatever the window's
// scale, and the coordinates match the game's own. A gamma below 1 brightens
// it, as turning up the game's brightness would.
static int fo_screenshot(lua_State* L)
{
    float gamma = static_cast<float>(luaL_optnumber(L, 1, 1.0));
    luaL_argcheck(L, gamma > 0.0f && gamma <= 4.0f, 1, "gamma must be above 0 and at most 4");

    std::vector<unsigned char> png;
    if (!mcp_encode_png(gSdlTextureSurface, png, gamma)) {
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

bool mcp_in_game()
{
    return main_game_is_running() && obj_dude != nullptr;
}

static bool in_game()
{
    return mcp_in_game();
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

// fo.view_center(): the tile the view is centered on.
static int fo_view_center(lua_State* L)
{
    lua_pushinteger(L, tile_center_tile);
    return 1;
}

// fo.set_view_center(tile, refresh): moves the view, as scrolling does, within
// the same limits a player scrolling has: no further than the game lets the
// view stray from the player, and not past scroll blockers. Without `refresh`
// nothing is redrawn, so the move can be undone unseen. Returns whether the
// view moved.
static int fo_set_view_center(lua_State* L)
{
    int tile = check_tile(L, 1);
    bool refresh = lua_toboolean(L, 2) != 0;
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    lua_pushboolean(L, tile_set_center(tile, refresh ? TILE_SET_CENTER_REFRESH_WINDOW : 0) == 0);
    return 1;
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

// Everything the message window has shown, numbered.
static MessageLog gMessages(500);

void mcp_record_message(const char* text)
{
    if (text != nullptr) {
        gMessages.add(text);
    }
}

// fo.messages(after): the message window's lines numbered after `after`, as
// { seq, text } oldest first, then the newest number.
static int fo_messages(lua_State* L)
{
    long long after = luaL_optinteger(L, 1, 0);

    auto lines = gMessages.since(after);
    lua_createtable(L, static_cast<int>(lines.size()), 0);
    for (size_t i = 0; i < lines.size(); i++) {
        lua_createtable(L, 0, 2);
        set_int(L, "seq", lines[i].first);
        set_string(L, "text", lines[i].second.c_str());
        lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
    }

    lua_pushinteger(L, gMessages.latest());
    return 2;
}

static const char* hit_mode_name(int hitMode)
{
    switch (hitMode) {
    case HIT_MODE_LEFT_WEAPON_PRIMARY:
    case HIT_MODE_RIGHT_WEAPON_PRIMARY:
        return "primary";
    case HIT_MODE_LEFT_WEAPON_SECONDARY:
    case HIT_MODE_RIGHT_WEAPON_SECONDARY:
        return "secondary";
    case HIT_MODE_LEFT_WEAPON_RELOAD:
    case HIT_MODE_RIGHT_WEAPON_RELOAD:
        return "reload";
    case HIT_MODE_KICK:
        return "kick";
    default:
        // Every unarmed punch, whatever its level.
        return "punch";
    }
}

static const char* bad_shot_reason(int rc)
{
    switch (rc) {
    case COMBAT_BAD_SHOT_NO_AMMO:
        return "out of ammo";
    case COMBAT_BAD_SHOT_OUT_OF_RANGE:
        return "out of range";
    case COMBAT_BAD_SHOT_NOT_ENOUGH_AP:
        return "not enough AP";
    case COMBAT_BAD_SHOT_ALREADY_DEAD:
        return "already dead";
    case COMBAT_BAD_SHOT_AIM_BLOCKED:
        return "your aim is blocked";
    case COMBAT_BAD_SHOT_ARM_CRIPPLED:
        return "a crippled arm can't use a two-handed weapon";
    case COMBAT_BAD_SHOT_BOTH_ARMS_CRIPPLED:
        return "both arms are crippled";
    default:
        return nullptr;
    }
}

// The health word the game's examine text uses ("almost dead" up to
// "unhurt"), from the same buckets as `obj_examine_func`.
static const char* health_description(Object* critter)
{
    int maximum = stat_level(critter, STAT_MAXIMUM_HIT_POINTS);
    int current = stat_level(critter, STAT_CURRENT_HIT_POINTS);

    int bucket;
    if (current <= 0 || critter_is_dead(critter)) {
        bucket = 0;
    } else if (current >= maximum) {
        bucket = 4;
    } else {
        bucket = (current * 3) / maximum + 1;
    }

    MessageListItem item;
    item.num = 500 + bucket;
    return message_search(&proto_main_msg_file, &item) ? item.text : nullptr;
}

// fo.combat(): nil outside combat; otherwise whose turn it is, whether the
// player can act, AP and free-move AP, whether anything is still playing
// out, and the attack the interface has selected.
static int fo_combat(lua_State* L)
{
    if (!in_game() || !isInCombat()) {
        lua_pushnil(L);
        return 1;
    }

    Object* turn = combat_whose_turn();
    bool playerTurn = turn == obj_dude;

    lua_createtable(L, 0, 7);
    set_string(L, "turn", turn != nullptr ? object_name(turn) : nullptr);
    set_bool(L, "player_turn", playerTurn);
    set_bool(L, "can_act", playerTurn && (combat_state & COMBAT_STATE_0x02) != 0);
    set_bool(L, "animating", combat_is_animating() || anim_busy(obj_dude) != 0);
    set_int(L, "ap", obj_dude->data.critter.combat.ap);
    set_int(L, "max_ap", stat_level(obj_dude, STAT_MAXIMUM_ACTION_POINTS));
    set_int(L, "free_move", combat_free_move);

    int hitMode;
    bool aiming;
    if (intface_get_attack(&hitMode, &aiming) != -1) {
        Object* weapon = item_hit_with(obj_dude, hitMode);
        lua_createtable(L, 0, 5);
        set_int(L, "hit_mode", hitMode);
        set_string(L, "mode", hit_mode_name(hitMode));
        set_bool(L, "aiming", aiming);
        set_int(L, "ap_cost", item_w_mp_cost(obj_dude, hitMode, aiming));
        set_int(L, "range", item_w_range(obj_dude, hitMode));
        set_string(L, "weapon", weapon != nullptr ? object_name(weapon) : "unarmed");
        if (weapon != nullptr && item_w_max_ammo(weapon) > 0) {
            set_int(L, "ammo", item_w_curr_ammo(weapon));
            set_int(L, "ammo_capacity", item_w_max_ammo(weapon));
        }
        lua_setfield(L, -2, "attack");
    }

    return 1;
}

// fo.critters(): every critter on the player's elevation but the player,
// with everything the views might show. lua/mcp/state.lua decides which
// critters and fields a player would see.
static int fo_critters(lua_State* L)
{
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    int hitMode = -1;
    bool aiming = false;
    bool canAttack = isInCombat() && intface_get_attack(&hitMode, &aiming) != -1;

    // Collected first: the object cursor is shared, and the hit-chance code
    // below shouldn't be trusted not to move it.
    std::vector<Object*> critters;
    for (Object* obj = obj_find_first_at(obj_dude->elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj != obj_dude && PID_TYPE(obj->pid) == OBJ_TYPE_CRITTER) {
            critters.push_back(obj);
        }
    }

    lua_createtable(L, static_cast<int>(critters.size()), 0);
    int count = 0;

    for (Object* obj : critters) {
        lua_createtable(L, 0, 14);
        set_int(L, "id", obj->id);
        set_string(L, "name", object_name(obj));
        set_int(L, "tile", obj->tile);
        set_bool(L, "hidden", (obj->flags & OBJECT_HIDDEN) != 0);
        set_bool(L, "visible", mcp_object_visible(obj));
        set_bool(L, "dead", critter_is_dead(obj));
        set_bool(L, "knocked_down", (obj->data.critter.combat.results & DAM_KNOCKED_DOWN) != 0);
        set_bool(L, "crippled", critter_is_crippled(obj));
        set_bool(L, "hostile", obj->data.critter.combat.team != obj_dude->data.critter.combat.team);
        set_int(L, "hp", stat_level(obj, STAT_CURRENT_HIT_POINTS));
        set_int(L, "max_hp", stat_level(obj, STAT_MAXIMUM_HIT_POINTS));
        set_string(L, "health", health_description(obj));

        if (canAttack && !critter_is_dead(obj)) {
            int rc = combat_check_bad_shot(obj_dude, obj, hitMode, aiming);
            set_int(L, "hit_chance", determine_to_hit(obj_dude, obj, HIT_LOCATION_UNCALLED, hitMode));
            set_bool(L, "can_attack", rc == COMBAT_BAD_SHOT_OK);
            set_string(L, "why_not", bad_shot_reason(rc));
        }

        lua_rawseti(L, -2, ++count);
    }

    return 1;
}

// fo.awareness(): whether the player has the Awareness perk, which makes
// examining a critter show its exact HP and weapon.
static int fo_awareness(lua_State* L)
{
    lua_pushboolean(L, perk_level(PERK_AWARENESS) > 0);
    return 1;
}

static Object* find_critter(int id)
{
    for (Object* obj = obj_find_first_at(obj_dude->elevation); obj != nullptr; obj = obj_find_next_at()) {
        if (obj->id == id && PID_TYPE(obj->pid) == OBJ_TYPE_CRITTER && obj != obj_dude) {
            return obj;
        }
    }
    return nullptr;
}

// fo.attack(id): during the player's turn, attacks critter `id` with the
// interface's selected attack, as clicking it in combat does
// (`combat_attack_this` without the called-shot screen). Returns true, or
// false and why not.
static int fo_attack(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    if (!in_game() || !isInCombat()) {
        return luaL_error(L, "not in combat");
    }

    Object* target = find_critter(id);
    if (target == nullptr) {
        lua_pushboolean(L, false);
        lua_pushfstring(L, "there's no critter %d here", id);
        return 2;
    }

    if (combat_whose_turn() != obj_dude || (combat_state & COMBAT_STATE_0x02) == 0) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "it isn't your turn");
        return 2;
    }

    int hitMode;
    bool aiming;
    if (intface_get_attack(&hitMode, &aiming) == -1) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "there's no attack selected");
        return 2;
    }

    if (hitMode == HIT_MODE_LEFT_WEAPON_RELOAD || hitMode == HIT_MODE_RIGHT_WEAPON_RELOAD) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "the selected mode is reload; press n to change mode");
        return 2;
    }

    if (aiming) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "aimed shots aren't supported yet; press n to change mode");
        return 2;
    }

    int rc = combat_check_bad_shot(obj_dude, target, hitMode, false);
    if (rc != COMBAT_BAD_SHOT_OK) {
        lua_pushboolean(L, false);
        lua_pushstring(L, bad_shot_reason(rc));
        return 2;
    }

    lua_pushboolean(L, combat_attack(obj_dude, target, hitMode, HIT_LOCATION_UNCALLED) == 0);
    return 1;
}

// fo.approach(id, reserve_ap): moves the player up next to critter `id`, the
// way the game walks up to something it's about to use. In combat it spends
// AP but keeps `reserve_ap` back, as the game's Ctrl-move keeps AP for an
// attack. Returns whether the engine took the move.
static int fo_approach(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    lua_Integer reserve = luaL_optinteger(L, 2, 0);
    if (!in_game()) {
        return luaL_error(L, "no game in progress");
    }

    Object* target = find_critter(id);
    if (target == nullptr) {
        return luaL_error(L, "there's no critter %d here", id);
    }

    int actionPoints = -1;
    if (isInCombat()) {
        actionPoints = combat_free_move + obj_dude->data.critter.combat.ap - static_cast<int>(reserve);
        if (actionPoints <= 0) {
            lua_pushboolean(L, false);
            return 1;
        }
    }

    register_begin(ANIMATION_REQUEST_RESERVED);
    register_object_move_to_object(obj_dude, target, actionPoints, 0);
    lua_pushboolean(L, register_end() == 0);
    return 1;
}

// fo.start_fight(id): outside combat, attacks critter `id`, which starts
// combat. This runs the whole combat loop, returning only when the fight is
// over, so Lua must `post` it rather than call it from a request.
static int fo_start_fight(lua_State* L)
{
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    if (!in_game() || isInCombat()) {
        return luaL_error(L, "already in combat, or no game in progress");
    }

    Object* target = find_critter(id);
    if (target == nullptr) {
        return luaL_error(L, "there's no critter %d here", id);
    }

    combat_attack_this(target);
    return 0;
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

void mcp_follow_player()
{
    // Only when the player has moved: a view panned with the arrow keys
    // stays put until they take a step.
    static int lastTile = -1;

    if (!in_game() || world_map_is_open() || dialog_active()) {
        return;
    }

    if (obj_dude->tile == lastTile || obj_dude->elevation != map_elevation) {
        return;
    }

    lastTile = obj_dude->tile;
    if (obj_dude->tile != tile_center_tile) {
        tile_scroll_to(obj_dude->tile, 2);
    }
}

void mcp_register_engine_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "window_focused", fo_window_focused },
        { "flags", fo_flags },
        { "premade", fo_premade },
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
        { "view_center", fo_view_center },
        { "set_view_center", fo_set_view_center },
        { "tile_direction", fo_tile_direction },
        { "exits", fo_exits },
        { "map_name", fo_map_name },
        { "messages", fo_messages },
        { "combat", fo_combat },
        { "critters", fo_critters },
        { "awareness", fo_awareness },
        { "attack", fo_attack },
        { "approach", fo_approach },
        { "start_fight", fo_start_fight },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
    mcp_register_inventory_bindings(L);
    mcp_register_character_bindings(L);
    mcp_register_map_bindings(L);
    mcp_register_walk_bindings(L);
}

} // namespace fallout
