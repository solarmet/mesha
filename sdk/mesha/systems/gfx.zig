//! The gfx system's contract: the device work that code off the render thread may ask for. The
//! device is the render thread's alone, so a caller appends a request (`tryRequest`, a row of
//! `commands.gfx`); the runtime's gfx system pipes the rows through its mailbox to the render
//! thread, copying what they point at, and the device applies them there, a destroy after every
//! frame recorded before it. A command that makes something answers its `reply` route with a
//! `ResourceUploadedMsg`, a frame or more later; a destroy answers nothing.
//!
//! The descriptors and the `GfxResource` handle are in `types`. The runtime's side is
//! `runtime/gfx.zig` and `runtime/gfx/`.
const std = @import("std");
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");

/// The descriptors and handles the commands carry.
pub const types = @import("gfx/types.zig");

/// What a create command's reply carries: the resource the device made.
pub const ResourceUploadedMsg = struct {
    /// The handle of what was made.
    resource: GfxResource,
};

/// One request of the device. Slices are borrowed for the call that appends the request, which
/// copies them. `reply` is where the handle of what was made is sent; left empty, nothing is sent.
pub const CmdPayload = union(enum) {
    /// Makes a render pipeline.
    create_pipeline: struct {
        /// What the pipeline is to be.
        desc: gfx_types.PipelineDescriptor,
        /// The size of its push data in bytes: a multiple of 4, `kMaxPushDataBytes` at most.
        push_data_size: u32,
        /// Where the pipeline's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },
    /// Makes a texture with no contents.
    create_texture: struct {
        /// What the texture is to be.
        desc: gfx_types.TextureDescriptor,
        /// Where the texture's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },
    /// Makes a sampler.
    create_sampler: struct {
        /// What the sampler is to be.
        desc: gfx_types.SamplerDescriptor,
        /// Where the sampler's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },
    /// Makes a dynamic uniform buffer.
    create_dynamic_buffer: struct {
        /// Its size in bytes; not zero.
        size: usize,
        /// Where the buffer's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Makes a buffer holding `data`.
    upload_buffer: struct {
        /// The buffer's contents, which give its size; not empty.
        data: []const u8,
        /// What the buffer is bound as.
        usage: gfx_types.BufferUsage,
        /// Where the buffer's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Makes a texture for sampling (`shader_read`) holding `data`.
    upload_texture: struct {
        /// The texels, four bytes each: `width * height * 4` bytes.
        data: []const u8,
        /// Width in texels; not zero.
        width: u32,
        /// Height in texels; not zero.
        height: u32,
        /// The texture's format.
        format: gfx_types.TextureFormat,
        /// Where the texture's handle is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Destroys a texture, after every frame recorded before the request.
    destroy_texture: struct {
        /// The texture's handle.
        handle: gfx_types.GfxResource,
    },
    /// Destroys a sampler, after every frame recorded before the request.
    destroy_sampler: struct {
        /// The sampler's handle.
        handle: gfx_types.GfxResource,
    },
};

/// What `validate` finds wrong with a command.
pub const ValidationError = error{
    /// A pipeline with no vertex shader words.
    EmptyVertexShader,
    /// A pipeline whose fragment shader is given and empty.
    EmptyFragmentShader,
    /// A pipeline with more than `MAX_COLOR_ATTACHMENTS` color formats.
    TooManyColorAttachments,
    /// A vertex layout with more than 16 attributes.
    TooManyVertexAttributes,
    /// Push data over `kMaxPushDataBytes`.
    PushDataTooLarge,
    /// Push data whose size is not a multiple of 4.
    PushDataMisaligned,
    /// A pipeline's depth format that is not a depth format.
    InvalidDepthFormat,
    /// A vertex layout with attributes and a stride of zero.
    InvalidVertexStride,
    /// A vertex attribute at a location of 16 or more.
    InvalidVertexLocation,
    /// A vertex attribute that ends past the stride.
    VertexAttributeOutOfStride,
    /// Two vertex attributes at one location.
    DuplicateVertexLocation,
    /// A pipeline with stencil state and no depth format that holds a stencil.
    InvalidStencilFormat,
    /// A texture whose usage does not go with its format: color with a depth format, or depth with
    /// a color format.
    IncompatibleTextureUsage,
    /// A destroy whose handle is not one of the kind destroyed.
    InvalidResourceHandle,
    /// A texture with a width or a height of zero.
    ZeroTextureExtent,
    /// A texture with no mip levels or no array layers.
    ZeroTextureSubresources,
    /// A texture with more mip levels than its size allows.
    TooManyTextureMipLevels,
    /// A dynamic buffer of no size.
    ZeroBufferSize,
    /// A buffer upload with no data.
    EmptyBufferUpload,
    /// A texture upload whose byte count overflows.
    TextureSizeOverflow,
    /// A texture upload whose data is not `width * height * 4` bytes.
    TextureDataLengthMismatch,
};

/// Checks what a command says of itself, the device apart. The runtime's mailbox checks every
/// command it is handed and takes a failure for a broken contract invariant, so a caller passing on
/// input it does not trust validates first.
pub fn validate(payload: CmdPayload) ValidationError!void {
    switch (payload) {
        .create_pipeline => |command| {
            if (command.desc.vertex_spirv.len == 0) return error.EmptyVertexShader;
            if (@as(usize, command.push_data_size) > gfx_types.kMaxPushDataBytes) return error.PushDataTooLarge;
            if (command.push_data_size % 4 != 0) return error.PushDataMisaligned;
            if (command.desc.fragment_spirv) |spirv| {
                if (spirv.len == 0) return error.EmptyFragmentShader;
            }
            if (command.desc.color_formats.len > gfx_types.MAX_COLOR_ATTACHMENTS)
                return error.TooManyColorAttachments;
            if (command.desc.depth_format) |depth_format| {
                if (!gfx_types.isDepthFormat(depth_format)) return error.InvalidDepthFormat;
            }
            if (command.desc.stencil != null and
                (command.desc.depth_format == null or !gfx_types.hasStencil(command.desc.depth_format.?)))
                return error.InvalidStencilFormat;
            if (command.desc.vertex_layout) |layout| {
                if (layout.attributes.len > 16) return error.TooManyVertexAttributes;
                if (layout.attributes.len > 0 and layout.stride == 0) return error.InvalidVertexStride;
                for (layout.attributes, 0..) |attribute, i| {
                    if (attribute.location >= 16) return error.InvalidVertexLocation;
                    const end = std.math.add(u32, attribute.offset, gfx_types.vertexFormatSize(attribute.format)) catch
                        return error.VertexAttributeOutOfStride;
                    if (end > layout.stride) return error.VertexAttributeOutOfStride;
                    for (layout.attributes[0..i]) |previous| {
                        if (previous.location == attribute.location) return error.DuplicateVertexLocation;
                    }
                }
            }
        },
        .create_texture => |command| {
            if (command.desc.width == 0 or command.desc.height == 0)
                return error.ZeroTextureExtent;
            if (command.desc.mip_levels == 0 or command.desc.array_layers == 0)
                return error.ZeroTextureSubresources;
            var max_extent = @max(command.desc.width, command.desc.height);
            var max_mip_levels: u32 = 1;
            while (max_extent > 1) : (max_mip_levels += 1) max_extent >>= 1;
            if (command.desc.mip_levels > max_mip_levels)
                return error.TooManyTextureMipLevels;
            const is_depth = gfx_types.isDepthFormat(command.desc.format);
            switch (command.desc.usage) {
                .color_attachment, .color_attachment_sampled => if (is_depth) return error.IncompatibleTextureUsage,
                .depth_attachment, .depth_attachment_sampled => if (!is_depth) return error.IncompatibleTextureUsage,
                .shader_write => if (is_depth) return error.IncompatibleTextureUsage,
                .shader_read => {},
            }
        },
        .create_dynamic_buffer => |command| {
            if (command.size == 0) return error.ZeroBufferSize;
        },
        .upload_buffer => |command| {
            if (command.data.len == 0) return error.EmptyBufferUpload;
        },
        .upload_texture => |command| {
            if (command.width == 0 or command.height == 0) return error.ZeroTextureExtent;

            const texels = std.math.mul(usize, @intCast(command.width), @intCast(command.height)) catch
                return error.TextureSizeOverflow;
            const byte_len = std.math.mul(usize, texels, 4) catch
                return error.TextureSizeOverflow;
            if (command.data.len != byte_len) return error.TextureDataLengthMismatch;
        },
        .destroy_texture => |command| {
            if (!gfx_types.isGfxResourceKind(command.handle, .texture)) return error.InvalidResourceHandle;
        },
        .destroy_sampler => |command| {
            if (!gfx_types.isGfxResourceKind(command.handle, .sampler)) return error.InvalidResourceHandle;
        },
        .create_sampler => {},
    }
}

/// `types`, by the name this file's declarations use.
pub const gfx_types = types;
/// `validate`, by another name.
pub const validateCommand = validate;
/// A handle to something the device made (`types.GfxResource`).
pub const GfxResource = types.GfxResource;

/// The table of gfx requests, a row each, which the runtime makes.
pub const commands_table_name = "commands.gfx";
/// `commands.gfx` as rows of `CmdPayload`.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the renderer for `wanted`, a row of `commands.gfx` applied after the frame's run is
/// flushed; what `wanted` points at is copied into the row. Fails when the row cannot be kept,
/// `MissingTable` before the runtime has made the table or the table's allocation error, as a
/// request whose loss the caller must answer for: a destroy leaks its object, an upload's requester
/// hears it failed.
pub fn tryRequest(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) !void {
    try Requests.of(memory, tables, commands_table_name).tryPush(wanted);
}

test "gfx payload validation rejects texture size mismatches and zero buffers" {
    const short_pixels = [_]u8{0} ** 3;
    const rgba_pixels = [_]u8{0} ** 4;
    try std.testing.expectError(error.TextureDataLengthMismatch, validate(.{
        .upload_texture = .{
            .data = &short_pixels,
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
        },
    }));
    try std.testing.expectError(error.ZeroBufferSize, validate(.{
        .create_dynamic_buffer = .{ .size = 0 },
    }));
    try validate(.{
        .upload_texture = .{
            .data = &rgba_pixels,
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
        },
    });
}

test "gfx texture descriptor validation matches current color and depth usage contract" {
    try validate(.{ .create_texture = .{ .desc = .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .color_attachment_sampled,
    } } });
    try validate(.{ .create_texture = .{ .desc = .{
        .width = 1,
        .height = 1,
        .format = .depth32_float,
        .usage = .depth_attachment,
    } } });
    try std.testing.expectError(error.ZeroTextureExtent, validate(.{ .create_texture = .{ .desc = .{
        .width = 0,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .shader_read,
    } } }));
    try std.testing.expectError(error.IncompatibleTextureUsage, validate(.{ .create_texture = .{ .desc = .{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .depth_attachment,
    } } }));
}

test "gfx texture descriptors validate mip and array dimensions" {
    const desc: gfx_types.TextureDescriptor = .{
        .width = 8,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .shader_read,
    };
    try validate(.{ .create_texture = .{ .desc = desc } });
    try std.testing.expectEqual(@as(u32, 1), desc.mip_levels);
    try std.testing.expectEqual(@as(u32, 1), desc.array_layers);
    try std.testing.expectError(error.ZeroTextureSubresources, validate(.{ .create_texture = .{ .desc = .{
        .width = 8,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .shader_read,
        .mip_levels = 0,
    } } }));
    try std.testing.expectError(error.ZeroTextureSubresources, validate(.{ .create_texture = .{ .desc = .{
        .width = 8,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .shader_read,
        .array_layers = 0,
    } } }));
    try std.testing.expectError(error.TooManyTextureMipLevels, validate(.{ .create_texture = .{ .desc = .{
        .width = 8,
        .height = 4,
        .format = .rgba8_unorm,
        .usage = .shader_read,
        .mip_levels = 5,
    } } }));
}

test "gfx payload validation rejects unsafe pipeline and texture descriptors" {
    const shader = [_]u32{1};
    try std.testing.expectError(error.PushDataTooLarge, validate(.{
        .create_pipeline = .{
            .desc = .{ .color_formats = &.{}, .vertex_spirv = &shader },
            .push_data_size = @intCast(gfx_types.kMaxPushDataBytes + 1),
        },
    }));
    try std.testing.expectError(error.PushDataMisaligned, validate(.{
        .create_pipeline = .{
            .desc = .{ .color_formats = &.{}, .vertex_spirv = &shader },
            .push_data_size = 3,
        },
    }));
    try std.testing.expectError(error.InvalidDepthFormat, validate(.{
        .create_pipeline = .{
            .desc = .{ .color_formats = &.{}, .depth_format = .rgba8_unorm, .vertex_spirv = &shader },
            .push_data_size = 0,
        },
    }));

    const attributes = [_]gfx_types.VertexAttribute{
        .{ .location = 0, .format = .float2, .offset = 12 },
    };
    try std.testing.expectError(error.VertexAttributeOutOfStride, validate(.{
        .create_pipeline = .{
            .desc = .{
                .color_formats = &.{},
                .vertex_spirv = &shader,
                .vertex_layout = .{ .stride = 16, .attributes = &attributes },
            },
            .push_data_size = 0,
        },
    }));
    const bad_location = [_]gfx_types.VertexAttribute{.{ .location = 16, .format = .float1, .offset = 0 }};
    try std.testing.expectError(error.InvalidVertexLocation, validate(.{
        .create_pipeline = .{
            .desc = .{
                .color_formats = &.{},
                .vertex_spirv = &shader,
                .vertex_layout = .{ .stride = 4, .attributes = &bad_location },
            },
            .push_data_size = 0,
        },
    }));

    try std.testing.expectError(error.InvalidStencilFormat, validate(.{
        .create_pipeline = .{
            .desc = .{
                .color_formats = &.{},
                .depth_format = .depth32_float,
                .stencil = .{ .func = .always, .front_pass_op = .keep },
                .vertex_spirv = &shader,
            },
            .push_data_size = 0,
        },
    }));

    try std.testing.expectError(error.IncompatibleTextureUsage, validate(.{
        .create_texture = .{ .desc = .{
            .width = 4,
            .height = 4,
            .format = .depth32_float,
            .usage = .color_attachment,
        } },
    }));

    const texture = gfx_types.makeGfxResource(.texture, 0, 1);
    try std.testing.expectError(error.InvalidResourceHandle, validate(.{
        .destroy_sampler = .{ .handle = texture },
    }));
    try std.testing.expectError(error.InvalidResourceHandle, validate(.{
        .destroy_texture = .{ .handle = .null_handle },
    }));
}
