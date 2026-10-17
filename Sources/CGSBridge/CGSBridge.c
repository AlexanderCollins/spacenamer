#include "CGSBridge.h"

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

typedef int32_t SNConnectionID;

typedef SNConnectionID (*SNMainConnectionIDFn)(void);
typedef CFArrayRef (*SNCopyManagedDisplaySpacesFn)(SNConnectionID);
typedef CFStringRef (*SNCopyActiveMenuBarDisplayIdentifierFn)(SNConnectionID);
typedef CFArrayRef (*SNCopySpacesForWindowsFn)(SNConnectionID, int32_t mask, CFArrayRef windows);

static SNMainConnectionIDFn sMainConnectionID;
static SNCopyManagedDisplaySpacesFn sCopyManagedDisplaySpaces;
static SNCopyActiveMenuBarDisplayIdentifierFn sCopyActiveMenuBarDisplayIdentifier;
static SNCopySpacesForWindowsFn sCopySpacesForWindows;
typedef uint64_t (*SNSpaceCreateFn)(SNConnectionID, int32_t flag, CFDictionaryRef _Nullable options);
typedef void (*SNSpaceSetAbsoluteLevelFn)(SNConnectionID, uint64_t space, int32_t level);
typedef void (*SNShowSpacesFn)(SNConnectionID, CFArrayRef spaces);
typedef void (*SNWindowsSpacesFn)(SNConnectionID, CFArrayRef windows, CFArrayRef spaces);
static SNSpaceCreateFn sSpaceCreate;
static SNSpaceSetAbsoluteLevelFn sSpaceSetAbsoluteLevel;
static SNShowSpacesFn sShowSpaces;
static SNWindowsSpacesFn sAddWindowsToSpaces;
static SNWindowsSpacesFn sRemoveWindowsFromSpaces;
static pthread_once_t sLoadOnce = PTHREAD_ONCE_INIT;

static void *SNLookup(const char *cgsName, const char *slsName) {
    void *symbol = dlsym(RTLD_DEFAULT, cgsName);
    if (symbol == NULL) symbol = dlsym(RTLD_DEFAULT, slsName);
    return symbol;
}

static void SNLoadSymbols(void) {
    // CoreGraphics re-exports these from SkyLight; load SkyLight too in case a release stops doing so.
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
    sMainConnectionID = (SNMainConnectionIDFn)SNLookup("CGSMainConnectionID", "SLSMainConnectionID");
    sCopyManagedDisplaySpaces = (SNCopyManagedDisplaySpacesFn)SNLookup("CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces");
    sCopyActiveMenuBarDisplayIdentifier = (SNCopyActiveMenuBarDisplayIdentifierFn)SNLookup("CGSCopyActiveMenuBarDisplayIdentifier", "SLSCopyActiveMenuBarDisplayIdentifier");
    sCopySpacesForWindows = (SNCopySpacesForWindowsFn)SNLookup("CGSCopySpacesForWindows", "SLSCopySpacesForWindows");
    sSpaceCreate = (SNSpaceCreateFn)SNLookup("CGSSpaceCreate", "SLSSpaceCreate");
    sSpaceSetAbsoluteLevel = (SNSpaceSetAbsoluteLevelFn)SNLookup("CGSSpaceSetAbsoluteLevel", "SLSSpaceSetAbsoluteLevel");
    sShowSpaces = (SNShowSpacesFn)SNLookup("CGSShowSpaces", "SLSShowSpaces");
    sAddWindowsToSpaces = (SNWindowsSpacesFn)SNLookup("CGSAddWindowsToSpaces", "SLSAddWindowsToSpaces");
    sRemoveWindowsFromSpaces = (SNWindowsSpacesFn)SNLookup("CGSRemoveWindowsFromSpaces", "SLSRemoveWindowsFromSpaces");
}

static inline void SNEnsureLoaded(void) {
    pthread_once(&sLoadOnce, SNLoadSymbols);
}

bool SNSpacesAvailable(void) {
    SNEnsureLoaded();
    return sMainConnectionID != NULL && sCopyManagedDisplaySpaces != NULL;
}

CFArrayRef SNCopyManagedDisplaySpaces(void) {
    if (!SNSpacesAvailable()) return NULL;
    return sCopyManagedDisplaySpaces(sMainConnectionID());
}

CFStringRef SNCopyActiveMenuBarDisplayIdentifier(void) {
    SNEnsureLoaded();
    if (sMainConnectionID == NULL || sCopyActiveMenuBarDisplayIdentifier == NULL) return NULL;
    return sCopyActiveMenuBarDisplayIdentifier(sMainConnectionID());
}

CFArrayRef SNCopySpacesForWindow(uint32_t windowID) {
    SNEnsureLoaded();
    if (sMainConnectionID == NULL || sCopySpacesForWindows == NULL) return NULL;

    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &windowID);
    if (number == NULL) return NULL;
    CFArrayRef windows = CFArrayCreate(kCFAllocatorDefault, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    if (windows == NULL) return NULL;

    const int32_t allSpacesMask = 0x7; // current | others | user
    CFArrayRef spaces = sCopySpacesForWindows(sMainConnectionID(), allSpacesMask, windows);
    CFRelease(windows);
    return spaces;
}

static CFArrayRef SNCreateNumberArray(CFNumberType type, const void *value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, type, value);
    if (number == NULL) return NULL;
    CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    return array;
}

uint64_t SNCreateOverlaySpace(int32_t level) {
    SNEnsureLoaded();
    if (sMainConnectionID == NULL || sSpaceCreate == NULL || sSpaceSetAbsoluteLevel == NULL
        || sShowSpaces == NULL || sAddWindowsToSpaces == NULL) return 0;
    SNConnectionID connection = sMainConnectionID();
    uint64_t space = sSpaceCreate(connection, 1, NULL);
    if (space == 0) return 0;
    sSpaceSetAbsoluteLevel(connection, space, level);
    CFArrayRef spaces = SNCreateNumberArray(kCFNumberSInt64Type, &space);
    if (spaces == NULL) return 0;
    sShowSpaces(connection, spaces);
    CFRelease(spaces);
    return space;
}

bool SNMoveWindowToSpace(uint32_t windowID, uint64_t space) {
    SNEnsureLoaded();
    if (space == 0 || sMainConnectionID == NULL || sAddWindowsToSpaces == NULL) return false;
    SNConnectionID connection = sMainConnectionID();
    CFArrayRef windows = SNCreateNumberArray(kCFNumberSInt32Type, &windowID);
    CFArrayRef target = SNCreateNumberArray(kCFNumberSInt64Type, &space);
    if (windows == NULL || target == NULL) {
        if (windows) CFRelease(windows);
        if (target) CFRelease(target);
        return false;
    }
    CFArrayRef current = SNCopySpacesForWindow(windowID);
    sAddWindowsToSpaces(connection, windows, target);
    if (current != NULL && sRemoveWindowsFromSpaces != NULL && CFArrayGetCount(current) > 0) {
        sRemoveWindowsFromSpaces(connection, windows, current);
    }
    if (current) CFRelease(current);
    CFRelease(windows);
    CFRelease(target);
    return true;
}

static bool SNChangeWindowSpace(uint32_t windowID, uint64_t space, SNWindowsSpacesFn change) {
    SNEnsureLoaded();
    if (space == 0 || sMainConnectionID == NULL || change == NULL) return false;
    CFArrayRef windows = SNCreateNumberArray(kCFNumberSInt32Type, &windowID);
    CFArrayRef spaces = SNCreateNumberArray(kCFNumberSInt64Type, &space);
    bool ok = windows != NULL && spaces != NULL;
    if (ok) change(sMainConnectionID(), windows, spaces);
    if (windows) CFRelease(windows);
    if (spaces) CFRelease(spaces);
    return ok;
}

bool SNAddWindowToSpace(uint32_t windowID, uint64_t space) {
    SNEnsureLoaded();
    return SNChangeWindowSpace(windowID, space, sAddWindowsToSpaces);
}

bool SNRemoveWindowFromSpace(uint32_t windowID, uint64_t space) {
    SNEnsureLoaded();
    return SNChangeWindowSpace(windowID, space, sRemoveWindowsFromSpaces);
}

// Undocumented CGEvent fields the Dock reads from trackpad gesture events.
enum {
    SNFieldGestureTag = 41,
    SNFieldEventType = 55,
    SNFieldHIDType = 110,
    SNFieldSwipeMotion = 123,
    SNFieldSwipeProgress = 124,
    SNFieldSwipeVelocityX = 129,
    SNFieldSwipeVelocityY = 130,
    SNFieldGesturePhase = 132,
    SNFieldSwipePhase = 134,
    SNFieldSwipeProgressBits = 135,
    SNFieldSwipeInverted = 136,
    SNFieldSwipeMotionAlt = 165,
};

enum {
    SNEventTypeGesture = 29,      // NSEventTypeGesture
    SNEventTypeDockControl = 30,  // carries the Dock swipe payload
    SNHIDTypeDockSwipe = 23,      // kIOHIDEventTypeDockSwipe
    SNGestureTagValue = 33231,
};

bool SNPostDockSwipe(SNSwipePhase phase, double progress, double velocity) {
    return SNPostDockSwipeWithMotion(phase, SNSwipeMotionHorizontal, progress, velocity, false);
}

bool SNPostDockSwipeWithMotion(SNSwipePhase phase, SNSwipeMotion motion, double progress, double velocity, bool inverted) {
    CGEventRef gesture = CGEventCreate(NULL);
    CGEventRef swipe = CGEventCreate(NULL);
    if (gesture == NULL || swipe == NULL) {
        if (gesture) CFRelease(gesture);
        if (swipe) CFRelease(swipe);
        return false;
    }

    CGEventSetDoubleValueField(gesture, SNFieldEventType, SNEventTypeGesture);
    CGEventSetDoubleValueField(gesture, SNFieldGestureTag, SNGestureTagValue);

    CGEventSetDoubleValueField(swipe, SNFieldEventType, SNEventTypeDockControl);
    CGEventSetDoubleValueField(swipe, SNFieldGestureTag, SNGestureTagValue);
    CGEventSetDoubleValueField(swipe, SNFieldHIDType, SNHIDTypeDockSwipe);
    CGEventSetDoubleValueField(swipe, SNFieldGesturePhase, phase);
    CGEventSetDoubleValueField(swipe, SNFieldSwipePhase, phase);
    CGEventSetDoubleValueField(swipe, SNFieldSwipeMotion, motion);
    CGEventSetDoubleValueField(swipe, SNFieldSwipeMotionAlt, motion);
    CGEventSetDoubleValueField(swipe, SNFieldSwipeProgress, progress);

    float progressFloat = (float)progress;
    uint32_t progressBits = 0;
    memcpy(&progressBits, &progressFloat, sizeof(progressBits));
    CGEventSetDoubleValueField(swipe, SNFieldSwipeProgressBits, progressBits);

    if (phase == SNSwipePhaseEnded || phase == SNSwipePhaseCancelled) {
        CGEventSetDoubleValueField(swipe, SNFieldSwipeVelocityX, velocity);
        CGEventSetDoubleValueField(swipe, SNFieldSwipeVelocityY, motion == SNSwipeMotionVertical ? velocity : 0);
    }
    if (inverted) CGEventSetDoubleValueField(swipe, SNFieldSwipeInverted, 1);

    CGEventPost(kCGSessionEventTap, swipe);
    CGEventPost(kCGSessionEventTap, gesture);
    CFRelease(swipe);
    CFRelease(gesture);
    return true;
}

// MARK: Events

typedef void (*SNNotifyProc)(int32_t type, void *data, uint32_t length, void *context);
typedef int32_t (*SNRegisterNotifyProcFn)(SNNotifyProc proc, int32_t type, void *context);

static void SNForwardEvent(int32_t type, void *data, uint32_t length, void *context) {
    if (context != NULL) ((SNWindowServerEventHandler)context)((SNWindowServerEvent)type);
}

bool SNObserveWindowServerEvent(SNWindowServerEvent event, SNWindowServerEventHandler handler) {
    SNEnsureLoaded();
    SNRegisterNotifyProcFn registerProc = (SNRegisterNotifyProcFn)SNLookup("CGSRegisterNotifyProc", "SLSRegisterNotifyProc");
    if (registerProc == NULL || handler == NULL) return false;
    return registerProc(SNForwardEvent, event, (void *)handler) == 0;
}

// MARK: Development

#if DEBUG
#include <stdio.h>
#include <os/log.h>
#include <mach/mach_time.h>

typedef int32_t (*SNRegisterConnectionNotifyProcFn)(SNConnectionID, SNNotifyProc proc, int32_t type, void *context);

static os_log_t SNDebugLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.alexandercollins.SpaceNamer", "cgs"); });
    return log;
}

static double SNHostSeconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}

static void SNDebugNotify(int32_t type, void *data, uint32_t length, void *context) {
    char hex[3 * 32 + 1] = {0};
    for (uint32_t i = 0; i < length && i < 32 && data != NULL; i++) {
        snprintf(hex + 3 * i, 4, "%02x ", ((const unsigned char *)data)[i]);
    }
    os_log_debug(SNDebugLog(), "cgs %{public}s %d len=%u at %.6f data=%{public}s", context ? "conn" : "global", type, length, SNHostSeconds(), hex);
}

void SNDebugObserveNotifications(int32_t from, int32_t to) {
    SNEnsureLoaded();
    SNRegisterNotifyProcFn global = (SNRegisterNotifyProcFn)SNLookup("CGSRegisterNotifyProc", "SLSRegisterNotifyProc");
    SNRegisterConnectionNotifyProcFn connection = (SNRegisterConnectionNotifyProcFn)SNLookup("CGSRegisterConnectionNotifyProc", "SLSRegisterConnectionNotifyProc");
    for (int32_t type = from; type < to; type++) {
        if (global) global(SNDebugNotify, type, NULL);
        if (connection && sMainConnectionID) connection(sMainConnectionID(), SNDebugNotify, type, (void *)1);
    }
}
#endif
