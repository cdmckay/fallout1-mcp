#include "mcp/bindings.h"

#include <algorithm>
#include <string.h>
#include <vector>

#include <lua.hpp>

#include "game/critter.h"
#include "game/editor.h"
#include "game/object.h"
#include "game/perk.h"
#include "game/proto_types.h"
#include "game/skill.h"
#include "game/stat.h"
#include "game/trait.h"
#include "mcp/lua_fields.h"
#include "plib/gnw/input.h"

namespace fallout {

// The character sheet, as the character screen shows it, and what the agent
// needs to spend points on that screen without the mouse. The screen itself
// does the spending: these only read it, and select a skill for its slider
// keys with a command code (editor.h).

static const char* const kSpecialNames[PRIMARY_STAT_COUNT] = {
    "strength",
    "perception",
    "endurance",
    "charisma",
    "intelligence",
    "agility",
    "luck",
};

// The derived stats in the order the screen lists them (ListDrvdStats).
static const struct {
    const char* name;
    int stat;
} kDerivedStats[] = {
    { "armor_class", STAT_ARMOR_CLASS },
    { "action_points", STAT_MAXIMUM_ACTION_POINTS },
    { "carry_weight", STAT_CARRY_WEIGHT },
    { "melee_damage", STAT_MELEE_DAMAGE },
    { "damage_resistance", STAT_DAMAGE_RESISTANCE },
    { "poison_resistance", STAT_POISON_RESISTANCE },
    { "radiation_resistance", STAT_RADIATION_RESISTANCE },
    { "sequence", STAT_SEQUENCE },
    { "healing_rate", STAT_HEALING_RATE },
    { "critical_chance", STAT_CRITICAL_CHANCE },
};

// The conditions the screen lights up under hit points, after poisoned and
// radiated.
static const struct {
    const char* name;
    int flag;
} kDamageConditions[] = {
    { "eye damage", DAM_BLIND },
    { "crippled right arm", DAM_CRIP_ARM_RIGHT },
    { "crippled left arm", DAM_CRIP_ARM_LEFT },
    { "crippled right leg", DAM_CRIP_LEG_RIGHT },
    { "crippled left leg", DAM_CRIP_LEG_LEFT },
};

static const char* choice_kind_name(int kind)
{
    switch (kind) {
    case EDITOR_CHOICE_PERK:
        return "perk";
    case EDITOR_CHOICE_TAG_SKILL:
        return "tag_skill";
    case EDITOR_CHOICE_LOSE_TRAIT:
        return "lose_trait";
    default:
        return "new_trait";
    }
}

static bool is_tagged(int skill)
{
    int tagged[NUM_TAGGED_SKILLS];
    skill_get_tags(tagged, NUM_TAGGED_SKILLS);
    return std::find(tagged, tagged + NUM_TAGGED_SKILLS, skill) != tagged + NUM_TAGGED_SKILLS;
}

static void push_perk(lua_State* L, int perk)
{
    lua_createtable(L, 0, 4);
    set_int(L, "id", perk);
    set_string(L, "name", perk_name(perk));
    set_int(L, "rank", perk_level(perk));
    set_string(L, "description", perk_description(perk));
}

static void push_trait(lua_State* L, int trait)
{
    lua_createtable(L, 0, 3);
    set_int(L, "id", trait);
    set_string(L, "name", trait_name(trait));
    set_string(L, "description", trait_description(trait));
}

static void push_skill_option(lua_State* L, int skill)
{
    lua_createtable(L, 0, 3);
    set_int(L, "id", skill);
    set_string(L, "name", skill_name(skill));
    set_int(L, "percent", skill_level(obj_dude, skill));
}

static void push_option(lua_State* L, int kind, int id)
{
    switch (kind) {
    case EDITOR_CHOICE_PERK:
        push_perk(L, id);
        break;
    case EDITOR_CHOICE_TAG_SKILL:
        push_skill_option(L, id);
        break;
    default:
        push_trait(L, id);
        break;
    }
}

// The perks a level-up will offer, in the order the perk dialog lists them:
// by name (ListDPerks).
static std::vector<int> perks_on_offer()
{
    int perks[PERK_COUNT];
    int count = perk_make_list(perks);
    std::vector<int> list(perks, perks + count);
    std::sort(list.begin(), list.end(), [](int a, int b) {
        return strcmp(perk_name(a), perk_name(b)) < 0;
    });
    return list;
}

// fo.character(): the player's character sheet, or nil when no game is in
// progress. Everything the character screen shows (SPECIAL, hit points and
// conditions, derived stats, skills and tags, traits, perks, level and XP),
// plus what's left to spend: `skill_points` counts the points a level-up
// will add when the screen next opens, and `perk_pending` says a perk is
// waiting. `choice` is the perk dialog's open list, with `selected` 1-based;
// with a perk waiting and no list open, `perk_options` is what it will offer.
static int fo_character(lua_State* L)
{
    if (!mcp_in_game()) {
        lua_pushnil(L);
        return 1;
    }

    lua_createtable(L, 0, 20);
    set_string(L, "name", critter_name(obj_dude));
    set_int(L, "age", stat_level(obj_dude, STAT_AGE));
    set_string(L, "gender", stat_level(obj_dude, STAT_GENDER) == GENDER_FEMALE ? "female" : "male");
    set_int(L, "level", stat_pc_get(PC_STAT_LEVEL));
    set_int(L, "xp", stat_pc_get(PC_STAT_EXPERIENCE));
    int nextLevelXp = stat_pc_min_exp();
    if (nextLevelXp != -1) {
        set_int(L, "next_level_xp", nextLevelXp);
    }
    set_int(L, "hp", critter_get_hits(obj_dude));
    set_int(L, "max_hp", stat_level(obj_dude, STAT_MAXIMUM_HIT_POINTS));
    set_bool(L, "screen_open", editor_is_open());

    lua_createtable(L, 0, PRIMARY_STAT_COUNT);
    for (int stat = 0; stat < PRIMARY_STAT_COUNT; stat++) {
        set_int(L, kSpecialNames[stat], stat_level(obj_dude, stat));
    }
    lua_setfield(L, -2, "special");

    lua_createtable(L, 0, sizeof(kDerivedStats) / sizeof(kDerivedStats[0]));
    for (const auto& derived : kDerivedStats) {
        set_int(L, derived.name, stat_level(obj_dude, derived.stat));
    }
    lua_setfield(L, -2, "derived");

    lua_newtable(L);
    int count = 0;
    if (critter_get_poison(obj_dude) != 0) {
        lua_pushstring(L, "poisoned");
        lua_rawseti(L, -2, ++count);
    }
    if (critter_get_rads(obj_dude) != 0) {
        lua_pushstring(L, "radiated");
        lua_rawseti(L, -2, ++count);
    }
    for (const auto& condition : kDamageConditions) {
        if ((obj_dude->data.critter.combat.results & condition.flag) != 0) {
            lua_pushstring(L, condition.name);
            lua_rawseti(L, -2, ++count);
        }
    }
    lua_setfield(L, -2, "conditions");

    lua_createtable(L, SKILL_COUNT, 0);
    for (int skill = 0; skill < SKILL_COUNT; skill++) {
        lua_createtable(L, 0, 4);
        set_int(L, "id", skill);
        set_string(L, "name", skill_name(skill));
        set_int(L, "percent", skill_level(obj_dude, skill));
        set_bool(L, "tagged", is_tagged(skill));
        lua_rawseti(L, -2, skill + 1);
    }
    lua_setfield(L, -2, "skills");

    int traits[PC_TRAIT_MAX];
    trait_get(&traits[0], &traits[1]);
    lua_newtable(L);
    count = 0;
    for (int trait : traits) {
        if (trait != -1) {
            push_trait(L, trait);
            lua_rawseti(L, -2, ++count);
        }
    }
    lua_setfield(L, -2, "traits");

    lua_newtable(L);
    count = 0;
    for (int perk = 0; perk < PERK_COUNT; perk++) {
        if (perk_level(perk) > 0) {
            push_perk(L, perk);
            lua_rawseti(L, -2, ++count);
        }
    }
    lua_setfield(L, -2, "perks");

    int skillPoints;
    bool perkPending;
    editor_level_up_preview(&skillPoints, &perkPending);
    set_int(L, "skill_points", skillPoints);
    set_bool(L, "perk_pending", perkPending);

    if (editor_is_open()) {
        set_string(L, "selected_skill", skill_name(editor_selected_skill()));
    }

    int kind;
    int ids[PERK_COUNT];
    int selected;
    int options = editor_choice(&kind, ids, PERK_COUNT, &selected);
    if (options > 0) {
        lua_createtable(L, 0, 3);
        set_string(L, "kind", choice_kind_name(kind));
        set_int(L, "selected", selected + 1);
        lua_createtable(L, options, 0);
        for (int index = 0; index < options; index++) {
            push_option(L, kind, ids[index]);
            lua_rawseti(L, -2, index + 1);
        }
        lua_setfield(L, -2, "options");
        lua_setfield(L, -2, "choice");
    } else if (perkPending) {
        std::vector<int> perks = perks_on_offer();
        lua_createtable(L, static_cast<int>(perks.size()), 0);
        for (size_t index = 0; index < perks.size(); index++) {
            push_perk(L, perks[index]);
            lua_rawseti(L, -2, static_cast<lua_Integer>(index + 1));
        }
        lua_setfield(L, -2, "perk_options");
    }

    return 1;
}

// fo.select_skill(id): on the character screen, selects skill `id` for the
// slider keys, as clicking its name does, by queueing the screen's command
// code. Returns false if the input queue is full.
static int fo_select_skill(lua_State* L)
{
    lua_Integer skill = luaL_checkinteger(L, 1);
    luaL_argcheck(L, skill >= 0 && skill < SKILL_COUNT, 1, "not a skill");

    if (!editor_is_open()) {
        return luaL_error(L, "the character screen isn't open");
    }

    if (input_buffer_is_full()) {
        lua_pushboolean(L, false);
        return 1;
    }

    GNW_add_input_buffer(EDITOR_SELECT_SKILL_CODE + static_cast<int>(skill));
    lua_pushboolean(L, true);
    return 1;
}

// fo.give_xp(amount): adds experience, as a quest reward does, levelling up
// if it's enough. For testing level-ups; Lua offers it in omniscient mode
// only.
static int fo_give_xp(lua_State* L)
{
    lua_Integer amount = luaL_checkinteger(L, 1);
    luaL_argcheck(L, amount > 0 && amount <= 1000000, 1, "amount must be 1 to 1000000");

    if (!mcp_in_game()) {
        return luaL_error(L, "no game in progress");
    }

    stat_pc_add_experience(static_cast<int>(amount));
    lua_pushinteger(L, stat_pc_get(PC_STAT_EXPERIENCE));
    return 1;
}

void mcp_register_character_bindings(lua_State* L)
{
    static const luaL_Reg functions[] = {
        { "character", fo_character },
        { "select_skill", fo_select_skill },
        { "give_xp", fo_give_xp },
        { nullptr, nullptr },
    };

    luaL_setfuncs(L, functions, 0);
}

} // namespace fallout
