#import <AppKit/AppKit.h>
#include <stdint.h>

typedef struct PhuxPointerEvent {
    uint32_t kind;
    uint32_t button;
    uint16_t modifiers;
    double x;
    double y;
} PhuxPointerEvent;

typedef void (*PhuxPointerCallback)(void *context, const PhuxPointerEvent *event);

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
            return YES;
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp:
            *kind = 1;
            return YES;
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
            *kind = 2;
            return YES;
        default:
            return NO;
    }
}

void *phux_pointer_monitor_start(void *context, PhuxPointerCallback callback) {
    if (callback == NULL) return NULL;
    const NSEventMask mask = NSEventMaskLeftMouseDown |
        NSEventMaskLeftMouseUp |
        NSEventMaskRightMouseDown |
        NSEventMaskRightMouseUp |
        NSEventMaskOtherMouseDown |
        NSEventMaskOtherMouseUp |
        NSEventMaskMouseMoved |
        NSEventMaskLeftMouseDragged |
        NSEventMaskRightMouseDragged |
        NSEventMaskOtherMouseDragged;
    __block BOOL captured = NO;
    id token = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        NSWindow *window = event.window;
        if (window == nil || ![window.title isEqualToString:@"phux"]) return event;
        NSView *content = window.contentView;
        if (content == nil) return event;
        window.acceptsMouseMovedEvents = YES;
        uint32_t kind = 0;
        if (!PhuxPointerKind(event.type, &kind)) return event;
        NSPoint point = [content convertPoint:event.locationInWindow fromView:nil];
        const NSRect bounds = content.bounds;
        const BOOL inside = NSPointInRect(point, bounds);
        if (!inside && !captured) return event;
        if (kind == 0 && inside) captured = YES;
        PhuxPointerEvent sample = {
            .kind = kind,
            .button = event.type == NSEventTypeMouseMoved ? UINT32_MAX : (uint32_t)event.buttonNumber,
            .modifiers = PhuxPointerModifiers(event.modifierFlags),
            .x = point.x,
            .y = bounds.size.height - point.y,
        };
        callback(context, &sample);
        if (kind == 1) captured = NO;
        return event;
    }];
    return token == nil ? NULL : (__bridge_retained void *)token;
}

void phux_pointer_monitor_stop(void *raw_monitor) {
    if (raw_monitor == NULL) return;
    id token = (__bridge_transfer id)raw_monitor;
    [NSEvent removeMonitor:token];
}
