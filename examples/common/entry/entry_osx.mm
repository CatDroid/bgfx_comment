/*
 * Copyright 2011-2021 Branimir Karadzic. All rights reserved.
 * License: https://github.com/bkaradzic/bgfx#license-bsd-2-clause
 */

#include "entry_p.h"

#if ENTRY_CONFIG_USE_NATIVE && BX_PLATFORM_OSX

#import <Cocoa/Cocoa.h>

#include <bgfx/platform.h>

#include <bx/uint32_t.h>
#include <bx/thread.h>
#include <bx/os.h>
#include <bx/handlealloc.h>

@interface AppDelegate : NSObject<NSApplicationDelegate>
{
	bool terminated;
}

+ (AppDelegate *)sharedDelegate; // 创建APP代理的函数
- (id)init;

// 代理的方法  可以监控app的各种生命周期 比如will|did Hide Unhide等各种通知
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;
- (void)applicationWillTerminate:(NSNotification *)notification;


// 这个不是代理方法 主循环 用来判断是否 退出
- (bool)applicationHasTerminated;

@end

@interface Window : NSObject<NSWindowDelegate> // 窗口代理对象
{
}

+ (Window*)sharedDelegate;
- (id)init;
- (void)windowCreated:(NSWindow*)window;
- (void)windowWillClose:(NSNotification*)notification;
- (BOOL)windowShouldClose:(NSWindow*)window;
- (void)windowDidResize:(NSNotification*)notification;
- (void)windowDidBecomeKey:(NSNotification *)notification;
- (void)windowDidResignKey:(NSNotification *)notification;

@end

namespace entry
{
	///
	inline void osxSetNSWindow(void* _window, void* _nsgl = NULL)
	{
		bgfx::PlatformData pd;
		pd.ndt          = NULL;
		pd.nwh          = _window;
		pd.context      = _nsgl;
		pd.backBuffer   = NULL;
		pd.backBufferDS = NULL;
		bgfx::setPlatformData(pd);
	}

	static uint8_t s_translateKey[256];

	struct MainThreadEntry
	{
		int m_argc;
		const char* const* m_argv;

		static int32_t threadFunc(bx::Thread* _thread, void* _userData)
		{
			BX_UNUSED(_thread);

			CFBundleRef mainBundle = CFBundleGetMainBundle();
			if (mainBundle != nil)
			{
				CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(mainBundle);
				if (resourcesURL != nil)
				{
					char path[PATH_MAX];
					if (CFURLGetFileSystemRepresentation(resourcesURL, TRUE, (UInt8*)path, PATH_MAX) )
					{
						chdir(path);
					}

					CFRelease(resourcesURL);
				}
			}

			MainThreadEntry* self = (MainThreadEntry*)_userData;
			uint32_t result = main(self->m_argc, self->m_argv);
			[NSApp terminate:nil]; // 终止app 这个在非主线程上调用了  -[NSApplication terminate:] must be used from main thread only
			return result;
		}
	};

	struct Context
	{
		Context()
			: m_scrollf(0.0f)
			, m_mx(0)
			, m_my(0)
			, m_scroll(0)
			, m_style(0)
			, m_exit(false)
			, m_mouseLock(NULL)
		{
			s_translateKey[27]             = Key::Esc;
			s_translateKey[uint8_t('\r')]  = Key::Return;
			s_translateKey[uint8_t('\t')]  = Key::Tab;
			s_translateKey[127]            = Key::Backspace;
			s_translateKey[uint8_t(' ')]   = Key::Space;

			s_translateKey[uint8_t('+')]   =
			s_translateKey[uint8_t('=')]   = Key::Plus;
			s_translateKey[uint8_t('_')]   =
			s_translateKey[uint8_t('-')]   = Key::Minus;

			s_translateKey[uint8_t('~')]   =
			s_translateKey[uint8_t('`')]   = Key::Tilde;

			s_translateKey[uint8_t(':')]   =
			s_translateKey[uint8_t(';')]   = Key::Semicolon;
			s_translateKey[uint8_t('"')]   =
			s_translateKey[uint8_t('\'')]  = Key::Quote;

			s_translateKey[uint8_t('{')]   =
			s_translateKey[uint8_t('[')]   = Key::LeftBracket;
			s_translateKey[uint8_t('}')]   =
			s_translateKey[uint8_t(']')]   = Key::RightBracket;

			s_translateKey[uint8_t('<')]   =
			s_translateKey[uint8_t(',')]   = Key::Comma;
			s_translateKey[uint8_t('>')]   =
			s_translateKey[uint8_t('.')]   = Key::Period;
			s_translateKey[uint8_t('?')]   =
			s_translateKey[uint8_t('/')]   = Key::Slash;
			s_translateKey[uint8_t('|')]   =
			s_translateKey[uint8_t('\\')]  = Key::Backslash;

			s_translateKey[uint8_t('0')]   = Key::Key0;
			s_translateKey[uint8_t('1')]   = Key::Key1;
			s_translateKey[uint8_t('2')]   = Key::Key2;
			s_translateKey[uint8_t('3')]   = Key::Key3;
			s_translateKey[uint8_t('4')]   = Key::Key4;
			s_translateKey[uint8_t('5')]   = Key::Key5;
			s_translateKey[uint8_t('6')]   = Key::Key6;
			s_translateKey[uint8_t('7')]   = Key::Key7;
			s_translateKey[uint8_t('8')]   = Key::Key8;
			s_translateKey[uint8_t('9')]   = Key::Key9;

			for (char ch = 'a'; ch <= 'z'; ++ch)
			{
				s_translateKey[uint8_t(ch)]       =
				s_translateKey[uint8_t(ch - ' ')] = Key::KeyA + (ch - 'a');
			}

			for(int ii=0; ii<ENTRY_CONFIG_MAX_WINDOWS; ++ii)
			{
				m_window[ii] = NULL;
			}
		}

		NSEvent* waitEvent()
		{
			return [NSApp
				nextEventMatchingMask:NSEventMaskAny
				untilDate:[NSDate distantFuture] // wait for event
				inMode:NSDefaultRunLoopMode
				dequeue:YES
				];
		}

		NSEvent* peekEvent()
		{
            // NSApp nextEvent
			return [NSApp
				nextEventMatchingMask:NSEventMaskAny // 匹配任何事件的掩码 NSUIntegerMax
				untilDate:[NSDate distantPast] // do not wait for event  表示过去的某个不可达到的事件点 也就是获取到目前为止所有的事件
				inMode:NSDefaultRunLoopMode // run node 是 default
				dequeue:YES
				];
		}

		void getMousePos(NSWindow *window, int* outX, int* outY)
		{
			//WindowHandle handle = { 0 };
			//NSWindow* window = m_window[handle.idx];

			NSRect  originalFrame = [window frame];
			NSPoint location      = [window mouseLocationOutsideOfEventStream];
			NSRect  adjustFrame   = [window contentRectForFrameRect: originalFrame];

			int32_t x = location.x;
			int32_t y = int32_t(adjustFrame.size.height) - int32_t(location.y);

			// clamp within the range of the window
			*outX = bx::clamp(x, 0, int32_t(adjustFrame.size.width) );
			*outY = bx::clamp(y, 0, int32_t(adjustFrame.size.height) );
		}

		void setMousePos(NSWindow* _window, int _x, int _y)
		{
			NSRect  originalFrame = [_window frame];
			NSRect  adjustFrame   = [_window contentRectForFrameRect: originalFrame];

			adjustFrame.origin.y = NSMaxY(NSScreen.screens[0].frame) - NSMaxY(adjustFrame);

			CGWarpMouseCursorPosition(CGPointMake(_x + adjustFrame.origin.x, _y + adjustFrame.origin.y));
			CGAssociateMouseAndMouseCursorPosition(YES);
		}

		void setMouseLock(NSWindow* _window, bool _lock)
		{
			NSWindow* newMouseLock = _lock ? _window : NULL;

			if ( m_mouseLock != newMouseLock )
			{
				if ( _lock )
				{
					NSRect  originalFrame = [_window frame];
					NSRect  adjustFrame   = [_window contentRectForFrameRect: originalFrame];

					m_cmx = (int)adjustFrame.size.width / 2;
					m_cmy = (int)adjustFrame.size.height / 2;

					setMousePos(_window, m_cmx, m_cmy);
					[NSCursor hide];
				}
				else
				{
					[NSCursor unhide];
				}
				m_mouseLock = newMouseLock;
			}
		}


		uint8_t translateModifiers(int flags)
		{
			return 0
				| ( (0 != (flags & NX_DEVICELSHIFTKEYMASK) ) ? Modifier::LeftShift  : 0)
				| ( (0 != (flags & NX_DEVICERSHIFTKEYMASK) ) ? Modifier::RightShift : 0)
				| ( (0 != (flags & NX_DEVICELALTKEYMASK) )   ? Modifier::LeftAlt    : 0)
				| ( (0 != (flags & NX_DEVICERALTKEYMASK) )   ? Modifier::RightAlt   : 0)
				| ( (0 != (flags & NX_DEVICELCTLKEYMASK) )   ? Modifier::LeftCtrl   : 0)
				| ( (0 != (flags & NX_DEVICERCTLKEYMASK) )   ? Modifier::RightCtrl  : 0)
				| ( (0 != (flags & NX_DEVICELCMDKEYMASK) )   ? Modifier::LeftMeta   : 0)
				| ( (0 != (flags & NX_DEVICERCMDKEYMASK) )   ? Modifier::RightMeta  : 0)
				;
		}

		Key::Enum handleKeyEvent(NSEvent* event, uint8_t* specialKeys, uint8_t* _pressedChar)
		{
			NSString* key = [event charactersIgnoringModifiers];
			unichar keyChar = 0;
			if ([key length] == 0)
			{
				return Key::None;
			}

			keyChar = [key characterAtIndex:0];
			*_pressedChar = (uint8_t)keyChar;

			int keyCode = keyChar;
			*specialKeys = translateModifiers(int([event modifierFlags]));

			// if this is a unhandled key just return None
			if (keyCode < 256)
			{
				return (Key::Enum)s_translateKey[keyCode];
			}

			switch (keyCode)
			{
			case NSF1FunctionKey:  return Key::F1;
			case NSF2FunctionKey:  return Key::F2;
			case NSF3FunctionKey:  return Key::F3;
			case NSF4FunctionKey:  return Key::F4;
			case NSF5FunctionKey:  return Key::F5;
			case NSF6FunctionKey:  return Key::F6;
			case NSF7FunctionKey:  return Key::F7;
			case NSF8FunctionKey:  return Key::F8;
			case NSF9FunctionKey:  return Key::F9;
			case NSF10FunctionKey: return Key::F10;
			case NSF11FunctionKey: return Key::F11;
			case NSF12FunctionKey: return Key::F12;

			case NSLeftArrowFunctionKey:   return Key::Left;
			case NSRightArrowFunctionKey:  return Key::Right;
			case NSUpArrowFunctionKey:     return Key::Up;
			case NSDownArrowFunctionKey:   return Key::Down;

			case NSPageUpFunctionKey:      return Key::PageUp;
			case NSPageDownFunctionKey:    return Key::PageDown;
			case NSHomeFunctionKey:        return Key::Home;
			case NSEndFunctionKey:         return Key::End;

			case NSPrintScreenFunctionKey: return Key::Print;
			}

			return Key::None;
		}

		bool dispatchEvent(NSEvent* event)
		{
			if (event)
			{
				NSEventType eventType = [event type]; // 窗口时间

				NSWindow *window = [event window]; //
				WindowHandle handle = {UINT16_MAX};
				if (nil != window)
				{
					handle = findHandle(window);
				}
				if (!isValid(handle)) // 事件所在窗口 没有注册找到 就直接
				{
					[NSApp sendEvent:event];
					[NSApp updateWindows];
					return true;
				}

                // 系统的事件 NSEvent* event 如果需要先自己处理一下
				switch (eventType)
				{
				case NSEventTypeMouseMoved:
				case NSEventTypeLeftMouseDragged:
				case NSEventTypeRightMouseDragged:
				case NSEventTypeOtherMouseDragged:
					getMousePos(window, &m_mx, &m_my);

					if (window == m_mouseLock)
					{
						m_mx -= m_cmx;
						m_my -= m_cmy;

						setMousePos(window, m_cmx, m_cmy);
					}

					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll);
					break;

				case NSEventTypeLeftMouseDown:
					{
						// Command + Left Mouse Button acts as middle! This just a temporary solution!
						// This is because the average OSX user doesn't have middle mouse click.
						MouseButton::Enum mb = ([event modifierFlags] & NSEventModifierFlagCommand)
							? MouseButton::Middle
							: MouseButton::Left
							;
						m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, mb, true);
					}
					break;

				case NSEventTypeLeftMouseUp:
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Left, false);
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Middle, false);
					break;

				case NSEventTypeRightMouseDown:
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Right, true);
					break;

				case NSEventTypeRightMouseUp:
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Right, false);
					break;

				case NSEventTypeOtherMouseDown:
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Middle, true);
					break;

				case NSEventTypeOtherMouseUp:
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Middle, false);
					break;

				case NSEventTypeScrollWheel:
					m_scrollf += [event deltaY];

					m_scroll = (int32_t)m_scrollf;
					m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll);
					break;

				case NSEventTypeKeyDown:
					{
						uint8_t modifiers = 0;
						uint8_t pressedChar[4];
						Key::Enum key = handleKeyEvent(event, &modifiers, &pressedChar[0]);

						// Returning false means that we take care of the key (instead of the default behavior)
						if (key != Key::None)
						{
							if (key == Key::KeyQ && (modifiers & Modifier::RightMeta) )
							{
								m_eventQueue.postExitEvent();
							}
							else
							{
								enum { ShiftMask = Modifier::LeftShift|Modifier::RightShift };
								m_eventQueue.postCharEvent(handle, 1, pressedChar);
								m_eventQueue.postKeyEvent(handle, key, modifiers, true);
								return false;
							}
						}
					}
					break;

				case NSEventTypeKeyUp:
					{
						uint8_t modifiers  = 0;
						uint8_t pressedChar[4];
						Key::Enum key = handleKeyEvent(event, &modifiers, &pressedChar[0]);

						BX_UNUSED(pressedChar);

						if (key != Key::None)
						{
							m_eventQueue.postKeyEvent(handle, key, modifiers, false);
							return false;
						}

					}
					break;

				default:
					break;
				}

				[NSApp sendEvent:event];
				[NSApp updateWindows];

				return true;
			}

			return false;
		}

		void windowDidResize(NSWindow *window)
		{
			WindowHandle handle = findHandle(window);
			NSRect originalFrame = [window frame];
			NSRect rect = [window contentRectForFrameRect: originalFrame];
			uint32_t width  = uint32_t(rect.size.width);
			uint32_t height = uint32_t(rect.size.height);
			m_eventQueue.postSizeEvent(handle, width, height);

			// Make sure mouse button state is 'up' after resize.
			m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Left,  false);
			m_eventQueue.postMouseEvent(handle, m_mx, m_my, m_scroll, MouseButton::Right, false);
		}

		void windowDidBecomeKey(NSWindow *window)
		{
			WindowHandle handle = findHandle(window);
			m_eventQueue.postSuspendEvent(handle, Suspend::WillResume);
			m_eventQueue.postSuspendEvent(handle, Suspend::DidResume);
		}

		void windowDidResignKey(NSWindow *window)
		{
			WindowHandle handle = findHandle(window);
			m_eventQueue.postSuspendEvent(handle, Suspend::WillSuspend);
			m_eventQueue.postSuspendEvent(handle, Suspend::DidSuspend);
		}

		int32_t run(int _argc, const char* const* _argv) // macOS main函数就到这里来
		{
			[NSApplication sharedApplication];

			id dg = [AppDelegate sharedDelegate];
			[NSApp setDelegate:dg];
			[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
			[NSApp activateIgnoringOtherApps:YES];
			[NSApp finishLaunching];

			[[NSNotificationCenter defaultCenter]
				postNotificationName:NSApplicationWillFinishLaunchingNotification
				object:NSApp];

			[[NSNotificationCenter defaultCenter]
				postNotificationName:NSApplicationDidFinishLaunchingNotification
				object:NSApp];

			id quitMenuItem = [NSMenuItem new];
			[quitMenuItem
				initWithTitle:@"Quit"
				action:@selector(terminate:)
				keyEquivalent:@"q"];

			id appMenu = [NSMenu new];
			[appMenu addItem:quitMenuItem];

			id appMenuItem = [NSMenuItem new];
			[appMenuItem setSubmenu:appMenu];

			id menubar = [[NSMenu new] autorelease];
			[menubar addItem:appMenuItem];
			[NSApp setMainMenu:menubar];

			m_style = 0
				| NSWindowStyleMaskTitled
				| NSWindowStyleMaskResizable
				| NSWindowStyleMaskClosable
				| NSWindowStyleMaskMiniaturizable
				;

			NSRect screenRect = [[NSScreen mainScreen] frame];
			const float centerX = (screenRect.size.width  - (float)ENTRY_DEFAULT_WIDTH )*0.5f;
			const float centerY = (screenRect.size.height - (float)ENTRY_DEFAULT_HEIGHT)*0.5f;
			NSString* appName = [[NSProcessInfo processInfo] processName];
			createWindow(centerX, centerY, ENTRY_DEFAULT_WIDTH, ENTRY_DEFAULT_HEIGHT, ENTRY_WINDOW_FLAG_NONE, [appName UTF8String]);

			m_windowFrame = [m_window[0] frame];

			osxSetNSWindow(m_window[0]);

			MainThreadEntry mte;
			mte.m_argc = _argc;
			mte.m_argv = _argv;

			bx::Thread thread;
			thread.init(mte.threadFunc, &mte); // 这里会启动一个线程 执行demo  MainThreadEntry::threadFunc --> bgfx::init() (在app::init中) bgfx::frame() (在app:update中)

			WindowHandle handle = { 0 };
			NSRect contentRect = [m_window[0] contentRectForFrameRect: m_windowFrame];
			uint32_t width = uint32_t(contentRect.size.width);
			uint32_t height = uint32_t(contentRect.size.height);
			m_eventQueue.postSizeEvent(handle, width, height);

            // [NSThread sleepForTimeInterval:0.5]; // 这样会崩溃
            // 在实际多线程的情况下 bgfx::renderFrame(); 要先与 bgfx::init 
            
            // 这里是主线程
			while (!(m_exit = [dg applicationHasTerminated]) ) // 这里不断循环
			{
                
                // APP的代理在applicationShouldTerminate 中会返回Cancel 同时标记terminal=true,
                // dg applicationHasTerminated 就会返回true 从而在main函数中退出
                
				bgfx::renderFrame(); // 跑到这里的时候 thread.init(mte.threadFunc, 还没有执行 ?? 这个怎么能确保??

				@autoreleasepool
				{
					while (dispatchEvent(peekEvent() ) ) // 接收键盘信息处理
					{
					}
				}
			}

			m_eventQueue.postExitEvent();

			while (bgfx::RenderFrame::NoContext != bgfx::renderFrame() ) {};
            
			thread.shutdown();

			return 0;
		}

		WindowHandle findHandle(NSWindow *_window)
		{
			bx::MutexScope scope(m_lock);
			for (uint16_t ii = 0, num = m_windowAlloc.getNumHandles(); ii < num; ++ii)
			{
				uint16_t idx = m_windowAlloc.getHandleAt(ii);
				if (_window == m_window[idx])
				{
					WindowHandle handle = { idx };
					return handle;
				}
			}

			WindowHandle invalid = { UINT16_MAX };
			return invalid;
		}

		EventQueue m_eventQueue;
		bx::Mutex m_lock;

		bx::HandleAllocT<ENTRY_CONFIG_MAX_WINDOWS> m_windowAlloc;
		NSWindow* m_window[ENTRY_CONFIG_MAX_WINDOWS];
		NSRect m_windowFrame;

		float   m_scrollf;
		int32_t m_mx;
		int32_t m_my;
		int32_t m_scroll;
		int32_t m_style;
		bool    m_exit;

		NSWindow* m_mouseLock;
		int32_t m_cmx;
		int32_t m_cmy;
	};

	static Context s_ctx;

	const Event* poll()
	{
		return s_ctx.m_eventQueue.poll();
	}

	const Event* poll(WindowHandle _handle)
	{
		return s_ctx.m_eventQueue.poll(_handle);
	}

	void release(const Event* _event)
	{
		s_ctx.m_eventQueue.release(_event);
	}

	WindowHandle createWindow(int32_t _x, int32_t _y, uint32_t _width, uint32_t _height, uint32_t _flags, const char* _title)
	{
		BX_UNUSED(_flags);

		bx::MutexScope scope(s_ctx.m_lock);
		WindowHandle handle = { s_ctx.m_windowAlloc.alloc() }; // 先分配一个窗口句柄 用来对应这个窗口

		if (UINT16_MAX != handle.idx)
		{
			void (^createWindowBlock)(void) = ^(void) {
				NSRect rect = NSMakeRect(_x, _y, _width, _height);
                NSWindow* window = [
                                    [NSWindow alloc]
                                    initWithContentRect:rect
                                    // 屏幕坐标中窗口内容区域的原点和大小。 请注意，窗口服务器将窗口位置坐标限制为 ±16,000，大小限制为 10,000。
                                    styleMask:s_ctx.m_style
                                    // 窗户的风格。 它可以是 NSBorderlessWindowMask，也可以包含 NSWindowStyleMask 中描述的任何选项， 使用|组合
                                    // 无边框窗口不显示任何常用的外围元素，通常仅用于显示或缓存目的； 您通常不需要创建它们(?外围元素)。
                                    // 另外，请注意，如果窗口有其他东西, 样式掩码包含应该包含 NSTitledWindowMask。
                                    backing:NSBackingStoreBuffered
                                    // 指定窗口设备如何缓冲在窗口中完成的绘图
                                    // NSBackingStoreRetained 和 NSBackingStoreNonretained 实际上是 NSBackingStoreBuffered 的同义词, 所以后面只用  NSBackingStoreBuffered
                                    defer:NO
                                    // 指定窗口服务器是否立即为窗口创建窗口设备。
                                    // 当为 YES 时，窗口服务器推迟创建窗口设备，直到 " 窗口在屏幕上移动 "。
                                    // 发送到窗口或其视图的所有显示消息都被"推迟postponed"到创建窗口之前，就刚好在windows在屏幕上移动之前。
                                    
                                    ];
                
                
                // 显示窗口的名字
				NSString* appName = [NSString stringWithUTF8String:_title];
				[window setTitle:appName];
                
                /*
                 将窗口移动到屏幕列表的最前面，
                 在其级别内，并使其成为关键窗口；
                 也就是说，它显示了窗口。
                 */
				[window makeKeyAndOrderFront:window];
                
                /*
                对于view 要接收 NSMouseMoved事件的，必须满足两个条件：
                 1. view必须是第一响应者responder。
                 2. view所在的windows必须调用 setAcceptsMouseMovedEvents:YES (sent a setAcceptsMouseMovedEvents: message with an argument of YES)。
                 */
				[window setAcceptsMouseMovedEvents:YES];
                
                /*
                 设置窗口window的背景颜色
                 */
				[window setBackgroundColor:[NSColor blackColor]];
                
                // 创建 窗口代理对象 里面只是：保存其代理的窗口 + setDelegate设置窗口的代理
				[[Window sharedDelegate] windowCreated:window];

                // entry::Context保存这个创建的NSWindows， WindowHandle句柄对应一个NSWindows对象
				s_ctx.m_window[handle.idx] = window;

                // 先往entry::Context事件队列 发送尺寸事件 和 窗口事件 事件都带有窗口句柄 + 其他参数(比如宽高，或者窗口对象NSWindows*)
				s_ctx.m_eventQueue.postSizeEvent(handle, _width, _height);
				s_ctx.m_eventQueue.postWindowEvent(handle, window);
			};

			if ([NSThread isMainThread]) // 如果运行的是主线程 就直接执行创建window
			{
				createWindowBlock();
			}
			else
			{
				dispatch_async(dispatch_get_main_queue(), createWindowBlock); // 异步抛给主线程处理
			}
		}

		return handle;
	}

	void destroyWindow(WindowHandle _handle, bool _closeWindow)
	{
		if (isValid(_handle))
		{
			dispatch_async(dispatch_get_main_queue()
				, ^(void){
					NSWindow *window = s_ctx.m_window[_handle.idx];
					if ( NULL != window)
					{
						s_ctx.m_eventQueue.postWindowEvent(_handle); // 抛给 entry::Context 事件队列处理 ??
						s_ctx.m_window[_handle.idx] = NULL;
						if ( _closeWindow )
						{
							[window close];
						}

						if (0 == _handle.idx) // 如果是第一个窗口关闭   程序退出
						{
                            // APPKIT_EXTERN __kindof NSApplication * _Null_unspecified NSApp;
                            
							[NSApp terminate:nil]; // receiver=nil   直接调用到 App代理 NSApplicationDelete的applicationShouldTerminate 判断是否真的退出
                            /*
                                终止receiver
                                当用户从应用程序的菜单中选择退出或退出时，通常会调用此方法。

                                调用时，此方法执行几个步骤来处理terminate请求。
                                首先，它要求应用程序的文档控制器（document controller  如果存在）保存其文档中任何未保存的更改。
                                     在此过程中，文档控制器(document controller)可以响应用户的输入取消终止。
                                    如果文档控制器没有取消操作，则此方法,将调用委托的 applicationShouldTerminate: 方法。
                                如果 applicationShouldTerminate: 返回 NSTerminateCancel，终止进程被中止，控制权被交还给主事件循环。
                                   如果该方法返回 NSTerminateLater，则应用程序在 NSModalPanelRunLoopMode 模式下运行其运行循环，（Modal Panel??） 直到以 YES 或 NO 值调用 replyToApplicationShouldTerminate: 方法。
                                   如果该方法返回 NSTerminateNow，则此方法将 NSApplicationWillTerminateNotification 通知发布到默认通知中心。

                                不要费心将最终的清理代码放在应用程序的 main() 函数中——它永远不会被执行。
                               
                                如果需要清理，请在(NSApplicationDelegate)委托的 applicationWillTerminate: 方法中执行清理。
                             
                             
                             */
						}
					}
				});

			bx::MutexScope scope(s_ctx.m_lock);
			s_ctx.m_windowAlloc.free(_handle.idx);
		}
	}

	void destroyWindow(WindowHandle _handle)
	{
		destroyWindow(_handle, true);
	}

	void setWindowPos(WindowHandle _handle, int32_t _x, int32_t _y)
	{
		dispatch_async(dispatch_get_main_queue()
			, ^{
				NSWindow* window = s_ctx.m_window[_handle.idx];
				NSScreen* screen = [window screen];

				NSRect screenRect = [screen frame];
				CGFloat menuBarHeight = [[[NSApplication sharedApplication] mainMenu] menuBarHeight];

				NSPoint position = { float(_x), screenRect.size.height - menuBarHeight - float(_y) };

				[window setFrameTopLeftPoint: position];
			});
	}

	void setWindowSize(WindowHandle _handle, uint32_t _width, uint32_t _height)
	{
		NSSize size = { float(_width), float(_height) };
		dispatch_async(dispatch_get_main_queue()
			, ^{
				[s_ctx.m_window[_handle.idx] setContentSize: size];
			});
	}

	void setWindowTitle(WindowHandle _handle, const char* _title)
	{
		NSString* title = [[NSString alloc] initWithCString:_title encoding:1];
		dispatch_async(dispatch_get_main_queue()
			, ^{
				[s_ctx.m_window[_handle.idx] setTitle: title]; // NSWindow m_window 在主线程上设置给定句柄对应窗口的名字
				[title release];
			});
	}

	void setWindowFlags(WindowHandle _handle, uint32_t _flags, bool _enabled)
	{
		BX_UNUSED(_handle, _flags, _enabled);
	}

	void toggleFullscreen(WindowHandle _handle)
	{
		dispatch_async(dispatch_get_main_queue()
			, ^{
				NSWindow* window = s_ctx.m_window[_handle.idx];
				[window toggleFullScreen:nil];
			});
	}

	void setMouseLock(WindowHandle _handle, bool _lock)
	{
		dispatch_async(dispatch_get_main_queue()
			, ^{
				NSWindow* window = s_ctx.m_window[_handle.idx];
				s_ctx.setMouseLock(window, _lock);
			});
	}

} // namespace entry

@implementation AppDelegate

+ (AppDelegate *)sharedDelegate
{
	static id delegate = [AppDelegate new];
	return delegate;
}

- (id)init
{
	self = [super init];

	if (nil == self)
	{
		return nil;
	}

	self->terminated = false;
	return self;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	BX_UNUSED(sender);
	self->terminated = true;
	return NSTerminateCancel;
    
    // 在调用 [NSApp terminate:nil]; 之后 会调用NSApplication代理询问是否关闭退出app --- AppDelegate : NSObject<NSApplicationDelegate>
    //  返回 NSTerminateCancel，终止进程被中止，控制权被交还给主事件循环
 
}

// 应用真的要退出的 处理流程
- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"applicationWillTerminate is called %@", notification);
    
    // 不要费心将最终的清理代码放在应用程序的 main() 函数中——它永远不会被执行。
    // 如果需要清理，请在委托的 applicationWillTerminate: 方法中执行清理。
    
    // 由默认通知中心在"应用程序终止"前立即发送。
    // 一个名为 NSApplicationWillTerminateNotification 的通知。
    // ??? 调用此通知(this notification )的对象方法(object method)返回 NSApplication 对象本身。
    
}


- (bool)applicationHasTerminated // 判断应用是否已经退出 主循环需要
{
	return self->terminated;
}

@end

@implementation Window

+ (Window*)sharedDelegate
{
	static id windowDelegate = [Window new];
	return windowDelegate;
}

- (id)init
{
	self = [super init];
	if (nil == self)
	{
		return nil;
	}

	return self;
}

- (void)windowCreated:(NSWindow*)window
{
	assert(window);

	[window setDelegate:self];
}

// 关闭窗口时候回调 -- 窗口代理的回调
// 主线程 [NSApp nextEvent*] 然后 [NSApp sendEvent:event];
- (void)windowWillClose:(NSNotification*)notification
{
	BX_UNUSED(notification);
	NSWindow *window = [notification object];

	[window setDelegate:nil];

	destroyWindow(entry::s_ctx.findHandle(window), false); // 为啥flase 不用调用 NSWindow close ？？
}

- (BOOL)windowShouldClose:(NSWindow*)window
{
	assert(window);
	BX_UNUSED(window);
	return true;
}

- (void)windowDidResize:(NSNotification*)notification
{
	NSWindow *window = [notification object];
	using namespace entry;
	s_ctx.windowDidResize(window);
}

- (void)windowDidBecomeKey:(NSNotification*)notification
{
	NSWindow *window = [notification object];
	using namespace entry;
	s_ctx.windowDidBecomeKey(window);
}

- (void)windowDidResignKey:(NSNotification*)notification
{
	NSWindow *window = [notification object];
	using namespace entry;
	s_ctx.windowDidResignKey(window);
}

@end

int main(int _argc, const char* const* _argv)
{
	using namespace entry; // entry::Context
	return s_ctx.run(_argc, _argv);
}

/*
 
 
 #import <Cocoa/Cocoa.h>

 int main(int argc, const char* argv[]) {
     return NSApplcationMain(argc, (const char**)argv);
 }

 
 clang -framework Cocoa -o simple simple.m
 
 直接执行 ./simple，会发现系统报错  因为缺少一些配置信息---- 除非是纯粹命令行程序
 
 而是要拆开一个现有的app 然后把 执行程序放到包里头 : 1.右键app，然后选“查看包内容” 2.建立simple.app/Contents/MacOS 目录 3.把编译出来的可执行文件 simple 复制进去
 执行 open simple.app
 
 */
 

#endif // BX_PLATFORM_OSX
