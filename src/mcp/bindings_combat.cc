#include "mcp/attacks.h"

#include <deque>
#include <optional>
#include <string>
#include <utility>

#include <lua.hpp>

#include "game/combat.h"
#include "game/critter.h"
#include "game/object.h"
#include "mcp/bindings.h"
#include "mcp/combat_rules.h"
#include "mcp/lua_fields.h"
#include "mcp/mcp.h"
#include "mcp/sight.h"

namespace fallout {

// As many attributed lines as the message log keeps lines.
static const size_t kAttributedCapacity = 500;

bool mcp_critter_hostile(Object* critter)
{
    int team = obj_dude->data.critter.combat.team;

    // who_hit_me only means something during a fight: the game clears it
    // when one starts and ends.
    bool hitByPlayerSide = false;
    if (isInCombat()) {
        Object* whoHitMe = critter->data.critter.combat.whoHitMe;
        hitByPlayerSide = whoHitMe != nullptr && (whoHitMe == obj_dude || whoHitMe->data.critter.combat.team == team);
    }

    McpHostility hostility;
    hostility.dead = critter_is_dead(critter);
    hostility.playerTeam = critter->data.critter.combat.team == team;
    hostility.combatant = combat_is_combatant(critter);
    hostility.hitByPlayerSide = hitByPlayerSide;
    hostility.killType = critter_kill_count_type(critter);
    return mcp_hostile(hostility);
}

// Who made an attack, as a player saw it when it happened.
struct Attacker {
    int id;
    std::string name;
    bool visible;
};

// The attack combat_display is printing, if it's someone else's.
static std::optional<Attacker> gAttacker;

// The lines printed during someone else's attack, by message number, oldest
// first.
static std::deque<std::pair<long long, Attacker>> gAttributed;

void mcp_attack_begin(Object* attacker)
{
    gAttacker.reset();
    // The player's own attacks need no naming.
    if (!mcp_is_enabled() || attacker == nullptr || attacker == obj_dude || PID_TYPE(attacker->pid) != OBJ_TYPE_CRITTER) {
        return;
    }

    const char* name = object_name(attacker);
    gAttacker = Attacker { attacker->id, name != nullptr ? name : "", mcp_object_visible(attacker) };
}

void mcp_attack_end()
{
    gAttacker.reset();
}

void mcp_attribute_message(long long seq)
{
    if (!gAttacker.has_value()) {
        return;
    }

    gAttributed.emplace_back(seq, *gAttacker);
    while (gAttributed.size() > kAttributedCapacity) {
        gAttributed.pop_front();
    }
}

void mcp_set_message_attacker(lua_State* L, long long seq)
{
    for (const auto& line : gAttributed) {
        if (line.first == seq) {
            lua_createtable(L, 0, 3);
            set_int(L, "id", line.second.id);
            set_string(L, "name", line.second.name.c_str());
            set_bool(L, "visible", line.second.visible);
            lua_setfield(L, -2, "attacker");
            return;
        }
    }
}

} // namespace fallout
