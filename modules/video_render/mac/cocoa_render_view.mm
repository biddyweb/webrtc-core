/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import "cocoa_render_view.h"
#include "trace.h"

using namespace webrtc;

@implementation CocoaRenderView

-(id)initWithFrame:(NSRect)frameRect
{
  _cs = CriticalSectionWrapper::CreateCriticalSection();

  CriticalSectionScoped lock(_cs);

  GLuint attribs[] =
  {
    NSOpenGLPFAColorSize,  24,
    NSOpenGLPFAAlphaSize,   8,
    NSOpenGLPFADepthSize,  16,
    NSOpenGLPFAAccelerated, 0
  };

  NSOpenGLPixelFormat* fmt = [[[NSOpenGLPixelFormat alloc] initWithAttributes: (NSOpenGLPixelFormatAttribute*) attribs] autorelease];

  self = [super initWithFrame:frameRect pixelFormat:fmt];
  if (self == nil) {
    WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, 0, "%s:%d Could not create instance", __FUNCTION__, __LINE__);
  }

  _observer = 0;

  return self;
}

-(void)dealloc
{
  delete _cs;
  [super dealloc];
}

-(void)registerObserver:(CocoaRenderViewObserverInterface*)observer
{
  CriticalSectionScoped lock(_cs);
  _observer = observer;
}

-(void)drawRect:(NSRect)dirtyRect
{
  CriticalSectionScoped lock(_cs);
  if (_observer)
  {
    _observer->drawRect(dirtyRect.origin.x, dirtyRect.origin.y, dirtyRect.size.width, dirtyRect.size.height);
  }
  [super drawRect:dirtyRect];
}

-(void)update
{
  CriticalSectionScoped lock(_cs);
  if (_observer)
  {
    _observer->drawRect(0,0,0,0);
  }
  [super update];
}

-(void)reshape
{
  CriticalSectionScoped lock(_cs);
  if (_observer)
  {
    _observer->drawRect(0,0,0,0);
  }
  [super reshape];
}

-(void)setOpenGLContext:(NSOpenGLContext*)context
{
  CriticalSectionScoped lock(_cs);
  [super setOpenGLContext:context];
}

-(NSOpenGLContext*)openGLContext
{
  CriticalSectionScoped lock(_cs);
  return [super openGLContext];
}

@end


