#ifndef WI_LIGHTING_HF
#define WI_LIGHTING_HF
#include "globals.hlsli"
#include "shadowHF.hlsli"
#include "brdf.hlsli"
#include "voxelConeTracingHF.hlsli"
#include "skyHF.hlsli"

#ifdef CARTOON
#define DISABLE_SOFT_SHADOWMAP
#endif // CARTOON

#ifdef WATER
#define LIGHTING_SCATTER
#endif // WATER

struct LightingPart
{
	half3 diffuse;
	half3 specular;
};
struct Lighting
{
	LightingPart direct;
	LightingPart indirect;

	inline void create(
		in half3 diffuse_direct,
		in half3 specular_direct,
		in half3 diffuse_indirect,
		in half3 specular_indirect
	)
	{
		direct.diffuse = diffuse_direct;
		direct.specular = specular_direct;
		indirect.diffuse = diffuse_indirect;
		indirect.specular = specular_indirect;
	}
};

inline void ApplyLighting(in Surface surface, in Lighting lighting, inout half4 color)
{
	half3 diffuse = lighting.direct.diffuse / PI + lighting.indirect.diffuse * GetGIBoost() * (1 - surface.F) * surface.occlusion + surface.ssgi;
	half3 specular = lighting.direct.specular + lighting.indirect.specular * surface.occlusion; // reminder: cannot apply surface.F for whole indirect specular, because multiple layers have separate fresnels (sheen, clearcoat)
	color.rgb = lerp(surface.albedo * diffuse, surface.refraction.rgb, surface.refraction.a);
	color.rgb += specular;
	color.rgb += surface.emissiveColor;
}

//#define CASCADE_DITHERING
inline void light_directional(in ShaderEntity light, in Surface surface, inout Lighting lighting, in half shadow_mask = 1)
{
	if (shadow_mask <= 0.001)
		return; // shadow mask zero
	if ((light.layerMask & surface.layerMask) == 0)
		return; // layer mismatch
		
	half3 L = light.GetDirection();
	SurfaceToLight surface_to_light;
	surface_to_light.create(surface, L);

	if (!any(surface_to_light.NdotL_sss))
		return; // facing away from light
		
	half3 light_color = light.GetColor().rgb * shadow_mask;

	[branch]
	if (light.IsCastingShadow() && surface.IsReceiveShadow())
	{
		if (GetFrame().options & OPTION_BIT_VOLUMETRICCLOUDS_CAST_SHADOW)
		{
			light_color *= shadow_2D_volumetricclouds(surface.P);
		}

#if defined(SHADOW_MASK_ENABLED) && !defined(TRANSPARENT)
		[branch]
		if ((GetFrame().options & OPTION_BIT_RAYTRACED_SHADOWS) == 0 || GetCamera().texture_rtshadow_index < 0 || (GetCamera().options & SHADERCAMERA_OPTION_USE_SHADOW_MASK) == 0)
#endif // SHADOW_MASK_ENABLED
		{
			// Loop through cascades from closest (smallest) to furthest (largest)
			[loop]
			for (min16uint cascade = 0; cascade < light.GetShadowCascadeCount(); ++cascade)
			{
				// Project into shadow map space (no need to divide by .w because ortho projection!):
				const float4x4 cascade_projection = load_entitymatrix(light.GetMatrixIndex() + cascade);
				float3 shadow_pos = mul(cascade_projection, float4(surface.P, 1)).xyz;
				float3 shadow_uv = clipspace_to_uv(shadow_pos);

				// Determine if pixel is inside current cascade bounds and compute shadow if it is:
				[branch]
				if (is_saturated(shadow_uv))
				{
					const half3 shadow_box = half3(shadow_pos.xy, shadow_pos.z * 2 - 1);
					const half3 cascade_edgefactor = saturate(saturate(abs(shadow_box)) - 0.8) * 5.0; // fade will be on edge and inwards 10%
					const half cascade_fade = max3(cascade_edgefactor);
						
#ifdef CASCADE_DITHERING
					// If we are on cascade edge threshold and not the last cascade, then fallback to a larger cascade:
					[branch]
					if (cascade_fade > 0 && dither(surface.pixel + GetTemporalAASampleRotation()) < cascade_fade)
						continue;
						
					light_color *= shadow_2D(light, shadow_pos.z, shadow_uv.xy, cascade);
					break;
#else
					const half3 shadow_main = shadow_2D(light, shadow_pos.z, shadow_uv.xy, cascade, surface.pixel);
					
					// If we are on cascade edge threshold and not the last cascade, then fallback to a larger cascade:
					[branch]
					if (cascade_fade > 0 && cascade < light.GetShadowCascadeCount() - 1)
					{
						// Project into next shadow cascade (no need to divide by .w because ortho projection!):
						cascade += 1;
						shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + cascade), float4(surface.P, 1)).xyz;
						shadow_uv = clipspace_to_uv(shadow_pos);
						const half3 shadow_fallback = shadow_2D(light, shadow_pos.z, shadow_uv.xy, cascade, surface.pixel);

						light_color *= lerp(shadow_main, shadow_fallback, cascade_fade);
					}
					else
					{
						light_color *= shadow_main;
					}
					break;
#endif // CASCADE_DITHERING
				}
			}
		}
		
		if (!any(light_color))
			return; // light color lost after shadow
	}

	[branch]
	if (GetFrame().options & OPTION_BIT_REALISTIC_SKY)
	{
		light_color *= GetAtmosphericLightTransmittance(GetWeather().atmosphere, surface.P, L, texture_transmittancelut);
	}

	lighting.direct.diffuse = mad(light_color, BRDF_GetDiffuse(surface, surface_to_light), lighting.direct.diffuse);
	lighting.direct.specular = mad(light_color, BRDF_GetSpecular(surface, surface_to_light), lighting.direct.specular);

#ifdef LIGHTING_SCATTER
	const half scattering = ComputeScattering(saturate(dot(L, -surface.V)));
	lighting.indirect.specular += scattering * light_color * (1 - surface.extinction) * (1 - sqr(1 - saturate(1 - surface.N.y)));
#endif // LIGHTING_SCATTER
			
#ifndef WATER
	// On non-water surfaces there can be procedural caustic if it's under ocean:
	const ShaderOcean ocean = GetWeather().ocean;
	if (ocean.texture_displacementmap >= 0)
	{
		Texture2D displacementmap = bindless_textures[descriptor_index(ocean.texture_displacementmap)];
		float2 ocean_uv = surface.P.xz * ocean.patch_size_rcp;
		float3 displacement = displacementmap.SampleLevel(sampler_linear_wrap, ocean_uv, 0).xzy;
		float water_height = ocean.water_height + displacement.y;
		if (surface.P.y < water_height)
		{
			half3 caustic = texture_caustics.SampleLevel(sampler_linear_mirror, ocean_uv, 0).rgb;
			caustic *= sqr(saturate((water_height - surface.P.y) * 0.5)); // fade out at shoreline
			caustic *= light_color;
			lighting.indirect.diffuse += caustic;

			// fade out specular at depth, it looks weird when specular appears under ocean from wetmap
			half water_depth = water_height - surface.P.y;
			lighting.direct.specular *= saturate(exp(-water_depth * 10));
		}
	}
#endif // WATER
}

inline half attenuation_pointlight(in half dist2, in half range, in half range2)
{
	// GLTF recommendation: https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_lights_punctual#range-property
	//return saturate(1 - pow(dist / range, 4)) / dist2;

	// Removed pow(x, 4):
	half dist_per_range = dist2 / range2; // pow2 (note: range cannot be 0, in that case light is not uploaded to GPU, so here will not be zero-division)
	dist_per_range *= dist_per_range; // pow4
	return saturate(1 - dist_per_range) / max(0.0001, dist2);
}
inline void light_point(in ShaderEntity light, in Surface surface, inout Lighting lighting, in half shadow_mask = 1)
{
	if (shadow_mask <= 0.001)
		return; // shadow mask zero
	if ((light.layerMask & surface.layerMask) == 0)
		return; // layer mismatch
	
	float3 Lunnormalized = light.position - surface.P;
	const float3 LunnormalizedShadow = Lunnormalized;

#ifndef DISABLE_AREA_LIGHTS
	if (light.GetLength() > 0)
	{
		// Diffuse representative point on line:
		const float3 line_point = closest_point_on_segment(
			light.position - light.GetDirection() * light.GetLength() * 0.5,
			light.position + light.GetDirection() * light.GetLength() * 0.5,
			surface.P
		);
		Lunnormalized = line_point - surface.P;
	}
#endif // DISABLE_AREA_LIGHTS

	const half dist2 = dot(Lunnormalized, Lunnormalized);
	const half range = light.GetRange();
	const half range2 = range * range;

	if (dist2 > range2)
		return; // outside range
		
	const half dist_rcp = rsqrt(dist2);
	half3 L = Lunnormalized * dist_rcp;

	SurfaceToLight surface_to_light;
	surface_to_light.create(surface, L);
		
	if (!any(surface_to_light.NdotL_sss))
		return; // facing away from light
		
	half3 light_color = light.GetColor().rgb * shadow_mask;

	[branch]
	if (light.IsCastingShadow() && surface.IsReceiveShadow())
	{
#if defined(SHADOW_MASK_ENABLED) && !defined(TRANSPARENT)
		[branch]
		if ((GetFrame().options & OPTION_BIT_RAYTRACED_SHADOWS) == 0 || GetCamera().texture_rtshadow_index < 0 || (GetCamera().options & SHADERCAMERA_OPTION_USE_SHADOW_MASK) == 0)
#endif // SHADOW_MASK_ENABLED
		{
			light_color *= shadow_cube(light, LunnormalizedShadow, surface.pixel);
		}
		
		if (!any(light_color))
			return; // light color lost after shadow
	}

	const uint maskTex = light.GetTextureIndex();
	[branch]
	if (maskTex > 0)
	{
		half4 mask = bindless_cubemaps_half4[descriptor_index(maskTex)].SampleLevel(sampler_linear_clamp, -LunnormalizedShadow, 0);
		light_color *= mask.rgb * mask.a;
	}
		
	light_color *= attenuation_pointlight(dist2, range, range2);

	lighting.direct.diffuse = mad(light_color, BRDF_GetDiffuse(surface, surface_to_light), lighting.direct.diffuse);

#ifndef DISABLE_AREA_LIGHTS
	if (light.GetLength() > 0)
	{
		// Specular representative point on line:
		float3 P0 = light.position - light.GetDirection() * light.GetLength() * 0.5;
		float3 P1 = light.position + light.GetDirection() * light.GetLength() * 0.5;
		float3 L0 = P0 - surface.P;
		float3 L1 = P1 - surface.P;
		float3 Ld = L1 - L0;
		float RdotLd = dot(surface.R, Ld);
		float t = dot(surface.R, L0) * RdotLd - dot(L0, Ld);
		t /= dot(Ld, Ld) - RdotLd * RdotLd;
		Lunnormalized = (L0 + saturate(t) * Ld);
	}
	else
	{
		Lunnormalized = light.position - surface.P;
	}
	if(light.GetRadius() > 0)
	{
		// Specular representative point on sphere:
		float3 centerToRay = mad(dot(Lunnormalized, surface.R), surface.R, -Lunnormalized);
		Lunnormalized = mad(centerToRay, saturate(light.GetRadius() / length(centerToRay)), Lunnormalized);
		// Energy conservation for radius:
		light_color /= max(1, sphere_volume(light.GetRadius()));
	}
	if (light.GetLength() > 0 || light.GetRadius() > 0)
	{
		L = normalize(Lunnormalized);
		surface_to_light.create(surface, L); // recompute all surface-light vectors
	}
#endif // DISABLE_AREA_LIGHTS

	lighting.direct.specular = mad(light_color, BRDF_GetSpecular(surface, surface_to_light), lighting.direct.specular);
				
#ifdef LIGHTING_SCATTER
	const half scattering = ComputeScattering(saturate(dot(L, -surface.V)));
	lighting.indirect.specular += scattering * light_color * (1 - surface.extinction) * (1 - sqr(1 - saturate(1 - surface.N.y)));
#endif // LIGHTING_SCATTER
}

inline half attenuation_spotlight(in half dist2, in half range, in half range2, in half spot_factor, in half angle_scale, in half angle_offset)
{
	half attenuation = attenuation_pointlight(dist2, range, range2);
	half angularAttenuation = saturate(mad(spot_factor, angle_scale, angle_offset));
	angularAttenuation *= angularAttenuation;
	attenuation *= angularAttenuation;
	return attenuation;
}
inline void light_spot(in ShaderEntity light, in Surface surface, inout Lighting lighting, in half shadow_mask = 1)
{
	if (shadow_mask <= 0.001)
		return; // shadow mask zero
	if ((light.layerMask & surface.layerMask) == 0)
		return; // layer mismatch
	
	float3 Lunnormalized = light.position - surface.P;
	const half dist2 = dot(Lunnormalized, Lunnormalized);
	const half range = light.GetRange();
	const half range2 = range * range;
	
	if (dist2 > range2)
		return; // outside range
		
	const half dist_rcp = rsqrt(dist2);
	half3 L = Lunnormalized * dist_rcp;

	SurfaceToLight surface_to_light;
	surface_to_light.create(surface, L);
		
	if (!any(surface_to_light.NdotL_sss))
		return; // facing away from light
			
	const half spot_factor = dot(L, light.GetDirection());
	const half spot_cutoff = light.GetConeAngleCos();
			
	if (spot_factor < spot_cutoff)
		return; // outside spotlight cone

	half3 light_color = light.GetColor().rgb * shadow_mask;
	
	[branch]
	if (light.IsCastingShadow() && surface.IsReceiveShadow())
	{
#if defined(SHADOW_MASK_ENABLED) && !defined(TRANSPARENT)
		[branch]
		if ((GetFrame().options & OPTION_BIT_RAYTRACED_SHADOWS) == 0 || GetCamera().texture_rtshadow_index < 0 || (GetCamera().options & SHADERCAMERA_OPTION_USE_SHADOW_MASK) == 0)
#endif // SHADOW_MASK_ENABLED
		{
			float4 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + 0), float4(surface.P, 1));
			shadow_pos.xyz /= shadow_pos.w;
			float2 shadow_uv = clipspace_to_uv(shadow_pos.xy);
			[branch]
			if (is_saturated(shadow_uv))
			{
				light_color *= shadow_2D(light, shadow_pos.z, shadow_uv.xy, 0, surface.pixel);
			}
		}
		
		if (!any(light_color))
			return; // light color lost after shadow
	}

	const uint maskTex = light.GetTextureIndex();
	[branch]
	if (maskTex > 0)
	{
		float4 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + 0), float4(surface.P, 1));
		shadow_pos.xyz /= shadow_pos.w;
		float2 shadow_uv = clipspace_to_uv(shadow_pos.xy);
		half4 mask = bindless_textures_half4[descriptor_index(maskTex)].SampleLevel(sampler_linear_clamp, shadow_uv, 0);
		light_color *= mask.rgb * mask.a;
	}
	
	light_color *= attenuation_spotlight(dist2, range, range2, spot_factor, light.GetAngleScale(), light.GetAngleOffset());
		
	lighting.direct.diffuse = mad(light_color, BRDF_GetDiffuse(surface, surface_to_light), lighting.direct.diffuse);

#ifndef DISABLE_AREA_LIGHTS
	if (light.GetRadius() > 0)
	{
		// Specular representative point on sphere:
		Lunnormalized = light.position - surface.P;
		float3 centerToRay = mad(dot(Lunnormalized, surface.R), surface.R, -Lunnormalized);
		Lunnormalized = mad(centerToRay, saturate(light.GetRadius() / length(centerToRay)), Lunnormalized);
		L = normalize(Lunnormalized);
		surface_to_light.create(surface, L); // recompute all surface-light vectors
		// Energy conservation for radius:
		light_color /= max(1, sphere_volume(light.GetRadius()));
	}
#endif // DISABLE_AREA_LIGHTS

	lighting.direct.specular = mad(light_color, BRDF_GetSpecular(surface, surface_to_light), lighting.direct.specular);
					
#ifdef LIGHTING_SCATTER
	const half scattering = ComputeScattering(saturate(dot(L, -surface.V)));
	lighting.indirect.specular += scattering * light_color * (1 - surface.extinction) * (1 - sqr(1 - saturate(1 - surface.N.y)));
#endif // LIGHTING_SCATTER
}

inline void light_rect(in ShaderEntity light, in Surface surface, inout Lighting lighting, in half shadow_mask = 1)
{
	if (shadow_mask <= 0.001)
		return; // shadow mask zero
	if ((light.layerMask & surface.layerMask) == 0)
		return; // layer mismatch
	
	const half4 quaternion = light.GetQuaternion();
	const half3 right = rotate_vector(half3(1, 0, 0), quaternion);
	const half3 up = rotate_vector(half3(0, 1, 0), quaternion);
	const half3 forward = cross(up, right);
	const half light_length = max(0.01, light.GetLength());
	const half light_height = max(0.01, light.GetHeight());
	const half light_area = light_length * light_height;
	const float3 p0 = light.position - right * light_length * 0.5 + up * light_height * 0.5;
	const float3 p1 = light.position + right * light_length * 0.5 + up * light_height * 0.5;
	const float3 p2 = light.position + right * light_length * 0.5 - up * light_height * 0.5;
	const float3 p3 = light.position - right * light_length * 0.5 - up * light_height * 0.5;
	
	if (dot(surface.P - light.position, forward) <= 0)
		return; // behind light

	// Determine closest point on rectangle to surface position:
	float3 closest_point_on_plane_to_surface = point_on_plane(surface.P, light.position, forward);
	float3 closest_vector_on_plane = closest_point_on_plane_to_surface - light.position;
	float2 plane_point = float2(dot(closest_vector_on_plane, right), dot(closest_vector_on_plane, up));
	float2 nearest_point = float2(clamp(plane_point.x, -light_length * 0.5, light_length * 0.5), clamp(plane_point.y, -light_height * 0.5, light_height * 0.5));
	float3 rectangle_point = light.position + nearest_point.x * right + nearest_point.y * up;
		
	float3 Lunnormalized = rectangle_point - surface.P;

	const half dist2 = dot(Lunnormalized, Lunnormalized);
	const half range = light.GetRange();
	const half range2 = range * range;

	if (dist2 > range2)
		return; // outside range
		
	const half dist_rcp = rsqrt(dist2);
	half3 L = Lunnormalized * dist_rcp;

	SurfaceToLight surface_to_light;
	surface_to_light.create(surface, L);
	
	// Solid angle based on the Frostbite presentation: Moving Frostbite to Physically Based Rendering by Sebastien Lagarde, Charles de Rousiers, Siggraph 2014
	//	https://media.contentapi.ea.com/content/dam/eacom/frostbite/files/course-notes-moving-frostbite-to-pbr-v2.pdf
	float3 v0 = normalize(p0 - surface.P);
	float3 v1 = normalize(p1 - surface.P);
	float3 v2 = normalize(p2 - surface.P);
	float3 v3 = normalize(p3 - surface.P);
	float3 n0 = normalize(cross(v0, v1));
	float3 n1 = normalize(cross(v1, v2));
	float3 n2 = normalize(cross(v2, v3));
	float3 n3 = normalize(cross(v3, v0));
	float g0 = acos(dot(-n0, n1));
	float g1 = acos(dot(-n1, n2));
	float g2 = acos(dot(-n2, n3));
	float g3 = acos(dot(-n3, n0));
	const float solid_angle = saturate(g0 + g1 + g2 + g3 - 2 * PI);
	
	surface_to_light.NdotL = solid_angle * 0.2 * (
		saturate(dot(v0, surface.N)) +
		saturate(dot(v1, surface.N)) +
		saturate(dot(v2, surface.N)) +
		saturate(dot(v3, surface.N)) +
		surface_to_light.NdotL
	);
	surface_to_light.NdotL_sss = surface_to_light.NdotL;
		
	if (!any(surface_to_light.NdotL_sss))
		return; // facing away from light
		
	half3 light_color = light.GetColor().rgb * shadow_mask;
	
	[branch]
	if (light.IsCastingShadow() && surface.IsReceiveShadow())
	{
#if defined(SHADOW_MASK_ENABLED) && !defined(TRANSPARENT)
		[branch]
		if ((GetFrame().options & OPTION_BIT_RAYTRACED_SHADOWS) == 0 || GetCamera().texture_rtshadow_index < 0 || (GetCamera().options & SHADERCAMERA_OPTION_USE_SHADOW_MASK) == 0)
#endif // SHADOW_MASK_ENABLED
		{
			float4 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + 0), float4(surface.P, 1));
			shadow_pos.xyz /= shadow_pos.w;
			float2 shadow_uv = clipspace_to_uv(shadow_pos.xy);
			[branch]
			if (is_saturated(shadow_uv))
			{
				light_color *= shadow_2D(light, shadow_pos.z, shadow_uv.xy, 0, surface.pixel);
			}
		}
		
		if (!any(light_color))
			return; // light color lost after shadow
	}
		
	light_color *= attenuation_pointlight(dist2, range, range2); // dist2 is the closest point on rectangle, so it will not be a falloff from light center, but as if a point light is placed on the closest rectangle point
	
	half3 light_color_diffuse = light_color * light_area * PI; // I increase the light color by the surface area, because I want larger lights to illuminate more.
	
	half3 light_color_specular = light_color;

	// Intersects the plane of the rectangle with reflection ray, then computes closest point on rectangle, source: https://alextardif.com/arealights.html
	float3 intersectPoint = surface.P + surface.R * trace_plane(surface.P, surface.R, light.position, forward);
	float3 intersectionVector = intersectPoint - light.position;
	float2 intersectPlanePoint = float2(dot(intersectionVector,right), dot(intersectionVector,up));
	float2 nearest2DPoint = float2(clamp(intersectPlanePoint.x, -light_length * 0.5, light_length * 0.5), clamp(intersectPlanePoint.y, -light_height * 0.5, light_height * 0.5));
	float3 specular_rect = light.position + nearest2DPoint.x * right + nearest2DPoint.y * up;

	const uint maskTex = light.GetTextureIndex();
	[branch]
	if (maskTex > 0)
	{
		Texture2D<half4> tex = bindless_textures_half4[descriptor_index(maskTex)];
		uint2 dim;
		uint mipcount;
		tex.GetDimensions(0, dim.x, dim.y, mipcount);
		
		float4 shadow_pos = mul(load_entitymatrix(light.GetMatrixIndex() + 0), float4(surface.P, 1));
		shadow_pos.xyz /= shadow_pos.w;
		float2 diffuse_uv = clipspace_to_uv(shadow_pos.xy);
		half4 diffuse_mask = tex.SampleLevel(sampler_linear_clamp, diffuse_uv, mipcount - 2);
		light_color_diffuse *= diffuse_mask.rgb * diffuse_mask.a;

		float2 specular_uv = clipspace_to_uv(nearest2DPoint / float2(light_length * 0.5, light_height * 0.5));
		half4 specular_mask = tex.SampleLevel(sampler_linear_clamp, specular_uv, (1 - sqr(1 - saturate(surface.roughness))) * mipcount);
		light_color_specular *= specular_mask.rgb * specular_mask.a;
	}
	
	lighting.direct.diffuse = mad(light_color_diffuse, BRDF_GetDiffuse(surface, surface_to_light), lighting.direct.diffuse);
	
	Lunnormalized = specular_rect - surface.P;
	L = normalize(Lunnormalized);
	surface_to_light.create(surface, L); // recompute all surface-light vectors
	lighting.direct.specular = mad(light_color_specular, BRDF_GetSpecular(surface, surface_to_light), lighting.direct.specular);
				
#ifdef LIGHTING_SCATTER
	const half scattering = ComputeScattering(saturate(dot(L, -surface.V)));
	lighting.indirect.specular += scattering * light_color * (1 - surface.extinction) * (1 - sqr(1 - saturate(1 - surface.N.y)));
#endif // LIGHTING_SCATTER
}

// ENVIRONMENT MAPS


inline half3 GetAmbient(in float3 N)
{
	half3 ambient;

#ifdef ENVMAPRENDERING

	// Set realistic_sky_stationary to true so we capture ambient at float3(0.0, 0.0, 0.0), similar to the standard sky to avoid flickering and weird behavior
	ambient = lerp(
		GetDynamicSkyColor(float3(0, -1, 0), false, false, true),
		GetDynamicSkyColor(float3(0, 1, 0), false, false, true),
		saturate(N.y * 0.5 + 0.5));

#else

	[branch]
	if (GetScene().globalprobe >= 0)
	{
		TextureCube<half4> cubemap = bindless_cubemaps_half4[descriptor_index(GetScene().globalprobe)];
		uint2 dim;
		uint mipcount;
		cubemap.GetDimensions(0, dim.x, dim.y, mipcount);
		ambient = cubemap.SampleLevel(sampler_linear_clamp, N, mipcount).rgb;
	}
	
#endif // ENVMAPRENDERING

#ifndef NO_FLAT_AMBIENT
	// This is not entirely correct if we have probes, because it shouldn't be added twice.
	//	However, it is not correct if we leave it out from probes, because if we render a scene
	//	with dark sky but ambient, we still want some visible result.
	ambient += GetAmbientColor();
#endif // NO_FLAT_AMBIENT

	return ambient;
}

// surface:				surface descriptor
// MIP:					mip level to sample
// return:				color of the environment color (rgb)
inline half3 EnvironmentReflection_Global(in Surface surface)
{
	half3 envColor;

#ifdef ENVMAPRENDERING

	// There is no access to envmaps, so approximate sky color:
	// Set realistic_sky_stationary to true so we capture environment at float3(0.0, 0.0, 0.0), similar to the standard sky to avoid flickering and weird behavior
	float3 skycolor_real = GetDynamicSkyColor(surface.R, false, false, true); // false: disable sun disk and clouds
	float3 skycolor_rough = lerp(
		GetDynamicSkyColor(float3(0, -1, 0), false, false, true),
		GetDynamicSkyColor(float3(0, 1, 0), false, false, true),
		saturate(surface.R.y * 0.5 + 0.5));

	envColor = lerp(skycolor_real, skycolor_rough, surface.roughness) * surface.F;

#else
	
	[branch]
	if (GetScene().globalprobe < 0)
		return 0;
	
	TextureCube<half4> cubemap = bindless_cubemaps_half4[descriptor_index(GetScene().globalprobe)];
	uint2 dim;
	uint mipcount;
	cubemap.GetDimensions(0, dim.x, dim.y, mipcount);
	half mipcount16f = half(mipcount);

	half MIP = surface.roughness * mipcount16f;
	envColor = cubemap.SampleLevel(sampler_linear_clamp, surface.R, MIP).rgb * surface.F;

#ifdef SHEEN
	envColor *= surface.sheen.albedoScaling;
	MIP = surface.sheen.roughness * mipcount16f;
	envColor += cubemap.SampleLevel(sampler_linear_clamp, surface.R, MIP).rgb * surface.sheen.color * surface.sheen.DFG;
#endif // SHEEN

#ifdef CLEARCOAT
	envColor *= 1 - surface.clearcoat.F;
	MIP = surface.clearcoat.roughness * mipcount16f;
	envColor += cubemap.SampleLevel(sampler_linear_clamp, surface.clearcoat.R, MIP).rgb * surface.clearcoat.F;
#endif // CLEARCOAT

#endif // ENVMAPRENDERING

	return envColor;
}

// surface:				surface descriptor
// probe :				the shader entity holding properties
// probeProjection:		the inverse OBB transform matrix
// clipSpacePos:		world space pixel position transformed into OBB space by probeProjection matrix
// MIP:					mip level to sample
// return:				color of the environment map (rgb), blend factor of the environment map (a)
inline half4 EnvironmentReflection_Local(in TextureCube<half4> cubemap, in Surface surface, in ShaderEntity probe, in float4x4 probeProjection, in half3 clipSpacePos)
{
	if ((probe.layerMask & surface.layerMask) == 0)
		return 0; // early exit: layer mismatch
		
	// Perform parallax correction of reflection ray (R) into OBB:
	half3 RayLS = mul((half3x3)probeProjection, surface.R);
	half3 FirstPlaneIntersect = (1 - clipSpacePos) / RayLS;
	half3 SecondPlaneIntersect = (-1 - clipSpacePos) / RayLS;
	half3 FurthestPlane = max(FirstPlaneIntersect, SecondPlaneIntersect);
	half Distance = min(FurthestPlane.x, min(FurthestPlane.y, FurthestPlane.z));
	half3 R_parallaxCorrected = surface.P - probe.position + surface.R * Distance;

	uint2 dim;
	uint mipcount;
	cubemap.GetDimensions(0, dim.x, dim.y, mipcount);
	half mipcount16f = half(mipcount);

	// Sample cubemap texture:
	half MIP = surface.roughness * mipcount16f;
	half3 envColor = cubemap.SampleLevel(sampler_linear_clamp, R_parallaxCorrected, MIP).rgb * surface.F;

#ifdef SHEEN
	envColor *= surface.sheen.albedoScaling;
	MIP = surface.sheen.roughness * mipcount16f;
	envColor += cubemap.SampleLevel(sampler_linear_clamp, R_parallaxCorrected, MIP).rgb * surface.sheen.color * surface.sheen.DFG;
#endif // SHEEN

#ifdef CLEARCOAT
	RayLS = mul((half3x3)probeProjection, surface.clearcoat.R);
	FirstPlaneIntersect = (1 - clipSpacePos) / RayLS;
	SecondPlaneIntersect = (-1 - clipSpacePos) / RayLS;
	FurthestPlane = max(FirstPlaneIntersect, SecondPlaneIntersect);
	Distance = min(FurthestPlane.x, min(FurthestPlane.y, FurthestPlane.z));
	R_parallaxCorrected = surface.P - probe.position + surface.clearcoat.R * Distance;

	envColor *= 1 - surface.clearcoat.F;
	MIP = surface.clearcoat.roughness * mipcount16f;
	envColor += cubemap.SampleLevel(sampler_linear_clamp, R_parallaxCorrected, MIP).rgb * surface.clearcoat.F;
#endif // CLEARCOAT

	// blend out if close to any cube edge:
	half edgeBlend = 1 - pow8(saturate(max(abs(clipSpacePos.x), max(abs(clipSpacePos.y), abs(clipSpacePos.z)))));

	return half4(envColor, edgeBlend);
}



// VOXEL RADIANCE

inline void VoxelGI(inout Surface surface, inout Lighting lighting)
{
	[branch]
	if (GetFrame().vxgi.resolution != 0 && GetFrame().vxgi.texture_radiance >= 0)
	{
		Texture3D<half4> voxels = bindless_textures3D_half4[descriptor_index(GetFrame().vxgi.texture_radiance)];

		// diffuse:
		half4 trace = ConeTraceDiffuse(voxels, surface.P, surface.N);
		lighting.indirect.diffuse = mad(lighting.indirect.diffuse, 1 - trace.a, trace.rgb);

		// specular:
		[branch]
		if (GetFrame().options & OPTION_BIT_VXGI_REFLECTIONS_ENABLED)
		{
			half roughnessBRDF = sqr(clamp(surface.roughness, min_roughness, 1));
			half4 trace = ConeTraceSpecular(voxels, surface.P, surface.N, surface.V, roughnessBRDF, surface.pixel);
			lighting.indirect.specular = mad(lighting.indirect.specular, 1 - trace.a, trace.rgb * surface.F);
		}
	}
}

#endif // WI_LIGHTING_HF
