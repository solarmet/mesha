//! What recording reads of the host's renderer: its fonts, its dummy image's slots, the images
//! registered for recordings to draw with and the layer limit, and the route by which drawing
//! asks resources for what it draws and finds missing. The runtime's `System` embeds one and
//! writes it, and every `Context` the host makes points at it.
const std = @import("std");
const gfx_types = @import("../gfx/types.zig");
const resources_api = @import("../resources.zig");
const contract = @import("../../core/contract.zig");
const memory_mod = @import("../../core/memory.zig");
const Table = @import("../../core/table.zig");
const sequencer = @import("../../core/sequencer.zig");
const Atom = resources_api.Atom;
const log = @import("../../core/log.zig");
const Log = log.scope("roop");

/// The tag of the reply a recording's inbox hears when a font it drew in before it was loaded
/// has loaded (`Context.redraw_inbox`): what drew with the engine's font in its place may draw
/// again. A `resources.ResourceMsg`.
pub const redraw_tag: Atom = Atom.from("redraw");

/// What drawing reaches of the host to ask resources for what it draws and finds missing, as
/// text in a font not loaded yet: the host's memory, tables and atoms, which outlive every
/// recording. Its requests land in `commands.resources` as a run's do and are applied after
/// the next run.
pub const Requests = struct {
    /// The host's memory, which resolves the application scope.
    memory: *memory_mod.Memory,
    /// The host's tables, which hold `commands.resources`.
    tables: *Table.Registry,
    /// The host's atoms, which learn the label of a font asked for so tables and logs name it.
    atoms: *Atom.Registry,
};

/// How many fonts drawing may have asked for and not yet found at once; past it, a font is
/// asked for again each time it is drawn until it loads.
pub const max_asked_fonts = 32;

/// A font drawing asked for, and the inbox its reply goes to.
const AskedFont = struct { name: Atom, inbox: Atom };

/// An image recordings draw with: a texture and sampler someone else made, which the thread
/// that records registers and retires, and the thread that renders reads.
pub const ImageEntry = struct {
    /// The image's texture, which whoever registered it made and destroys.
    texture: gfx_types.GfxResource,
    /// The sampler it is read through, likewise.
    sampler: gfx_types.GfxResource,
    /// How the shader reads a texel: 0 as premultiplied RGBA, as it is; 1 as straight RGBA, which
    /// it premultiplies; 2 as coverage in the red channel, as a font atlas holds.
    tex_type: i32,
    /// Not yet retired: recordings may name it. The recording thread's alone; rendering asks
    /// the device whether the texture is still there instead.
    active: bool = true,
};

/// How many images may be registered in a run: a handle is never reused, as a frame recorded
/// before a retirement may still be rendering with it. The runtime's, which `Renderer` uses
/// too; not part of what a plugin relies on.
pub const max_images = 16384;

/// Why the runtime's `wrapImage` registered nothing: `ImageHandleSpaceExhausted` when `max_images`
/// are registered; `InvalidImageResource` when the texture or the sampler is not a handle of its
/// kind, or `tex_type` is not 0, 1 or 2.
pub const ImageRegistrationError = error{ ImageHandleSpaceExhausted, InvalidImageResource };

/// Why a handle names no image to draw with: `InvalidImageHandle` for zero or one never registered,
/// `ImageReleased` for one retired.
pub const ImageHandleError = error{ InvalidImageHandle, ImageReleased };
/// An image's bindless slots. The runtime's, the type of `Renderer.dummy_slots`; not part of
/// what a plugin relies on.
pub const ImageSlots = struct { image: u32, sampler: u32 };

/// Layer scopes' attachments one Context may hold live, unless the host's pool says otherwise.
/// The runtime's, which `Renderer` uses too; not part of what a plugin relies on.
pub const default_document_live_attachments: u32 = 24;

/// What recording reads of the host's renderer. The runtime's `System` owns the one instance and is
/// its only writer; a `Context` reads it through `Context.renderer`.
pub const Renderer = struct {
    /// Where `Context.text` and the measuring functions find a font by name. Null, as before the
    /// host sets one (the runtime's `setFontProvider`), draws no text and measures zero.
    font_provider: ?resources_api.FontProvider = null,

    /// Where drawing asks resources for what it draws and does not find (`askFont`). Null, as
    /// before the host sets it (the runtime's `setRequests`) and in tests, asks for nothing.
    requests: ?Requests = null,
    /// The fonts drawing has asked for and not found loaded since, each with the inbox its reply
    /// goes to; the first `asked_font_count` are set. The recording thread's.
    asked_fonts: [max_asked_fonts]AskedFont = undefined,
    /// How many of `asked_fonts` are set.
    asked_font_count: u32 = 0,

    /// The dummy texture's and the sampler's bindless slots, so recording reads no device.
    /// The runtime's `System.init` sets them; zero before, as in tests that never render.
    dummy_slots: ImageSlots = .{ .image = 0, .sampler = 0 },

    /// Every image registered, by handle less one, `max_images` long so registering never
    /// moves an entry rendering reads. The first `image_count` are registered: each is written
    /// before the count takes it in, and only `active` changes after. The runtime's `System`
    /// allocates it and its `wrapImage` and `retireImage` write it.
    images: []ImageEntry = &.{},
    /// How many of `images` are registered. Atomic: the recording thread adds, the rendering thread
    /// reads.
    image_count: std.atomic.Value(u32) = .init(0),

    /// The layer target pool's `limits.document_live_attachments`, which is the source of
    /// truth: the runtime's `System.init` copies it here once, for `Context.pathBudget`.
    document_live_attachments: u32 = default_document_live_attachments,

    /// Asks resources to load `font`, which drawing did not find, with its reply to `inbox` under
    /// `redraw_tag`; `sequencer.no_inbox` wants no reply. A font already asked for with the same
    /// inbox is not asked for again until `forgetFont`; the first time a font is asked for, it is
    /// logged, as text drawn in the engine's font in its place. The recording thread's.
    pub fn askFont(self: *Renderer, font: resources_api.Font, inbox: Atom) void {
        const requests = self.requests orelse return;
        var named = false;
        for (self.asked_fonts[0..self.asked_font_count]) |asked| {
            if (asked.name != font.name) continue;
            named = true;
            if (asked.inbox == inbox) return;
        }
        if (!named) Log.warn("font_not_loaded", .{ .font = font.label });
        if (self.asked_font_count < max_asked_fonts) {
            self.asked_fonts[self.asked_font_count] = .{ .name = font.name, .inbox = inbox };
            self.asked_font_count += 1;
        }
        // So the row's name reads as the font in tables and logs; without it, it reads as a number.
        requests.atoms.tryInternAll(&.{font.label}) catch {};
        const scope = resources_api.applicationScope(requests.memory);
        const reply: sequencer.ReplyTo = if (inbox == sequencer.no_inbox) .{} else .{ .inbox = inbox, .tag = redraw_tag };
        resources_api.request(requests.memory, requests.tables, .{ .load_resource = .{ .scope = scope, .decl = font.decl(), .plugin = font.plugin, .reply = reply } });
    }

    /// Forgets that the font `name` was asked for, as once it is found loaded: should it go and be
    /// drawn again, it is asked for again.
    pub fn forgetFont(self: *Renderer, name: Atom) void {
        var index: u32 = 0;
        while (index < self.asked_font_count) {
            if (self.asked_fonts[index].name != name) {
                index += 1;
                continue;
            }
            self.asked_font_count -= 1;
            self.asked_fonts[index] = self.asked_fonts[self.asked_font_count];
        }
    }

    /// The images registered so far; on the rendering thread, at least every image a recording
    /// it was handed names.
    pub fn registeredImages(self: *const Renderer) []const ImageEntry {
        const count = self.image_count.load(.acquire);
        return self.images[0..count];
    }

    /// The `tex_type` of `image`; 0 for image 0, which is no image. A handle never registered or
    /// retired breaks the contract invariant `roop.image.tex_type.handle`.
    pub fn imageTexType(self: *const Renderer, image: u32) i32 {
        return self.imageTexTypeChecked(image) catch {
            contract.invariant(false, "roop.image.tex_type.handle");
            unreachable;
        };
    }

    /// As `imageTexType`, returning the handle's fault instead: `InvalidImageHandle` or
    /// `ImageReleased`.
    pub fn imageTexTypeChecked(self: *const Renderer, image: u32) ImageHandleError!i32 {
        if (image == 0) return 0;
        const images = self.registeredImages();
        const index = try validateImageHandle(image, images);
        return images[index].tex_type;
    }
};

/// The index in `entries` of the image `image` names, handles counting from 1. `InvalidImageHandle`
/// for zero or a handle past `entries`; `ImageReleased` for one whose entry is not active.
pub fn validateImageHandle(image: u32, entries: []const ImageEntry) ImageHandleError!usize {
    if (image == 0) return error.InvalidImageHandle;
    const index: usize = image - 1;
    if (index >= entries.len) return error.InvalidImageHandle;
    if (!entries[index].active) return error.ImageReleased;
    return index;
}

test "image handles are 1-based, bounded, and invalid after release" {
    const entries = [_]ImageEntry{
        .{ .texture = .null_handle, .sampler = .null_handle, .tex_type = 0 },
        .{ .texture = .null_handle, .sampler = .null_handle, .tex_type = 0, .active = false },
    };
    try std.testing.expectEqual(@as(usize, 0), try validateImageHandle(1, &entries));
    try std.testing.expectError(error.InvalidImageHandle, validateImageHandle(0, &entries));
    try std.testing.expectError(error.InvalidImageHandle, validateImageHandle(3, &entries));
    try std.testing.expectError(error.ImageReleased, validateImageHandle(2, &entries));
}
