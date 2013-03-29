//
//  cocoa_render_view_draw_rect_observer.h
//  modules
//
//  Created by Dmitry Zhukov on 30.08.12.
//
//

#ifndef modules_cocoa_render_view_observer_interface_h
#define modules_cocoa_render_view_observer_interface_h

class CocoaRenderViewObserverInterface
{
public:
    virtual void drawRect(float x, float y, float w, float h) = 0;
};

#endif
