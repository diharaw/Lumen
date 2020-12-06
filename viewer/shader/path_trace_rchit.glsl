#include "common.glsl"
#include "brdf.glsl"

// ------------------------------------------------------------------------
// Set 0 ------------------------------------------------------------------
// ------------------------------------------------------------------------

layout (set = 0, binding = 0, std430) readonly buffer MaterialBuffer 
{
    Material data[];
} Materials;

layout (set = 0, binding = 1, std430) readonly buffer InstanceBuffer 
{
    Instance data[];
} Instances;

layout (set = 0, binding = 2, std430) readonly buffer LightBuffer 
{
    Light data[];
} Lights;

layout (set = 0, binding = 3) uniform accelerationStructureEXT u_TopLevelAS;

layout (set = 0, binding = 4) uniform samplerCube s_EnvironmentMap;

// ------------------------------------------------------------------------
// Set 1 ------------------------------------------------------------------
// ------------------------------------------------------------------------

layout (set = 1, binding = 0, std430) readonly buffer VertexBuffer 
{
    Vertex data[];
} Vertices[];

// ------------------------------------------------------------------------
// Set 2 ------------------------------------------------------------------
// ------------------------------------------------------------------------

layout (set = 2, binding = 0) readonly buffer IndexBuffer 
{
    uint data[];
} Indices[];

// ------------------------------------------------------------------------
// Set 3 ------------------------------------------------------------------
// ------------------------------------------------------------------------

layout (set = 3, binding = 0) readonly buffer SubmeshInfoBuffer 
{
    uvec2 data[];
} SubmeshInfo[];

// ------------------------------------------------------------------------
// Set 4 ------------------------------------------------------------------
// ------------------------------------------------------------------------

layout (set = 4, binding = 0) uniform sampler2D s_Textures[];

// ------------------------------------------------------------------------
// Set 5 ------------------------------------------------------------------
// ------------------------------------------------------------------------

#if defined(RAY_DEBUG_VIEW)
layout (set = 5, binding = 0) writeonly buffer DebugRayVertexBuffer_t 
{
    DebugRayVertex vertices[];
} DebugRayVertexBuffer;

layout (set = 5, binding = 1) buffer DebugRayDrawArgs_t
{
    uint count;
    uint instance_count;
    uint first;
    uint base_instance;
} DebugRayDrawArgs;
#else
layout(set = 5, binding = 0, rgba32f) readonly uniform image2D i_PreviousColor;
#endif

// ------------------------------------------------------------------------
// Set 6 ------------------------------------------------------------------
// ------------------------------------------------------------------------

#if !defined(RAY_DEBUG_VIEW)
layout(set = 6, binding = 0, rgba32f) writeonly uniform image2D i_CurrentColor;
#endif

// ------------------------------------------------------------------------
// Push Constants ---------------------------------------------------------
// ------------------------------------------------------------------------

layout(push_constant) uniform PathTraceConsts
{
    mat4 view_inverse;
    mat4 proj_inverse;
    ivec4 ray_debug_pixel_coord;
    float accumulation;
    uint num_lights;
    uint num_frames;
} u_PathTraceConsts;

// ------------------------------------------------------------------------
// Input Payload ----------------------------------------------------------
// ------------------------------------------------------------------------

rayPayloadInEXT PathTracePayload p_PathTracePayload;

// ------------------------------------------------------------------------
// Output Payload ---------------------------------------------------------
// ------------------------------------------------------------------------

layout(location = 1) rayPayloadInEXT PathTracePayload p_IndirectPayload;

layout(location = 2) rayPayloadEXT bool p_Visibility;

// ------------------------------------------------------------------------
// Hit Attributes ---------------------------------------------------------
// ------------------------------------------------------------------------

hitAttributeEXT vec2 hit_attribs;

// ------------------------------------------------------------------------
// Functions --------------------------------------------------------------
// ------------------------------------------------------------------------

Vertex get_vertex(uint mesh_idx, uint vertex_idx)
{
    return Vertices[nonuniformEXT(mesh_idx)].data[vertex_idx];
}

// ------------------------------------------------------------------------

HitInfo fetch_hit_info()
{
    uvec2 primitive_offset_mat_idx = SubmeshInfo[nonuniformEXT(gl_InstanceCustomIndexEXT)].data[gl_GeometryIndexEXT];

    HitInfo hit_info;

    hit_info.mat_idx = primitive_offset_mat_idx.y;
    hit_info.primitive_offset = primitive_offset_mat_idx.x;

    return hit_info;
}

// ------------------------------------------------------------------------

Triangle fetch_triangle(in Instance instance, in HitInfo hit_info)
{
    Triangle tri;

    uint primitive_id = gl_PrimitiveID + hit_info.primitive_offset;

    uvec3 idx = uvec3(Indices[nonuniformEXT(instance.mesh_idx)].data[3 * primitive_id], 
                      Indices[nonuniformEXT(instance.mesh_idx)].data[3 * primitive_id + 1],
                      Indices[nonuniformEXT(instance.mesh_idx)].data[3 * primitive_id + 2]);

    tri.v0 = get_vertex(instance.mesh_idx, idx.x);
    tri.v1 = get_vertex(instance.mesh_idx, idx.y);
    tri.v2 = get_vertex(instance.mesh_idx, idx.z);

    tri.mat_idx = hit_info.mat_idx;

    return tri;
}

// ------------------------------------------------------------------------

Vertex interpolated_vertex(in Instance instance, in HitInfo hit_info, in Triangle tri)
{;
    mat4 model_mat = instance.model_matrix;
    mat3 normal_mat = mat3(instance.normal_matrix);

    const vec3 barycentrics = vec3(1.0 - hit_attribs.x - hit_attribs.y, hit_attribs.x, hit_attribs.y);

    Vertex o;

    o.position = model_mat * vec4(tri.v0.position.xyz * barycentrics.x + tri.v1.position.xyz * barycentrics.y + tri.v2.position.xyz * barycentrics.z, 1.0);
    o.tex_coord.xy = tri.v0.tex_coord.xy * barycentrics.x + tri.v1.tex_coord.xy * barycentrics.y + tri.v2.tex_coord.xy * barycentrics.z;
    o.normal.xyz = normal_mat * normalize(tri.v0.normal.xyz * barycentrics.x + tri.v1.normal.xyz * barycentrics.y + tri.v2.normal.xyz * barycentrics.z);
    o.tangent.xyz = normal_mat * normalize(tri.v0.tangent.xyz * barycentrics.x + tri.v1.tangent.xyz * barycentrics.y + tri.v2.tangent.xyz * barycentrics.z);
    o.bitangent.xyz = normal_mat * normalize(tri.v0.bitangent.xyz * barycentrics.x + tri.v1.bitangent.xyz * barycentrics.y + tri.v2.bitangent.xyz * barycentrics.z);

    return o;
}

// ------------------------------------------------------------------------

vec3 get_normal_from_map(vec3 tangent, vec3 bitangent, vec3 normal, vec2 tex_coord, uint normal_map_idx)
{
    // Create TBN matrix.
    mat3 TBN = mat3(normalize(tangent), normalize(bitangent), normalize(normal));

    // Sample tangent space normal vector from normal map and remap it from [0, 1] to [-1, 1] range.
    vec3 n = normalize(textureLod(s_Textures[nonuniformEXT(normal_map_idx)], tex_coord, 0.0).rgb * 2.0 - 1.0);

    // Multiple vector by the TBN matrix to transform the normal from tangent space to world space.
    n = normalize(TBN * n);

    return n;
}

// ------------------------------------------------------------------------

void fetch_albedo(in Material material, inout SurfaceProperties p)
{
    if (material.texture_indices0.x == -1)
        p.albedo = material.albedo;
    else
        p.albedo = textureLod(s_Textures[nonuniformEXT(material.texture_indices0.x)], p.vertex.tex_coord.xy, 0.0);
}

// ------------------------------------------------------------------------

void fetch_normal(in Material material, inout SurfaceProperties p)
{
    if (material.texture_indices0.y == -1)
        p.normal = p.vertex.normal.xyz;
    else
        p.normal = get_normal_from_map(p.vertex.tangent.xyz, p.vertex.bitangent.xyz, p.vertex.normal.xyz, p.vertex.tex_coord.xy, material.texture_indices0.y);
}

// ------------------------------------------------------------------------

void fetch_roughness(in Material material, inout SurfaceProperties p)
{
    if (material.texture_indices0.z == -1)
        p.roughness = material.roughness_metallic.r;
    else
        p.roughness = textureLod(s_Textures[nonuniformEXT(material.texture_indices0.z)], p.vertex.tex_coord.xy, 0.0)[material.texture_indices1.z];
}

// ------------------------------------------------------------------------

void fetch_metallic(in Material material, inout SurfaceProperties p)
{
    if (material.texture_indices0.w == -1)
        p.metallic = material.roughness_metallic.g;
    else
        p.metallic = textureLod(s_Textures[nonuniformEXT(material.texture_indices0.w)], p.vertex.tex_coord.xy, 0.0)[material.texture_indices1.w];
}

// ------------------------------------------------------------------------

void fetch_emissive(in Material material, inout SurfaceProperties p)
{
    if (material.texture_indices1.x == -1)
        p.emissive = material.emissive.rgb;
    else
        p.emissive = textureLod(s_Textures[nonuniformEXT(material.texture_indices1.x)], p.vertex.tex_coord.xy, 0.0).rgb;
}

// ------------------------------------------------------------------------

void populate_surface_properties(out SurfaceProperties p)
{
    const Instance instance = Instances.data[gl_InstanceCustomIndexEXT];
    const HitInfo hit_info = fetch_hit_info();
    const Triangle triangle = fetch_triangle(instance, hit_info);
    const Material material = Materials.data[triangle.mat_idx];

    p.vertex = interpolated_vertex(instance, hit_info, triangle);

    fetch_albedo(material, p);
    fetch_normal(material, p);
    fetch_roughness(material, p);
    fetch_metallic(material, p);
    fetch_emissive(material, p);

    p.roughness = max(p.roughness, MIN_ROUGHNESS);

    p.F0 = mix(vec3(0.03), p.albedo.xyz, p.metallic);
    p.alpha = p.roughness * p.roughness;
    p.alpha2 = p.alpha * p.alpha;
}

// ------------------------------------------------------------------------

vec3 sample_light(in SurfaceProperties p, in Light light, out vec3 Wi, out float pdf)
{
    vec3 Li = vec3(0.0f);

    uint type = uint(light.light_data0.x);

    if (type == LIGHT_DIRECTIONAL)
    {
        Wi = -light.light_data1.xyz;
        Li = light.light_data0.yzw * light.light_data1.w;
        pdf = 0.0f;
    }
    else if (type == LIGHT_SPOT)
    {
        Wi = -light.light_data1.xyz;
        Li = light.light_data0.yzw * light.light_data1.w;
        pdf = 0.0f;
    }
    else if (type == LIGHT_POINT)
    {
        Wi = normalize(light.light_data1.xyz - p.vertex.position.xyz);
        Li = light.light_data0.yzw * light.light_data1.w;
        pdf = 0.0f;
    }
    else if (type == LIGHT_ENVIRONMENT_MAP)
    {
        vec2 rand_value = next_vec2(p_PathTracePayload.rng);
        Wi = sample_cosine_lobe(p.normal, rand_value);
        Li = texture(s_EnvironmentMap, Wi).rgb;
        pdf = 0.0f;
    }
    else if (type == LIGHT_AREA)
    {
        // TODO
    }

    uint  ray_flags = gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT;
    uint  cull_mask = 0xFF;
    float tmin      = 0.0001;
    float tmax      = 10000.0;

    // Trace Ray
    traceRayEXT(u_TopLevelAS, 
                ray_flags, 
                cull_mask, 
                VISIBILITY_CLOSEST_HIT_SHADER_IDX, 
                1, 
                VISIBILITY_MISS_SHADER_IDX, 
                p.vertex.position.xyz, 
                tmin, 
                Wi, 
                tmax, 
                1);

    return Li * float(p_Visibility);
}

// ------------------------------------------------------------------------

vec3 direct_lighting(in SurfaceProperties p)
{
    vec3 L = vec3(0.0f);

    uint light_idx = next_uint(p_PathTracePayload.rng, u_PathTraceConsts.num_lights);
    const Light light = Lights.data[light_idx];

    vec3 Wo = -gl_WorldRayDirectionEXT;
    vec3 Wi = vec3(0.0f);
    vec3 Wh = vec3(0.0f);
    float pdf = 0.0f;

    vec3 Li = sample_light(p, light, Wi, pdf);

    Wh = normalize(Wo + Wi);

    vec3 brdf = evaluate_uber(p, Wo, Wh, Wi);
    float cos_theta = clamp(dot(p.normal, Wo), 0.0, 1.0);

    if (!is_black(Li))
    {
        if (pdf == 0.0f)
            L = p_PathTracePayload.T * brdf * cos_theta * Li;
        else
            L = (p_PathTracePayload.T * brdf * cos_theta * Li) / pdf;
    }
 
    return L * float(u_PathTraceConsts.num_lights);
}

// ------------------------------------------------------------------------

vec3 indirect_lighting(in SurfaceProperties p)
{
    vec3 Wo = -gl_WorldRayDirectionEXT;
    vec3 Wi;
    float pdf;

    vec3 brdf = sample_uber(p, Wo, p_PathTracePayload.rng, Wi, pdf);

    float cos_theta = clamp(dot(p.normal, Wo), 0.0, 1.0);

    p_IndirectPayload.L = vec3(0.0f);
    p_IndirectPayload.T = p_PathTracePayload.T *  (brdf * cos_theta) / pdf;
    p_IndirectPayload.depth = p_PathTracePayload.depth + 1;
    p_IndirectPayload.rng = p_PathTracePayload.rng;

    uint  ray_flags = gl_RayFlagsOpaqueEXT;
    uint  cull_mask = 0xFF;
    float tmin      = 0.0001;
    float tmax      = 10000.0;  

    // Trace Ray
    traceRayEXT(u_TopLevelAS, 
            ray_flags, 
            cull_mask, 
            PATH_TRACE_CLOSEST_HIT_SHADER_IDX, 
            1, 
            PATH_TRACE_MISS_SHADER_IDX, 
            p.vertex.position.xyz, 
            tmin, 
            Wi, 
            tmax, 
            1);

    return p_IndirectPayload.L;
}

// ------------------------------------------------------------------------
// Main -------------------------------------------------------------------
// ------------------------------------------------------------------------

void main()
{
    SurfaceProperties p;

    populate_surface_properties(p);

#if defined(RAY_DEBUG_VIEW)
    // Skip the primary ray
    if (p_PathTracePayload.depth > 0)
    {
        uint debug_ray_vert_idx = atomicAdd(DebugRayDrawArgs.count, 2);

        DebugRayVertex v0;

        v0.position = vec4(gl_WorldRayOriginEXT, 1.0f);
        v0.color = vec4(p_PathTracePayload.debug_color, 1.0f);

        DebugRayVertex v1;

        v1.position = vec4(gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT  * gl_HitTEXT, 1.0f);
        v1.color = vec4(p_PathTracePayload.debug_color, 1.0f);

        DebugRayVertexBuffer.vertices[debug_ray_vert_idx + 0] = v0;
        DebugRayVertexBuffer.vertices[debug_ray_vert_idx + 1] = v1;
    }
#endif

    if (p_PathTracePayload.depth == 0 && !is_black(p.emissive.rgb))
        p_PathTracePayload.L = p.emissive.rgb;
    else
    {
        p_PathTracePayload.L = direct_lighting(p);

        if (p_PathTracePayload.depth < MAX_RAY_BOUNCES)
            p_PathTracePayload.L += indirect_lighting(p);
    }
}

// ------------------------------------------------------------------------