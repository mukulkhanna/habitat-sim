// Copyright (c) Meta Platforms, Inc. and its affiliates.
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.

precision highp float;
// TODO Make this an actual uniform
const float uExposure = 4.5f;

// TODO Make this an actual uniform
const float uGamma = 2.2f;
const vec3 GAMMA_VEC = vec3(uGamma);

const float INV_GAMMA = 1.0f / uGamma;
const vec3 INV_GAMMA_VEC = vec3(INV_GAMMA);

// linear to sRGB approximation
// see http://chilliant.blogspot.com/2012/08/srgb-approximations-for-hlsl.html
vec3 linearToSRGB(vec3 color) {
  return pow(color, INV_GAMMA_VEC);
}

// Approximation mapping
vec4 linearToSRGB(vec4 color) {
  return vec4(linearToSRGB(color.rgb), color.a);
}

// sRGB to linear approximation
// see http://chilliant.blogspot.com/2012/08/srgb-approximations-for-hlsl.html
vec3 sRGBToLinear(vec3 srgbIn) {
  return vec3(pow(srgbIn.xyz, GAMMA_VEC));
}

vec4 sRGBToLinear(vec4 srgbIn) {
  return vec4(sRGBToLinear(srgbIn.xyz), srgbIn.w);
}

#if (LIGHT_COUNT > 0)
// Configure a LightInfo object
// light : normalized point to light vector
// lightIrradiance : distance-attenuated light intensity/irradiance color
// n : normal
// view : normalized view vector (point to camera)
// n_dot_v : cos angle between n and view
// (out) l : LightInfo structure being populated
void configureLightInfo(vec3 light,
                        vec3 lightIrradiance,
                        vec3 n,
                        vec3 view,
                        float n_dot_v,
                        out LightInfo l) {
  l.light = light;
  l.lightIrradiance = lightIrradiance;
  l.n_dot_v = n_dot_v;
  // if n dot l is negative we should never see this light's contribution
  l.n_dot_l = clamp(dot(n, light), 0.0, 1.0);
  l.halfVector = normalize(light + view);
  l.v_dot_h = clamp(dot(view, l.halfVector), 0.0, 1.0);  // == l_dot_h
  l.n_dot_h = clamp(dot(n, l.halfVector), 0.0, 1.0);
  l.projLightIrradiance = lightIrradiance * l.n_dot_l;
}  // configureLightInfo

// Build a lightInfo structure from the light represented by the light index
// iLight : the index of the light
// pbrInfo : the PBRData object that holds all the precalculated material data
// (out) l : LightInfo structure being populated
bool buildLightInfoFromLightIdx(int iLight, PBRData pbrInfo, out LightInfo l) {
  // Directional lights have the .w component set to 0
  // Non-directional lights (i.e. point) have w == 1

  // Incident light vector - directions have been flipped for directional
  // lights before being fed to uniform so we can use the same function for
  // both kinds of lights without a condition check
  vec3 toLightVec =
      uLightDirections[iLight].xyz - (position * uLightDirections[iLight].w);
  // either the length of the toLightVec vector or 0 (for directional
  // lights, to enable directional attenuation to remain at 1)
  float dist = length(toLightVec) * uLightDirections[iLight].w;

  // either the squared length of the toLightVec vector or 1 (for
  // directional lights, to prevent divide by 0)
  float sqDist = (uLightDirections[iLight].w * ((dist * dist) - 1)) + 1;

  // If uLightRanges[iLight] is 0 for whatever reason, clamp it to a small value
  // to avoid a NaN when dist is 0 as well (which is the case for directional
  // lights)
  // https://github.com/KhronosGroup/glTF/blob/master/extensions/2.0/Khronos/KHR_lights_punctual/README.md#range-property
  // Attenuation is 1 for directional lights, governed by inverse square law
  // otherwise
  float attenuation =
      clamp(1 - pow4(dist / (uLightRanges[iLight] + EPSILON)), 0.0, 1.0) /
      sqDist;

  // if color is not visible, skip contribution
  if (attenuation == 0) {
    return false;
  }

  // Build a light info for this light
  configureLightInfo(normalize(toLightVec), uLightColors[iLight] * attenuation,
                     pbrInfo.n, pbrInfo.view, pbrInfo.n_dot_v, l);
  return true;
}  // buildLightInfoFromLightIdx

#if defined(ANISOTROPY_LAYER)

// Configure a light-dependent AnisotropyDirectLight object
// l : LightInfo structure for current light
// PBRData pbrInfo : structure populated with precalculated material values
// (out) info : AnisotropyInfo structure to be populated
void configureAnisotropyLightInfo(LightInfo l,
                                  PBRData pbrInfo,
                                  out AnisotropyDirectLight info) {
  info.t_dot_l = dot(pbrInfo.anisotropicT, l.light);
  info.b_dot_l = dot(pbrInfo.anisotropicB, l.light);
  info.t_dot_h = dot(pbrInfo.anisotropicT, l.halfVector);
  info.b_dot_h = dot(pbrInfo.anisotropicB, l.halfVector);

}  // configureAnisotropyLightInfo

#endif  // ANISOTROPY_LAYER

#endif  // (LIGHT_COUNT > 0)

//#if defined(TONE_MAP)
// The following function Uncharted2toneMap is based on:
// https://github.com/SaschaWillems/Vulkan-glTF-PBR/blob/master/data/shaders/pbr_khr.frag
vec3 Uncharted2Tonemap(vec3 color) {
  float A = 0.15;
  float B = 0.50;
  float C = 0.10;
  float D = 0.20;
  float E = 0.02;
  float F = 0.30;
  float W = 11.2;
  return ((color * (A * color + C * B) + D * E) /
          (color * (A * color + B) + D * F)) -
         E / F;
}
//(1.0f / Uncharted2Tonemap(vec3(11.2f)));
const vec3 toneMapUC2Denom = vec3(1.1962848297213622);
// The following function toneMap is based on:
// https://github.com/SaschaWillems/Vulkan-glTF-PBR/blob/master/data/shaders/pbr_khr.frag
// Tone mapping takes a wide dynamic range of values and compresses them
// into a smaller range that is appropriate for the output device.
vec4 toneMapToSRGB(vec4 color) {
  vec3 outcol = Uncharted2Tonemap(color.rgb * uExposure) * toneMapUC2Denom;
  return vec4(linearToSRGB(outcol.rgb), color.a);
}
// Tone map without linear-to-srgb mapping
vec4 toneMap(vec4 color) {
  vec3 outcol = Uncharted2Tonemap(color.rgb * uExposure) * toneMapUC2Denom;
  return vec4(outcol, color.a);
}

//#endif  // TONE_MAP

/////////////////
// IBL Support

#if defined(IMAGE_BASED_LIGHTING)
// diffuseColor: diffuse color
// n: normal on shading location in world space
vec3 computeIBLDiffuse(vec3 diffuseColor, vec3 n) {
  // diffuse part = diffuseColor * irradiance
  vec4 IBLDiffuseIrradiance = texture(uIrradianceMap, n);
  // texture assumed to be sRGB
#if defined(REMAP_COLORS_TO_LINEAR)
// If using remapping, final result is remapped to sRGB so don't do it here
#if defined(TONE_MAP)
  IBLDiffuseIrradiance = toneMap(IBLDiffuseIrradiance);
#endif  // TONE_MAP
#else   // not REMAP_COLORS_TO_LINEAR
// If not using remapping, make sure we still remap IBL image
#if defined(TONE_MAP)
  IBLDiffuseIrradiance = toneMapToSRGB(IBLDiffuseIrradiance);
#else
  IBLDiffuseIrradiance = linearToSRGB(IBLDiffuseIrradiance);
#endif  // TONE_MAP
#endif  // REMAP_COLORS_TO_LINEAR

  return diffuseColor * IBLDiffuseIrradiance.rgb;
}  // computeIBLDiffuse

vec3 computeIBLSpecular(float roughness,
                        float n_dot_v,
                        vec3 specularReflectance,
                        vec3 reflectionDir) {
  vec2 brdfSamplePt =
      clamp(vec2(n_dot_v, 1.0 - roughness), vec2(0.0, 0.0), vec2(1.0, 1.0));
  vec3 brdf = texture(uBrdfLUT, brdfSamplePt).rgb;
  // LOD roughness scaled by mip levels -1
  float lod = roughness * float(uPrefilteredMapMipLevels - 1u);
  vec4 IBLSpecIrradiance = textureLod(uPrefilteredMap, reflectionDir, lod);
  // texture assumed to be sRGB

#if defined(REMAP_COLORS_TO_LINEAR)
// If using remapping, final result is remapped to sRGB so don't do it here
#if defined(TONE_MAP)
  IBLSpecIrradiance = toneMap(IBLSpecIrradiance);
#endif  // TONE_MAP
#else   // not REMAP_COLORS_TO_LINEAR
// If not using remapping, make sure we still remap IBL image
#if defined(TONE_MAP)
  IBLSpecIrradiance = toneMapToSRGB(IBLSpecIrradiance);
#else
  IBLSpecIrradiance = linearToSRGB(IBLSpecIrradiance);
#endif  // TONE_MAP
#endif  // REMAP_COLORS_TO_LINEAR

  return (specularReflectance * brdf.x + brdf.y) * IBLSpecIrradiance.rgb;
}  // computeIBLSpecular
#endif  // IMAGE_BASED_LIGHTING
