//! The descriptors and handles the gfx commands carry (`gfx.CmdPayload`): what a buffer, a texture,
//! a sampler or a pipeline is to be, and the `GfxResource` handle that names one once the device
//! has made it. Data only: the device that reads them is the runtime's (`runtime/gfx/`).
const std = @import("std");
const contract = @import("../../core/contract.zig");

/// What a buffer is bound as.
pub const BufferUsage = enum {
    /// Vertex data.
    vertex,
    /// Index data.
    index,
    /// Uniform data.
    uniform,
    /// A storage buffer shaders read.
    storage,
    /// Indirect draw arguments.
    indirect,

    /// Indirect draw arguments that a shader also writes as a storage buffer.
    indirect_storage,
};

/// A texture's texel format.
pub const TextureFormat = enum {
    /// Four 8-bit channels, blue first.
    bgra8_unorm,
    /// Four 8-bit channels, red first.
    rgba8_unorm,
    /// 32-bit float depth, no stencil.
    depth32_float,
    /// 24-bit depth with 8-bit stencil.
    depth24_unorm_stencil8,
    /// 32-bit float depth with 8-bit stencil.
    depth32_float_stencil8,
};

/// Whether `f` holds a stencil.
pub fn hasStencil(f: TextureFormat) bool {
    return f == .depth24_unorm_stencil8 or f == .depth32_float_stencil8;
}

/// Whether `f` is a depth format, with or without stencil.
pub fn isDepthFormat(f: TextureFormat) bool {
    return f == .depth32_float or hasStencil(f);
}

/// What a texture is for. `gfx.validate` holds a color usage to a color format and a depth usage to
/// a depth format.
pub const TextureUsage = enum {
    /// Rendered into as color.
    color_attachment,
    /// Rendered into as color, and sampled.
    color_attachment_sampled,
    /// Rendered into as depth and stencil.
    depth_attachment,
    /// Rendered into as depth and stencil, and sampled.
    depth_attachment_sampled,
    /// Sampled, its texels uploaded: an image. Any format.
    shader_read,
    /// Written by a shader as a storage image. A color format.
    shader_write,
};

/// What else may be done with a texture, beyond its `TextureUsage`.
pub const TextureCapabilities = packed struct(u8) {
    /// May be copied from, as a readback is.
    transfer_src: bool = false,
    /// May be copied into.
    transfer_dst: bool = false,
    /// Unused bits, zero.
    _padding: u6 = 0,
};

/// What a texture is to be.
pub const TextureDescriptor = struct {
    /// Width in texels; not zero.
    width: u32,
    /// Height in texels; not zero.
    height: u32,
    /// Its texel format.
    format: TextureFormat,
    /// What it is for.
    usage: TextureUsage,
    /// How many mip levels, from 1 to as many as halve the larger side down to one texel.
    mip_levels: u32 = 1,
    /// How many array layers; not zero.
    array_layers: u32 = 1,
    /// What else may be done with it.
    capabilities: TextureCapabilities = .{},

    /// The width and height of mip `mip_level`, each halved for every level and never under 1; null
    /// for a level the texture lacks or a texture with no extent.
    pub fn extentAtMip(self: TextureDescriptor, mip_level: u32) ?[2]u32 {
        if (mip_level >= self.mip_levels or self.width == 0 or self.height == 0) return null;
        return .{ @max(1, self.width >> @intCast(@min(mip_level, 31))), @max(1, self.height >> @intCast(@min(mip_level, 31))) };
    }
};

/// A vertex attribute's type: one to four 32-bit floats.
pub const VertexFormat = enum { float1, float2, float3, float4 };

/// The most bytes of push data a pipeline may take.
pub const kMaxPushDataBytes: usize = 128;

/// The size of `format` in bytes.
pub fn vertexFormatSize(format: VertexFormat) u32 {
    return switch (format) {
        .float1 => 4,
        .float2 => 8,
        .float3 => 12,
        .float4 => 16,
    };
}

/// One attribute of a vertex layout.
pub const VertexAttribute = struct {
    /// Its shader location, 0 to 15, one attribute to a location.
    location: u32,
    /// Its type.
    format: VertexFormat,
    /// Where it starts in a vertex, in bytes; it must end within the stride.
    offset: u32,
};

/// How a pipeline's vertex buffer is laid out.
pub const VertexLayout = struct {
    /// The bytes from one vertex to the next; not zero when there are attributes.
    stride: u32,
    /// The attributes, 16 at most. Borrowed: a command copies them when it is stored.
    attributes: []const VertexAttribute,
};

/// A handle to something the device made: its `ResourceKind` in the top 4 bits, a generation, never
/// zero, in the next 12, and an index in the low 16. A handle whose object is destroyed goes stale:
/// its slot's next object has another generation.
pub const GfxResource = enum(u32) {
    /// No resource.
    null_handle = 0,
    _,
};

/// The runtime's bounds on a handle's index and generation, which `makeGfxResource` checks;
/// not part of what a plugin relies on.
pub const kMaxResourceIndex: u32 = 0xFFFF;
/// The greatest generation a handle holds. The runtime's, as `kMaxResourceIndex`.
pub const kMaxResourceGeneration: u16 = 0x0FFF;

/// What kind of object a handle names.
pub const ResourceKind = enum(u4) {
    /// A render pipeline.
    pipeline = 0,
    /// A texture.
    texture = 1,
    /// A sampler.
    sampler = 2,
    /// A dynamic buffer, as `create_dynamic_buffer` makes.
    dynamic_buffer = 3,
    /// A buffer.
    buffer = 4,
    /// A compute pipeline.
    compute_pipeline = 5,
};

/// The handle of the `kind` object at `index` with `generation`. The runtime's pools make handles;
/// an index over `kMaxResourceIndex`, or a generation of zero or over `kMaxResourceGeneration`,
/// breaks a contract invariant.
pub fn makeGfxResource(kind: ResourceKind, index: u32, generation: u16) GfxResource {
    contract.invariant(index <= kMaxResourceIndex, "gfx.resource.index_fits_handle");
    contract.invariant(generation > 0 and generation <= kMaxResourceGeneration, "gfx.resource.generation_valid");
    const k = @as(u32, @intFromEnum(kind)) << 28;
    const g = @as(u32, generation) << 16;
    return @enumFromInt(k | g | index);
}

/// Whether `h` is shaped as a handle of kind `expected`: not null, that kind, a generation that is
/// not zero. It does not ask the device whether the object still exists.
pub fn isGfxResourceKind(h: GfxResource, expected: ResourceKind) bool {
    const raw = @intFromEnum(h);
    const kind_bits = (raw >> 28) & 0x0F;
    const generation = (raw >> 16) & 0x0FFF;
    return raw != 0 and kind_bits == @intFromEnum(expected) and generation != 0;
}

/// How texels are read between their centers: the nearest one, or a linear blend.
pub const SamplerFilter = enum { nearest, linear };

/// What a sampler reads outside 0 to 1.
pub const SamplerAddressMode = enum {
    /// The texture again.
    repeat,
    /// The texture again, mirrored each time.
    mirror_repeat,
    /// The edge texel.
    clamp_to_edge,
    /// The border color.
    clamp_to_border,
};

/// The color `clamp_to_border` reads.
pub const SamplerBorderColor = enum {
    /// Black with zero alpha.
    transparent_black,
    /// Black.
    opaque_black,
    /// White.
    opaque_white,
};

/// What a sampler is to be. The defaults blend linearly and repeat.
pub const SamplerDescriptor = struct {
    /// The filter when the texture is drawn smaller.
    min_filter: SamplerFilter = .linear,
    /// The filter when the texture is drawn larger.
    mag_filter: SamplerFilter = .linear,
    /// The filter between mip levels.
    mipmap_filter: SamplerFilter = .nearest,
    /// The addressing along u.
    address_mode_u: SamplerAddressMode = .repeat,
    /// The addressing along v.
    address_mode_v: SamplerAddressMode = .repeat,
    /// The addressing along w.
    address_mode_w: SamplerAddressMode = .repeat,
    /// The color read under `clamp_to_border`.
    border_color: SamplerBorderColor = .opaque_white,
};

/// How a pipeline's output combines with the target. Sources are premultiplied.
pub const BlendMode = enum {
    /// Source over destination: ordinary drawing.
    alpha_premultiplied,
    /// The source where the destination is.
    source_in,
    /// The source where the destination is not.
    source_out,
    /// The source over the destination, only where the destination is.
    atop,
    /// The destination over the source.
    destination_over,
    /// The destination where the source is.
    destination_in,
    /// The destination where the source is not.
    destination_out,
    /// The destination over the source, only where the source is.
    destination_atop,
    /// The sum of the two.
    lighter,
    /// The source alone.
    copy,
    /// Each where the other is not.
    xor,
};

/// What a fragment that passes does to the stencil: `keep` it, set it to `zero`, or add or take
/// one, wrapping.
pub const StencilOp = enum { keep, zero, incr_wrap, decr_wrap };
/// How the stencil is tested against the reference: `always` passes, or it must be `equal` or
/// `not_equal`.
pub const StencilFunc = enum { always, equal, not_equal };

/// A pipeline's stencil test and what passing it writes.
pub const StencilState = struct {
    /// The test.
    func: StencilFunc,
    /// What a passing fragment of a front face does to the stencil.
    front_pass_op: StencilOp,
    /// What a passing fragment of a back face does to the stencil.
    back_pass_op: StencilOp = .keep,
    /// The stencil bits that may be written.
    write_mask: u8 = 0xff,
    /// Whether the pipeline writes color; false writes the stencil alone.
    color_write: bool = true,
};

/// What a render pipeline is to be. Its slices are borrowed: a command copies them when it is
/// stored.
pub const PipelineDescriptor = struct {
    /// The formats of the color attachments it draws into, `MAX_COLOR_ATTACHMENTS` at most.
    color_formats: []const TextureFormat,
    /// The depth attachment's format, or null for none; a depth format.
    depth_format: ?TextureFormat = null,
    /// Whether depth is tested and written, when there is a depth format.
    depth_test: bool = true,
    /// The stencil state, or null for none; it needs a depth format that holds a stencil.
    stencil: ?StencilState = null,
    /// The vertex shader as SPIR-V words; not empty.
    vertex_spirv: []const u32,
    /// The fragment shader as SPIR-V words, or null for none; not empty when given.
    fragment_spirv: ?[]const u32 = null,
    /// The vertex shader's entry point.
    vertex_entry: [*:0]const u8 = "main",
    /// The fragment shader's entry point.
    fragment_entry: [*:0]const u8 = "main",
    /// The vertex buffer's layout, or null for a pipeline that binds none.
    vertex_layout: ?VertexLayout = null,
    /// How output combines with the target, or null for no blending.
    blend: ?BlendMode = null,
    /// Whether both faces are drawn; false culls back faces.
    cull_mode_none: bool = false,
};

/// The most color attachments a pipeline or a pass may have.
pub const MAX_COLOR_ATTACHMENTS: usize = 4;

test "texture descriptor derives clamped mip extents" {
    const desc = TextureDescriptor{ .width = 7, .height = 3, .format = .rgba8_unorm, .usage = .shader_read, .mip_levels = 3 };
    try std.testing.expectEqual([2]u32{ 7, 3 }, desc.extentAtMip(0).?);
    try std.testing.expectEqual([2]u32{ 3, 1 }, desc.extentAtMip(1).?);
    try std.testing.expectEqual([2]u32{ 1, 1 }, desc.extentAtMip(2).?);
    try std.testing.expect(desc.extentAtMip(3) == null);
}
