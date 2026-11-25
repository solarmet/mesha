//! A path as a `Context` holds it: the commands appended to it, already in target pixels, and their
//! flattened form (`PathCache`: points and the subpaths they make), which `geometry` fills in when
//! the path is filled or stroked. The limits here bound one path, not a frame.
const std = @import("std");

/// The most commands one path may hold.
pub const kMaxPathCommands: usize = 1 << 24;
/// The most subpaths one path may hold.
pub const kMaxPaths: usize = 1024;
/// The most points one path may flatten to.
pub const kMaxFlattenedPoints: usize = 1 << 24;

/// Whether `additional` more commands fit a path holding `current`; `TooManyCommands` when not.
pub fn validateCommandCapacity(current: usize, additional: usize) error{TooManyCommands}!void {
    if (current > kMaxPathCommands or additional > kMaxPathCommands - current) return error.TooManyCommands;
}

/// Whether `additional` more subpaths fit a path holding `current`; `TooManyPaths` when not.
pub fn validatePathCapacity(current: usize, additional: usize) error{TooManyPaths}!void {
    if (current > kMaxPaths or additional > kMaxPaths - current) return error.TooManyPaths;
}

/// Whether `additional` more points fit a path holding `current`; `TooManyPoints` when not.
pub fn validatePointCapacity(current: usize, additional: usize) error{TooManyPoints}!void {
    if (current > kMaxFlattenedPoints or additional > kMaxFlattenedPoints - current) return error.TooManyPoints;
}

/// The kinds of path command.
pub const CommandTag = enum(u8) {
    /// Starts a subpath at a point.
    move_to,
    /// A straight line from the current point.
    line_to,
    /// A cubic Bezier curve from the current point.
    bezier_to,
    /// Closes the current subpath: its last point joins its first.
    close,
    /// Sets the current subpath's winding.
    winding,
};

/// Whether a subpath is a solid shape or a hole: flattening orders its points by it, whichever way
/// they were given and whatever the transform mirrors.
pub const Winding = enum(i32) {
    /// A solid shape: what a subpath is until told otherwise.
    ccw = 1,
    /// A hole.
    cw = -1,
};

/// One path command, its coordinates in target pixels: the `Context`'s transform is applied as the
/// command is appended.
pub const Command = union(CommandTag) {
    /// The point `x, y` a subpath starts at.
    move_to: [2]f32,
    /// The point `x, y` a line runs to.
    line_to: [2]f32,
    /// The two control points and the end point: `c1x, c1y, c2x, c2y, x, y`.
    bezier_to: [6]f32,
    /// Closes the latest subpath.
    close: void,
    /// The latest subpath's winding.
    winding: Winding,
};

/// What flattening and join classification found at a point. The tessellation shader reads the bits
/// by position.
pub const PointFlag = packed struct(u8) {
    /// A point a path command ended at, not one a curve was divided into.
    corner: bool = false,
    /// The path turns left here.
    left: bool = false,
    /// The join here is beveled: its miter would pass the miter limit, or the join style is `bevel`
    /// or `round`.
    bevel: bool = false,
    /// The join's inner side is beveled: its neighbouring segments are too short for the miter.
    innerbevel: bool = false,
    /// Unused bits, zero.
    _pad: u4 = 0,
};

/// A flattened point, in target pixels.
pub const Point = struct {
    /// Position along x.
    x: f32,
    /// Position along y.
    y: f32,
    /// The unit direction to the next point, along x; zero when the next point is this one.
    dx: f32 = 0,
    /// The unit direction to the next point, along y.
    dy: f32 = 0,
    /// The distance to the next point.
    len: f32 = 0,
    /// The miter direction at this point, along x: the mean of the two segments' normals, scaled so
    /// that a stroke's edge lies along it (the scale is limited to 600).
    dmx: f32 = 0,
    /// The miter direction at this point, along y.
    dmy: f32 = 0,
    /// What was found here.
    flags: PointFlag = .{},
};

/// One subpath of a flattened path: a run of a `PathCache`'s points.
pub const SubPath = struct {
    /// The index of its first point in `PathCache.points`.
    first: u32,
    /// How many points it has. A closed subpath's last point is dropped when it repeats the first.
    count: u32,
    /// Whether its last point joins its first.
    closed: bool,
    /// Solid or hole, as the path's commands said.
    winding: Winding,

    /// Unused: nothing writes or reads it.
    fill_first: u32 = 0,
    /// Its point count, set by `geometry.expandFill` when it has three points or more.
    fill_count: u32 = 0,
    /// Unused: nothing writes or reads it.
    stroke_first: u32 = 0,
    /// Unused: nothing writes or reads it.
    stroke_count: u32 = 0,
    /// Whether every join turns left: with one such subpath a fill is drawn without the stencil.
    convex: bool = false,

    /// Whether every join turns the same way, left or right.
    geom_convex: bool = false,

    /// The order of its points as flattening left them: the polygon's signed area is not positive.
    /// The tessellation shader takes it for the side the inside is on.
    ccw: bool = true,
};

test "path command, subpath, and flattened-point capacities are bounded" {
    try validateCommandCapacity(kMaxPathCommands - 1, 1);
    try std.testing.expectError(error.TooManyCommands, validateCommandCapacity(kMaxPathCommands, 1));
    try validatePathCapacity(kMaxPaths - 1, 1);
    try std.testing.expectError(error.TooManyPaths, validatePathCapacity(kMaxPaths, 1));
    try validatePointCapacity(kMaxFlattenedPoints - 1, 1);
    try std.testing.expectError(error.TooManyPoints, validatePointCapacity(kMaxFlattenedPoints, 1));
}

/// A path's flattened form: every subpath's points in one list. Its lists are its owner's, grown
/// with the owner's allocator: it keeps none of its own.
pub const PathCache = struct {
    /// Every subpath's points, each subpath's together.
    points: std.ArrayList(Point),
    /// The subpaths, in the order their `move_to`s came.
    paths: std.ArrayList(SubPath),

    /// The points' bounding box in target pixels, `.{ min_x, min_y, max_x, max_y }`, as the last
    /// flattening left it.
    bounds: [4]f32 = .{ 0, 0, 0, 0 },

    /// A cache holding nothing and no memory.
    pub const empty: PathCache = .{ .points = .empty, .paths = .empty };

    /// Frees both lists with `allocator`, which must be the one they grew with.
    pub fn deinit(self: *PathCache, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.paths.deinit(allocator);
    }

    /// Empties both lists, keeping their memory.
    pub fn reset(self: *PathCache) void {
        self.points.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
    }
};
