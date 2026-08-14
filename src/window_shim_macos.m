#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

#import <AppKit/AppKit.h>
#include <math.h>

static NSWindow *grimalkin_cocoa_window(void *glfw_window) {
  if (glfw_window == NULL) return nil;
  return glfwGetCocoaWindow((GLFWwindow *)glfw_window);
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
