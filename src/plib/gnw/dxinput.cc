#include "plib/gnw/dxinput.h"

#include <stdio.h>

#include "plib/gnw/mouse.h"
#include "plib/gnw/svga.h"
#include "plib/gnw/winmain.h"

namespace fallout {

static bool dxinput_mouse_init();
static void dxinput_mouse_exit();
static bool dxinput_keyboard_init();
static void dxinput_keyboard_exit();

static int gMouseWheelDeltaX = 0;
static int gMouseWheelDeltaY = 0;

// CE: Whether the game has the pointer, the way a virtual machine's window has
// it. Captured, SDL's relative mode locks the pointer to the window and reports
// DirectInput-style deltas. Released, the pointer belongs to the desktop and the
// game ignores it. A click in the window captures it, and Ctrl+Alt releases it.
static bool gMouseCaptured = false;

// CE: The click that captures the pointer is for the window, not the game, so
// the buttons read as up until it's let go.
static bool gMouseSwallowClick = false;

// 0x4E0400
bool dxinput_init()
{
    if (SDL_InitSubSystem(SDL_INIT_EVENTS) != 0) {
        return false;
    }

    if (!dxinput_mouse_init()) {
        goto err;
    }

    if (!dxinput_keyboard_init()) {
        goto err;
    }

    return true;

err:

    dxinput_mouse_exit();

    return false;
}

// 0x4E0478
void dxinput_exit()
{
    SDL_QuitSubSystem(SDL_INIT_EVENTS);
}

// 0x4E04E8
bool dxinput_acquire_mouse()
{
    return true;
}

// 0x4E0514
bool dxinput_unacquire_mouse()
{
    return true;
}

// 0x4E053C
bool dxinput_get_mouse_state(MouseData* mouseState)
{
    // CE: This function is sometimes called outside loops calling `get_input`
    // and subsequently `GNW95_process_message`, so mouse events might not be
    // handled by SDL yet.
    //
    // TODO: Move mouse events processing into `GNW95_process_message` and
    // update mouse position manually.
    SDL_PumpEvents();

    Uint32 buttons = SDL_GetRelativeMouseState(&(mouseState->x), &(mouseState->y));

    // CE: Released, the pointer is the desktop's: no motion, buttons or wheel.
    // The deltas are still read above, so they don't pile up for the next
    // capture.
    if (!gMouseCaptured) {
        mouseState->x = 0;
        mouseState->y = 0;
        buttons = 0;
        gMouseWheelDeltaX = 0;
        gMouseWheelDeltaY = 0;
    }

    if (gMouseSwallowClick) {
        if ((buttons & (SDL_BUTTON(SDL_BUTTON_LEFT) | SDL_BUTTON(SDL_BUTTON_RIGHT))) == 0) {
            gMouseSwallowClick = false;
        }
        buttons = 0;
    }

    mouseState->buttons[0] = (buttons & SDL_BUTTON(SDL_BUTTON_LEFT)) != 0;
    mouseState->buttons[1] = (buttons & SDL_BUTTON(SDL_BUTTON_RIGHT)) != 0;
    mouseState->wheelX = gMouseWheelDeltaX;
    mouseState->wheelY = gMouseWheelDeltaY;

    gMouseWheelDeltaX = 0;
    gMouseWheelDeltaY = 0;

    return true;
}

// 0x4E05A8
bool dxinput_acquire_keyboard()
{
    return true;
}

// 0x4E05D4
bool dxinput_unacquire_keyboard()
{
    return true;
}

// 0x4E05FC
bool dxinput_flush_keyboard_buffer()
{
    SDL_FlushEvents(SDL_KEYDOWN, SDL_TEXTINPUT);
    return true;
}

// 0x4E0650
bool dxinput_read_keyboard_buffer(KeyboardData* keyboardData)
{
    return true;
}

// 0x4E070C
bool dxinput_mouse_init()
{
    // CE: A window leaves the pointer alone until it's clicked. Fullscreen takes
    // it straight away, since there's nothing else on screen to point at.
    if ((SDL_GetWindowFlags(gSdlWindow) & SDL_WINDOW_FULLSCREEN) == 0) {
        SDL_ShowCursor(SDL_ENABLE);
        return true;
    }

    return dxinput_capture_mouse();
}

// CE: Takes the pointer; see `gMouseCaptured`. The window title says how to let
// it go.
bool dxinput_capture_mouse()
{
    if (SDL_SetRelativeMouseMode(SDL_TRUE) != 0) {
        return false;
    }

    // Drop the motion from while the pointer was the desktop's.
    SDL_GetRelativeMouseState(NULL, NULL);
    SDL_ShowCursor(SDL_DISABLE);
    gMouseCaptured = true;

    char title[sizeof(GNW95_title) + 64];
    snprintf(title, sizeof(title), "%s (press Ctrl+Alt to release the mouse)", GNW95_title);
    SDL_SetWindowTitle(gSdlWindow, title);

    return true;
}

// CE: Gives the pointer back to the desktop; see `gMouseCaptured`. With
// `atCursor`, the pointer reappears where the game's cursor is. It's moved
// before relative mode ends, because Wayland moves only a locked pointer.
void dxinput_release_mouse(bool atCursor)
{
    if (!gMouseCaptured) {
        return;
    }

    if (atCursor) {
        int x;
        int y;
        mouse_get_position(&x, &y);

        int windowX;
        int windowY;
        SDL_RenderLogicalToWindow(gSdlRenderer, static_cast<float>(x), static_cast<float>(y), &windowX, &windowY);
        SDL_WarpMouseInWindow(gSdlWindow, windowX, windowY);
    }

    SDL_SetRelativeMouseMode(SDL_FALSE);

    // The game draws its own cursor, so the desktop's shows only while it's
    // the desktop's pointer.
    SDL_ShowCursor(SDL_ENABLE);
    gMouseCaptured = false;
    SDL_SetWindowTitle(gSdlWindow, GNW95_title);
}

bool dxinput_mouse_is_captured()
{
    return gMouseCaptured;
}

// 0x4E078C
void dxinput_mouse_exit()
{
}

// 0x4E07B8
bool dxinput_keyboard_init()
{
    return true;
}

// 0x4E0874
void dxinput_keyboard_exit()
{
}

void handleMouseEvent(SDL_Event* event)
{
    // Mouse movement and buttons are accumulated in SDL itself and will be
    // processed later in `mouseDeviceGetData` via `SDL_GetRelativeMouseState`.

    // CE: A click in the window takes the pointer back, and goes no further.
    if (event->type == SDL_MOUSEBUTTONDOWN && !gMouseCaptured) {
        if (dxinput_capture_mouse()) {
            gMouseSwallowClick = true;
        }
        return;
    }

    if (event->type == SDL_MOUSEWHEEL) {
        gMouseWheelDeltaX += event->wheel.x;
        gMouseWheelDeltaY += event->wheel.y;
    }
}

} // namespace fallout
