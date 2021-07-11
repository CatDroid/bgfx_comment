/*
 * Copyright 2011-2021 Branimir Karadzic. All rights reserved.
 * License: https://github.com/bkaradzic/bgfx#license-bsd-2-clause
 */

#include "common.h"
#include "bgfx_utils.h"
#include "imgui/imgui.h"

namespace
{

struct PosColorTexCoord0Vertex
{
	float m_x;
	float m_y;
	float m_z;
	uint32_t m_abgr;
	float m_u;
	float m_v;

	static void init()
	{
		ms_layout
			.begin()
			.add(bgfx::Attrib::Position,  3, bgfx::AttribType::Float)
			.add(bgfx::Attrib::Color0,    4, bgfx::AttribType::Uint8, true)
			.add(bgfx::Attrib::TexCoord0, 2, bgfx::AttribType::Float)
			.end();
	}

	static bgfx::VertexLayout ms_layout;
};

bgfx::VertexLayout PosColorTexCoord0Vertex::ms_layout;

void renderScreenSpaceQuad(uint8_t _view, bgfx::ProgramHandle _program, float _x, float _y, float _width, float _height)
{
	bgfx::TransientVertexBuffer tvb;
	bgfx::TransientIndexBuffer tib;

	if (bgfx::allocTransientBuffers(&tvb, PosColorTexCoord0Vertex::ms_layout, 4, &tib, 6) )
	{
		PosColorTexCoord0Vertex* vertex = (PosColorTexCoord0Vertex*)tvb.data;

		float zz = 0.0f;

		const float minx = _x;
		const float maxx = _x + _width;
		const float miny = _y;
		const float maxy = _y + _height;

		float minu = -1.0f;
		float minv = -1.0f;
		float maxu =  1.0f;
		float maxv =  1.0f;

		vertex[0].m_x = minx;
		vertex[0].m_y = miny;
		vertex[0].m_z = zz;
		vertex[0].m_abgr = 0xff0000ff;
		vertex[0].m_u = minu;
		vertex[0].m_v = minv;

		vertex[1].m_x = maxx;
		vertex[1].m_y = miny;
		vertex[1].m_z = zz;
		vertex[1].m_abgr = 0xff00ff00;
		vertex[1].m_u = maxu;
		vertex[1].m_v = minv;

		vertex[2].m_x = maxx;
		vertex[2].m_y = maxy;
		vertex[2].m_z = zz;
		vertex[2].m_abgr = 0xffff0000;
		vertex[2].m_u = maxu;
		vertex[2].m_v = maxv;

		vertex[3].m_x = minx;
		vertex[3].m_y = maxy;
		vertex[3].m_z = zz;
		vertex[3].m_abgr = 0xffffffff;
		vertex[3].m_u = minu;
		vertex[3].m_v = maxv;

		uint16_t* indices = (uint16_t*)tib.data;

		indices[0] = 0;
		indices[1] = 2;
		indices[2] = 1;
		indices[3] = 0;
		indices[4] = 3;
		indices[5] = 2;

		bgfx::setState(BGFX_STATE_DEFAULT);
		bgfx::setIndexBuffer(&tib);
		bgfx::setVertexBuffer(0, &tvb);
		bgfx::submit(_view, _program);
	}
}

class ExampleRaymarch : public entry::AppI
{
public:
	ExampleRaymarch(const char* _name, const char* _description, const char* _url)
		: entry::AppI(_name, _description, _url)
	{
	}

	void init(int32_t _argc, const char* const* _argv, uint32_t _width, uint32_t _height) override
	{
		Args args(_argc, _argv);

		m_width  = _width;
		m_height = _height;
		m_debug  = BGFX_DEBUG_NONE;
		m_reset  = BGFX_RESET_VSYNC;

		bgfx::Init init;
		init.type     = args.m_type;
		init.vendorId = args.m_pciId;
		init.resolution.width  = m_width;
		init.resolution.height = m_height;
		init.resolution.reset  = m_reset;
		bgfx::init(init);

		// Enable debug text.
		bgfx::setDebug(m_debug);

		// Set view 0 clear state.
		bgfx::setViewClear(0
				, BGFX_CLEAR_COLOR|BGFX_CLEAR_DEPTH
				, 0x303030ff
				, 1.0f
				, 0
				);

		// Create vertex stream declaration.
		PosColorTexCoord0Vertex::init();

		u_mtx          = bgfx::createUniform("u_mtx",      bgfx::UniformType::Mat4);
		u_lightDirTime = bgfx::createUniform("u_lightDirTime", bgfx::UniformType::Vec4); // 这里默认regNum为1
        // 这里不注册，CreateShader也会获取memory开头信息CreteUniform，只是会增加引用数目和regNum调整
        // CreateShader中注册的unfrom 会保存到 Context:: ShaderRef  m_shaderRef[BGFX_CONFIG_MAX_SHADERS]; 每个shader的信息中?

		// Create program from shaders.
		m_program = loadProgram("vs_raymarching", "fs_raymarching");

		m_timeOffset = bx::getHPCounter();

		imguiCreate();
        
        /*
         
         $input a_position, a_color0, a_texcoord0
         $output v_color0, v_texcoord0
         
         #include "../common/common.sh"
         
         void main()
         {
             gl_Position = mul(u_modelViewProj, vec4(a_position, 1.0) );
             v_color0 = a_color0;
             v_texcoord0 = a_texcoord0;
         }
         
         
         bgfx 会转换成 metal的格式如下  所有attribute合并到一个结构体 所有的unifom也合并到一个结构体中 并且uniform形参一定是[[buffer(0)]]
         // 注意 给到bgfx CreateShader的struct Memory, 除了shader 开头还有声明uniform的部分，这个uniform声明部分会在CreateShader内部自动CreateUnifrom
         
         include <metal_stdlib>
         #include <simd/simd.h>

         using namespace metal;

         struct _Global
         {
             float4x4 u_modelViewProj;
         };

         struct xlatMtlMain_out
         {
             float4 _entryPointOutput_v_color0 [[user(locn0)]];
             float2 _entryPointOutput_v_texcoord0 [[user(locn1)]];
             float4 gl_Position [[position]];  // 包含了 gl_Position在内的所有顶点着色器输出 @output
         };

         struct xlatMtlMain_in
         {
             float4 a_color0 [[attribute(0)]];
             float3 a_position [[attribute(1)]];
             float2 a_texcoord0 [[attribute(2)]];
         };

         vertex xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], constant _Global& _mtl_u [[buffer(0)]])
         {
             xlatMtlMain_out out = {};
             out.gl_Position = _mtl_u.u_modelViewProj * float4(in.a_position, 1.0);
             out._entryPointOutput_v_color0 = in.a_color0;
             out._entryPointOutput_v_texcoord0 = in.a_texcoord0;
             return out;
         }
         
         
         
         
         
         ----------------------------------------------------------------------------------------
         fs_debugfont
         
         
         #include <metal_stdlib>
         #include <simd/simd.h>

         using namespace metal;

         struct xlatMtlMain_out
         {
             float4 bgfx_FragData0 [[color(0)]];
         };

         struct xlatMtlMain_in
         {
             float4 v_color0 [[user(locn0)]];
             float4 v_color1 [[user(locn1)]];
             float2 v_texcoord0 [[user(locn2)]];
         };

         fragment xlatMtlMain_out xlatMtlMain(
                    xlatMtlMain_in      in                  [[stage_in]],
                    texture2d<float>    s_texColor          [[texture(0)]],
                    sampler             s_texColorSampler   [[sampler(0)]])
         {
             xlatMtlMain_out out = {};
             float4 _190 = s_texColor.sample(s_texColorSampler, in.v_texcoord0);
             float4 _196 = mix(in.v_color1, in.v_color0, _190.xxxx);
             if (_196.w < 0.0039215688593685627)
             {
                 discard_fragment(); // ??? 可以这样 ??
             }
             out.bgfx_FragData0 = _196;
             return out;
         }

         
         
         */
	}

	int shutdown() override
	{
		imguiDestroy();

		// Cleanup.
		bgfx::destroy(m_program);

		bgfx::destroy(u_mtx);
		bgfx::destroy(u_lightDirTime);

		// Shutdown bgfx.
		bgfx::shutdown();

		return 0;
	}

	bool update() override
	{
		if (!entry::processEvents(m_width, m_height, m_debug, m_reset, &m_mouseState) )
		{
			imguiBeginFrame(m_mouseState.m_mx
				,  m_mouseState.m_my
				, (m_mouseState.m_buttons[entry::MouseButton::Left  ] ? IMGUI_MBUT_LEFT   : 0)
				| (m_mouseState.m_buttons[entry::MouseButton::Right ] ? IMGUI_MBUT_RIGHT  : 0)
				| (m_mouseState.m_buttons[entry::MouseButton::Middle] ? IMGUI_MBUT_MIDDLE : 0)
				,  m_mouseState.m_mz
				, uint16_t(m_width)
				, uint16_t(m_height)
				);

			showExampleDialog(this);

			imguiEndFrame();
			// Set view 0 default viewport.
			bgfx::setViewRect(0, 0, 0, uint16_t(m_width), uint16_t(m_height) );

			// Set view 1 default viewport.
			bgfx::setViewRect(1, 0, 0, uint16_t(m_width), uint16_t(m_height) );

			// This dummy draw call is here to make sure that view 0 is cleared
			// if no other draw calls are submitted to viewZ 0.
			bgfx::touch(0);

			const bx::Vec3 at  = { 0.0f, 0.0f,   0.0f };
			const bx::Vec3 eye = { 0.0f, 0.0f, -15.0f };

			float view[16];
			float proj[16];
			bx::mtxLookAt(view, eye, at);

			const bgfx::Caps* caps = bgfx::getCaps();
			bx::mtxProj(proj, 60.0f, float(m_width)/float(m_height), 0.1f, 100.0f, caps->homogeneousDepth);

			// Set view and projection matrix for view 1.
			bgfx::setViewTransform(0, view, proj);

			float ortho[16];
			bx::mtxOrtho(ortho, 0.0f, 1280.0f, 720.0f, 0.0f, 0.0f, 100.0f, 0.0, caps->homogeneousDepth);

			// Set view and projection matrix for view 0.
			bgfx::setViewTransform(1, NULL, ortho);

			float time = (float)( (bx::getHPCounter()-m_timeOffset)/double(bx::getHPFrequency() ) );

			float vp[16];
			bx::mtxMul(vp, view, proj);

			float mtx[16];
			bx::mtxRotateXY(mtx
				, time
				, time*0.37f
				);

			float mtxInv[16];
			bx::mtxInverse(mtxInv, mtx);
			float lightDirTime[4];
			const bx::Vec3 lightDirModelN = bx::normalize(bx::Vec3{-0.4f, -0.5f, -1.0f});
			bx::store(lightDirTime, bx::mul(lightDirModelN, mtxInv) );
			lightDirTime[3] = time;
			bgfx::setUniform(u_lightDirTime, lightDirTime); // encoder0 设置vec4 uniform  两个自定义uniform

			float mvp[16];
			bx::mtxMul(mvp, mtx, vp);

			float invMvp[16];
			bx::mtxInverse(invMvp, mvp);
			bgfx::setUniform(u_mtx, invMvp); // encoder0 设置mat4 uniform 

			renderScreenSpaceQuad(1, m_program, 0.0f, 0.0f, 1280.0f, 720.0f);

			// Advance to next frame. Rendering thread will be kicked to
			// process submitted rendering primitives.
			bgfx::frame();

			return true;
		}

		return false;
	}

	entry::MouseState m_mouseState;

	uint32_t m_width;
	uint32_t m_height;
	uint32_t m_debug;
	uint32_t m_reset;

	int64_t m_timeOffset;
	bgfx::UniformHandle u_mtx;
	bgfx::UniformHandle u_lightDirTime;
	bgfx::ProgramHandle m_program;
};

} // namespace

ENTRY_IMPLEMENT_MAIN(
	  ExampleRaymarch
	, "03-raymarch"
	, "Updating shader uniforms."
	, "https://bkaradzic.github.io/bgfx/examples.html#raymarch"
	);


/*
 #include "../common/common.sh"
 #include "iq_sdf.sh"

 uniform mat4 u_mtx;
 uniform vec4 u_lightDirTime;

 #define u_lightDir u_lightDirTime.xyz
 #define u_time     u_lightDirTime.w
 
 ......
 
 void main()
 {
     vec4 tmp;
     tmp = mul(u_mtx, vec4(v_texcoord0.xy, 0.0, 1.0) );
     vec3 eye = tmp.xyz/tmp.w;

     tmp = mul(u_mtx, vec4(v_texcoord0.xy, 1.0, 1.0) );
     vec3 at = tmp.xyz/tmp.w;

     float maxd = length(at - eye);
     vec3 dir = normalize(at - eye);

     float dist = trace(eye, dir, maxd);

     if (dist > 0.5)
     {
         vec3 pos = eye + dir*dist;
         vec3 normal = calcNormal(pos);

         vec2 bln = blinn(u_lightDir, normal, dir);
         vec4 lc = lit(bln.x, bln.y, 1.0);
         float fres = fresnel(bln.x, 0.2, 5.0);

         float val = 0.9*lc.y + pow(lc.z, 128.0)*fres;
         val *= calcAmbOcc(pos, normal);
         val = pow(val, 1.0/2.2);

         gl_FragColor = vec4(val, val, val, 1.0);
         gl_FragDepth = dist/maxd;
     }
     else
     {
         gl_FragColor = v_color0;
         gl_FragDepth = 1.0;
     }
 }
 
 
 ---------------------------------------------------------
 
 
 #include <metal_stdlib>
 #include <simd/simd.h>

 using namespace metal;

 struct _Global
 {
     float4x4 u_mtx;            //  u_mtx的偏移 m_loc = uniform.offset = 0
     float4 u_lightDirTime;     //  这两个合并在一起  所有在processArguemnt@renderer_mtl.mm中    u_lightDirTime的偏移  m_loc = uniform.offset = 64
 };

 struct xlatMtlMain_out
 {
     float4 bgfx_FragData0 [[color(0)]];
     float gl_FragDepth [[depth(any)]];
 };

 struct xlatMtlMain_in
 {
     float4 v_color0 [[user(locn0)]];
     float2 v_texcoord0 [[user(locn1)]];
 };

 // 函数调用都没有了 ???? 全部合并到一起 ？？？？
 fragment xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], constant _Global& _mtl_u [[buffer(0)]])
 {
     xlatMtlMain_out out = {};
     float4 _555 = _mtl_u.u_mtx * float4(in.v_texcoord0, 0.0, 1.0);
     float3 _561 = _555.xyz / float3(_555.w);
     float4 _568 = _mtl_u.u_mtx * float4(in.v_texcoord0, 1.0, 1.0);
     float3 _574 = _568.xyz / float3(_568.w);
     float _578 = length(_574 - _561);
     float3 _582 = normalize(_574 - _561);
     float _1696;
     _1696 = 0.0;
     float _1703;
     for (int _1695 = 0; _1695 < 64; _1696 = _1703, _1695++)
     {
         float3 _660 = _561 + (_582 * _1696);
         float _736 = fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_660) - float3(2.5), float3(0.0))) - 0.5, length(_660 + float3(4.0, 0.0, 0.0)) - 1.0), length(_660 + float3(-4.0, 0.0, 0.0)) - 1.0), length(_660 + float3(0.0, 4.0, 0.0)) - 1.0), length(_660 + float3(0.0, -4.0, 0.0)) - 1.0), length(_660 + float3(0.0, 0.0, 4.0)) - 1.0), length(_660 + float3(0.0, 0.0, -4.0)) - 1.0);
         if (_736 > 0.001000000047497451305389404296875)
         {
             _1703 = _1696 + _736;
         }
         else
         {
             _1703 = _1696;
         }
     }
     float _678 = (_1696 < _578) ? _1696 : 0.0;
     float4 _1700;
     float _1701;
     if (_678 > 0.5)
     {
         float3 _594 = _561 + (_582 * _678);
         float3 _820 = normalize(float3(fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 + float3(0.00200000009499490261077880859375, 0.0, 0.0)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(4.00199985504150390625, 0.0, 0.0)) - 1.0), length(_594 + float3(-3.9979999065399169921875, 0.0, 0.0)) - 1.0), length(_594 + float3(0.00200000009499490261077880859375, 4.0, 0.0)) - 1.0), length(_594 + float3(0.00200000009499490261077880859375, -4.0, 0.0)) - 1.0), length(_594 + float3(0.00200000009499490261077880859375, 0.0, 4.0)) - 1.0), length(_594 + float3(0.00200000009499490261077880859375, 0.0, -4.0)) - 1.0) - fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 - float3(0.00200000009499490261077880859375, 0.0, 0.0)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(3.9979999065399169921875, 0.0, 0.0)) - 1.0), length(_594 + float3(-4.00199985504150390625, 0.0, 0.0)) - 1.0), length(_594 + float3(-0.00200000009499490261077880859375, 4.0, 0.0)) - 1.0), length(_594 + float3(-0.00200000009499490261077880859375, -4.0, 0.0)) - 1.0), length(_594 + float3(-0.00200000009499490261077880859375, 0.0, 4.0)) - 1.0), length(_594 + float3(-0.00200000009499490261077880859375, 0.0, -4.0)) - 1.0), fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 + float3(0.0, 0.00200000009499490261077880859375, 0.0)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(4.0, 0.00200000009499490261077880859375, 0.0)) - 1.0), length(_594 + float3(-4.0, 0.00200000009499490261077880859375, 0.0)) - 1.0), length(_594 + float3(0.0, 4.00199985504150390625, 0.0)) - 1.0), length(_594 + float3(0.0, -3.9979999065399169921875, 0.0)) - 1.0), length(_594 + float3(0.0, 0.00200000009499490261077880859375, 4.0)) - 1.0), length(_594 + float3(0.0, 0.00200000009499490261077880859375, -4.0)) - 1.0) - fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 - float3(0.0, 0.00200000009499490261077880859375, 0.0)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(4.0, -0.00200000009499490261077880859375, 0.0)) - 1.0), length(_594 + float3(-4.0, -0.00200000009499490261077880859375, 0.0)) - 1.0), length(_594 + float3(0.0, 3.9979999065399169921875, 0.0)) - 1.0), length(_594 + float3(0.0, -4.00199985504150390625, 0.0)) - 1.0), length(_594 + float3(0.0, -0.00200000009499490261077880859375, 4.0)) - 1.0), length(_594 + float3(0.0, -0.00200000009499490261077880859375, -4.0)) - 1.0), fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 + float3(0.0, 0.0, 0.00200000009499490261077880859375)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(4.0, 0.0, 0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(-4.0, 0.0, 0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, 4.0, 0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, -4.0, 0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, 0.0, 4.00199985504150390625)) - 1.0), length(_594 + float3(0.0, 0.0, -3.9979999065399169921875)) - 1.0) - fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_594 - float3(0.0, 0.0, 0.00200000009499490261077880859375)) - float3(2.5), float3(0.0))) - 0.5, length(_594 + float3(4.0, 0.0, -0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(-4.0, 0.0, -0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, 4.0, -0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, -4.0, -0.00200000009499490261077880859375)) - 1.0), length(_594 + float3(0.0, 0.0, 3.9979999065399169921875)) - 1.0), length(_594 + float3(0.0, 0.0, -4.00199985504150390625)) - 1.0)));
         float _1458 = dot(_820, _mtl_u.u_lightDirTime.xyz);
         float _1698;
         _1698 = 0.0;
         for (int _1697 = 1; _1697 < 4; )
         {
             float _1515 = float(_1697);
             float3 _1522 = _594 + ((_820 * _1515) * 0.20000000298023223876953125);
             _1698 += (((_1515 * 0.20000000298023223876953125) - fast::min(fast::min(fast::min(fast::min(fast::min(fast::min(length(fast::max(abs(_1522) - float3(2.5), float3(0.0))) - 0.5, length(_1522 + float3(4.0, 0.0, 0.0)) - 1.0), length(_1522 + float3(-4.0, 0.0, 0.0)) - 1.0), length(_1522 + float3(0.0, 4.0, 0.0)) - 1.0), length(_1522 + float3(0.0, -4.0, 0.0)) - 1.0), length(_1522 + float3(0.0, 0.0, 4.0)) - 1.0), length(_1522 + float3(0.0, 0.0, -4.0)) - 1.0)) / pow(2.0, _1515));
             _1697++;
             continue;
         }
         float _626 = pow(((0.89999997615814208984375 * fast::max(0.0, _1458)) + (pow(step(0.0, _1458) * fast::max(0.0, dot(_mtl_u.u_lightDirTime.xyz - (_820 * (2.0 * _1458)), _582)), 128.0) * fast::max(0.20000000298023223876953125 + (0.800000011920928955078125 * pow(1.0 - _1458, 5.0)), 0.0))) * (1.0 - _1698), 0.4545454680919647216796875);
         _1701 = _678 / _578;
         _1700 = float4(_626, _626, _626, 1.0);
     }
     else
     {
         _1701 = 1.0;
         _1700 = in.v_color0;
     }
     out.bgfx_FragData0 = _1700;
     out.gl_FragDepth = _1701;
     return out;
 }
 
 */
