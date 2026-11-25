//! The 2D renderer's recording, as `mesha.roop`: a `Context` records paths, paints, text and layers
//! into lists of draw data (`draw_list`), and the runtime's backend draws what was recorded, on the
//! render thread. The host makes every `Context`; code that draws (`ui`, a panel, a stage) records
//! into the one it is given and touches no device.
//!
//! This file gathers the names of `roop/`: the `Context` and its state, the paints and colors it
//! fills and strokes with, transforms, and what the runtime shares with recording (`Renderer` and
//! its image registry, `draw_list`, `layer_stream`, `layer_admission`).
/// The recording surface: transform and paint state, a path under construction, and the draw lists
/// that `fill`, `stroke` and `text` append to.
pub const Context = @import("roop/context.zig").Context;
/// One level of a `Context`'s save stack: its paints, stroke settings, transform, scissor and text
/// settings.
pub const State = @import("roop/context.zig").State;
/// The color and depth-stencil textures a `Context` renders into, which the runtime makes.
pub const RenderTarget = @import("roop/context.zig").RenderTarget;
/// What recording reads of the host's renderer: its fonts, its registered images and its layer
/// limit.
pub const Renderer = @import("roop/renderer.zig").Renderer;
/// A registered image: the texture and sampler a recording draws with under an image handle.
pub const ImageEntry = @import("roop/renderer.zig").ImageEntry;
/// Checks an image handle against the registered images and gives its index among them.
pub const validateImageHandle = @import("roop/renderer.zig").validateImageHandle;
/// Why the runtime could not register an image.
pub const ImageRegistrationError = @import("roop/renderer.zig").ImageRegistrationError;
/// Why an image handle names no image a recording may draw with.
pub const ImageHandleError = @import("roop/renderer.zig").ImageHandleError;
/// How many images may be registered in a run.
pub const max_images = @import("roop/renderer.zig").max_images;
/// The layer attachments one `Context` may hold live when the host's pool sets no other limit.
pub const default_document_live_attachments = @import("roop/renderer.zig").default_document_live_attachments;
/// What a recording writes for the backend: draw calls, the lists they index and the frame's
/// limits.
pub const draw_list = @import("roop/draw_list.zig");
/// A color in sRGB-encoded channels with straight alpha, each 0 to 1: what paints take.
pub const Color = @import("../core/color.zig").Color;
/// How a fill or a stroke is colored: a solid color, a gradient or an image pattern.
pub const Paint = @import("roop/paint.zig").Paint;
/// An image handle: 0 for none, else as the runtime registered it, from 1.
pub const Image = @import("roop/paint.zig").Image;
/// Options for an image, which nothing reads (see `paint.ImageFlags`).
pub const ImageFlags = @import("roop/paint.zig").ImageFlags;
/// A 2D affine transform as six floats (see `transform`).
pub const Transform2D = @import("roop/transform.zig").Transform2D;
/// Whether a subpath is a solid shape (`ccw`) or a hole (`cw`).
pub const Winding = @import("roop/path.zig").Winding;
/// How a stroke ends on an open subpath: `butt`, `round` or `square`.
pub const LineCap = @import("roop/context.zig").LineCap;
/// How a stroke turns a corner: `miter`, `round` or `bevel`.
pub const LineJoin = @import("roop/context.zig").LineJoin;
/// Where text sits against the point `Context.text` is given.
pub const Align = @import("roop/context.zig").Align;
/// How a layer's colors mix with what is beneath it (`paint.blend.Mode`).
pub const BlendMode = @import("roop/paint.zig").blend.Mode;
/// The Porter-Duff operation a layer is composited with (`paint.composite.Operation`).
pub const CompositeOperation = @import("roop/context.zig").CompositeOperation;
const resources_api = @import("resources.zig");
/// An interned name: here, a font's.
pub const Atom = resources_api.Atom;
/// The font a `Context` draws text in until `fontFace` names another: `default`, which the editor
/// loads.
pub const default_font: Atom = resources_api.kDefaultFontName;

/// A color in linear light with straight alpha: a type apart from `Color`, which no paint takes.
pub const LinearColor = @import("../core/color.zig").LinearColor;
/// An opaque `Color` from 8-bit sRGB channels.
pub const rgb = @import("../core/color.zig").rgb;
/// A `Color` from 8-bit sRGB channels and 8-bit straight alpha (255 opaque).
pub const rgba = @import("../core/color.zig").rgba;
/// An opaque `Color` from sRGB channels, each 0 to 1.
pub const rgbf = @import("../core/color.zig").rgbf;
/// A `Color` from sRGB channels and straight alpha, each 0 to 1.
pub const rgbaf = @import("../core/color.zig").rgbaf;
/// A `Color` with its alpha replaced by an 8-bit one (255 opaque).
pub const transRGBA = @import("../core/color.zig").transRGBA;
/// A `Color` with its alpha replaced by one from 0 to 1.
pub const transRGBAf = @import("../core/color.zig").transRGBAf;
/// Two `Color`s mixed channel by channel, as encoded: the first at 0, the second at 1.
pub const lerpRGBA = @import("../core/color.zig").lerpRGBA;
/// An opaque `Color` from hue (in turns, wrapping), saturation and lightness (0 to 1, clamped).
pub const hsl = @import("../core/color.zig").hsl;
/// As `hsl`, with an 8-bit straight alpha (255 opaque).
pub const hsla = @import("../core/color.zig").hsla;
/// A `Color` as `.{ r, g, b, a }`.
pub const colorToArray = @import("../core/color.zig").toArray;

/// A `Paint` of one color.
pub const solidColor = @import("roop/paint.zig").solidColor;
/// A `Paint` that runs from one color at a point to another at a second point.
pub const linearGradient = @import("roop/paint.zig").linearGradient;
/// A `Paint` that runs from one color inside an inner radius to another outside an outer one.
pub const radialGradient = @import("roop/paint.zig").radialGradient;
/// A `Paint` of a feathered rounded rectangle: one color inside, another outside.
pub const boxGradient = @import("roop/paint.zig").boxGradient;
/// A `Paint` that draws an image, placed, sized and rotated.
pub const imagePattern = @import("roop/paint.zig").imagePattern;

/// Paints, blends and compositing. The runtime's layer schedule reads its compositing rules
/// here; not part of what a plugin relies on beyond the names above.
pub const paint = @import("roop/paint.zig");
/// Constructors and algebra for `Transform2D`.
pub const transform = @import("roop/transform.zig");
/// Flattens a path's commands into points and classifies their joins: `Context.fill` and
/// `Context.stroke` call it.
pub const geometry = @import("roop/geometry.zig");
/// A path's commands, its flattened points and subpaths, and their limits.
pub const path = @import("roop/path.zig");

/// The layer markers a recording writes beside its draw calls.
pub const layer_stream = @import("roop/layer_stream.zig");
/// What drawing costs of a recording's capacities, and the ledgers the runtime's layer schedule
/// admits a frame's layers through.
pub const layer_admission = @import("roop/layer_admission.zig");

test {
    _ = @import("roop/context.zig");
    _ = @import("roop/draw_list.zig");
    _ = @import("roop/renderer.zig");
}
