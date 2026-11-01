#ifndef FALLOUT_GAME_INVENTRY_H_
#define FALLOUT_GAME_INVENTRY_H_

#include "game/art.h"
#include "game/object_types.h"

namespace fallout {

// TODO: Convert to enum.
#define OFF_59E7BC_COUNT 12

typedef enum InventoryWindowCursor {
    INVENTORY_WINDOW_CURSOR_HAND,
    INVENTORY_WINDOW_CURSOR_ARROW,
    INVENTORY_WINDOW_CURSOR_PICK,
    INVENTORY_WINDOW_CURSOR_MENU,
    INVENTORY_WINDOW_CURSOR_BLANK,
    INVENTORY_WINDOW_CURSOR_COUNT,
} InventoryWindowCursor;

typedef enum InventoryWindowType {
    // Normal inventory window with quick character sheet.
    INVENTORY_WINDOW_TYPE_NORMAL,

    // Narrow inventory window with just an item scroller that's shown when
    // a "Use item on" is selected from context menu.
    INVENTORY_WINDOW_TYPE_USE_ITEM_ON,

    // Looting/strealing interface.
    INVENTORY_WINDOW_TYPE_LOOT,

    // Barter interface.
    INVENTORY_WINDOW_TYPE_TRADE,

    // Supplementary "Move items" window. Used to set quantity of items when
    // moving items between inventories.
    INVENTORY_WINDOW_TYPE_MOVE_ITEMS,

    // Supplementary "Set timer" window. Internally it's implemented as "Move
    // items" window but with timer overlay and slightly different adjustment
    // mechanics.
    INVENTORY_WINDOW_TYPE_SET_TIMER,

    INVENTORY_WINDOW_TYPE_COUNT,
} InventoryWindowType;

// MCP: An event code the agent injects into the loot screen to take an item
// from the other side without dragging it. `inven_take_request` says which
// and how many, and the loop moves it as dropping it on the player's side
// does (`move_inventory`).
#define INVEN_TAKE_ITEM_CODE 0x7300

// MCP: How an INVEN_TAKE_ITEM_CODE went.
typedef enum InvenTakeResult {
    INVEN_TAKE_PENDING, // not handled yet
    INVEN_TAKE_DONE,
    INVEN_TAKE_NOT_THERE, // no such item on the other side
    INVEN_TAKE_TOO_HEAVY, // more than the player can carry
    INVEN_TAKE_STEALING, // stealing goes through the Steal skill's checks
} InvenTakeResult;

// MCP: What INVEN_TAKE_ITEM_CODE takes: an item's id and how many of its
// stack. The loot screen sets `result`.
typedef struct InvenTakeRequest {
    int itemId;
    int quantity;
    int result;
} InvenTakeRequest;

extern CacheEntry* ikey[OFF_59E7BC_COUNT];
extern InvenTakeRequest inven_take_request; // MCP

void inven_set_dude(Object* obj, int pid);
void inven_reset_dude();
void handle_inventory();
bool setup_inventory(int inventoryWindowType);
void exit_inventory(bool a1);
void display_inventory(int a1, int a2, int inventoryWindowType);
void display_target_inventory(int a1, int a2, Inventory* a3, int a4);
void display_body(int fid, int inventoryWindowType);
int inven_init();
void inven_exit();
void inven_set_mouse(int cursor);
void inven_hover_on(int btn, int keyCode);
void inven_hover_off(int btn, int keyCode);
void inven_pickup(int keyCode, int a2);
void switch_hand(Object* a1, Object** a2, Object** a3, int a4);
void adjust_ac(Object* critter, Object* oldArmor, Object* newArmor);
void adjust_fid();
void use_inventory_on(Object* a1);
Object* inven_right_hand(Object* obj);
Object* inven_left_hand(Object* obj);
Object* inven_worn(Object* obj);
int inven_pid_is_carried(Object* obj, int pid);
Object* inven_pid_is_carried_ptr(Object* obj, int pid);
int inven_pid_quantity_carried(Object* obj, int pid);
void display_stats();
Object* inven_find_type(Object* obj, int a2, int* inout_a3);
Object* inven_find_id(Object* obj, int a2);
Object* inven_index_ptr(Object* obj, int a2);
int inven_wield(Object* critter, Object* item, int a3);
int inven_unwield(Object* critter, int a2);
int inven_open_screen(); // MCP
Object* inven_loot_target(); // MCP
int inven_from_button(int input, Object** a2, Object*** a3, Object** a4);
void inven_display_msg(char* string);
void inven_obj_examine_func(Object* critter, Object* item);
void inven_action_cursor(int eventCode, int inventoryWindowType);
int loot_container(Object* a1, Object* a2);
int inven_steal_container(Object* a1, Object* a2);
int move_inventory(Object* a1, int a2, Object* a3, bool a4);
void barter_inventory(int win, Object* a2, Object* a3, Object* a4, int a5);
void container_enter(int a1, int a2);
void container_exit(int keyCode, int inventoryWindowType);
int drop_into_container(Object* a1, Object* a2, int a3, Object** a4, int quantity);
int drop_ammo_into_weapon(Object* weapon, Object* ammo, Object** a3, int quantity, int keyCode);
void draw_amount(int value, int inventoryWindowType);
int inven_set_timer(Object* a1);

} // namespace fallout

#endif /* FALLOUT_GAME_INVENTRY_H_ */
