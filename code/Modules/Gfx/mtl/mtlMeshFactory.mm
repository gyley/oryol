//------------------------------------------------------------------------------
//  mtlMeshFactory.mm
//------------------------------------------------------------------------------
#include "Pre.h"
#include "mtl_impl.h"
#include "mtlMeshFactory.h"
#include "mtlTypes.h"
#include "Gfx/Resource/mesh.h"
#include "Gfx/Core/renderer.h"

namespace Oryol {
namespace _priv {

//------------------------------------------------------------------------------
mtlMeshFactory::mtlMeshFactory() :
isValid(false) {
    // empty
}

//------------------------------------------------------------------------------
mtlMeshFactory::~mtlMeshFactory() {
    o_assert_dbg(!this->isValid);
}

//------------------------------------------------------------------------------
void
mtlMeshFactory::Setup(const gfxPointers& ptrs) {
    o_assert_dbg(!this->isValid);
    this->isValid = true;
    this->pointers = ptrs;
}

//------------------------------------------------------------------------------
void
mtlMeshFactory::Discard() {
    o_assert_dbg(this->isValid);
    this->pointers = gfxPointers();
    this->isValid = false;
}

//------------------------------------------------------------------------------
bool
mtlMeshFactory::IsValid() const {
    return this->isValid;
}

//------------------------------------------------------------------------------
ResourceState::Code
mtlMeshFactory::SetupResource(mesh& msh) {
    o_assert_dbg(this->isValid);
    if (msh.Setup.ShouldSetupEmpty()) {
        return this->createEmptyMesh(msh);
    }
    else if (msh.Setup.ShouldSetupFullScreenQuad()) {
        return this->createFullscreenQuad(msh);
    }
    else {
        o_error("mtlMeshFactory::SetupResource(): don't know how to create mesh!\n");
        return ResourceState::InvalidState;
    }
}

//------------------------------------------------------------------------------
ResourceState::Code
mtlMeshFactory::SetupResource(mesh& msh, const void* data, int size) {
    o_assert_dbg(this->isValid);
    o_assert_dbg(msh.Setup.ShouldSetupFromData());
    return this->createFromData(msh, data, size);
}

//------------------------------------------------------------------------------
void
mtlMeshFactory::DestroyResource(mesh& msh) {
    for (auto& buf : msh.buffers) {
        for (auto& mtlBuf : buf.mtlBuffers) {
            if (nil != mtlBuf) {
                this->pointers.renderer->releaseDeferred(mtlBuf);
            }
        }
    }
    msh.Clear();
}

//------------------------------------------------------------------------------
/**
    NOTE: data pointer can be a nullptr
*/
id<MTLBuffer>
mtlMeshFactory::createBuffer(const void* data, uint32 dataSize, Usage::Code usage) {
    o_assert_dbg(dataSize > 0);

    MTLResourceOptions options = mtlTypes::asBufferResourceOptions(usage);
    id<MTLBuffer> buf;
    if (data) {
        buf = [this->pointers.renderer->mtlDevice newBufferWithBytes:data length:dataSize options:options];
    }
    else {
        buf = [this->pointers.renderer->mtlDevice newBufferWithLength:dataSize options:options];
    }
    return buf;
}

//------------------------------------------------------------------------------
void
mtlMeshFactory::setupAttrs(mesh& msh) {

    VertexBufferAttrs vbAttrs;
    vbAttrs.NumVertices = msh.Setup.NumVertices;
    vbAttrs.BufferUsage = msh.Setup.VertexUsage;
    vbAttrs.Layout = msh.Setup.Layout;
    msh.vertexBufferAttrs = vbAttrs;

    IndexBufferAttrs ibAttrs;
    ibAttrs.NumIndices = msh.Setup.NumIndices;
    ibAttrs.Type = msh.Setup.IndicesType;
    ibAttrs.BufferUsage = msh.Setup.IndexUsage;
    msh.indexBufferAttrs = ibAttrs;
}

//------------------------------------------------------------------------------
void
mtlMeshFactory::setupPrimGroups(mesh& msh) {
    msh.numPrimGroups = msh.Setup.NumPrimitiveGroups();
    o_assert_dbg(msh.numPrimGroups < GfxConfig::MaxNumPrimGroups);
    for (int i = 0; i < msh.numPrimGroups; i++) {
        msh.primGroups[i] = msh.Setup.PrimitiveGroup(i);
    }
}

//------------------------------------------------------------------------------
ResourceState::Code
mtlMeshFactory::createEmptyMesh(mesh& msh) {
    o_assert_dbg(nil == msh.buffers[mesh::vb].mtlBuffers[0]);
    o_assert_dbg(nil == msh.buffers[mesh::ib].mtlBuffers[0]);
    o_assert_dbg(0 < msh.Setup.NumVertices);

    this->setupAttrs(msh);
    this->setupPrimGroups(msh);

    // create vertex buffer(s)
    const auto& vbAttrs = msh.vertexBufferAttrs;
    const int vbSize = msh.Setup.NumVertices * msh.Setup.Layout.ByteSize();
    msh.buffers[mesh::vb].numSlots = Usage::Immutable == vbAttrs.BufferUsage ? 1 : 2;
    for (uint8 slotIndex = 0; slotIndex < msh.buffers[mesh::vb].numSlots; slotIndex++) {
        msh.buffers[mesh::vb].mtlBuffers[slotIndex] = this->createBuffer(nullptr, vbSize, vbAttrs.BufferUsage);
        o_assert_dbg(nil != msh.buffers[mesh::vb].mtlBuffers[slotIndex]);
    }

    // create optional index buffer(s)
    const auto& ibAttrs = msh.indexBufferAttrs;
    if (IndexType::None != ibAttrs.Type) {
        msh.buffers[mesh::ib].numSlots = Usage::Immutable == ibAttrs.BufferUsage ? 1 : 2;
        const int ibSize = ibAttrs.NumIndices * IndexType::ByteSize(ibAttrs.Type);
        for (uint8_t slotIndex = 0; slotIndex < msh.buffers[mesh::ib].numSlots; slotIndex++) {
            msh.buffers[mesh::ib].mtlBuffers[slotIndex] = this->createBuffer(nullptr, ibSize, ibAttrs.BufferUsage);
        }
    }

    return ResourceState::Valid;
}

//------------------------------------------------------------------------------
ResourceState::Code
mtlMeshFactory::createFromData(mesh& msh, const void* data, int size) {
    o_assert_dbg(nil == msh.buffers[mesh::vb].mtlBuffers[0]);
    o_assert_dbg(nil == msh.buffers[mesh::ib].mtlBuffers[0]);
    o_assert_dbg(1 == msh.buffers[mesh::vb].numSlots);
    o_assert_dbg(1 == msh.buffers[mesh::ib].numSlots);
    o_assert_dbg(nullptr != data);
    o_assert_dbg(size > 0);

    this->setupAttrs(msh);
    this->setupPrimGroups(msh);
    const uint8* ptr = (const uint8*) data;

    // create vertex buffer
    if (msh.Setup.NumVertices > 0) {
        const auto& vbAttrs = msh.vertexBufferAttrs;
        const int vbSize = vbAttrs.NumVertices * msh.Setup.Layout.ByteSize();
        msh.buffers[mesh::vb].numSlots = Usage::Immutable == vbAttrs.BufferUsage ? 1 : 2;
        const uint8* vertices = nullptr;
        if (InvalidIndex != msh.Setup.DataVertexOffset) {
            vertices = ptr + msh.Setup.DataVertexOffset;
            o_assert_dbg((ptr + size) >= (vertices + vbSize));
        }
        for (uint8 slotIndex = 0; slotIndex < msh.buffers[mesh::vb].numSlots; slotIndex++) {
            msh.buffers[mesh::vb].mtlBuffers[slotIndex] = this->createBuffer(vertices, vbSize, vbAttrs.BufferUsage);
            o_assert_dbg(nil != msh.buffers[mesh::vb].mtlBuffers[slotIndex]);
        }
    }

    // create optional index buffer
    if (msh.indexBufferAttrs.Type != IndexType::None) {
        const auto& ibAttrs = msh.indexBufferAttrs;
        const int ibSize = ibAttrs.NumIndices * IndexType::ByteSize(ibAttrs.Type);
        msh.buffers[mesh::ib].numSlots = Usage::Immutable == ibAttrs.BufferUsage ? 1 : 2;
        const uint8* indices = nullptr;
        if (InvalidIndex != msh.Setup.DataIndexOffset) {
            indices = ptr + msh.Setup.DataIndexOffset;
            o_assert_dbg((ptr + size) >= (indices + ibSize));
        }
        for (uint8 slotIndex = 0; slotIndex < msh.buffers[mesh::ib].numSlots; slotIndex++) {
            msh.buffers[mesh::ib].mtlBuffers[slotIndex] = this->createBuffer(indices, ibSize, ibAttrs.BufferUsage);
            o_assert_dbg(nil != msh.buffers[mesh::ib].mtlBuffers[slotIndex]);
        }
    }
    return ResourceState::Valid;
}


//------------------------------------------------------------------------------
ResourceState::Code
mtlMeshFactory::createFullscreenQuad(mesh& msh) {

    VertexBufferAttrs vbAttrs;
    vbAttrs.NumVertices = 4;
    vbAttrs.BufferUsage = Usage::Immutable;
    vbAttrs.Layout.Add(VertexAttr::Position, VertexFormat::Float3);
    vbAttrs.Layout.Add(VertexAttr::TexCoord0, VertexFormat::Float2);
    msh.vertexBufferAttrs = vbAttrs;

    IndexBufferAttrs ibAttrs;
    ibAttrs.NumIndices = 6;
    ibAttrs.Type = IndexType::Index16;
    ibAttrs.BufferUsage = Usage::Immutable;
    msh.indexBufferAttrs = ibAttrs;

    msh.numPrimGroups = 1;
    msh.primGroups[0] = PrimitiveGroup(0, 6);

    const float topV = msh.Setup.FullScreenQuadFlipV ? 0.0f : 1.0f;
    const float botV = msh.Setup.FullScreenQuadFlipV ? 1.0f : 0.0f;
    float vertices[] = {
        -1.0f, +1.0f, 0.0f, 0.0f, topV,     // top-left corner
        +1.0f, +1.0f, 0.0f, 1.0f, topV,     // top-right corner
        +1.0f, -1.0f, 0.0f, 1.0f, botV,     // bottom-right corner
        -1.0f, -1.0f, 0.0f, 0.0f, botV,     // bottom-left corner
    };

    uint16_t indices[] = {
        0, 2, 1,            // topleft -> bottomright -> topright
        0, 3, 2,            // topleft -> bottomleft -> bottomright
    };

    msh.buffers[mesh::vb].mtlBuffers[0] = this->createBuffer(vertices, sizeof(vertices), Usage::Immutable);
    msh.buffers[mesh::ib].mtlBuffers[0] = this->createBuffer(indices, sizeof(indices), Usage::Immutable);

    return ResourceState::Valid;
}

} // namespace _priv
} // namespace Oryol
