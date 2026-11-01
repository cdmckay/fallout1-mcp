#ifndef FALLOUT_MCP_ATTACKS_H_
#define FALLOUT_MCP_ATTACKS_H_

#include "game/object_types.h"

namespace fallout {

// Who's a threat, and who hit whom. The engine side of the combat views, in
// mcp/bindings_combat.cc.

// Whether `critter` will attack the player, as far as a player can tell
// (mcp_hostile in mcp/combat_rules.h).
bool mcp_critter_hostile(Object* critter);

// The attack whose lines combat_display is printing, so each line can say
// whose attack it was: "You were hit for 4 hit points" doesn't. combat_display
// opens an McpAttack scope (marked MCP) for as long as it prints.
void mcp_attack_begin(Object* attacker);
void mcp_attack_end();

class McpAttack {
public:
    explicit McpAttack(Object* attacker)
    {
        mcp_attack_begin(attacker);
    }

    ~McpAttack()
    {
        mcp_attack_end();
    }

    McpAttack(const McpAttack&) = delete;
    McpAttack& operator=(const McpAttack&) = delete;
};

// Notes that message `seq` was printed during the attack in progress, if
// there is one. Called as each line is recorded.
void mcp_attribute_message(long long seq);

} // namespace fallout

#endif /* FALLOUT_MCP_ATTACKS_H_ */
