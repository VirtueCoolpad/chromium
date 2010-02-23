// Copyright (c) 2010 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/cocoa/fullscreen_controller.h"

#include <algorithm>

#include "base/mac_util.h"
#import "chrome/browser/cocoa/browser_window_controller.h"
#import "third_party/GTM/AppKit/GTMNSAnimation+Duration.h"


namespace {
// The activation zone for the main menu is 4 pixels high; if we make it any
// smaller, then the menu can be made to appear without the bar sliding down.
const CGFloat kDropdownActivationZoneHeight = 4;
const NSTimeInterval kDropdownAnimationDuration = 0.12;
const NSTimeInterval kMouseExitCheckDelay = 0.1;
// This show delay attempts to match the delay for the main menu.
const NSTimeInterval kDropdownShowDelay = 0.3;
const NSTimeInterval kDropdownHideDelay = 0.2;
}  // end namespace


// Helper class to manage animations for the fullscreen dropdown bar.  Calls
// back to [BrowserWindowController setFloatingBarShownFraction] once per
// animation step.
@interface DropdownAnimation : NSAnimation {
 @private
  BrowserWindowController* controller_;
  CGFloat startFraction_;
  CGFloat endFraction_;
}

@property(readonly, nonatomic) CGFloat startFraction;
@property(readonly, nonatomic) CGFloat endFraction;

// Designated initializer.  Asks |controller| for the current shown fraction, so
// if the bar is already partially shown or partially hidden, the animation
// duration may be less than |fullDuration|.
- (id)initWithFraction:(CGFloat)fromFraction
          fullDuration:(CGFloat)fullDuration
        animationCurve:(NSInteger)animationCurve
            controller:(BrowserWindowController*)controller;

@end

@implementation DropdownAnimation

@synthesize startFraction = startFraction_;
@synthesize endFraction = endFraction_;

- (id)initWithFraction:(CGFloat)toFraction
          fullDuration:(CGFloat)fullDuration
        animationCurve:(NSInteger)animationCurve
            controller:(BrowserWindowController*)controller {
  // Calculate the effective duration, based on the current shown fraction.
  DCHECK(controller);
  CGFloat fromFraction = [controller floatingBarShownFraction];
  CGFloat effectiveDuration = fabs(fullDuration * (fromFraction - toFraction));

  if ((self = [super gtm_initWithDuration:effectiveDuration
                           animationCurve:animationCurve])) {
    startFraction_ = fromFraction;
    endFraction_ = toFraction;
    controller_ = controller;
  }
  return self;
}

// Called once per animation step.  Overridden to change the floating bar's
// position based on the animation's progress.
- (void)setCurrentProgress:(NSAnimationProgress)progress {
  CGFloat fraction =
      startFraction_ + (progress * (endFraction_ - startFraction_));
  [controller_ setFloatingBarShownFraction:fraction];
}

@end


@interface FullscreenController (PrivateMethods)

// Change the overlay to the given fraction, with or without animation. Only
// guaranteed to work properly with |fraction == 0| or |fraction == 1|. This
// performs the show/hide (animation) immediately. It does not touch the timers.
- (void)changeOverlayToFraction:(CGFloat)fraction
                  withAnimation:(BOOL)animate;

// Schedule the floating bar to be shown/hidden because of mouse position.
- (void)scheduleShowForMouse;
- (void)scheduleHideForMouse;

// Returns YES if the mouse is currently in any current tracking rectangle, NO
// otherwise.
- (BOOL)mouseInsideTrackingRect;

// The tracking area can "falsely" report exits when the menu slides down over
// it. In that case, we have to monitor for a "real" mouse exit on a timer.
// |-setupMouseExitCheck| schedules a check; |-cancelMouseExitCheck| cancels any
// scheduled check.
- (void)setupMouseExitCheck;
- (void)cancelMouseExitCheck;

// Called (after a delay) by |-setupMouseExitCheck|, to check whether the mouse
// has exited or not; if it hasn't, it will schedule another check.
- (void)checkForMouseExit;

// Start timers for showing/hiding the floating bar.
- (void)startShowTimer;
- (void)startHideTimer;
- (void)cancelShowTimer;
- (void)cancelHideTimer;
- (void)cancelAllTimers;

// Methods called when the show/hide timers fire. Do not call directly.
- (void)showTimerFire:(NSTimer*)timer;
- (void)hideTimerFire:(NSTimer*)timer;

// Stops any running animations, removes tracking areas, etc. Common cleanup
// code shared by |-exitFullscreen| and |-dealloc|.
- (void)cleanup;

@end


@implementation FullscreenController

@synthesize isFullscreen = isFullscreen_;

- (id)initWithBrowserController:(BrowserWindowController*)controller {
  if ((self == [super init])) {
    browserController_ = controller;
  }
  return self;
}

- (void)dealloc {
  [self cleanup];
  [super dealloc];
}

- (void)enterFullscreenForContentView:(NSView*)contentView
                         showDropdown:(BOOL)showDropdown {
  DCHECK(!isFullscreen_);
  isFullscreen_ = YES;
  contentView_ = contentView;
  [browserController_ setFloatingBarShownFraction:(showDropdown ? 1 : 0)];
}

- (void)exitFullscreen {
  DCHECK(isFullscreen_);
  [self cleanup];
  isFullscreen_ = NO;
}

- (void)windowDidBecomeMain {
  if (!menubarIsHidden_) {
    // Only hide the menubar if our window is on the main screen.
    NSScreen* screen = [[browserController_ window] screen];
    NSScreen* mainScreen = [[NSScreen screens] objectAtIndex:0];
    if (screen == mainScreen) {
      mac_util::RequestFullScreen();
      menubarIsHidden_ = YES;
    }
  }
  // TODO(rohitrao): Insert the Exit Fullscreen button.  http://crbug.com/35956
}

- (void)windowDidResignMain {
  if (menubarIsHidden_) {
    mac_util::ReleaseFullScreen();
    menubarIsHidden_ = NO;
  }
  // TODO(rohitrao): Remove the Exit Fullscreen button.  http://crbug.com/35956
}

- (void)overlayFrameChanged:(NSRect)frame {
  if (!isFullscreen_)
    return;

  // Make sure |trackingAreaBounds_| always reflects either the tracking area or
  // the desired tracking area.
  trackingAreaBounds_ = frame;
  // The tracking area should always be at least the height of activation zone.
  NSRect contentBounds = [contentView_ bounds];
  trackingAreaBounds_.origin.y =
      std::min(trackingAreaBounds_.origin.y,
               NSMaxY(contentBounds) - kDropdownActivationZoneHeight);
  trackingAreaBounds_.size.height =
      NSMaxY(contentBounds) - trackingAreaBounds_.origin.y + 1;

  // If an animation is currently running, do not set up a tracking area now.
  // Instead, leave it to be created it in |-animationDidEnd:|.
  if (currentAnimation_)
    return;

  NSWindow* window = [browserController_ window];
  NSPoint mouseLoc =
      [contentView_ convertPointFromBase:
                      [window mouseLocationOutsideOfEventStream]];

  if (trackingArea_) {
    // If the tracking rectangle is already |rect|, quit early.
    NSRect oldRect = [trackingArea_ rect];
    if (NSEqualRects(trackingAreaBounds_, oldRect))
      return;

    // Otherwise, remove it.
    [contentView_ removeTrackingArea:trackingArea_];
  }

  // Create and add a new tracking area for |frame|.
  trackingArea_.reset(
      [[NSTrackingArea alloc] initWithRect:trackingAreaBounds_
                                   options:NSTrackingMouseEnteredAndExited |
                                           NSTrackingActiveInKeyWindow
                                     owner:self
                                  userInfo:nil]);
  [contentView_ addTrackingArea:trackingArea_];
}

- (void)ensureOverlayShownWithAnimation:(BOOL)animate delay:(BOOL)delay {
  if (!isFullscreen_)
    return;

  if (animate) {
    if (delay) {
      [self startShowTimer];
    } else {
      [self cancelAllTimers];
      [self changeOverlayToFraction:1 withAnimation:YES];
    }
  } else {
    DCHECK(!delay);
    [self cancelAllTimers];
    [self changeOverlayToFraction:1 withAnimation:NO];
  }
}

- (void)ensureOverlayHiddenWithAnimation:(BOOL)animate delay:(BOOL)delay {
  if (!isFullscreen_)
    return;

  if (animate) {
    if (delay) {
      [self startHideTimer];
    } else {
      [self cancelAllTimers];
      [self changeOverlayToFraction:0 withAnimation:YES];
    }
  } else {
    DCHECK(!delay);
    [self cancelAllTimers];
    [self changeOverlayToFraction:0 withAnimation:NO];
  }
}

- (void)cancelAnimationAndTimers {
  [self cancelAllTimers];
  [currentAnimation_ stopAnimation];
  currentAnimation_.reset();
}

// Used to activate the floating bar in fullscreen mode.
- (void)mouseEntered:(NSEvent*)event {
  DCHECK(isFullscreen_);

  // Having gotten a mouse entered, we no longer need to do exit checks.
  [self cancelMouseExitCheck];

  NSTrackingArea* trackingArea = [event trackingArea];
  if (trackingArea == trackingArea_) {
    // The tracking area shouldn't be active during animation.
    DCHECK(!currentAnimation_);
    [self scheduleShowForMouse];
  }
}

// Used to deactivate the floating bar in fullscreen mode.
- (void)mouseExited:(NSEvent*)event {
  DCHECK(isFullscreen_);

  NSTrackingArea* trackingArea = [event trackingArea];
  if (trackingArea == trackingArea_) {
    // The tracking area shouldn't be active during animation.
    DCHECK(!currentAnimation_);

    // We can get a false mouse exit when the menu slides down, so if the mouse
    // is still actually over the tracking area, we ignore the mouse exit, but
    // we set up to check the mouse position again after a delay.
    if ([self mouseInsideTrackingRect]) {
      [self setupMouseExitCheck];
      return;
    }

    [self scheduleHideForMouse];
  }
}

- (void)animationDidStop:(NSAnimation*)animation {
  // Reset the |currentAnimation_| pointer now that the animation is over.
  currentAnimation_.reset();

  // Invariant says that the tracking area is not installed while animations are
  // in progress. Ensure this is true.
  DCHECK(!trackingArea_);
  if (trackingArea_) {
    [contentView_ removeTrackingArea:trackingArea_];
    trackingArea_.reset();
  }
  // Don't automatically set up a new tracking area. When explicitly stopped,
  // either another animation is going to start immediately or the state will be
  // changed immediately.
}

- (void)animationDidEnd:(NSAnimation*)animation {
  [self animationDidStop:animation];

  // |trackingAreaBounds_| contains the correct tracking area bounds, including
  // |any updates that may have come while the animation was running.  Install a
  // |new tracking area with these bounds.
  trackingArea_.reset(
      [[NSTrackingArea alloc] initWithRect:trackingAreaBounds_
                                   options:NSTrackingMouseEnteredAndExited |
                                           NSTrackingActiveInKeyWindow
                                     owner:self
                                  userInfo:nil]);
  [contentView_ addTrackingArea:trackingArea_];

  // TODO(viettrungluu): Better would be to check during the animation; doing it
  // here means that the timing is slightly off.
  if (![self mouseInsideTrackingRect])
    [self scheduleHideForMouse];
}

@end


@implementation FullscreenController (PrivateMethods)

- (void)changeOverlayToFraction:(CGFloat)fraction
                  withAnimation:(BOOL)animate {
  // The non-animated case is really simple, so do it and return.
  if (!animate) {
    [currentAnimation_ stopAnimation];
    [browserController_ setFloatingBarShownFraction:fraction];
    return;
  }

  // If we're already animating to the given fraction, then there's nothing more
  // to do.
  if (currentAnimation_ && [currentAnimation_ endFraction] == fraction)
    return;

  // In all other cases, we want to cancel any running animation (which may be
  // to show or to hide).
  [currentAnimation_ stopAnimation];

  // Now, if it happens to already be in the right state, there's nothing more
  // to do.
  if ([browserController_ floatingBarShownFraction] == fraction)
    return;

  // Create the animation and set it up.
  currentAnimation_.reset(
      [[DropdownAnimation alloc] initWithFraction:fraction
                                     fullDuration:kDropdownAnimationDuration
                                   animationCurve:NSAnimationEaseOut
                                       controller:browserController_]);
  DCHECK(currentAnimation_);
  [currentAnimation_ setAnimationBlockingMode:NSAnimationNonblocking];
  [currentAnimation_ setDelegate:self];

  // If there is an existing tracking area, remove it. We do not track mouse
  // movements during animations (see class comment in the header file).
  if (trackingArea_) {
    [contentView_ removeTrackingArea:trackingArea_];
    trackingArea_.reset();
  }

  [currentAnimation_ startAnimation];
}

- (void)scheduleShowForMouse {
  [browserController_ lockBarVisibilityForOwner:self
                                  withAnimation:YES
                                          delay:YES];
}

- (void)scheduleHideForMouse {
  [browserController_ releaseBarVisibilityForOwner:self
                                     withAnimation:YES
                                             delay:YES];
}

- (BOOL)mouseInsideTrackingRect {
  NSWindow* window = [browserController_ window];
  NSPoint mouseLoc = [window mouseLocationOutsideOfEventStream];
  NSPoint mousePos = [contentView_ convertPointFromBase:mouseLoc];
  return NSMouseInRect(mousePos, trackingAreaBounds_, [contentView_ isFlipped]);
}

- (void)setupMouseExitCheck {
  [self performSelector:@selector(checkForMouseExit)
             withObject:nil
             afterDelay:kMouseExitCheckDelay];
}

- (void)cancelMouseExitCheck {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
      selector:@selector(checkForMouseExit) object:nil];
}

- (void)checkForMouseExit {
  if ([self mouseInsideTrackingRect])
    [self setupMouseExitCheck];
  else
    [self scheduleHideForMouse];
}

- (void)startShowTimer {
  // If there's already a show timer going, just keep it.
  if (showTimer_) {
    DCHECK([showTimer_ isValid]);
    DCHECK(!hideTimer_);
    return;
  }

  // Cancel the hide timer (if necessary) and set up the new show timer.
  [self cancelHideTimer];
  showTimer_.reset(
      [[NSTimer scheduledTimerWithTimeInterval:kDropdownShowDelay
                                        target:self
                                      selector:@selector(showTimerFire:)
                                      userInfo:nil
                                       repeats:NO] retain]);
  DCHECK([showTimer_ isValid]);  // This also checks that |showTimer_ != nil|.
}

- (void)startHideTimer {
  // If there's already a hide timer going, just keep it.
  if (hideTimer_) {
    DCHECK([hideTimer_ isValid]);
    DCHECK(!showTimer_);
    return;
  }

  // Cancel the show timer (if necessary) and set up the new hide timer.
  [self cancelShowTimer];
  hideTimer_.reset(
      [[NSTimer scheduledTimerWithTimeInterval:kDropdownHideDelay
                                        target:self
                                      selector:@selector(hideTimerFire:)
                                      userInfo:nil
                                       repeats:NO] retain]);
  DCHECK([hideTimer_ isValid]);  // This also checks that |hideTimer_ != nil|.
}

- (void)cancelShowTimer {
  [showTimer_ invalidate];
  showTimer_.reset();
}

- (void)cancelHideTimer {
  [hideTimer_ invalidate];
  hideTimer_.reset();
}

- (void)cancelAllTimers {
  [self cancelShowTimer];
  [self cancelHideTimer];
}

- (void)showTimerFire:(NSTimer*)timer {
  DCHECK_EQ(showTimer_, timer);  // This better be our show timer.
  [showTimer_ invalidate];       // Make sure it doesn't repeat.
  showTimer_.reset();            // And get rid of it.
  [self changeOverlayToFraction:1 withAnimation:YES];
}

- (void)hideTimerFire:(NSTimer*)timer {
  DCHECK_EQ(hideTimer_, timer);  // This better be our hide timer.
  [hideTimer_ invalidate];       // Make sure it doesn't repeat.
  hideTimer_.reset();            // And get rid of it.
  [self changeOverlayToFraction:0 withAnimation:YES];
}

- (void)cleanup {
  [self cancelMouseExitCheck];
  [self cancelAnimationAndTimers];

  [contentView_ removeTrackingArea:trackingArea_];
  contentView_ = nil;

  trackingArea_.reset();

  // This isn't tracked when not in fullscreen mode.
  [browserController_ releaseBarVisibilityForOwner:self
                                     withAnimation:NO
                                             delay:NO];

  // Call the main status resignation code to perform the associated cleanup,
  // since we will no longer be receiving actual status resignation
  // notifications.
  [self windowDidResignMain];
}

@end
