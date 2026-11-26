//! The layer markers a recording writes beside its draw calls: what the runtime's schedule
//! (`runtime/roop/layer_stream.zig`) reads to isolate layers.
/// A rectangle in target pixels by two corners, `x0 <= x1` and `y0 <= y1`.
pub const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
/// A run of draw calls: `count` of them from index `first` in the recording's calls.
pub const Span = struct { first: u64, count: u64 };
/// What opens a layer (`Context.beginLayer`): how the layer's drawing, isolated, is composited onto
/// what is beneath it when the layer ends.
pub const Begin = struct {
    /// The layer's opacity when composited, 0 to 1.
    opacity: f32 = 1,
    /// The layer's extent in target pixels, whatever the transform; the schedule rounds it and
    /// keeps it within the enclosing scope's. Null takes the enclosing scope's bounds.
    bounds: ?Rect = null,
    /// How the layer's colors mix with what is beneath. A mode other than `normal` needs
    /// `composite` to be `source_over`; `unsupported` is refused.
    blend: @import("paint.zig").blend.Mode = .normal,
    /// The Porter-Duff operation the layer is composited with.
    composite: @import("paint.zig").composite.Operation = .source_over,
    /// Must be false: a mask is refused.
    mask: bool = false,
    /// What the scope is: every kind nests on the one stack. The runtime's schedule refuses `mask`.
    kind: enum { layer, instance, mask } = .layer,
};
/// One entry of a recording's layer stream, in order: `draw`, the calls recorded since the last
/// marker; `begin`, a layer opening; `end`, the innermost open layer closing.
pub const Op = union(enum) { draw: Span, begin: Begin, end };
