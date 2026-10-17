#ifndef CGSBRIDGE_H
#define CGSBRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

/// The window server functions used here are private but read-only, and have been
/// stable since OS X 10.9. They are resolved lazily with dlsym so a future macOS that
/// drops one degrades gracefully instead of failing to launch.

/// True when every symbol needed to read the Spaces layout is available.
bool SNSpacesAvailable(void);

/// One dictionary per display ("Display Identifier", "Current Space", "Spaces"),
/// with Spaces listed in Mission Control order.
CFArrayRef _Nullable SNCopyManagedDisplaySpaces(void) CF_RETURNS_RETAINED;

/// Identifier of the display that owns the active menu bar ("Main" when displays share Spaces).
CFStringRef _Nullable SNCopyActiveMenuBarDisplayIdentifier(void) CF_RETURNS_RETAINED;

/// Managed IDs of every Space the given window is on, or NULL.
CFArrayRef _Nullable SNCopySpacesForWindow(uint32_t windowID) CF_RETURNS_RETAINED;

/// Creates a space of our own, drawn above the desktops at `level` (1 or more) and
/// outside them, so windows put in it stay where they are while desktops slide past
/// during a Space switch. Returns 0 if unavailable. It goes away with the process.
uint64_t SNCreateOverlaySpace(int32_t level);

/// Moves one of this app's windows into `space` (from `SNCreateOverlaySpace`), out of
/// every desktop it was on.
bool SNMoveWindowToSpace(uint32_t windowID, uint64_t space);

/// Adds one of this app's windows to, or removes it from, a space (a desktop's managed ID
/// or one from `SNCreateOverlaySpace`).
bool SNAddWindowToSpace(uint32_t windowID, uint64_t space);
bool SNRemoveWindowFromSpace(uint32_t windowID, uint64_t space);

/// Gesture phases understood by the Dock.
typedef CF_ENUM(int32_t, SNSwipePhase) {
    SNSwipePhaseBegan = 1,
    SNSwipePhaseChanged = 2,
    SNSwipePhaseEnded = 4,
    SNSwipePhaseCancelled = 8,
};

/// Direction of a Dock swipe: between Spaces, or up/down for Mission Control.
typedef CF_ENUM(int32_t, SNSwipeMotion) {
    SNSwipeMotionHorizontal = 1,
    SNSwipeMotionVertical = 2,
};

/// Posts one frame of a synthetic Dock swipe, the same event a trackpad produces when
/// swiping between Spaces (horizontal) or into Mission Control (vertical). `progress`
/// is measured in Space widths; `velocity` only matters on the final (ended) frame and
/// controls how fast the Dock finishes the transition. Requires Accessibility access.
bool SNPostDockSwipe(SNSwipePhase phase, double progress, double velocity);
bool SNPostDockSwipeWithMotion(SNSwipePhase phase, SNSwipeMotion motion, double progress, double velocity);

/// Variations used while working out which fields the Dock requires.
typedef CF_OPTIONS(uint32_t, SNSwipeOptions) {
    SNSwipeOptionHIDTap = 1 << 0,
    SNSwipeOptionInverted = 1 << 1,
    SNSwipeOptionScrollField = 1 << 2,
    SNSwipeOptionGestureHIDType = 1 << 3,
    SNSwipeOptionGestureFirst = 1 << 4,
    SNSwipeOptionNoGesture = 1 << 5,
};
bool SNPostDockSwipeWithOptions(SNSwipePhase phase, SNSwipeMotion motion, double progress, double velocity, SNSwipeOptions options);

/// Window server events of interest. These arrive without any polling.
typedef CF_ENUM(int32_t, SNWindowServerEvent) {
    /// Mission Control (or App Exposé) is starting to come up; posted as it begins.
    SNWindowServerEventExposeBegan = 1327,
    /// It has finished going away.
    SNWindowServerEventExposeEnded = 1328,
};

typedef void (*SNWindowServerEventHandler)(SNWindowServerEvent event);

/// Calls `handler` (on the main thread) whenever `event` is posted. Returns false if the
/// window server doesn't offer it.
bool SNObserveWindowServerEvent(SNWindowServerEvent event, SNWindowServerEventHandler handler);

/// Development aid: logs every window server notification in [from, to) with its host time.
void SNDebugObserveNotifications(int32_t from, int32_t to);

CF_ASSUME_NONNULL_END

#endif
