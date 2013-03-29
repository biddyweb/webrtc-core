/*
 *  Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "engine_configurations.h"
#if defined(COCOA_RENDERING)

#include "video_render_nsopengl.h"
#include "critical_section_wrapper.h"
#include "event_wrapper.h"
#include "trace.h"
#include "thread_wrapper.h"
#include "common_video/libyuv/include/webrtc_libyuv.h"

namespace webrtc {

VideoChannelNSOpenGL::VideoChannelNSOpenGL(NSOpenGLContext *nsglContext, int iId, VideoRenderNSOpenGL* owner) :
_nsglContext( nsglContext),
_id( iId),
_owner( owner),
_width( 0),
_height( 0),
_startWidth( 0.0f),
_startHeight( 0.0f),
_stopWidth( 0.0f),
_stopHeight( 0.0f),
_stretchedWidth( 0),
_stretchedHeight( 0),
_oldStretchedHeight( 0),
_oldStretchedWidth( 0),
_buffer( 0),
_bufferSize( 0),
_incommingBufferSize( 0),
_bufferIsUpdated( false),
_numberOfStreams( 0),
_pixelFormat( GL_RGBA),
_pixelDataType( GL_UNSIGNED_INT_8_8_8_8),
_texture( 0),
_frameSizeChanged(false),
_crop_left(0),
_crop_top(0),
_crop_right(1),
_crop_bottom(1)
{

}

VideoChannelNSOpenGL::~VideoChannelNSOpenGL()
{
    _owner->LockAGLCntx();
    
    if (_buffer)
    {
        delete [] _buffer;
        _buffer = NULL;
    }

    if (_texture != 0)
    {
        [_nsglContext makeCurrentContext];
        glDeleteTextures(1, (const GLuint*) &_texture);
        _texture = 0;
    }
    
    _owner->UnlockAGLCntx();
}

int VideoChannelNSOpenGL::ChangeContext(NSOpenGLContext *nsglContext)
{
    _owner->LockAGLCntx();

    _nsglContext = nsglContext;
    [_nsglContext makeCurrentContext];

    _owner->UnlockAGLCntx();
    return 0;

}

WebRtc_Word32 VideoChannelNSOpenGL::GetChannelProperties(float& left,
        float& top,
        float& right,
        float& bottom)
{

    _owner->LockAGLCntx();

    left = _startWidth;
    top = _startHeight;
    right = _stopWidth;
    bottom = _stopHeight;

    _owner->UnlockAGLCntx();
    return 0;
}

WebRtc_Word32 VideoChannelNSOpenGL::RenderFrame(const WebRtc_UWord32 /*streamId*/, I420VideoFrame& videoFrame)
{
    _owner->LockAGLCntx();

    if(_width != (int)videoFrame.width() ||
            _height != (int)videoFrame.height())
    {
        if(FrameSizeChange(videoFrame.width(), videoFrame.height(), 1) == -1)
        {
            _owner->UnlockAGLCntx();
            return -1;
        }
    }

    int ret = DeliverFrame(videoFrame);

    _owner->UnlockAGLCntx();
    return ret;
}

int VideoChannelNSOpenGL::UpdateSize(int width, int height)
{
    _owner->LockAGLCntx();
    _width = width;
    _height = height;
    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::UpdateStretchSize(int stretchHeight, int stretchWidth)
{

    _owner->LockAGLCntx();
    _stretchedHeight = stretchHeight;
    _stretchedWidth = stretchWidth;
    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::FrameSizeChange(int width, int height, int numberOfStreams)
{
    //  We got a new frame size from VideoAPI, prepare the buffer
    _owner->LockAGLCntx();

    if (width == _width && _height == height)
    {
        // We already have a correct buffer size
        _numberOfStreams = numberOfStreams;
        _owner->UnlockAGLCntx();
        return 0;
    }

    _width = width;
    _height = height;

    // Delete the old buffer, create a new one with correct size.
    if (_buffer)
    {
        delete [] _buffer;
        _bufferSize = 0;
    }

    _incommingBufferSize = CalcBufferSize(kI420, _width, _height);
    _bufferSize = CalcBufferSize(kARGB, _width, _height);//_width * _height * bytesPerPixel;
    _buffer = new unsigned char [_bufferSize];
    memset(_buffer, 0, _bufferSize * sizeof(unsigned char));

    _frameSizeChanged = true;

    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::FrameSizeChangeInternal()
{
    _owner->LockAGLCntx();
    
    if (!_frameSizeChanged)
    {
        _owner->UnlockAGLCntx();
        return 0;
    }
    
    [_nsglContext makeCurrentContext];

    glDeleteTextures(1, (const GLuint*) &_texture);
    _texture = 0;

    // Create a new texture
    glGenTextures(1, (GLuint *) &_texture);

    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glGenTextures in FrameSizeChange", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }

    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, _texture);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glBindTexture in FrameSizeChange", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }

    GLint texSize;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &texSize);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glGetIntegerv in FrameSizeChange", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }

    if (texSize < _width || texSize < _height)
    {
        _owner->UnlockAGLCntx();
        return -1;
    }

    // Set up th texture type and size
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, // target
            0, // level
            GL_RGBA, // internal format
            _width, // width
            _height, // height
            0, // border 0/1 = off/on
            _pixelFormat, // format, GL_RGBA
            _pixelDataType, // data type, GL_UNSIGNED_INT_8_8_8_8
            _buffer); // pixel data

    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glTexImage2D in FrameSizeChange", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    
    _frameSizeChanged = false;

    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::DeliverFrame(const I420VideoFrame& videoFrame)
{
    _owner->LockAGLCntx();
    
    if (CalcBufferSize(kI420, videoFrame.width(), videoFrame.height()) != _incommingBufferSize)
    {
        _owner->UnlockAGLCntx();
        return -1;
    }

    int rgbRet = ConvertFromYV12(videoFrame, kBGRA, 0, _buffer);
    if (rgbRet < 0)
    {
        _owner->UnlockAGLCntx();
        return -1;
    }

    _bufferIsUpdated = true;

    _owner->UnlockAGLCntx();
    return 0;
}
    
int VideoChannelNSOpenGL::UpdateTexture()
{
    _owner->LockAGLCntx();
    
    if (_texture == 0)
    {
        _owner->UnlockAGLCntx();
        return 0;
    }
    
    if (!_bufferIsUpdated)
    {
        _owner->UnlockAGLCntx();
        return 0;
    }
    
    [_nsglContext makeCurrentContext];
    
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, _texture); // Make sure this texture is the active one
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glBindTexture in DeliverFrame", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    
    glTexSubImage2D(GL_TEXTURE_RECTANGLE_EXT,
                    0, // Level, not use
                    0, // start point x, (low left of pic)
                    0, // start point y,
                    _width, // width
                    _height, // height
                    _pixelFormat, // pictue format for _buffer
                    _pixelDataType, // data type of _buffer
                    (const GLvoid*) _buffer); // the pixel data
    
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glTexSubImage2d in DeliverFrame", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    
    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::RenderOffScreenBuffer()
{
    _owner->LockAGLCntx();
    
    FrameSizeChangeInternal();
    
    UpdateTexture();

    if (_texture == 0)
    {
        _owner->UnlockAGLCntx();
        return 0;
    }

    //	if(_fullscreen)
    //	{
    // NSRect mainDisplayRect = [[NSScreen mainScreen] frame];
    //		_width = mainDisplayRect.size.width;
    //		_height = mainDisplayRect.size.height;
    //		glViewport(0, 0, mainDisplayRect.size.width, mainDisplayRect.size.height);
    //		float newX = mainDisplayRect.size.width/_width;
    //		float newY = mainDisplayRect.size.height/_height;

    // convert from 0.0 <= size <= 1.0 to
    // open gl world -1.0 < size < 1.0
    GLfloat xStart = 2.0f * _startWidth - 1.0f;
    GLfloat xStop = 2.0f * _stopWidth - 1.0f;
    GLfloat yStart = 1.0f - 2.0f * _stopHeight;
    GLfloat yStop = 1.0f - 2.0f * _startHeight;

    [_nsglContext makeCurrentContext];

    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, _texture);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glBindTexture in RenderOffScreenBuffer", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    _oldStretchedHeight = _stretchedHeight;
    _oldStretchedWidth = _stretchedWidth;

    glLoadIdentity();
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glLoadIdentity in RenderOffScreenBuffer", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    glEnable(GL_TEXTURE_RECTANGLE_EXT);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glEnable in RenderOffScreenBuffer", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }
    
    glBegin(GL_POLYGON);
    {
        glTexCoord2f(_width * _crop_left,  _height * _crop_top);    glVertex2f(xStart, yStop);
        glTexCoord2f(_width * _crop_right, _height * _crop_top);    glVertex2f(xStop, yStop);
        glTexCoord2f(_width * _crop_right, _height * _crop_bottom); glVertex2f(xStop, yStart);
        glTexCoord2f(_width * _crop_left,  _height * _crop_bottom); glVertex2f(xStart, yStart);
    }
    glEnd();
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d between glBegin/glEnd in RenderOffScreenBuffer", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }

    glDisable(GL_TEXTURE_RECTANGLE_EXT);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glDisable in RenderOffScreenBuffer", glErr);
        _owner->UnlockAGLCntx();
        return -1;
    }

    _bufferIsUpdated = false;

    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::IsUpdated(bool& isUpdated)
{
    _owner->LockAGLCntx();

    isUpdated = _bufferIsUpdated;

    _owner->UnlockAGLCntx();
    return 0;
}

int VideoChannelNSOpenGL::SetStreamSettings(int /*streamId*/, float startWidth, float startHeight, float stopWidth, float stopHeight)
{
    _owner->LockAGLCntx();

    _startWidth = startWidth;
    _stopWidth = stopWidth;
    _startHeight = startHeight;
    _stopHeight = stopHeight;

    int oldWidth = _width;
    int oldHeight = _height;
    int oldNumberOfStreams = _numberOfStreams;

    _width = 0;
    _height = 0;

    int retVal = FrameSizeChange(oldWidth, oldHeight, oldNumberOfStreams);

    _owner->UnlockAGLCntx();
    return retVal;
}

int VideoChannelNSOpenGL::SetStreamCropSettings(int /*streamId*/,
                                                float left,
                                                float top,
                                                float right,
                                                float bottom)
{
    _owner->LockAGLCntx();
    
    _crop_left = left;
    _crop_top = top;
    _crop_right = right;
    _crop_bottom = bottom;
        
    _owner->UnlockAGLCntx();
    return 0;
}

/*
 *
 *    VideoRenderNSOpenGL
 *
 */

VideoRenderNSOpenGL::VideoRenderNSOpenGL(NSView *windowRefSuperView, bool fullScreen, int iId) :
_windowRef(NULL),
_fullScreen( fullScreen),
_id( iId),
_nsglContextCritSec( *CriticalSectionWrapper::CreateCriticalSection()),
_screenUpdateThread( 0),
_screenUpdateEvent( 0),
_nsglContext( 0),
_nsglFullScreenContext( 0),
_fullScreenWindow( nil),
_windowRect( ),
_windowWidth( 0),
_windowHeight( 0),
_nsglChannels( ),
_zOrderToChannel( ),
_threadID (0),
_renderingIsPaused (FALSE),
_windowRefSuperView(windowRefSuperView),
_mixingContextReady(false)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);

    if (NULL == windowRefSuperView)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "windowRefSuperView is NULL");
        return;
    }
    _windowRefSuperViewFrame = [_windowRefSuperView frame];
    
    _windowRef = [[CocoaRenderView alloc] initWithFrame:_windowRefSuperView.bounds];
    [_windowRef registerObserver:this];
    [_windowRefSuperView addSubview:_windowRef];
    [_windowRefSuperView setAutoresizesSubviews:YES];
    [_windowRef setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _nsglContext = [_windowRef openGLContext];
    
    _screenUpdateThread = ThreadWrapper::CreateThread(ScreenUpdateThreadProc, this, kRealtimePriority);
    _screenUpdateEvent = EventWrapper::Create();
}

int VideoRenderNSOpenGL::ChangeWindow(NSView* newWindowRefSuperView)
{
    LockAGLCntx();

    [_windowRef removeFromSuperview];
    _windowRefSuperView = newWindowRefSuperView;
    _windowRefSuperViewFrame = _windowRefSuperView.frame;
    _windowRef.frame = _windowRefSuperView.bounds;
    [_windowRefSuperView addSubview:_windowRef];
    _nsglContext = _windowRef.openGLContext;

    int error = 0;
    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.begin();
    while (it!= _nsglChannels.end())
    {
        error |= (it->second)->ChangeContext(_nsglContext);
        it++;
    }
    if(error != 0)
    {
        UnlockAGLCntx();
        return -1;
    }

    UnlockAGLCntx();
    return 0;
}

/* Check if the thread and event already exist. 
 * If so then they will simply be restarted
 * If not then create them and continue
 */
WebRtc_Word32 VideoRenderNSOpenGL::StartRender()
{

    LockAGLCntx();

    const unsigned int MONITOR_FREQ = 60;
    if(TRUE == _renderingIsPaused)
    {
        WEBRTC_TRACE(kTraceDebug, kTraceVideoRenderer, _id, "Restarting screenUpdateThread");

        // we already have the thread. Most likely StopRender() was called and they were paused
        if(FALSE == _screenUpdateThread->Start(_threadID) ||
                FALSE == _screenUpdateEvent->StartTimer(true, 1000/MONITOR_FREQ))
        {
            WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "Failed to restart screenUpdateThread or screenUpdateEvent");
            UnlockAGLCntx();
            return -1;
        }

        UnlockAGLCntx();
        return 0;
    }


    if (!_screenUpdateThread)
    {
        WEBRTC_TRACE(kTraceDebug, kTraceVideoRenderer, _id, "failed start screenUpdateThread");
        UnlockAGLCntx();
        return -1;
    }

    UnlockAGLCntx();
    return 0;
}
WebRtc_Word32 VideoRenderNSOpenGL::StopRender()
{

    LockAGLCntx();

    /* The code below is functional
     * but it pauses for several seconds
     */

    // pause the update thread and the event timer
    if(!_screenUpdateThread || !_screenUpdateEvent)
    {
        _renderingIsPaused = TRUE;

        UnlockAGLCntx();
        return 0;
    }

    if(FALSE == _screenUpdateThread->Stop() || FALSE == _screenUpdateEvent->StopTimer())
    {
        _renderingIsPaused = FALSE;

        UnlockAGLCntx();
        return -1;
    }

    _renderingIsPaused = TRUE;

    UnlockAGLCntx();
    return 0;
}

int VideoRenderNSOpenGL::configureNSOpenGLView()
{
    return 0;
}

int VideoRenderNSOpenGL::configureNSOpenGLEngine()
{
    LockAGLCntx();

    // Disable not needed functionality to increase performance
    glDisable(GL_DITHER);
    glDisable(GL_ALPHA_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_FOG);
    glDisable(GL_TEXTURE_2D);
    glPixelZoom(1.0, 1.0);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDepthMask(GL_FALSE);
    glDisable(GL_CULL_FACE);
    
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while disabling not needed functionality", glErr);
        UnlockAGLCntx();
        return -1;
    }

    // Set texture parameters
    glTexParameterf(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_PRIORITY, 1.0);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE, GL_STORAGE_SHARED_APPLE);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while setting texture parameters", glErr);
        UnlockAGLCntx();
        return -1;
    }

    if (GetWindowRect(_windowRect) == -1)
    {
        UnlockAGLCntx();
        return true;
    }

    if (_windowWidth != (_windowRect.right - _windowRect.left)
            || _windowHeight != (_windowRect.bottom - _windowRect.top))
    {
        _windowWidth = _windowRect.right - _windowRect.left;
        _windowHeight = _windowRect.bottom - _windowRect.top;
    }
    glViewport(0, 0, _windowWidth, _windowHeight);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glViewport", glErr);
        UnlockAGLCntx();
        return -1;
    }

    // Synchronize buffer swaps with vertical refresh rate
    GLint swapInt = 1;
    [_nsglContext setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];

    UnlockAGLCntx();
    return 0;
}

int VideoRenderNSOpenGL::setRenderTargetWindow()
{
    LockAGLCntx();
    
    [_nsglContext makeCurrentContext];

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glClearColor in setRenderTargetWindow", glErr);
        UnlockAGLCntx();
        return -1;
    }
    glClear(GL_COLOR_BUFFER_BIT);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glClear in setRenderTargetWindow", glErr);
        UnlockAGLCntx();
        return -1;
    }

    if (-1 == DisplayBuffers())
    {
        UnlockAGLCntx();
        return -1;
    }

    UnlockAGLCntx();
    return 0;
}

int VideoRenderNSOpenGL::setRenderTargetFullScreen()
{
    LockAGLCntx();

    // create new fullscreen window
    NSRect screenRect = [[NSScreen mainScreen]frame];
    [_windowRef setFrame:screenRect];
    [_windowRef setBounds:screenRect];

    
    _fullScreenWindow = [[CocoaFullScreenWindow alloc] init];
    [_fullScreenWindow grabFullScreen];
    [[[_fullScreenWindow window] contentView] addSubview:_windowRef];

    [_nsglContext makeCurrentContext];

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glClearColor in setRenderTargetFullScreen", glErr);
        UnlockAGLCntx();
        return -1;
    }
    glClear(GL_COLOR_BUFFER_BIT);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glClear in setRenderTargetFullScreen", glErr);
        UnlockAGLCntx();
        return -1;
    }
    
    if (-1 == DisplayBuffers())
    {
        UnlockAGLCntx();
        return -1;
    }

    UnlockAGLCntx();
    return 0;
}

VideoRenderNSOpenGL::~VideoRenderNSOpenGL()
{
    [_windowRef registerObserver:0];
    
    if(_fullScreen)
    {
        if(_fullScreenWindow)
        {
            // Detach CocoaRenderView from full screen view back to 
            // it's original parent.
            [_windowRef removeFromSuperview];
            if(_windowRefSuperView) 
            {
              [_windowRefSuperView addSubview:_windowRef];
              [_windowRef setFrame:_windowRefSuperViewFrame];
            }
            
            WEBRTC_TRACE(kTraceDebug, kTraceVideoRenderer, 0, "%s:%d Attempting to release fullscreen window", __FUNCTION__, __LINE__);
            [_fullScreenWindow release];
//            [_fullScreenWindow releaseFullScreen];
            _fullScreenWindow = nil;
     
        }
    }

    // Signal event to exit thread, then delete it
    ThreadWrapper* tmpPtr = _screenUpdateThread;
    _screenUpdateThread = NULL;

    if (tmpPtr)
    {
        tmpPtr->SetNotAlive();
        _screenUpdateEvent->Set();
        _screenUpdateEvent->StopTimer();

        if (tmpPtr->Stop())
        {
            delete tmpPtr;
        }
        delete _screenUpdateEvent;
        _screenUpdateEvent = NULL;
    }

    if (_nsglContext != 0)
    {
        [_nsglContext makeCurrentContext];
        _nsglContext = nil;
    }

    // Delete all channels
    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.begin();
    while (it!= _nsglChannels.end())
    {
        delete it->second;
        _nsglChannels.erase(it);
        it = _nsglChannels.begin();
    }
    _nsglChannels.clear();

    // Clean the zOrder map
    std::multimap<int, int>::iterator zIt = _zOrderToChannel.begin();
    while(zIt != _zOrderToChannel.end())
    {
        _zOrderToChannel.erase(zIt);
        zIt = _zOrderToChannel.begin();
    }
    _zOrderToChannel.clear();
    
    [_windowRef release];
}

/* static */
int VideoRenderNSOpenGL::GetOpenGLVersion(int& /*nsglMajor*/, int& /*nsglMinor*/)
{
    return -1;
}

int VideoRenderNSOpenGL::Init()
{
    LockAGLCntx();
 
    if (!_screenUpdateThread)
    {
        UnlockAGLCntx();
        return -1;
    }
    
    _screenUpdateThread->Start(_threadID);
    
    // Start the event triggering the render process
    unsigned int monitorFreq = 60;
    _screenUpdateEvent->StartTimer(true, 1000/monitorFreq);

    UnlockAGLCntx();
    return 0;
}

VideoChannelNSOpenGL* VideoRenderNSOpenGL::CreateNSGLChannel(int channel, int zOrder, float startWidth, float startHeight, float stopWidth, float stopHeight)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);

    if (HasChannel(channel))
    {
        return NULL;
    }

    if (_zOrderToChannel.find(zOrder) != _zOrderToChannel.end())
    {

    }

    VideoChannelNSOpenGL* newAGLChannel = new VideoChannelNSOpenGL(_nsglContext, _id, this);
    if (newAGLChannel->SetStreamSettings(0, startWidth, startHeight, stopWidth, stopHeight) == -1)
    {
        if (newAGLChannel)
        {
            delete newAGLChannel;
            newAGLChannel = NULL;
        }

        return NULL;
    }

    _nsglChannels[channel] = newAGLChannel;
    _zOrderToChannel.insert(std::pair<int, int>(zOrder, channel));

    WEBRTC_TRACE(kTraceInfo, kTraceVideoRenderer, _id, "%s successfully created NSGL channel number %d", __FUNCTION__, channel);

    return newAGLChannel;
}

int VideoRenderNSOpenGL::DeleteAllNSGLChannels()
{

    CriticalSectionScoped cs(&_nsglContextCritSec);

    std::map<int, VideoChannelNSOpenGL*>::iterator it;
    it = _nsglChannels.begin();

    while (it != _nsglChannels.end())
    {
        VideoChannelNSOpenGL* channel = it->second;
        WEBRTC_TRACE(kTraceInfo, kTraceVideoRenderer, _id, "%s Deleting channel %d", __FUNCTION__, channel);
        delete channel;
        it++;
    }
    _nsglChannels.clear();
    return 0;
}

WebRtc_Word32 VideoRenderNSOpenGL::DeleteNSGLChannel(const WebRtc_UWord32 channel)
{

    CriticalSectionScoped cs(&_nsglContextCritSec);

    std::map<int, VideoChannelNSOpenGL*>::iterator it;
    it = _nsglChannels.find(channel);
    if (it != _nsglChannels.end())
    {
        delete it->second;
        _nsglChannels.erase(it);
    }
    else
    {
        return -1;
    }

    std::multimap<int, int>::iterator zIt = _zOrderToChannel.begin();
    while( zIt != _zOrderToChannel.end())
    {
        if (zIt->second == (int)channel)
        {
            _zOrderToChannel.erase(zIt);
            break;
        }
        zIt++;
    }

    return 0;
}

WebRtc_Word32 VideoRenderNSOpenGL::GetChannelProperties(const WebRtc_UWord16 streamId,
        WebRtc_UWord32& zOrder,
        float& left,
        float& top,
        float& right,
        float& bottom)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);

    bool channelFound = false;

    // Loop through all channels until we find a match.
    // From that, get zorder.
    // From that, get T, L, R, B
    for (std::multimap<int, int>::reverse_iterator rIt = _zOrderToChannel.rbegin();
            rIt != _zOrderToChannel.rend();
            rIt++)
    {
        if(streamId == rIt->second)
        {
            channelFound = true;

            zOrder = rIt->second;

            std::map<int, VideoChannelNSOpenGL*>::iterator rIt = _nsglChannels.find(streamId);
            VideoChannelNSOpenGL* tempChannel = rIt->second;

            if(-1 == tempChannel->GetChannelProperties(left, top, right, bottom) )
            {
                return -1;
            }
            break;
        }
    }

    if(false == channelFound)
    {

        return -1;
    }

    return 0;
}

WebRtc_Word32 VideoRenderNSOpenGL::SetStreamCropping(const WebRtc_UWord16 channel,
                                                     const WebRtc_UWord16 streamId,
                                                     float left,
                                                     float top,
                                                     float right,
                                                     float bottom)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);
    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.find(channel);
    if (it == _nsglChannels.end() || it->second == NULL)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "Could not find the channel %d", channel);
        return -1;
    }
    return it->second->SetStreamCropSettings(streamId, left, top, right, bottom);
}
    
int VideoRenderNSOpenGL::StopThread()
{

    ThreadWrapper* tmpPtr = _screenUpdateThread;
    WEBRTC_TRACE(kTraceInfo, kTraceVideoRenderer, _id, "%s Stopping thread ", __FUNCTION__, _screenUpdateThread);
    _screenUpdateThread = NULL;

    if (tmpPtr)
    {
        tmpPtr->SetNotAlive();
        _screenUpdateEvent->Set();
        if (tmpPtr->Stop())
        {
            delete tmpPtr;
        }
    }

    delete _screenUpdateEvent;
    _screenUpdateEvent = NULL;

    return 0;
}

bool VideoRenderNSOpenGL::IsFullScreen()
{

    CriticalSectionScoped cs(&_nsglContextCritSec);
    return _fullScreen;
}

bool VideoRenderNSOpenGL::HasChannels()
{
    CriticalSectionScoped cs(&_nsglContextCritSec);

    if (_nsglChannels.begin() != _nsglChannels.end())
    {
        return true;
    }
    return false;
}

bool VideoRenderNSOpenGL::HasChannel(int channel)
{

    CriticalSectionScoped cs(&_nsglContextCritSec);

    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.find(channel);

    if (it != _nsglChannels.end())
    {
        return true;
    }
    return false;
}

int VideoRenderNSOpenGL::GetChannels(std::list<int>& channelList)
{

    CriticalSectionScoped cs(&_nsglContextCritSec);

    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.begin();

    while (it != _nsglChannels.end())
    {
        channelList.push_back(it->first);
        it++;
    }

    return 0;
}

VideoChannelNSOpenGL* VideoRenderNSOpenGL::ConfigureNSGLChannel(int channel, int zOrder, float startWidth, float startHeight, float stopWidth, float stopHeight)
{

    CriticalSectionScoped cs(&_nsglContextCritSec);

    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.find(channel);

    if (it != _nsglChannels.end())
    {
        VideoChannelNSOpenGL* aglChannel = it->second;
        if (aglChannel->SetStreamSettings(0, startWidth, startHeight, stopWidth, stopHeight) == -1)
        {
            WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "%s failed to set stream settings: channel %d. channel=%d zOrder=%d startWidth=%d startHeight=%d stopWidth=%d stopHeight=%d",
                    __FUNCTION__, channel, zOrder, startWidth, startHeight, stopWidth, stopHeight);
            return NULL;
        }
        WEBRTC_TRACE(kTraceInfo, kTraceVideoRenderer, _id, "%s Configuring channel %d. channel=%d zOrder=%d startWidth=%d startHeight=%d stopWidth=%d stopHeight=%d",
                __FUNCTION__, channel, zOrder, startWidth, startHeight, stopWidth, stopHeight);

        std::multimap<int, int>::iterator it = _zOrderToChannel.begin();
        while(it != _zOrderToChannel.end())
        {
            if (it->second == channel)
            {
                if (it->first != zOrder)
                {
                    _zOrderToChannel.erase(it);
                    _zOrderToChannel.insert(std::pair<int, int>(zOrder, channel));
                }
                break;
            }
            it++;
        }
        return aglChannel;
    }

    return NULL;
}

/*
 *
 *    Rendering process
 *
 */

bool VideoRenderNSOpenGL::ScreenUpdateThreadProc(void* obj)
{
    return static_cast<VideoRenderNSOpenGL*>(obj)->ScreenUpdateProcess();
}

bool VideoRenderNSOpenGL::ScreenUpdateProcess()
{
    if (_screenUpdateEvent->Wait(100) == kEventTimeout)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "_screenUpdateEvent seems the have been stuck");
    }
    
    CriticalSectionScoped cs(&_nsglContextCritSec);
    if (_mixingContextReady)
    {
        return RedrawFrame();
    }
    return true;
}
    
bool VideoRenderNSOpenGL::RedrawFrame()
{
    LockAGLCntx();
    
    if (!_screenUpdateThread)
    {
        WEBRTC_TRACE(kTraceWarning, kTraceVideoRenderer, _id, "%s no screen update thread", __FUNCTION__);
        UnlockAGLCntx();
        return false;
    }
    
    [_nsglContext makeCurrentContext];
    
    if (GetWindowRect(_windowRect) == -1)
    {
        UnlockAGLCntx();
        return true;
    }
    
    if (_windowWidth != (_windowRect.right - _windowRect.left)
        || _windowHeight != (_windowRect.bottom - _windowRect.top))
    {
        _windowWidth = _windowRect.right - _windowRect.left;
        _windowHeight = _windowRect.bottom - _windowRect.top;
        glViewport(0, 0, _windowWidth, _windowHeight);
        GLenum glErr = glGetError();
        if (glErr != GL_NO_ERROR)
        {
            WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glViewport", glErr);
            UnlockAGLCntx();
            return false;
        }
    }
    
    // Check if there are any updated buffers
    bool updated = false;
    std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.begin();
    while (it != _nsglChannels.end())
    {
        
        VideoChannelNSOpenGL* aglChannel = it->second;
        aglChannel->UpdateStretchSize(_windowHeight, _windowWidth);
        aglChannel->IsUpdated(updated);
        if (updated)
        {
            break;
        }
        it++;
    }
    
    if (updated)
    {
        // At least on buffers is updated, we need to repaint the texture
        if (RenderOffScreenBuffers() != -1)
        {
            UnlockAGLCntx();
            return true;
        }
    }

    UnlockAGLCntx();
    return true;
}
    
void VideoRenderNSOpenGL::drawRect(float x, float y, float w, float h)
{
    if(CreateMixingContext() == -1)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR creating mixing context");
        return;
    }

    RedrawFrame();
}

/*
 *
 *    Functions for creating mixing buffers and screen settings
 *
 */

int VideoRenderNSOpenGL::CreateMixingContext()
{
    CriticalSectionScoped cs(&_nsglContextCritSec);
    
    if (_mixingContextReady)
    {
        return 0;
    }
    
    if(_fullScreen)
    {
        if(-1 == setRenderTargetFullScreen())
        {
            return -1;
        }
    }
    else
    {
        if(-1 == setRenderTargetWindow())
        {
            return -1;
        }
    }

    if (-1 == configureNSOpenGLEngine())
    {
        return -1;
    }

    if (-1 == DisplayBuffers())
    {
        return -1;
    }
    
    _mixingContextReady = true;

    return 0;
}

/*
 *
 *    Rendering functions
 *
 */

int VideoRenderNSOpenGL::RenderOffScreenBuffers()
{
    LockAGLCntx();

    // Get the current window size, it might have changed since last render.
    if (GetWindowRect(_windowRect) == -1)
    {
        UnlockAGLCntx();
        return -1;
    }

    [_nsglContext makeCurrentContext];
    glClear(GL_COLOR_BUFFER_BIT);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glClear", glErr);
        UnlockAGLCntx();
        return -1;
    }

    // Loop through all channels starting highest zOrder ending with lowest.
    for (std::multimap<int, int>::reverse_iterator rIt = _zOrderToChannel.rbegin();
            rIt != _zOrderToChannel.rend();
            rIt++)
    {
        int channelId = rIt->second;
        std::map<int, VideoChannelNSOpenGL*>::iterator it = _nsglChannels.find(channelId);

        VideoChannelNSOpenGL* aglChannel = it->second;

        if (aglChannel->RenderOffScreenBuffer() == -1)
        {
            UnlockAGLCntx();
            return -1;
        }
    }

    if (-1 == DisplayBuffers())
    {
        UnlockAGLCntx();
        return -1;
    }

    UnlockAGLCntx();
    return 0;
}

/*
 *
 * Help functions
 *
 * All help functions assumes external protections
 *
 */

int VideoRenderNSOpenGL::DisplayBuffers()
{
    LockAGLCntx();

    glFinish();
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR)
    {
        WEBRTC_TRACE(kTraceError, kTraceVideoRenderer, _id, "ERROR %d while calling glFinish in DisplayBuffers()", glErr);
        UnlockAGLCntx();
        return -1;
    }
    
    [_nsglContext flushBuffer];

    WEBRTC_TRACE(kTraceDebug, kTraceVideoRenderer, _id, "%s glFinish and [_nsglContext flushBuffer]", __FUNCTION__);

    UnlockAGLCntx();
    return 0;
}

int VideoRenderNSOpenGL::GetWindowRect(Rect& rect)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);

    if (_windowRef)
    {
        if(_fullScreen)
        {
            NSRect mainDisplayRect = [[NSScreen mainScreen] frame];
            rect.bottom = 0;
            rect.left = 0;
            rect.right = mainDisplayRect.size.width;
            rect.top = mainDisplayRect.size.height;
        }
        else
        {
            rect.top = [_windowRef frame].origin.y;
            rect.left = [_windowRef frame].origin.x;
            rect.bottom = [_windowRef frame].origin.y + [_windowRef frame].size.height;
            rect.right = [_windowRef frame].origin.x + [_windowRef frame].size.width;
        }

        return 0;
    }
    else
    {
        return -1;
    }
}

WebRtc_Word32 VideoRenderNSOpenGL::ChangeUniqueID(WebRtc_Word32 id)
{
    CriticalSectionScoped cs(&_nsglContextCritSec);
    _id = id;
    return 0;
}

WebRtc_Word32 VideoRenderNSOpenGL::SetText(const WebRtc_UWord8 /*textId*/,
        const WebRtc_UWord8* /*text*/,
        const WebRtc_Word32 /*textLength*/,
        const WebRtc_UWord32 /*textColorRef*/,
        const WebRtc_UWord32 /*backgroundColorRef*/,
        const float /*left*/,
        const float /*top*/,
        const float /*right*/,
        const float /*bottom*/)
{

    return 0;

}

void VideoRenderNSOpenGL::LockAGLCntx()
{
    _nsglContextCritSec.Enter();
}
void VideoRenderNSOpenGL::UnlockAGLCntx()
{
    _nsglContextCritSec.Leave();
}

/*

 bool VideoRenderNSOpenGL::SetFullScreen(bool fullscreen)
 {
 NSRect mainDisplayRect, viewRect;

 // Create a screen-sized window on the display you want to take over
 // Note, mainDisplayRect has a non-zero origin if the key window is on a secondary display
 mainDisplayRect = [[NSScreen mainScreen] frame];
 fullScreenWindow = [[NSWindow alloc] initWithContentRect:mainDisplayRect styleMask:NSBorderlessWindowMask
 backing:NSBackingStoreBuffered defer:YES];

 // Set the window level to be above the menu bar
 [fullScreenWindow setLevel:NSMainMenuWindowLevel+1];

 // Perform any other window configuration you desire
 [fullScreenWindow setOpaque:YES];
 [fullScreenWindow setHidesOnDeactivate:YES];

 // Create a view with a double-buffered OpenGL context and attach it to the window
 // By specifying the non-fullscreen context as the shareContext, we automatically inherit the OpenGL objects (textures, etc) it has defined
 viewRect = NSMakeRect(0.0, 0.0, mainDisplayRect.size.width, mainDisplayRect.size.height);
 fullScreenView = [[MyOpenGLView alloc] initWithFrame:viewRect shareContext:[openGLView openGLContext]];
 [fullScreenWindow setContentView:fullScreenView];

 // Show the window
 [fullScreenWindow makeKeyAndOrderFront:self];

 // Set the scene with the full-screen viewport and viewing transformation
 [scene setViewportRect:viewRect];

 // Assign the view's MainController to self
 [fullScreenView setMainController:self];

 if (!isAnimating) {
 // Mark the view as needing drawing to initalize its contents
 [fullScreenView setNeedsDisplay:YES];
 }
 else {
 // Start playing the animation
 [fullScreenView startAnimation];
 }

 }



 */


} //namespace webrtc

#endif // COCOA_RENDERING
