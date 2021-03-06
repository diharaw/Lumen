#include <resource/mesh.h>
#include <resource/material.h>
#include <vk_mem_alloc.h>
#include <utility/macros.h>

namespace helios
{
// -----------------------------------------------------------------------------------------------------------------------------------

static uint32_t g_last_mesh_id = 0;

// -----------------------------------------------------------------------------------------------------------------------------------

Mesh::Ptr Mesh::create(vk::Backend::Ptr                       backend,
                       vk::Buffer::Ptr                        vbo,
                       vk::Buffer::Ptr                        ibo,
                       std::vector<SubMesh>                   submeshes,
                       std::vector<std::shared_ptr<Material>> materials,
                       vk::BatchUploader&                     uploader,
                       const std::string&                     path)
{
    return std::shared_ptr<Mesh>(new Mesh(backend, vbo, ibo, submeshes, materials, uploader, path));
}

// -----------------------------------------------------------------------------------------------------------------------------------

Mesh::Ptr Mesh::create(vk::Backend::Ptr                       backend,
                       std::vector<Vertex>                    vertices,
                       std::vector<uint32_t>                  indices,
                       std::vector<SubMesh>                   submeshes,
                       std::vector<std::shared_ptr<Material>> materials,
                       vk::BatchUploader&                     uploader,
                       const std::string&                     path)
{
    vk::Buffer::Ptr vbo = vk::Buffer::create(backend, VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, sizeof(Vertex) * vertices.size(), VMA_MEMORY_USAGE_GPU_ONLY, 0);
    vk::Buffer::Ptr ibo = vk::Buffer::create(backend, VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, sizeof(uint32_t) * indices.size(), VMA_MEMORY_USAGE_GPU_ONLY, 0);

    uploader.upload_buffer_data(vbo, vertices.data(), 0, sizeof(Vertex) * vertices.size());
    uploader.upload_buffer_data(ibo, indices.data(), 0, sizeof(uint32_t) * indices.size());

    return std::shared_ptr<Mesh>(new Mesh(backend, vbo, ibo, submeshes, materials, uploader, path));
}

// -----------------------------------------------------------------------------------------------------------------------------------

Mesh::Mesh(vk::Backend::Ptr                       backend,
           vk::Buffer::Ptr                        vbo,
           vk::Buffer::Ptr                        ibo,
           std::vector<SubMesh>                   submeshes,
           std::vector<std::shared_ptr<Material>> materials,
           vk::BatchUploader&                     uploader,
           const std::string&                     path) :
    vk::Object(backend),
    m_vbo(vbo),
    m_ibo(ibo),
    m_sub_meshes(submeshes),
    m_materials(materials),
    m_id(g_last_mesh_id++),
    m_path(path)
{
    std::vector<VkAccelerationStructureBuildRangeInfoKHR> build_ranges;
    std::vector<VkAccelerationStructureGeometryKHR>       geometries;
    std::vector<uint32_t>                                 max_primitive_counts;

    // Populate geometries
    for (int i = 0; i < submeshes.size(); i++)
    {
        Material::Ptr material = materials[submeshes[i].mat_idx];

        VkAccelerationStructureGeometryKHR geometry;
        HELIOS_ZERO_MEMORY(geometry);

        VkGeometryFlagsKHR geometry_flags = 0;

        if (material->type() == MATERIAL_OPAQUE && !material->is_alpha_tested())
            geometry_flags = VK_GEOMETRY_OPAQUE_BIT_KHR;

        geometry.sType                                       = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;
        geometry.pNext                                       = nullptr;
        geometry.geometryType                                = VK_GEOMETRY_TYPE_TRIANGLES_KHR;
        geometry.geometry.triangles.sType                    = VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
        geometry.geometry.triangles.pNext                    = nullptr;
        geometry.geometry.triangles.vertexData.deviceAddress = m_vbo->device_address();
        geometry.geometry.triangles.vertexStride             = sizeof(Vertex);
        geometry.geometry.triangles.maxVertex                = submeshes[i].vertex_count;
        geometry.geometry.triangles.vertexFormat             = VK_FORMAT_R32G32B32_SFLOAT;
        geometry.geometry.triangles.indexData.deviceAddress  = m_ibo->device_address();
        geometry.geometry.triangles.indexType                = VK_INDEX_TYPE_UINT32;
        geometry.flags                                       = geometry_flags;

        geometries.push_back(geometry);
        max_primitive_counts.push_back(submeshes[i].index_count / 3);

        VkAccelerationStructureBuildRangeInfoKHR build_range;
        HELIOS_ZERO_MEMORY(build_range);

        build_range.primitiveCount  = submeshes[i].index_count / 3;
        build_range.primitiveOffset = submeshes[i].base_index * sizeof(uint32_t);
        build_range.firstVertex     = 0;
        build_range.transformOffset = 0;

        build_ranges.push_back(build_range);
    }

    // Create blas
    vk::AccelerationStructure::Desc desc;

    desc.set_type(VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR);
    desc.set_flags(VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR);
    desc.set_geometries(geometries);
    desc.set_geometry_count(geometries.size());
    desc.set_max_primitive_counts(max_primitive_counts);

    m_blas = vk::AccelerationStructure::create(backend, desc);

    uploader.build_blas(m_blas, geometries, build_ranges);
}

// -----------------------------------------------------------------------------------------------------------------------------------

Mesh::~Mesh()
{
}

// -----------------------------------------------------------------------------------------------------------------------------------
} // namespace helios