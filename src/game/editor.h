#ifndef FALLOUT_GAME_EDITOR_H_
#define FALLOUT_GAME_EDITOR_H_

#include "plib/db/db.h"

namespace fallout {

extern int character_points;

int editor_design(bool isCreationMode);
void CharEditInit();
int get_input_str(int win, int cancelKeyCode, char* text, int maxLength, int x, int y, int textColor, int backgroundColor, int flags);
bool isdoschar(int ch);
char* strmfe(char* dest, const char* name, const char* ext);
bool db_access(const char* fname);
char* AddSpaces(char* string, int length);
char* itostndn(int value, char* dest);
int editor_save(DB_FILE* stream);
int editor_load(DB_FILE* stream);
void editor_reset();
void RedrwDMPrk();

// MCP
bool editor_is_open();

// MCP: An event code the agent injects into the character screen to select a
// skill for the slider keys, as clicking its name does: this plus the skill.
#define EDITOR_SELECT_SKILL_CODE 0x7000

// MCP: What the perk dialog's list is offering.
typedef enum EditorChoice {
    EDITOR_CHOICE_PERK,
    EDITOR_CHOICE_TAG_SKILL, // Tag!'s extra tag skill
    EDITOR_CHOICE_LOSE_TRAIT, // Mutate!'s trait to give up
    EDITOR_CHOICE_NEW_TRAIT, // and the one to take instead
} EditorChoice;

// MCP
int editor_selected_skill();
void editor_level_up_preview(int* skillPoints, bool* perk);
int editor_choice(int* kind, int* ids, int max, int* selected);

} // namespace fallout

#endif /* FALLOUT_GAME_EDITOR_H_ */
