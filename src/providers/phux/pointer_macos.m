#include <stdint.h>

// Minimal AppKit declarations keep this translation unit independent of the
// generated Cockpit model and of every phux client header.
typedef signed char BOOL;
typedef unsigned long NSUInteger;
typedef unsigned long NSEventType;
typedef unsigned long long NSEventMask;
typedef unsigned long NSEventModifierFlags;
typedef struct objc_object *id;

typedef struct { double x, y; } NSPoint;
typedef struct { double width, height; } NSSize;
typedef struct { NSPoint origin; NSSize size; } NSRect;

@class NSWindow;
@class NSView;

__attribute__((objc_root_class))
@interface NSEvent
+ (id)addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(NSEvent * (^)(NSEvent *event))handler;
+ (void)removeMonitor:(id)monitor;
@property(readonly) NSEventType type;
@property(readonly) NSUInteger buttonNumber;
@property(readonly) NSEventModifierFlags modifierFlags;
@property(readonly) NSPoint locationInWindow;
@property(readonly) NSWindow *window;
@end

__attribute__((objc_root_class))
@interface NSWindow
@property(readonly) NSView *contentView;
@property BOOL acceptsMouseMovedEvents;
@end

__attribute__((objc_root_class))
@interface NSView
@property(readonly) NSRect bounds;
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view;
@end

enum {
    NSEventTypeLeftMouseDown = 1,
    NSEventTypeLeftMouseUp = 2,
    NSEventTypeRightMouseDown = 3,
    NSEventTypeRightMouseUp = 4,
    NSEventTypeMouseMoved = 5,
    NSEventTypeLeftMouseDragged = 6,
    NSEventTypeRightMouseDragged = 7,
    NSEventTypeOtherMouseDown = 25,
    NSEventTypeOtherMouseUp = 26,
    NSEventTypeOtherMouseDragged = 27,
};

#define NSEventMaskFor(type) (1ULL << (type))
#define NSEventModifierFlagCapsLock (1UL << 16)
#define NSEventModifierFlagShift (1UL << 17)
#define NSEventModifierFlagControl (1UL << 18)
#define NSEventModifierFlagOption (1UL << 19)
#define NSEventModifierFlagCommand (1UL << 20)
#define NSEventModifierFlagNumericPad (1UL << 21)

typedef struct PhuxPointerEvent {
    uint32_t kind;
    uint32_t button;
    uint16_t modifiers;
    double x;
    double y;
} PhuxPointerEvent;

// The callback is the Zig queue-staging shim. This layer has no model or
// client-FFI symbols and cannot perform provider work synchronously.
typedef void (*PhuxPointerStage)(void *context, const PhuxPointerEvent *event);

static BOOL PhuxPointInRect(NSPoint point, NSRect rect) {
    return point.x >= rect.origin.x && point.y >= rect.origin.y &&
        point.x <= rect.origin.x + rect.size.width && point.y <= rect.origin.y + rect.size.height;
}

static uint16_t PhuxPointerModifiers(NSEventModifierFlags flags) {
    uint16_t result = 0;
    if ((flags & NSEventModifierFlagShift) != 0) result |= 1u << 0;
    if ((flags & NSEventModifierFlagControl) != 0) result |= 1u << 1;
    if ((flags & NSEventModifierFlagOption) != 0) result |= 1u << 2;
    if ((flags & NSEventModifierFlagCommand) != 0) result |= 1u << 3;
    if ((flags & NSEventModifierFlagCapsLock) != 0) result |= 1u << 4;
    if ((flags & NSEventModifierFlagNumericPad) != 0) result |= 1u << 5;
    return result;
}

static BOOL PhuxPointerKind(NSEventType type, uint32_t *kind) {
    switch (type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
            *kind = 0;
            return 1;
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp:
            *kind = 1;
            return 1;
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
            *kind = 2;
            return 1;
        default:
            return 0;
    }
}

void *phux_pointer_monitor_start(void *context, PhuxPointerStage stage) {
    if (context == 0 || stage == 0) return 0;
    const NSEventMask mask = NSEventMaskFor(NSEventTypeLeftMouseDown) |
        NSEventMaskFor(NSEventTypeLeftMouseUp) |
        NSEventMaskFor(NSEventTypeRightMouseDown) |
        NSEventMaskFor(NSEventTypeRightMouseUp) |
        NSEventMaskFor(NSEventTypeOtherMouseDown) |
        NSEventMaskFor(NSEventTypeOtherMouseUp) |
        NSEventMaskFor(NSEventTypeMouseMoved) |
        NSEventMaskFor(NSEventTypeLeftMouseDragged) |
        NSEventMaskFor(NSEventTypeRightMouseDragged) |
        NSEventMaskFor(NSEventTypeOtherMouseDragged);

    // Capture only preserves release/drag delivery when the pointer leaves the
    // content view. Header, divider, provider, and Web filtering is expressly
    // deferred to the deterministic main-layer consumer.
    __block BOOL captured = 0;
    id token = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        NSWindow *window = event.window;
        if (window == 0) return event;
        NSView *content = window.contentView;
        if (content == 0) return event;
        window.acceptsMouseMovedEvents = 1;

        uint32_t kind = 0;
        if (!PhuxPointerKind(event.type, &kind)) return event;
        NSPoint point = [content convertPoint:event.locationInWindow fromView:(NSView *)0];
        const NSRect bounds = content.bounds;
        const BOOL inside = PhuxPointInRect(point, bounds);
        if (!inside && !captured) return event;
        if (kind == 0 && inside) captured = 1;

        const PhuxPointerEvent sample = {
            .kind = kind,
            .button = event.type == NSEventTypeMouseMoved ? UINT32_MAX : (uint32_t)event.buttonNumber,
            .modifiers = PhuxPointerModifiers(event.modifierFlags),
            .x = point.x,
            .y = bounds.size.height - point.y,
        };
        stage(context, &sample);
        if (kind == 1) captured = 0;
        return event;
    }];
    return token == 0 ? 0 : (__bridge_retained void *)token;
}

void phux_pointer_monitor_stop(void *raw_monitor) {
    if (raw_monitor == 0) return;
    id token = (__bridge_transfer id)raw_monitor;
    [NSEvent removeMonitor:token];
}
