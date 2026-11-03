// RealityKit custom material functions for the world: ocean, clouds, stars and haze on scenery.
//
// Every shader samples the same sky panorama (custom texture, equirectangular, row 0 = zenith, u = 0.5
// looking north, increasing east), so water reflections, haze and cloud lighting always match the sky.
// Scene axes: +x east, +y up, -z north, meters. The world is re-centered on the aircraft every frame.

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

constant float earthRadius = 6371000.0;
constant float hazeScaleHeight = 1500.0;

// MARK: - Shared helpers

static float2 skyUV(float3 d) {
    float azimuth = atan2(d.x, -d.z);
    return float2(azimuth / (2.0 * M_PI_F) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / M_PI_F);
}

static half3 skyRadiance(texture2d<half> sky, float3 direction) {
    constexpr sampler s(coord::normalized, address::repeat, filter::linear);
    return sky.sample(s, skyUV(normalize(direction))).rgb;
}

/// Camera position in world space from the world-to-view matrix ([R | t], camera at -Rᵀt).
static float3 cameraPosition(float4x4 worldToView) {
    float3x3 r = float3x3(worldToView[0].xyz, worldToView[1].xyz, worldToView[2].xyz);
    return -(transpose(r) * worldToView[3].xyz);
}

static float3 sunDirection(float azimuth, float elevation) {
    return float3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation));
}

/// Fraction of light scattered away between camera and point by haze whose density falls off with height:
/// density(h) = sigma * exp(-h / H), integrated analytically along the ray.
static float hazeAmount(float sigma, float distance, float cameraAltitude, float pointAltitude) {
    float dh = pointAltitude - cameraAltitude;
    float a = exp(-max(cameraAltitude, 0.0) / hazeScaleHeight);
    float b = exp(-max(pointAltitude, 0.0) / hazeScaleHeight);
    float average = abs(dh) < 1.0 ? a : hazeScaleHeight * (a - b) / dh;
    return 1.0 - exp(-sigma * average * distance);
}

/// The haze color is the sky just above the horizon in the viewing direction.
static half3 hazeColor(texture2d<half> sky, float3 viewToPoint) {
    float3 d = normalize(float3(viewToPoint.x, 0.0, viewToPoint.z) + float3(0, 0.03, 0));
    return skyRadiance(sky, d);
}

// MARK: - Sky dome

/// The sky: the panorama looked up by the view direction, so there are no UV seams or poles.
[[visible]]
void skyDomeSurface(realitykit::surface_parameters params) {
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 direction = params.geometry().world_position() - camera;
    params.surface().set_emissive_color(skyRadiance(params.textures().custom(), direction));
}

// MARK: - Ocean

/// Drops the ocean with the Earth's curvature (h = r² / 2R) so the horizon sits where it should.
[[visible]]
void oceanGeometry(realitykit::geometry_parameters params) {
    float3 p = params.geometry().world_position();
    float r2 = p.x * p.x + p.z * p.z;
    params.geometry().set_world_position_offset(float3(0, -r2 / (2.0 * earthRadius), 0));
}

/// Deep water: Fresnel blend of the reflected sky and the water's own color, sun glint, and haze.
/// custom_parameter: (sun azimuth, sun elevation, sun visibility 0...1, haze density per meter at sea level).
/// base color tint: the sun's color at the surface.
[[visible]]
void oceanSurface(realitykit::surface_parameters params) {
    auto tex = params.textures();
    float4 c = params.uniforms().custom_parameter();
    float3 sun = sunDirection(c.x, c.y);
    float3 world = params.geometry().world_position();
    // The model frame is anchored to the Earth (modulo the wave period), so waves don't follow the aircraft.
    float2 anchored = params.geometry().model_position().xz;
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 toCamera = camera - world;
    float distance = length(toCamera);
    float3 v = toCamera / distance;
    float time = params.uniforms().time();

    // Eight swells from 160 m to 1.5 m. Their wave vectors are whole multiples of 2π / 1600 m in x and z,
    // so the pattern repeats exactly every 1,600 m and the mesh can be re-anchored by that much unseen.
    // Each is faded out before it would shimmer at distance.
    const float2 lattice[8] = { float2(8, 6), float2(-18, 12), float2(-7, 25), float2(33, 29), float2(42, -55),
                                float2(-169, -55), float2(90, 435), float2(1060, -120) };
    const float steepnesses[8] = { 0.012, 0.016, 0.02, 0.026, 0.032, 0.04, 0.045, 0.04 };
    float2 slope = float2(0);
    for (int i = 0; i < 8; i++) {
        float2 waveVector = lattice[i] * (2.0 * M_PI_F / 1600.0);
        float k = length(waveVector);
        float omega = sqrt(9.81 * k);
        float steepness = steepnesses[i];
        // Fade each wave before it is smaller than a few pixels, or it aliases into moire rings.
        float fade = saturate(1.0 - distance / (2.0 * M_PI_F / k * 60.0));
        slope += (waveVector / k) * steepness * cos(dot(waveVector, anchored) - omega * time) * fade;
    }
    float3 n = normalize(float3(-slope.x, 1.0, -slope.y));

    float cosine = saturate(dot(n, v));
    // Schlick Fresnel for water, capped: real waves tilt away from grazing, so the sea is never a perfect mirror.
    float fresnel = min(0.02 + 0.98 * pow(1.0 - cosine, 5.0), 0.6);
    float3 reflected = reflect(-v, n);
    reflected.y = abs(reflected.y);
    half3 skyReflection = skyRadiance(tex.custom(), reflected);
    half3 zenith = skyRadiance(tex.custom(), float3(0, 1, 0));
    half3 horizon = hazeColor(tex.custom(), -v);
    // Light scattered back up from below the surface: a dark blue-green lit by the sky.
    half3 body = half3(0.003, 0.022, 0.045) * (zenith * 0.7h + horizon * 0.3h) * 2.5h;
    half3 color = mix(body, skyReflection, half(fresnel));

    // Sun glint: a sharp highlight near, a broad glitter path far away where waves are below a pixel.
    float3 h = normalize(v + sun);
    float roughness = mix(0.02, 0.12, saturate(distance / 20000.0));
    float alpha2 = roughness * roughness;
    float ndh = saturate(dot(n, h));
    float d = ndh * ndh * (alpha2 - 1.0) + 1.0;
    float specular = alpha2 / (M_PI_F * d * d) * fresnel * 0.25;
    half3 sunColor = half3(params.material_constants().base_color_tint());
    color += sunColor * half(min(specular, 60.0) * c.z * step(0.0, c.y));

    // The surface is at sea level, so the camera's height above it is its altitude.
    float haze = hazeAmount(c.w, distance, max(camera.y - world.y, 0.0), 0.0);
    color = mix(color, horizon, half(haze));
    params.surface().set_emissive_color(color);
}

// MARK: - Billboards (cloud puffs and stars)

/// Turns each quad (four vertices at the same center, uv0 at the corners 0...1, uv1.x the half size in
/// meters) into a square facing the camera.
[[visible]]
void billboardGeometry(realitykit::geometry_parameters params) {
    float2 corner = params.geometry().uv0() * 2.0 - 1.0;
    float size = params.geometry().uv1().x;
    float4x4 mv = params.uniforms().model_to_view();
    float3 right = normalize(float3(mv[0][0], mv[1][0], mv[2][0]));
    float3 up = normalize(float3(mv[0][1], mv[1][1], mv[2][1]));
    params.geometry().set_model_position_offset((right * corner.x + up * corner.y) * size);
}

/// A cumulus puff: soft density from the puff texture, lit from above and toward the sun, hazed with distance.
/// uv1.y: height of the puff within its cloud, 0 base ... 1 top.
/// custom_parameter: (sun azimuth, sun elevation, sun visibility, haze density). base color tint: sun color.
[[visible]]
void cloudSurface(realitykit::surface_parameters params) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    auto tex = params.textures();
    float4 c = params.uniforms().custom_parameter();
    float3 sun = sunDirection(c.x, c.y);
    float3 world = params.geometry().world_position();
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 toPoint = world - camera;
    float distance = length(toPoint);
    float height = params.geometry().uv1().y;

    // RealityKit may store color textures without alpha, so the puff texture keeps its density in red too.
    half density = tex.base_color().sample(s, params.geometry().uv0()).r;
    half3 zenith = skyRadiance(tex.custom(), float3(0, 1, 0));
    // Clouds scatter light almost neutrally, so they take only part of the sun's sunset tint.
    half3 sunColor = mix(half3(params.material_constants().base_color_tint()), half3(1.0h), 0.45h);
    // Silver lining when looking toward the sun through the cloud edge (Henyey-Greenstein forward peak).
    float g = 0.6;
    float cosine = dot(normalize(toPoint), sun);
    float phase = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cosine, 1.5) * 0.25;
    half daylight = half(saturate(c.y * 4.0 + 0.3));
    // Bright, near-white tops in sunlight, gray-blue bases lit only by the sky.
    half3 ambient = zenith * (0.7h + 0.5h * half(height)) * 4.5h + half3(0.04h) * daylight;
    half3 direct = sunColor * half(c.z) * half(0.35 + 0.65 * height) * half(0.8 + phase * 1.2) * daylight * 1.3h;
    half3 color = ambient + direct;

    float haze = hazeAmount(c.w, distance, max(camera.y, 0.0), max(world.y, 0.0));
    color = mix(color, hazeColor(tex.custom(), toPoint), half(haze));
    // Fade puffs right in front of the camera so flying through a cloud is a soft whiteout, not a pop,
    // and toward the edge of the 40 km cloud field that travels with the aircraft.
    half nearFade = half(saturate((distance - 15.0) / 120.0));
    half edgeFade = half(saturate((20000.0 - length(toPoint.xz)) / 5000.0));
    // Transparent custom materials blend premultiplied: color must already be scaled by opacity.
    half opacity = density * nearFade * edgeFade * half(params.material_constants().opacity_scale());
    params.surface().set_emissive_color(color * opacity);
    params.surface().set_opacity(opacity);
}

/// A star: a soft dot whose brightness is uv1.y; custom_parameter.x is how dark the sky is (0 day ... 1 night).
[[visible]]
void starSurface(realitykit::surface_parameters params) {
    float2 p = params.geometry().uv0() * 2.0 - 1.0;
    float falloff = saturate(1.0 - dot(p, p));
    float brightness = params.geometry().uv1().y * params.uniforms().custom_parameter().x;
    half opacity = half(falloff * falloff * saturate(brightness * 4.0));
    params.surface().set_emissive_color(half3(0.9, 0.93, 1.0) * half(brightness * 3.0) * opacity);
    params.surface().set_opacity(opacity);
}

/// The sun or moon disc: texture color times tint times intensity (custom_parameter.x, may exceed 1
/// for the sun), with custom_parameter.y as overall opacity (hidden behind an overcast).
[[visible]]
void glowSurface(realitykit::surface_parameters params) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    half4 t = params.textures().base_color().sample(s, params.geometry().uv0());
    float4 c = params.uniforms().custom_parameter();
    // The texture is premultiplied (its color carries its coverage), and its alpha channel may not survive
    // texture conversion, so coverage is taken from the color.
    half opacity = max(t.r, max(t.g, t.b)) * half(c.y);
    params.surface().set_emissive_color(t.rgb * half3(params.material_constants().base_color_tint()) * half(c.x) * half(c.y));
    params.surface().set_opacity(opacity);
}

// MARK: - Stratus deck

static float hash2(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float2 wrapCell(float2 cell, float period) {
    float2 wrapped = fmod(cell, period);
    return select(wrapped, wrapped + period, wrapped < 0.0);
}

/// Value noise that repeats every `period` cells, so the deck can be re-anchored by a whole period unseen.
static float valueNoise(float2 p, float period) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float2 a = wrapCell(i, period), b = wrapCell(i + float2(1, 0), period);
    float2 c = wrapCell(i + float2(0, 1), period), d = wrapCell(i + float2(1, 1), period);
    return mix(mix(hash2(a), hash2(b), u.x), mix(hash2(c), hash2(d), u.x), u.y);
}

/// A continuous cloud deck seen from below (gray, darker where thick) or above (sunlit white tops).
/// The model frame is Earth-anchored modulo the noise period; its origin is at sea level, so the
/// camera's altitude is minus the model-to-world translation.
/// custom_parameter: (sun azimuth, sun elevation, sun visibility, haze density). base color tint: sun color.
/// opacity scale: coverage.
[[visible]]
void stratusSurface(realitykit::surface_parameters params) {
    auto tex = params.textures();
    float4 c = params.uniforms().custom_parameter();
    float3 sun = sunDirection(c.x, c.y);
    float3 world = params.geometry().world_position();
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 toPoint = world - camera;
    float distance = length(toPoint);
    // 2,200 m cells, 32 cells per period (70.4 km); octaves at whole multiples keep the period.
    float2 p = params.geometry().model_position().xz / 2200.0;
    float n = valueNoise(p, 32.0) * 0.5 + valueNoise(p * 2.0, 64.0) * 0.3 + valueNoise(p * 4.0, 128.0) * 0.2;
    float coverage = params.material_constants().opacity_scale();
    float thickness = saturate((n - (1.0 - coverage) * 0.6) * 2.2);
    bool fromAbove = camera.y > world.y;

    half3 zenith = skyRadiance(tex.custom(), float3(0, 1, 0));
    half3 sunColor = half3(params.material_constants().base_color_tint());
    half3 color;
    if (fromAbove) {
        half lit = half(saturate(sun.y * 2.0 + 0.15) * c.z);
        color = zenith * 1.6h + sunColor * lit * half(0.55 + 0.35 * n);
    } else {
        color = (zenith * 1.4h + sunColor * half(0.15 * c.z)) * half(1.05 - 0.55 * thickness);
    }
    float haze = hazeAmount(c.w, distance, max(camera.y, 0.0), max(world.y, 0.0));
    color = mix(color, hazeColor(tex.custom(), toPoint), half(haze));
    half edgeFade = half(saturate(1.0 - distance / 90000.0));
    half opacity = half(saturate(thickness * 1.6 + coverage * 0.35)) * edgeFade;
    params.surface().set_emissive_color(color * opacity);
    params.surface().set_opacity(opacity);
}

// MARK: - Haze on lit scenery

/// PhysicallyBasedMaterial's behavior (base color, normal, roughness, metallic from the copied textures
/// and constants) plus haze: the surface fades toward the sky's horizon color with distance and altitude.
/// custom_parameter.x: haze density per meter at sea level; .y: the altitude of the model origin (m).
[[visible]]
void sceneryHazeSurface(realitykit::surface_parameters params) {
    constexpr sampler s(coord::normalized, address::repeat, filter::linear, mip_filter::linear, max_anisotropy(8));
    auto tex = params.textures();
    auto surface = params.surface();
    auto constants = params.material_constants();
    float2 uv = params.geometry().uv0();
    uv.y = 1.0 - uv.y;

    half4 base = tex.base_color().sample(s, uv);
    half3 color = base.rgb * half3(constants.base_color_tint());
    surface.set_normal(float3(realitykit::unpack_normal(tex.normal().sample(s, uv).rgb)));
    surface.set_roughness(tex.roughness().sample(s, uv).r * half(constants.roughness_scale()));
    surface.set_metallic(tex.metallic().sample(s, uv).r * half(constants.metallic_scale()));
    surface.set_opacity(half(constants.opacity_scale()) * base.a);

    float4 c = params.uniforms().custom_parameter();
    float3 world = params.geometry().world_position();
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 toPoint = world - camera;
    float pointAltitude = c.y + params.geometry().model_position().y;
    float cameraAltitude = pointAltitude - toPoint.y;
    half haze = half(hazeAmount(c.x, length(toPoint), cameraAltitude, pointAltitude));
    // Lit color fades out while the haze color is added as emission: lit * (1 - f) + haze * f.
    surface.set_base_color(color * (1.0h - haze));
    surface.set_specular(0.5h * (1.0h - haze));
    surface.set_emissive_color(max(half3(constants.emissive_color()), hazeColor(tex.custom(), toPoint) * haze));
}

// MARK: - Terrain

/// Integer hash, stable for the very large Earth-anchored coordinates terrain uses (a sin-based hash
/// loses precision there and turns blocky).
static float hashCell(int2 cell) {
    uint h = uint(cell.x) * 374761393u + uint(cell.y) * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return float(h ^ (h >> 16)) / 4294967295.0;
}

static float terrainNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    return mix(mix(hashCell(c), hashCell(c + int2(1, 0)), u.x), mix(hashCell(c + int2(0, 1)), hashCell(c + int2(1, 1)), u.x), u.y);
}

static float terrainFBM(float2 p) {
    return terrainNoise(p) * 0.5 + terrainNoise(p * 2.03 + 17.0) * 0.3 + terrainNoise(p * 4.11 + 41.0) * 0.2;
}

/// Land cover from height, slope and latitude: beaches at the shore, grass and farmland patches, forest,
/// dry and desert ground in the subtropics, rock on steep slopes and above the tree line, and snow above a
/// snowline that falls toward the poles. Hazed like the rest of the scenery.
/// uv0: Earth-anchored meters (continuous across tiles). uv1: (height above sea level m, latitude degrees).
/// custom_parameter.x: haze density per meter at sea level.
[[visible]]
void terrainSurface(realitykit::surface_parameters params) {
    auto tex = params.textures();
    auto surface = params.surface();
    float2 anchor = params.geometry().uv0();
    float2 info = params.geometry().uv1();
    float elevation = info.x;
    float latitude = abs(info.y);
    float3 n = normalize(params.geometry().normal());
    float slope = 1.0 - saturate(n.y);

    float large = terrainFBM(anchor / 2400.0);
    float medium = terrainFBM(anchor / 420.0);
    float fine = terrainNoise(anchor / 55.0);
    float snowline = mix(4600.0, 800.0, saturate((latitude - 30.0) / 40.0)) + (large - 0.5) * 500.0;
    float treeline = snowline - 1100.0;
    // The subtropical desert belt (about 15 to 33 degrees), patchy.
    float aridity = smoothstep(14.0, 20.0, latitude) * (1.0 - smoothstep(28.0, 34.0, latitude)) * smoothstep(0.35, 0.65, large);

    half3 grass = mix(half3(0.16, 0.23, 0.09), half3(0.34, 0.31, 0.16), half(aridity));
    half3 farmland = mix(half3(0.27, 0.30, 0.14), half3(0.40, 0.35, 0.21), half(fine));
    half3 forest = half3(0.06, 0.11, 0.05);
    half3 rock = half3(0.30, 0.28, 0.25);
    half3 sand = half3(0.62, 0.56, 0.42);
    half3 desert = half3(0.56, 0.44, 0.29);
    half3 snow = half3(0.88, 0.90, 0.94);

    half3 color = mix(grass, farmland, half(smoothstep(0.42, 0.6, large) * (1.0 - smoothstep(600.0, 1300.0, elevation))));
    color = mix(color, desert, half(aridity * smoothstep(0.5, 0.75, large)));
    // Forest favors hillsides (farms take the flat land) and stops at the tree line.
    float forestAmount = smoothstep(0.45, 0.6, medium + slope * 0.9) * smoothstep(15.0, 80.0, elevation)
        * (1.0 - smoothstep(treeline - 250.0, treeline, elevation)) * (1.0 - aridity * 0.8);
    color = mix(color, forest, half(forestAmount));
    color = mix(color, rock, half(max(smoothstep(0.22, 0.42, slope), smoothstep(treeline, treeline + 300.0, elevation))));
    color = mix(color, sand, half(1.0 - smoothstep(1.0, 9.0, elevation)));
    float snowAmount = smoothstep(snowline - 150.0, snowline + 150.0, elevation + (fine - 0.5) * 250.0)
        * (1.0 - smoothstep(0.55, 0.85, slope) * 0.7);
    color = mix(color, snow, half(snowAmount));
    color *= half(0.85 + 0.3 * fine);

    float4 c = params.uniforms().custom_parameter();
    float3 world = params.geometry().world_position();
    float3 camera = cameraPosition(params.uniforms().world_to_view());
    float3 toPoint = world - camera;
    float cameraAltitude = elevation - toPoint.y;
    half haze = half(hazeAmount(c.x, length(toPoint), cameraAltitude, max(elevation, 0.0)));
    surface.set_base_color(color * (1.0h - haze));
    surface.set_roughness(half(0.95 - snowAmount * 0.4));
    surface.set_metallic(0.0h);
    surface.set_specular(half(0.3 * (1.0 - haze)));
    surface.set_emissive_color(hazeColor(tex.custom(), toPoint) * haze);
}
