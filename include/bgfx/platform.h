/*
 * Copyright 2011-2021 Branimir Karadzic. All rights reserved.
 * License: https://github.com/bkaradzic/bgfx/blob/master/LICENSE
 */

#ifndef BGFX_PLATFORM_H_HEADER_GUARD
#define BGFX_PLATFORM_H_HEADER_GUARD

// NOTICE:
// This header file contains platform specific interfaces. It is only
// necessary to use this header in conjunction with creating windows.

#include <bx/platform.h>
#include "bgfx.h"

namespace bgfx
{
	/// Render frame enum.
	///
	/// @attention C99 equivalent is `bgfx_render_frame_t`.
	///
	struct RenderFrame
	{
		enum Enum
		{
			NoContext,
			Render,
			Timeout,
			Exiting,

			Count
		};
	};

	/// Render frame.
	///
	/// @param _msecs Timeout in milliseconds.                          以毫秒为单位的超时时间。
	///
	/// @returns Current renderer state. See: `bgfx::RenderFrame`.
	///
	/// @attention `bgfx::renderFrame` is blocking call. It waits for
	///   `bgfx::frame` to be called from API thread to process frame.  `bgfx::renderFrame` 正在阻塞调用。 它等待从 API 线程调用 `bgfx::frame` 来处理帧。
	///   If timeout value is passed call will timeout and return even    如果超时值被传递，即使没有调用`bgfx::frame`，调用也会超时并返回。
	///   if `bgfx::frame` is not called.
	///
	/// @warning This call should be only used on platforms that don't
	///   allow creating separate rendering thread. If it is called before
	///   to bgfx::init, render thread won't be created by bgfx::init call.  此调用应仅用于不允许创建单独渲染线程的平台。 如果它在 bgfx::init 之前被调用，渲染线程将不会被 bgfx::init 调用创建。
	///
	/// @attention C99 equivalent is `bgfx_render_frame`.
	///
	RenderFrame::Enum renderFrame(int32_t _msecs = -1);

	/// Set platform data.  设置平台数据。
	///
	/// @warning Must be called before `bgfx::init`.                必须在 `bgfx::init` 之前调用。
	///
	/// @attention C99 equivalent is `bgfx_set_platform_data`.
	///
	void setPlatformData(const PlatformData& _data);

	/// Internal data.   内部数据。
	///
	/// @attention C99 equivalent is `bgfx_internal_data_t`.
	///
	struct InternalData
	{
		const struct Caps* caps; //!< Renderer capabilities.
		void* context;           //!< GL context, or D3D device.
	};

	/// Get internal data for interop.      获取用于互操作的内部数据。
	///
	/// @attention It's expected you understand some bgfx internals before you  在使用此调用之前，您应该了解一些 bgfx 内部原理。
	///   use this call.
	///
	/// @warning Must be called only on render thread.
	///
	/// @attention C99 equivalent is `bgfx_get_internal_data`.
	///
	const InternalData* getInternalData();

	/// Override internal texture with externally created texture. Previously   用外部创建的纹理覆盖内部纹理。 先前创建的内部纹理将被释放。
	/// created internal texture will released.
	///
	/// @attention It's expected you understand some bgfx internals before you
	///   use this call.
	///
	/// @param[in] _handle Texture handle.
	/// @param[in] _ptr Native API pointer to texture.
	///
	/// @returns Native API pointer to texture. If result is 0, texture is not created yet from the   指向纹理的native API 指针。 如果结果为 0，则尚未从主线程创建纹理。
	///   main thread.
	///
	/// @warning Must be called only on render thread.  只能在渲染线程上调用。
	///
	/// @attention C99 equivalent is `bgfx_override_internal_texture_ptr`.
	///
	uintptr_t overrideInternal(TextureHandle _handle, uintptr_t _ptr);

	/// Override internal texture by creating new texture. Previously created
	/// internal texture will released.
	///
	/// @attention It's expected you understand some bgfx internals before you
	///   use this call.
	///
	/// @param[in] _handle Texture handle.
	/// @param[in] _width Width.
	/// @param[in] _height Height.
	/// @param[in] _numMips Number of mip-maps.
	/// @param[in] _format Texture format. See: `TextureFormat::Enum`.
	/// @param[in] _flags Default texture sampling mode is linear, and wrap mode
	///   is repeat.
	///   - `BGFX_SAMPLER_[U/V/W]_[MIRROR/CLAMP]` - Mirror or clamp to edge wrap
	///     mode.
	///   - `BGFX_SAMPLER_[MIN/MAG/MIP]_[POINT/ANISOTROPIC]` - Point or anisotropic
	///     sampling.
	///
	/// @returns Native API pointer to texture. If result is 0, texture is not created yet from the
	///   main thread.
	///
	/// @warning Must be called only on render thread.
	///
	/// @attention C99 equivalent is `bgfx_override_internal_texture`.
	///
	uintptr_t overrideInternal(
		  TextureHandle _handle
		, uint16_t _width
		, uint16_t _height
		, uint8_t _numMips
		, TextureFormat::Enum _format
		, uint64_t _flags = BGFX_TEXTURE_NONE|BGFX_SAMPLER_NONE
		);

} // namespace bgfx

#endif // BGFX_PLATFORM_H_HEADER_GUARD
