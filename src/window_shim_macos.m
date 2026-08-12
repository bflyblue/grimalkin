#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#include <math.h>

enum {
  GRIMALKIN_EDGE_NONE = 0,
  GRIMALKIN_EDGE_LEFT = 1 << 0,
  GRIMALKIN_EDGE_RIGHT = 1 << 1,
  GRIMALKIN_EDGE_BOTTOM = 1 << 2,
  GRIMALKIN_EDGE_TOP = 1 << 3,
};

static NSWindow *grimalkin_cocoa_window(void *glfw_window) {
  if (glfw_window == NULL) return nil;
  return glfwGetCocoaWindow((GLFWwindow *)glfw_window);
}

int grimalkin_macos_window_interaction_supported(void *glfw_window) {
  return grimalkin_cocoa_window(glfw_window) != nil;
}

static BOOL grimalkin_native_drag_active;
static id grimalkin_drag_local_monitor;
static id grimalkin_drag_global_monitor;

static void grimalkin_finish_native_drag(void) {
  if (!grimalkin_native_drag_active) return;
  grimalkin_native_drag_active = NO;
  if (grimalkin_drag_local_monitor != nil) {
    [NSEvent removeMonitor:grimalkin_drag_local_monitor];
    grimalkin_drag_local_monitor = nil;
  }
  if (grimalkin_drag_global_monitor != nil) {
    [NSEvent removeMonitor:grimalkin_drag_global_monitor];
    grimalkin_drag_global_monitor = nil;
  }
  if ((NSEvent.modifierFlags & NSEventModifierFlagOption) != 0) {
    [NSCursor.openHandCursor set];
  } else {
    [NSCursor.arrowCursor set];
  }
}

static void grimalkin_reassert_drag_cursor(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (grimalkin_native_drag_active) [NSCursor.openHandCursor set];
  });
}

int grimalkin_macos_display_rotation(void *glfw_window) {
  NSWindow *window = grimalkin_cocoa_window(glfw_window);
  NSScreen *screen = window != nil ? window.screen : NSScreen.mainScreen;
  NSNumber *screen_number = screen.deviceDescription[@"NSScreenNumber"];
  if (screen_number == nil) return -1;
  double angle = CGDisplayRotation((CGDirectDisplayID)screen_number.unsignedIntValue);
  int normalized = ((int)lround(angle) % 360 + 360) % 360;
  if (normalized < 45 || normalized >= 315) return 0;
  if (normalized < 135) return 90;
  if (normalized < 225) return 180;
  return 270;
}

int grimalkin_macos_configure_window(void *glfw_window, int frameless) {
  NSWindow *window = grimalkin_cocoa_window(glfw_window);
  if (window == nil) return 0;

  NSRect frame = window.frame;
  if (frameless) {
    window.styleMask |= NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable |
        NSWindowStyleMaskFullSizeContentView;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    [window standardWindowButton:NSWindowCloseButton].hidden = YES;
    [window standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [window standardWindowButton:NSWindowZoomButton].hidden = YES;
  } else {
    window.styleMask |= NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;
    window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
    window.titleVisibility = NSWindowTitleVisible;
    window.titlebarAppearsTransparent = NO;
    [window standardWindowButton:NSWindowCloseButton].hidden = NO;
    [window standardWindowButton:NSWindowMiniaturizeButton].hidden = NO;
    [window standardWindowButton:NSWindowZoomButton].hidden = NO;
  }
  [window setFrame:frame display:NO];
  return 1;
}

int grimalkin_macos_window_click_count(void *glfw_window, int button) {
  (void)button;
  if (grimalkin_cocoa_window(glfw_window) == nil) return 1;
  NSEvent *event = NSApp.currentEvent;
  return event == nil ? 1 : (int)event.clickCount;
}

int grimalkin_macos_toggle_window_zoom(void *glfw_window) {
  NSWindow *window = grimalkin_cocoa_window(glfw_window);
  if (window == nil) return 0;
  [window zoom:nil];
  return 1;
}

static unsigned grimalkin_window_edges(NSWindow *window, NSPoint mouse) {
  NSRect frame = window.frame;
  const CGFloat edge_width = 8.0;
  unsigned edges = GRIMALKIN_EDGE_NONE;
  if (mouse.x < NSMinX(frame) + edge_width) edges |= GRIMALKIN_EDGE_LEFT;
  if (mouse.x >= NSMaxX(frame) - edge_width) edges |= GRIMALKIN_EDGE_RIGHT;
  if (mouse.y < NSMinY(frame) + edge_width) edges |= GRIMALKIN_EDGE_BOTTOM;
  if (mouse.y >= NSMaxY(frame) - edge_width) edges |= GRIMALKIN_EDGE_TOP;
  return edges;
}

static NSCursor *grimalkin_cursor_for_edges(unsigned edges) {
  bool horizontal = (edges & (GRIMALKIN_EDGE_LEFT | GRIMALKIN_EDGE_RIGHT)) != 0;
  bool vertical = (edges & (GRIMALKIN_EDGE_BOTTOM | GRIMALKIN_EDGE_TOP)) != 0;
  if (horizontal && vertical) return NSCursor.crosshairCursor;
  if (horizontal) return NSCursor.resizeLeftRightCursor;
  if (vertical) return NSCursor.resizeUpDownCursor;
  return NSCursor.openHandCursor;
}

static CGFloat grimalkin_clamp(CGFloat value, CGFloat minimum, CGFloat maximum) {
  if (value < minimum) return minimum;
  if (maximum > 0.0 && value > maximum) return maximum;
  return value;
}

static void grimalkin_resize_window(NSWindow *window, unsigned edges,
                                    int button) {
  NSRect initial = window.frame;
  NSPoint start = NSEvent.mouseLocation;
  NSSize minimum = window.minSize;
  NSSize maximum = window.maxSize;

  NSEventMask dragged_mask = button == GLFW_MOUSE_BUTTON_MIDDLE ?
      NSEventMaskOtherMouseDragged : NSEventMaskLeftMouseDragged;
  NSEventMask up_mask = button == GLFW_MOUSE_BUTTON_MIDDLE ?
      NSEventMaskOtherMouseUp : NSEventMaskLeftMouseUp;
  NSEventType up_type = button == GLFW_MOUSE_BUTTON_MIDDLE ?
      NSEventTypeOtherMouseUp : NSEventTypeLeftMouseUp;

  for (;;) {
    NSEvent *event = [window nextEventMatchingMask:dragged_mask | up_mask];
    if (event == nil || event.type == up_type) break;

    NSPoint mouse = NSEvent.mouseLocation;
    CGFloat dx = mouse.x - start.x;
    CGFloat dy = mouse.y - start.y;
    NSRect frame = initial;

    if (edges & GRIMALKIN_EDGE_LEFT) {
      frame.size.width = grimalkin_clamp(
          initial.size.width - dx, minimum.width, maximum.width);
      frame.origin.x = NSMaxX(initial) - frame.size.width;
    } else if (edges & GRIMALKIN_EDGE_RIGHT) {
      frame.size.width = grimalkin_clamp(
          initial.size.width + dx, minimum.width, maximum.width);
    }

    if (edges & GRIMALKIN_EDGE_BOTTOM) {
      frame.size.height = grimalkin_clamp(
          initial.size.height - dy, minimum.height, maximum.height);
      frame.origin.y = NSMaxY(initial) - frame.size.height;
    } else if (edges & GRIMALKIN_EDGE_TOP) {
      frame.size.height = grimalkin_clamp(
          initial.size.height + dy, minimum.height, maximum.height);
    }

    [window setFrame:frame display:YES];
  }
}

int grimalkin_macos_begin_window_interaction(void *glfw_window, int button) {
  NSWindow *window = grimalkin_cocoa_window(glfw_window);
  NSEvent *event = NSApp.currentEvent;
  if (window == nil || event == nil) return 0;

  unsigned edges = grimalkin_window_edges(window, NSEvent.mouseLocation);
  if (edges == GRIMALKIN_EDGE_NONE) {
    NSEventMask up_mask = button == GLFW_MOUSE_BUTTON_MIDDLE ?
        NSEventMaskOtherMouseUp : NSEventMaskLeftMouseUp;
    NSEventType up_type = button == GLFW_MOUSE_BUTTON_MIDDLE ?
        NSEventTypeOtherMouseUp : NSEventTypeLeftMouseUp;
    grimalkin_native_drag_active = YES;
    grimalkin_drag_local_monitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:
            NSEventMaskFlagsChanged | up_mask
                              handler:^NSEvent *(NSEvent *drag_event) {
      if (drag_event.type == up_type) {
        grimalkin_finish_native_drag();
      } else {
        grimalkin_reassert_drag_cursor();
      }
      return drag_event;
    }];
    grimalkin_drag_global_monitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:up_mask
                                      handler:^(NSEvent *drag_event) {
      (void)drag_event;
      dispatch_async(dispatch_get_main_queue(), ^{
        grimalkin_finish_native_drag();
      });
    }];
    [window performWindowDragWithEvent:event];
  } else {
    grimalkin_resize_window(window, edges, button);
  }
  return 1;
}

int grimalkin_macos_update_window_interaction_cursor(void *glfw_window,
                                                      int enabled) {
  NSWindow *window = grimalkin_cocoa_window(glfw_window);
  if (window == nil) return 0;
  if (enabled == 2 && grimalkin_native_drag_active) {
    [grimalkin_cursor_for_edges(
        grimalkin_window_edges(window, NSEvent.mouseLocation)) set];
    return 2;
  }
  if (enabled == 2) enabled = 1;
  if (!enabled ||
      (enabled == 1 &&
       (NSEvent.modifierFlags & NSEventModifierFlagOption) == 0)) {
    [NSCursor.arrowCursor set];
    return enabled ? 0 : 1;
  }
  [grimalkin_cursor_for_edges(
      grimalkin_window_edges(window, NSEvent.mouseLocation)) set];
  return 1;
}

int grimalkin_macos_set_window_interactive_style(void *glfw_window,
                                                  int enabled) {
  (void)enabled;
  return grimalkin_cocoa_window(glfw_window) != nil;
}
