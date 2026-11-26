//! Draw-mode tools. Drafts/configuration are inspectable tables, never hidden globals.
const std = @import("std");
const mesha = @import("mesha");
const modes = @import("../modes.zig");
const math = mesha.math;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const figure = mesha.figure;
const roop = mesha.roop;
const controls = @import("../ui/style.zig").canvas_controls;
const geometry = @import("geometry.zig");
const session = @import("session.zig");
const watches = @import("watches.zig");
const preview = @import("preview.zig");
const weight = @import("weight.zig");
const api = plugin.figure_api;
const transport = @import("commands.zig");
const selection = @import("selection.zig");
const prompts = @import("prompts.zig");
const gesture = @import("gesture.zig");
const os = mesha.os;
const color_picker = @import("color_picker.zig");
const sequencer = mesha.sequencer;
const pose = @import("pose.zig");
const view = @import("view.zig");
const workspace = @import("workspace.zig");
const asks = @import("asks.zig");

// ---- the system -----------------------------------------------------------------------------

/// Drawing in design mode: the drawing tools, editing points, the clipboard, layers, tool
/// options, and the fill and stroke colors with their popover.
pub fn system() sequencer.System {
    return .{
        .name = "figure_drawing",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claims,
        .active = workspace.shown,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_drawing.take_answers", .run = takeAnswers },
            .{ .name = "figure_drawing.take_actions", .run = takeActions },
            .{ .name = "figure_drawing.follow_selection", .run = followSelection },
            .{ .name = "figure_drawing.ask_paint_handles", .run = askPaintHandles },
        },
    };
}

/// The tags of the drawing tools' actions, their options' among them.
pub const Msg = enum(u64) {
    figure_tool_pen = Atom.from("figure_tool_pen").value(),
    figure_tool_rect = Atom.from("figure_tool_rect").value(),
    figure_tool_ellipse = Atom.from("figure_tool_ellipse").value(),
    figure_tool_line = Atom.from("figure_tool_line").value(),
    figure_tool_polygon = Atom.from("figure_tool_polygon").value(),
    figure_tool_pencil = Atom.from("figure_tool_pencil").value(),
    figure_edit_points = Atom.from("figure_edit_points").value(),
    figure_edit_points_done = Atom.from("figure_edit_points_done").value(),
    figure_tool_joint_fill = Atom.from("figure_tool_joint_fill").value(),
    figure_tool_gradient = Atom.from("figure_tool_gradient").value(),
    figure_tool_radial = Atom.from("figure_tool_radial").value(),
    figure_tool_eyedropper = Atom.from("figure_tool_eyedropper").value(),
    figure_tool_eraser = Atom.from("figure_tool_eraser").value(),
    figure_draft_backspace = Atom.from("figure_draft_backspace").value(),
    figure_polygon_more = Atom.from("figure_polygon_more").value(),
    figure_polygon_less = Atom.from("figure_polygon_less").value(),
    figure_point_delete = Atom.from("figure_point_delete").value(),
    figure_point_smooth = Atom.from("figure_point_smooth").value(),
    figure_point_corner = Atom.from("figure_point_corner").value(),
    figure_point_make_smooth = Atom.from("figure_point_make_smooth").value(),
    figure_point_mirror = Atom.from("figure_point_mirror").value(),
    figure_path_closed = Atom.from("figure_path_closed").value(),
    figure_point_x = Atom.from("figure_point_x").value(),
    figure_point_y = Atom.from("figure_point_y").value(),
    figure_layer_add = Atom.from("figure_layer_add").value(),
    figure_layer_delete = Atom.from("figure_layer_delete").value(),
    figure_layer_up = Atom.from("figure_layer_up").value(),
    figure_layer_down = Atom.from("figure_layer_down").value(),
    figure_shape_forward = Atom.from("figure_shape_forward").value(),
    figure_shape_backward = Atom.from("figure_shape_backward").value(),
    figure_shape_front = Atom.from("figure_shape_front").value(),
    figure_shape_back = Atom.from("figure_shape_back").value(),
    figure_shapes_to_layer = Atom.from("figure_shapes_to_layer").value(),
    figure_shape_delete = Atom.from("figure_shape_delete").value(),
    figure_copy = Atom.from("figure_copy").value(),
    figure_cut = Atom.from("figure_cut").value(),
    figure_paste = Atom.from("figure_paste").value(),
    figure_duplicate = Atom.from("figure_duplicate").value(),
    figure_fill_toggle = Atom.from("figure_fill_toggle").value(),
    figure_stroke_toggle = Atom.from("figure_stroke_toggle").value(),
    figure_corner_radius = Atom.from("figure_corner_radius").value(),
    figure_polygon_sides = Atom.from("figure_polygon_sides").value(),
    figure_pencil_spacing = Atom.from("figure_pencil_spacing").value(),
    figure_pencil_simplify = Atom.from("figure_pencil_simplify").value(),
    figure_pencil_error = Atom.from("figure_pencil_error").value(),
    figure_pencil_close = Atom.from("figure_pencil_close").value(),
    _,
};

/// Its own actions, and the color popover's actions and swatches; the pointer over the
/// popover is the canvas's.
fn claims(tag: Atom) bool {
    switch (tag.to(Msg)) {
        _ => {},
        else => return true,
    }
    return switch (tag.to(color_picker.Msg)) {
        .figure_color_down, .figure_color_move, .figure_color_up, .figure_color_cancel, _ => false,
        else => true,
    };
}

/// Actions reach the drawing tables, the selection, the requests they send, and the prompts
/// they open, and stop weight painting and the IK tool. Following the selection writes the
/// color popover, the point editor and, while either is in use, their rows. The gradient tools
/// ask where the selected paint lies, and the clipboard's actions what they copy.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    result.writeAll(&.{ groups.editor, groups.draw, Atom.from(color_picker.name) });
    result.writeAll(&groups.selected);
    result.write(Atom.from(color_picker.targets_name));
    const tool = session.get(frame.tables).tool.*;
    const gradient_tool = tool == names.gradient or tool == names.radial;
    if (gradient_tool or frame.messages.len != 0) groups.declareAsking(&result, frame.tables);
    if (frame.messages.len == 0) return result;
    result.writeAll(&groups.state);
    result.writeAll(&groups.drawing_rows);
    result.writeAll(&.{ groups.commands, groups.figure_requests, groups.palette_requests, Atom.from(weight.bones_name) });
    return result;
}

fn takeActions(pass: *sequencer.Pass) !void {
    try workspace.takeToolActions(pass, claims, runAction);
}

fn runAction(frame: *const sequencer.Frame, received: sequencer.Message) !void {
    const tables = frame.tables;
    const atoms = frame.atoms;
    if (try color_picker.handleAction(frame.memory, tables, atoms, received)) return;
    const tag = received.tag;
    const message = tag.to(Msg);
    for (std.enums.values(ToolOption)) |option| {
        if (message != option.details().action) continue;
        try prompts.showDrawingOption(frame.memory, tables, atoms, option);
        return;
    }
    switch (message) {
        .figure_point_x, .figure_point_y => {
            const axis: PointAxis = if (message == .figure_point_x) .x else .y;
            try prompts.showPointCoordinate(frame.memory, tables, atoms, axis);
            return;
        },
        // While the IK tool is out, the keys that change a polygon's sides change its chain.
        .figure_polygon_more, .figure_polygon_less => if (try pose.handleAction(tables, atoms, tag)) return,
        else => {},
    }
    if (!try handleAction(tables, atoms, tag)) return;
    switch (message) {
        .figure_edit_points, .figure_edit_points_done => view.clearCanvasHover(tables),
        else => {},
    }
}

/// Closes the color popover when what it colors is gone, and the point editor when its
/// path is.
fn followSelection(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    color_picker.sync(tables, atoms);
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    syncPointEditingWithReads(&reads);
}

/// The answers to the drawing system's questions: where the gradient tools' paint lies, and the
/// bytes the clipboard's actions copied.
fn takeAnswers(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const asked = asks.rows(tables);
    for (pass.frame.messages) |received| {
        const document = session.get(tables).doc.*;
        const answer = asks.take(asked, document, received) orelse continue;
        switch (answer.purpose) {
            .paint_handles => {
                const settings = config(tables);
                paintHandlesAnswered(settings, answer);
            },
            // A copy that failed is told as the action's own failure is (`workspace.reject`).
            .clipboard => clipboardAnswered(tables, atoms, answer) catch |err| {
                const session_table = session.table(tables);
                const editor = session.get(tables);
                const feedback = session.feedback(tables);
                const motion_view = session.motion(tables);
                workspace.reject(session_table, editor, feedback, motion_view, err);
            },
            else => {},
        }
    }
}

/// The paint whose handles the gradient tools show: the selected shape's fill or stroke paint, as
/// the colour target picks.
const PaintKey = struct { doc: Atom, shape: u32, paint: u32 };

fn selectedPaint(tables: *Table.Registry, atoms: *Atom.Registry) ?PaintKey {
    const editor = session.get(tables);
    const tool = editor.tool.*;
    if (tool != names.gradient and tool != names.radial) return null;
    const shape = primaryShape(tables, atoms) orelse return null;
    const settings = config(tables);
    const paint = if (settings.color_target.* == names.stroke) shape.stroke_paint else shape.fill_paint;
    if (paint == 0) return null;
    return .{ .doc = editor.doc.*, .shape = shape.id, .paint = paint };
}

/// Asks where the selected shape's paint lies whenever the selection, the colour target or what
/// the canvas shows (`preview.Data.version`) changed since it last asked, for the gradient tools'
/// handles (`paintHandlesAnswered`). Handles of the paint already shown stay until the answer
/// replaces them; another paint's are dropped at once. A question that cannot be asked never
/// fails the run.
fn askPaintHandles(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const settings = config(tables);
    const wanted = selectedPaint(tables, atoms) orelse {
        if (settings.handles_shape.* == 0) return;
        settings.handles_doc.* = session.none;
        settings.handles_shape.* = 0;
        settings.handles_paint.* = 0;
        settings.handles_known.* = 0;
        return;
    };
    const version = preview.state(tables).version.*;
    const same_paint = settings.handles_doc.* == wanted.doc and settings.handles_shape.* == wanted.shape and settings.handles_paint.* == wanted.paint;
    if (same_paint and settings.handles_version.* == version) return;
    const question: asks.Question = .{ .purpose = .paint_handles, .point = session.zero, .value = wanted.shape };
    const asker = system();
    asks.paintMapping(tables, atoms, asker, question, wanted.shape, wanted.paint, null) catch |err| switch (err) {
        // A question refused as asked, or with nowhere to go, is not asked again until the
        // paint or what the canvas shows changes; meanwhile no handles show.
        error.InvalidInput, error.NotInitialized => {
            settings.handles_known.* = 0;
            settings.handles_doc.* = wanted.doc;
            settings.handles_shape.* = wanted.shape;
            settings.handles_paint.* = wanted.paint;
            settings.handles_version.* = version;
            return;
        },
        // Not yet shown, or no room to ask: asked again next frame. The run goes on either way.
        else => return,
    };
    if (!same_paint) settings.handles_known.* = 0;
    settings.handles_doc.* = wanted.doc;
    settings.handles_shape.* = wanted.shape;
    settings.handles_paint.* = wanted.paint;
    settings.handles_version.* = version;
}

/// Keeps where the asked paint lies for the gradient tools' handles; a failed answer shows none.
fn paintHandlesAnswered(settings: ConfigView, answer: asks.Answer) void {
    if (answer.value != settings.handles_shape.*) return;
    answer.failure.check() catch {
        settings.handles_known.* = 0;
        return;
    };
    const mapped = answer.paint();
    const start = mapped.start orelse {
        settings.handles_known.* = 0;
        return;
    };
    const end = mapped.end orelse {
        settings.handles_known.* = 0;
        return;
    };
    settings.handles_start.* = start;
    settings.handles_end.* = end;
    settings.handles_known.* = 1;
}

/// Where `shape`'s `paint` lies as the gradient tools last heard it, or null while unknown.
fn paintHandles(settings: ConfigView, editor: session.View, shape: u32, paint: u32) ?struct { start: session.Vec2, end: session.Vec2 } {
    if (settings.handles_known.* == 0) return null;
    const same_paint = settings.handles_doc.* == editor.doc.* and settings.handles_shape.* == shape and settings.handles_paint.* == paint;
    if (!same_paint) return null;
    return .{ .start = settings.handles_start.*, .end = settings.handles_end.* };
}

pub const config_name = "editor_figure_draw";
pub const Config = struct {
    fill_color: session.Color = .{ 152, 196, 239, 255 },
    stroke_color: session.Color = .{ 104, 110, 133, 255 },
    stroke_width: f32 = 2,
    fill_enabled: u8 = 1,
    stroke_enabled: u8 = 1,
    opacity: f32 = 1,
    cap: Atom = Atom.from("round"),
    join: Atom = Atom.from("round"),
    corner_radius: f32 = 0,
    polygon_sides: u32 = 5,
    pencil_spacing: f32 = 2,
    pencil_simplify: f32 = 0.7,
    pencil_error: f32 = 1,
    pencil_close: f32 = 10,
    creation_doc: Atom = session.none,
    creation_request: u32 = 0,
    creation_tool: Atom = session.none,
    primitive_layer: u32 = 0,
    locked_tool: Atom = session.none,
    tool_tap_remaining: f32 = 0,
    pen_press_count: u32 = 0,
    pen_press_point: session.Vec2 = session.zero,
    pivot: session.Vec2 = session.zero,
    custom_pivot: u8 = 0,
    pivot_version: u64 = 0,
    pivot_before: session.Vec2 = session.zero,
    pivot_custom_before: u8 = 0,
    transform_handle: u8 = 0,
    transform_min: session.Vec2 = session.zero,
    transform_max: session.Vec2 = session.zero,
    transform_pivot: session.Vec2 = session.zero,
    point_shape: u32 = 0,
    point_index: u32 = 0,
    point_handle: u32 = 0,
    point_anchor: session.Vec2 = session.zero,
    point_in: session.Vec2 = session.zero,
    point_out: session.Vec2 = session.zero,
    point_flags: u32 = 0,
    point_width: f32 = 1,
    edit_doc: Atom = session.none,
    edit_shape: u32 = 0,
    edit_point_count: u32 = 0,
    sampled_color: session.Color = .{ 0, 0, 0, 0 },
    color_target: Atom = Atom.from("fill"),
    pending_delete_layer: u32 = 0,
    eraser_point: session.Vec2 = session.zero,
    eraser_sent: u32 = 0,
    /// The paint whose handles the gradient tools draw and press (`askPaintHandles`): its
    /// document, shape and paint, and the `preview.Data.version` it was last asked at.
    handles_doc: Atom = session.none,
    handles_shape: u32 = 0,
    handles_paint: u32 = 0,
    handles_version: u64 = 0,
    /// Whether `handles_start` and `handles_end` hold where that paint lies, as posed.
    handles_known: u8 = 0,
    handles_start: session.Vec2 = session.zero,
    handles_end: session.Vec2 = session.zero,
    /// A released gradient drag waiting for its points in the paint's space
    /// (`gradientAnswered`): its shape (0 for none), the paint it edits (0 for a new one),
    /// whether that is the stroke's, its kind and colours, and the points answered so far, as
    /// `GradientAnswers` bits.
    gradient_shape: u32 = 0,
    gradient_paint: u32 = 0,
    gradient_stroke: u8 = 0,
    gradient_kind: Atom = session.none,
    gradient_colors: [2]session.Color = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
    gradient_start: session.Vec2 = session.zero,
    gradient_end: session.Vec2 = session.zero,
    gradient_answers: u8 = 0,
};

/// Which of a released gradient's points have been answered (`Config.gradient_answers`).
const GradientAnswers = struct {
    const start: u8 = 1;
    const end: u8 = 2;
};

/// What a copy of the selected shapes is for, kept with its question (`asks.Purpose.clipboard`).
pub const ClipboardUse = enum(u32) {
    copy,
    /// Copy, then delete what was copied.
    cut,
    /// Copy, then paste it at once.
    duplicate,
};
/// Shapes the current eraser drag has claimed. Rows are reset at press; each preview
/// resubmits the whole set against the transaction's baseline, so cancel restores them all.
const Erased = struct { id: u32 = 0 };
pub const erased_name = "editor_figure_erased";
pub const clipboard_name = "editor_figure_clipboard";
/// The table of `Copied` rows.
pub const copied_name = "editor_figure_copied";
/// A shape the clipboard's question in flight copies, which a cut deletes once it is answered.
const Copied = struct { id: u32 = 0 };
/// As many as a selection holds.
const copied_capacity = 4096;
pub const recent_colors_name = "editor_figure_recent_colors";
const erased_capacity = 4096;
/// Screen pixels between eraser samples. It does not exceed the 4px hit tolerance, so the
/// sampled sweep leaves no gap that a stroke under the pointer's path could slip through.
const eraser_spacing: f32 = 4;
pub const Clipboard = struct { index: u32 = 0, len: u32 = 0, bytes: [1024]u8 = @splat(0) };
pub const Recent = struct { index: u32 = 0, color: session.Color = .{ 0, 0, 0, 0 } };
pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ "fill", "stroke" });
    const old = tables.scope;
    tables.scope = .editor;
    defer tables.scope = old;
    _ = try session.ensureSingleton(Config, mem, atoms, tables, config_name);
    _ = try session.ensureTable(Clipboard, mem, atoms, tables, clipboard_name, 256);
    _ = try session.ensureTable(Copied, mem, atoms, tables, copied_name, copied_capacity);
    _ = try session.ensureTable(Recent, mem, atoms, tables, recent_colors_name, 16);
    _ = try session.ensureTable(Erased, mem, atoms, tables, erased_name, erased_capacity);
}
pub const ConfigView = session.Row(Config);
pub fn config(tables: *Table.Registry) ConfigView {
    const config_table = tables.findByName(Atom.from(config_name)).?;
    return config_table.getRow(.{ .row = 0, .generation = config_table.rowGeneration(0) }, session.Row(Config)).?;
}

pub const ToolOption = enum {
    corner_radius,
    polygon_sides,
    pencil_spacing,
    pencil_simplify,
    pencil_error,
    pencil_close,

    pub fn details(option: ToolOption) struct { label: []const u8, range: []const u8, action: Msg } {
        return switch (option) {
            .corner_radius => .{ .label = "Corner radius", .range = "Radius must be finite and at least 0", .action = .figure_corner_radius },
            .polygon_sides => .{ .label = "Sides", .range = "Sides must be an integer from 3 to 128", .action = .figure_polygon_sides },
            .pencil_spacing => .{ .label = "Spacing", .range = "Spacing must be finite and at least 0.5 pixels", .action = .figure_pencil_spacing },
            .pencil_simplify => .{ .label = "Simplify", .range = "Simplify must be finite and at least 0 pixels", .action = .figure_pencil_simplify },
            .pencil_error => .{ .label = "Fit error", .range = "Fit error must be finite and greater than 0 pixels", .action = .figure_pencil_error },
            .pencil_close => .{ .label = "Close distance", .range = "Close distance must be finite and at least 0 pixels", .action = .figure_pencil_close },
        };
    }

    pub fn value(option: ToolOption, settings: session.Row(Config)) f32 {
        return switch (option) {
            .corner_radius => settings.corner_radius.*,
            .polygon_sides => @floatFromInt(settings.polygon_sides.*),
            .pencil_spacing => settings.pencil_spacing.*,
            .pencil_simplify => settings.pencil_simplify.*,
            .pencil_error => settings.pencil_error.*,
            .pencil_close => settings.pencil_close.*,
        };
    }

    pub fn apply(option: ToolOption, settings: session.Row(Config), text: []const u8) !void {
        if (option == .polygon_sides) {
            const sides = std.fmt.parseInt(u32, text, 10) catch return error.InvalidToolOption;
            if (sides < 3 or sides > 128) return error.InvalidToolOption;
            settings.polygon_sides.* = sides;
            return;
        }
        const number = std.fmt.parseFloat(f32, text) catch return error.InvalidToolOption;
        if (!std.math.isFinite(number) or number < 0) return error.InvalidToolOption;
        switch (option) {
            .corner_radius => settings.corner_radius.* = number,
            .polygon_sides => unreachable,
            .pencil_spacing => {
                if (number < 0.5) return error.InvalidToolOption;
                settings.pencil_spacing.* = number;
            },
            .pencil_simplify => settings.pencil_simplify.* = number,
            .pencil_error => {
                if (number == 0) return error.InvalidToolOption;
                settings.pencil_error.* = number;
            },
            .pencil_close => settings.pencil_close.* = number,
        }
    }
};

pub fn toolOptions(tool: Atom) []const ToolOption {
    if (tool == Atom.from("rect")) return &.{.corner_radius};
    if (tool == Atom.from("polygon")) return &.{.polygon_sides};
    if (tool == Atom.from("pencil")) return &.{ .pencil_spacing, .pencil_simplify, .pencil_error, .pencil_close };
    return &.{};
}

pub fn createsArtwork(tool: Atom) bool {
    return switch (tool) {
        Atom.from("pen"),
        Atom.from("pencil"),
        Atom.from("rect"),
        Atom.from("ellipse"),
        Atom.from("line"),
        Atom.from("polygon"),
        Atom.from("joint_fill"),
        => true,
        else => false,
    };
}

pub fn primitiveTool(tool: Atom) ?api.Primitive {
    return switch (tool) {
        Atom.from("rect") => .rect,
        Atom.from("ellipse") => .ellipse,
        Atom.from("line") => .line,
        Atom.from("polygon") => .polygon,
        else => null,
    };
}

pub fn recordToolChoice(editor: session.View, settings: ConfigView, tool: Atom) void {
    if (tool != editor.tool.* or primitiveTool(tool) == null) settings.locked_tool.* = session.none;
    if (primitiveTool(tool) != null) {
        if (tool == editor.tool.* and settings.tool_tap_remaining.* > 0) settings.locked_tool.* = tool;
        settings.tool_tap_remaining.* = 0.4;
    } else settings.tool_tap_remaining.* = 0;
}

pub fn clearCreation(settings: ConfigView) void {
    settings.creation_doc.* = session.none;
    settings.creation_request.* = 0;
    settings.creation_tool.* = session.none;
}

pub fn reconcileCreation(settings: ConfigView, editor: session.View, metadata: session.Metadata, result: anyerror!?u32) void {
    if (settings.creation_request.* == 0 or metadata.request != settings.creation_request.* or metadata.operation != .add_shape) return;
    const doc = settings.creation_doc.*;
    const tool = settings.creation_tool.*;
    // The matching terminal result drains ownership even if its document vanished.
    clearCreation(settings);
    const created = result catch return;
    if (created == null) return;
    if (metadata.doc != doc or editor.doc.* != doc or editor.tool.* != tool or !session.atRest(editor)) return;
    if (settings.locked_tool.* == tool) return;
    editor.tool.* = names.select;
    editor.hover_kind.* = session.none;
    editor.hover_id.* = 0;
    settings.tool_tap_remaining.* = 0;
}

pub const actions = blk: {
    const defs = .{
        .{ Msg.figure_tool_pen, "Pen: click corners, drag handles, Shift 45 degrees, Enter/Esc finish open" },
        .{ Msg.figure_tool_rect, "Rectangle tool (Shift square, Alt centered)" },
        .{ Msg.figure_tool_ellipse, "Ellipse tool (Shift circle, Alt centered)" },
        .{ Msg.figure_tool_line, "Line tool (Shift angle constraint)" },
        .{ Msg.figure_tool_polygon, "Regular polygon (arrows change sides)" },
        .{ Msg.figure_tool_pencil, "Pencil: fitted cubic stroke" },
        .{ Msg.figure_edit_points, "Edit the selected path's anchors and handles" },
        .{ Msg.figure_edit_points_done, "Finish editing points and select the path" },
        .{ Msg.figure_tool_joint_fill, "Joint fill: click joints, Enter closes" },
        .{ Msg.figure_tool_gradient, "Drag linear gradient endpoints" },
        .{ Msg.figure_tool_radial, "Drag radial center and radius" },
        .{ Msg.figure_tool_eyedropper, "Sample top shape's document color" },
        .{ Msg.figure_tool_eraser, "Delete the strokes you drag over" },
        .{ Msg.figure_draft_backspace, "Remove last draft point" },
        .{ Msg.figure_polygon_more, "Increase polygon sides" },
        .{ Msg.figure_polygon_less, "Decrease polygon sides" },
        .{ Msg.figure_point_delete, "Delete selected anchors" },
        .{ Msg.figure_point_smooth, "Toggle smooth/corner handles" },
        .{ Msg.figure_point_corner, "Make selected anchors corners without handles" },
        .{ Msg.figure_point_make_smooth, "Make selected anchors smooth with mirrored handles" },
        .{ Msg.figure_point_mirror, "Toggle mirroring on selected anchors" },
        .{ Msg.figure_path_closed, "Open or close the edited path" },
        .{ Msg.figure_point_x, "Set the selected anchor's bind-space X coordinate" },
        .{ Msg.figure_point_y, "Set the selected anchor's bind-space Y coordinate" },
        .{ Msg.figure_layer_add, "Add vector layer" },
        .{ Msg.figure_layer_delete, "Delete layer (repeat to confirm if nonempty)" },
        .{ Msg.figure_layer_up, "Move layer forward" },
        .{ Msg.figure_layer_down, "Move layer backward" },
        .{ Msg.figure_shape_forward, "Bring shapes forward" },
        .{ Msg.figure_shape_backward, "Send shapes backward" },
        .{ Msg.figure_shape_front, "Bring shapes to front" },
        .{ Msg.figure_shape_back, "Send shapes to back" },
        .{ Msg.figure_shapes_to_layer, "Move selected shapes to active layer" },
        .{ Msg.figure_shape_delete, "Delete selected shapes" },
        .{ Msg.figure_copy, "Copy artwork" },
        .{ Msg.figure_cut, "Cut artwork" },
        .{ Msg.figure_paste, "Paste artwork (also across documents)" },
        .{ Msg.figure_duplicate, "Duplicate artwork" },
        .{ Msg.figure_fill_toggle, "Toggle fill" },
        .{ Msg.figure_stroke_toggle, "Toggle stroke" },
    };
    const options = std.enums.values(ToolOption);
    var out: [defs.len + options.len]plugin.action_api.Def = undefined;
    for (defs, 0..) |d, i| out[i] = .{
        .name = modes.shortName("figure", @tagName(d[0])),
        .tag = @tagName(d[0]),
        .doc = d[1],
    };
    for (options, defs.len..) |option, index| {
        const detail = option.details();
        out[index] = .{ .name = modes.shortName("figure", @tagName(detail.action)), .tag = @tagName(detail.action), .doc = detail.range };
    }
    break :blk out;
};
/// The tools the drawing system owns.
const drawing_tools = [_]Atom{ names.pen, names.rect, names.ellipse, names.line, names.polygon, names.pencil, names.edit_points, names.joint_fill, names.gradient, names.radial, names.eyedropper, names.eraser };

pub fn owns(tool: Atom) bool {
    return std.mem.indexOfScalar(Atom, &drawing_tools, tool) != null;
}

pub fn beginPointEditing(tables: *Table.Registry, atoms: *Atom.Registry, shape_id: u32) !bool {
    const editor = session.get(tables);
    if (editor.mode.* != names.design) return false;
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const shape = session.findById(api.read.Shape, definition.shapes, shape_id) orelse return false;
    if (shape.kind != names.path or shape.visible == 0) return false;
    if (!session.editableLayer(definition, shape.layer)) return false;
    const settings = config(tables);
    settings.edit_doc.* = editor.doc.*;
    settings.locked_tool.* = session.none;
    settings.tool_tap_remaining.* = 0;
    settings.edit_shape.* = shape_id;
    settings.edit_point_count.* = 0;
    for (definition.points) |point| {
        if (point.shape == shape_id) settings.edit_point_count.* += 1;
    }
    // The path is owned by the edit context; selection rows now describe anchors.
    selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
    editor.tool.* = names.edit_points;
    editor.gesture_active.* = 0;
    editor.hover_kind.* = session.none;
    editor.hover_id.* = 0;
    return true;
}

pub fn clearPointEditing(editor: session.View, settings: ConfigView) void {
    settings.edit_doc.* = session.none;
    settings.edit_shape.* = 0;
    settings.edit_point_count.* = 0;
    if (editor.tool.* == names.edit_points) editor.tool.* = names.select;
}

pub fn finishPointEditing(tables: *Table.Registry, atoms: *Atom.Registry) void {
    defer clearPointEditing(session.get(tables), config(tables));
    const editor = session.get(tables);
    const settings = config(tables);
    if (settings.edit_doc.* != editor.doc.*) return;
    const definition = session.readDefinition(tables, atoms, editor.doc.*) catch return;
    if (session.findById(api.read.Shape, definition.shapes, settings.edit_shape.*) == null) return;
    const kind = names.shape;
    selection.select(tables, atoms, kind, settings.edit_shape.*, false, false);
}

/// Reconcile owned edit context during update, after any gesture has drained.
pub fn syncPointEditing(tables: *Table.Registry, atoms: *Atom.Registry) void {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    syncPointEditingWithReads(&reads);
}

pub fn syncPointEditingWithReads(reads: *session.ReadContext) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    if (gesture.busy(gesture.get(tables))) return;
    const editor = session.get(tables);
    const settings = config(tables);
    if (settings.edit_shape.* == 0 and editor.tool.* != names.edit_points) return;
    if (editor.tool.* == names.edit_points and editor.mode.* == names.design and settings.edit_doc.* == editor.doc.*) {
        var selected = session.selections(tables).read();
        while (selected.next()) |row| {
            if (row.view.doc.* != editor.doc.*) continue;
            if (row.view.kind.* != names.point or row.view.id.* != settings.edit_shape.*) {
                clearPointEditing(session.get(tables), config(tables));
                return;
            }
        }
        const definition = reads.definition(editor.doc.*) catch {
            clearPointEditing(session.get(tables), config(tables));
            return;
        };
        if (session.findById(api.read.Shape, definition.shapes, settings.edit_shape.*)) |shape| {
            if (shape.kind == names.path and shape.visible != 0 and session.editableLayer(definition, shape.layer)) {
                var count: u32 = 0;
                for (definition.points) |point| {
                    if (point.shape == shape.id) count += 1;
                }
                // Numeric indices do not retain anchor identity across topology edits or undo.
                if (count != settings.edit_point_count.*) selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
                settings.edit_point_count.* = count;
                return;
            }
        }
    }
    finishPointEditing(tables, atoms);
}

// Draft paths and selection
pub fn draftCount(editor: session.View, draft_rows: session.DraftRows) usize {
    var rows = draft_rows.query();
    var count: usize = 0;
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.*) count += 1;
    }
    return count;
}

pub fn clear(draft_rows: session.DraftRows, editor: session.View) void {
    session.removeRows(draft_rows.table, editor.doc.*);
}
pub fn cancelDraft(tables: *Table.Registry) void {
    const editor = session.get(tables);
    const settings = config(tables);
    if (editor.tool.* == names.pen and color_picker.isOpen(tables)) return;
    if (editor.tool.* != names.pen or editor.gesture_active.* == 0) {
        clear(session.drafts(tables), session.get(tables));
        return;
    }
    if (editor.gesture_kind.* != names.draw) return;
    const count = settings.pen_press_count.*;
    const drafts = session.drafts(tables);
    var rows = drafts.query();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.* and row.view.index.* >= count) drafts.free(row.handle);
    }
}

pub const PenConstraint = enum { free, angle };
fn anglePoint(origin: session.Vec2, point: session.Vec2) session.Vec2 {
    const delta = session.Vec2.sub(point, origin);
    const length = geometry.distance(point, origin);
    const step = std.math.pi / 4.0;
    const angle = @round(std.math.atan2(delta.y, delta.x) / step) * step;
    const offset = session.Vec2{ .x = @cos(angle) * length, .y = @sin(angle) * length };
    return session.Vec2.add(origin, offset);
}

fn penPosition(points: []const api.read.Point, point: session.Vec2, zoom: f32, constraint: PenConstraint) struct { point: session.Vec2, closing: bool = false } {
    if (points.len >= 3 and geometry.distance(points[0].p, point) * zoom <= 8) return .{ .point = points[0].p, .closing = true };
    if (constraint == .angle and points.len > 0) return .{ .point = anglePoint(points[points.len - 1].p, point) };
    return .{ .point = point };
}

pub fn penHover(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2, constraint: PenConstraint) !geometry.Hit {
    const points = try draftPoints(tables);
    const zoom = session.get(tables).view_zoom.*;
    if (points.len == 0) {
        if (try selectedPathSegment(tables, atoms, point)) |segment| {
            return .{ .kind = names.pen_insert, .id = segment.shape, .sub = segment.index, .point = segment.point };
        }
    }
    const target = penPosition(points, point, zoom, constraint);
    return .{ .kind = if (target.closing) names.pen_close else names.pen_cursor, .id = 0, .point = target.point };
}
fn frameAllocator(tables: *Table.Registry) !std.mem.Allocator {
    return (try tables.memory.frameScratchAllocator()).allocator;
}
fn draftPoints(tables: *Table.Registry) ![]api.read.Point {
    var points: std.ArrayListUnmanaged(api.read.Point) = .empty;
    const frame_allocator = try frameAllocator(tables);
    const editor = session.get(tables);
    var rows = session.drafts(tables).query();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.*) {
            try points.append(frame_allocator, .{
                .index = row.view.index.*,
                .p = row.view.p.*,
                .in = row.view.in.*,
                .out = row.view.out.*,
                .flags = row.view.flags.*,
                .joint_bone = row.view.ref_id.*,
                .joint_end = @intFromBool(row.view.ref_kind.* != names.origin),
            });
        }
    }
    std.mem.sort(api.read.Point, points.items, {}, struct {
        fn less(_: void, x: api.read.Point, y: api.read.Point) bool {
            return x.index < y.index;
        }
    }.less);
    return points.toOwnedSlice(frame_allocator);
}
fn addDraft(draft_table: session.DraftRows, editor: session.View, path_point: session.Vec2, bone: u32, end: u32) !void {
    _ = try draft_table.insert(session.Draft{
        .doc = editor.doc.*,
        .index = draft_table.count(),
        .p = path_point,
        .ref_id = bone,
        .ref_kind = if (end == 0) names.origin else names.tip,
    });
}
fn commandPoints(allocator: std.mem.Allocator, path_points: []const api.read.Point) ![]api.Point {
    const command_points = try allocator.alloc(api.Point, path_points.len);
    for (command_points, path_points) |*command_point, path_point| {
        inline for (std.meta.fields(api.Point)) |f| @field(command_point.*, f.name) = @field(path_point, f.name);
    }
    return command_points;
}
const PathKind = enum { open, closed, joint_fill };

fn pathStyle(settings: session.Row(Config), kind: PathKind) api.Style {
    return .{
        .fill_color = if (settings.fill_enabled.* != 0 and kind != .open) settings.fill_color.* else .{ 0, 0, 0, 0 },
        .stroke_color = if (settings.stroke_enabled.* != 0) settings.stroke_color.* else .{ 0, 0, 0, 0 },
        .stroke_width = settings.stroke_width.*,
        .cap = settings.cap.*,
        .join = settings.join.*,
        .opacity = settings.opacity.*,
    };
}

fn commitPath(tables: *Table.Registry, atoms: *Atom.Registry, path_points: []const api.read.Point, kind: PathKind) !void {
    const editor = session.get(tables);
    const joint = kind == .joint_fill;
    if (path_points.len < 2 or (joint and path_points.len < 3)) return;
    const frame_allocator = try frameAllocator(tables);
    const command_points = try commandPoints(frame_allocator, path_points);
    if (joint) for (command_points) |*path_point| {
        path_point.p = session.zero;
        path_point.in = session.zero;
        path_point.out = session.zero;
    };
    const settings = config(tables);
    const path_style = pathStyle(settings, kind);
    if (settings.creation_request.* != 0) return error.CreationSettling;
    const context = session.figureContext(tables, atoms);
    const request = try transport.submit(context, .{ .add_shape = .{
        .doc = editor.doc.*,
        .layer = if (primitiveTool(editor.tool.*) != null) settings.primitive_layer.* else editor.active_layer.*,
        .kind = if (joint) names.joint_fill else names.path,
        .closed = @intFromBool(kind != .open),
        .style = path_style,
        .points = command_points,
    } });
    if (primitiveTool(editor.tool.*) != null) {
        settings.creation_doc.* = editor.doc.*;
        settings.creation_request.* = request;
        settings.creation_tool.* = editor.tool.*;
    }
    clear(session.drafts(tables), session.get(tables));
}
pub fn finish(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const editor = session.get(tables);
    if (editor.tool.* == names.pen or editor.tool.* == names.joint_fill) {
        const path_points = try draftPoints(tables);
        const joint = editor.tool.* == names.joint_fill;
        if (joint and path_points.len < 3) {
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Pick at least three distinct joints to close a fill");
            return;
        }
        if (path_points.len < 2) {
            clear(session.drafts(tables), session.get(tables));
            return;
        }
        try commitPath(tables, atoms, path_points, if (joint) .joint_fill else .open);
    }
}
fn primaryShape(tables: *Table.Registry, atoms: *Atom.Registry) ?api.read.Shape {
    const editor = session.get(tables);
    const definition = session.readDefinition(tables, atoms, editor.doc.*) catch return null;
    return session.findById(api.read.Shape, definition.shapes, editor.active_id.*);
}
// Pointer gestures
const EditablePath = struct { shape: api.read.Shape, points: []const api.read.Point };
const PickedPoint = struct { p: api.read.Point, handle: u32 };
const Segment = struct { shape: u32, index: u32, next: u32, t: f32, point: session.Vec2 };
const PointHit = union(enum) { point: PickedPoint, segment: Segment };

fn editingPath(tables: *Table.Registry, atoms: *Atom.Registry) !?EditablePath {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return editingPathWithReads(&reads);
}

fn editingPathWithReads(reads: *session.ReadContext) !?EditablePath {
    const tables = reads.tables;
    const editor = session.get(tables);
    const settings = config(tables);
    if (editor.tool.* != names.edit_points or settings.edit_doc.* != editor.doc.*) return null;
    const definition = try reads.definition(editor.doc.*);
    const allocator = try reads.readAllocator();
    return readEditablePath(allocator, definition, settings.edit_shape.*);
}

fn readEditablePath(allocator: std.mem.Allocator, definition: api.read.Definition, id: u32) !?EditablePath {
    const shape = session.findById(api.read.Shape, definition.shapes, id) orelse return null;
    if (shape.kind != names.path or shape.visible == 0 or !session.editableLayer(definition, shape.layer)) return null;
    var points: std.ArrayListUnmanaged(api.read.Point) = .empty;
    for (definition.points) |point| {
        if (point.shape == shape.id) try points.append(allocator, point);
    }
    std.mem.sort(api.read.Point, points.items, {}, struct {
        fn less(_: void, left: api.read.Point, right: api.read.Point) bool {
            return left.index < right.index;
        }
    }.less);
    return .{ .shape = shape, .points = points.items };
}

fn pointSelected(editor: session.View, selected: session.SelectionRows, shape: u32, index: u32) bool {
    var rows = selected.query();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.* and row.view.kind.* == names.point and row.view.id.* == shape and row.view.sub.* == index) return true;
    }
    return false;
}

pub const PointOptions = struct {
    shape: api.read.Shape,
    selected_count: usize = 0,
    smooth_count: usize = 0,
    corner_count: usize = 0,
    anchor: ?api.read.Point = null,
};
pub const PointAxis = enum { x, y };

pub fn pointOptions(tables: *Table.Registry, atoms: *Atom.Registry) !?PointOptions {
    const path = try editingPath(tables, atoms) orelse return null;
    var options = PointOptions{ .shape = path.shape };
    for (path.points) |point| {
        if (!pointSelected(session.get(tables), session.selections(tables), path.shape.id, point.index)) continue;
        options.selected_count += 1;
        if (point.flags & 1 != 0) options.smooth_count += 1;
        if (point.flags & 1 == 0 and point.in.x == 0 and point.in.y == 0 and point.out.x == 0 and point.out.y == 0) options.corner_count += 1;
        options.anchor = point;
    }
    if (options.selected_count != 1) options.anchor = null;
    return options;
}

pub fn pointCoordinateCommand(tables: *Table.Registry, atoms: *Atom.Registry, text: []const u8) !api.Payload {
    try session.validatePromptDocument(tables, atoms);
    const editor = session.get(tables);
    const capture = session.observed(tables);
    const info = session.definitionInfo(tables, atoms, editor.prompt_doc.*) orelse return error.PromptDocumentChanged;
    // A captured numeric index must not outlive any intervening authored edit.
    if (info.authored_revision != capture.prompt_revision.*) return error.PromptTargetChanged;
    const value = try std.fmt.parseFloat(f32, text);
    if (!std.math.isFinite(value)) return error.InvalidNumber;
    const definition = try session.readDefinition(tables, atoms, editor.prompt_doc.*);
    const anchor = for (definition.points) |point| {
        if (point.shape == editor.prompt_id.* and point.index == capture.prompt_anchor_index.*) break point;
    } else return error.PromptTargetMissing;
    const allocator = try frameAllocator(tables);
    const points = try commandPoints(allocator, &.{anchor});
    if (editor.prompt_field.* == names.x) {
        points[0].p.x = value;
    } else if (editor.prompt_field.* == names.y) {
        points[0].p.y = value;
    } else return error.MissingField;
    return .{ .set_points = .{ .doc = editor.prompt_doc.*, .shape = editor.prompt_id.*, .first = anchor.index, .points = points } };
}

fn showPointHandles(editor: session.View, selected: session.SelectionRows, path: EditablePath, index: usize) bool {
    if (pointSelected(editor, selected, path.shape.id, path.points[index].index)) return true;
    if (index > 0 or path.shape.closed != 0) {
        const previous = if (index > 0) index - 1 else path.points.len - 1;
        if (pointSelected(editor, selected, path.shape.id, path.points[previous].index)) return true;
    }
    if (index + 1 < path.points.len or path.shape.closed != 0) {
        const next = (index + 1) % path.points.len;
        if (pointSelected(editor, selected, path.shape.id, path.points[next].index)) return true;
    }
    return false;
}

fn pickPathPoint(editor: session.View, selected: session.SelectionRows, path: EditablePath, position: session.Vec2) ?PointHit {
    const zoom = editor.view_zoom.*;
    var best: f32 = 8 / zoom;
    var picked: ?PickedPoint = null;
    for (path.points, 0..) |point, index| {
        const handles = showPointHandles(editor, selected, path, index);
        const positions = [_]session.Vec2{ point.p, session.Vec2.add(point.p, point.in), session.Vec2.add(point.p, point.out) };
        for (positions, 0..) |position_on_path, handle| {
            if (handle != 0) {
                if (!handles or geometry.distance(point.p, position_on_path) * zoom < 2) continue;
            }
            const distance = geometry.distance(position, position_on_path);
            if (distance < best) {
                best = distance;
                picked = .{ .p = point, .handle = @intCast(handle) };
            }
        }
    }
    if (picked) |point| return .{ .point = point };
    if (path.points.len < 2) return null;
    best = 6 / zoom;
    var segment: ?Segment = null;
    const count = if (path.shape.closed != 0) path.points.len else path.points.len - 1;
    for (0..count) |index| {
        const next = (index + 1) % path.points.len;
        var previous = path.points[index].p;
        for (1..101) |step| {
            const end_t = @as(f32, @floatFromInt(step)) / 100;
            const sample = figure.pathCubic(path.points[index], path.points[next], end_t);
            const delta = session.Vec2.sub(sample, previous);
            const relative = session.Vec2.sub(position, previous);
            const length_squared = delta.x * delta.x + delta.y * delta.y;
            // Project onto each sampled chord so long segments have no pick gaps.
            const fraction = if (length_squared == 0) 0 else std.math.clamp((relative.x * delta.x + relative.y * delta.y) / length_squared, 0, 1);
            const t = (end_t - 0.01) + fraction * 0.01;
            previous = sample;
            if (t <= 0 or t >= 1) continue;
            const on_curve = figure.pathCubic(path.points[index], path.points[next], t);
            const distance = geometry.distance(on_curve, position);
            if (distance < best) {
                best = distance;
                segment = .{ .shape = path.shape.id, .index = path.points[index].index, .next = path.points[next].index, .t = t, .point = on_curve };
            }
        }
    }
    if (segment) |hit| return .{ .segment = hit };
    return null;
}

fn selectedPathSegment(tables: *Table.Registry, atoms: *Atom.Registry, position: session.Vec2) !?Segment {
    const editor = session.get(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const allocator = try frameAllocator(tables);
    const ids = try selection.selectedShapeIds(tables);
    var best: f32 = 6 / editor.view_zoom.*;
    var segment: ?Segment = null;
    for (ids) |id| {
        const path = try readEditablePath(allocator, definition, id) orelse continue;
        const hit = pickPathPoint(session.get(tables), session.selections(tables), path, position) orelse continue;
        if (hit != .segment) continue;
        const distance = geometry.distance(position, hit.segment.point);
        if (distance < best) {
            best = distance;
            segment = hit.segment;
        }
    }
    return segment;
}

pub fn pointHover(tables: *Table.Registry, atoms: *Atom.Registry, position: session.Vec2) !?geometry.Hit {
    const path = try editingPath(tables, atoms) orelse return null;
    const hit = pickPathPoint(session.get(tables), session.selections(tables), path, position) orelse return null;
    return switch (hit) {
        .point => |point| .{ .kind = if (point.handle == 0) names.path_anchor else names.path_handle, .id = path.shape.id, .sub = point.p.index, .point = position },
        .segment => |segment| .{ .kind = names.path_segment, .id = path.shape.id, .sub = segment.index, .point = position },
    };
}

pub fn pointerDown(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2, shift: bool, alt: bool, control: bool, clicks: u8, bones: []const api.EvaluatedBone) !bool {
    const editor = session.get(tables);
    if (!owns(editor.tool.*)) return false;
    const settings = config(tables);
    const tool = editor.tool.*;
    settings.tool_tap_remaining.* = 0;
    if (tool == names.pen) {
        const points = try draftPoints(tables);
        if (points.len == 0) {
            if (try selectedPathSegment(tables, atoms, point)) |segment| {
                try transport.send(tables, atoms, .{ .insert_point = .{
                    .doc = editor.doc.*,
                    .shape = segment.shape,
                    .segment = segment.index,
                    .t = segment.t,
                } });
                return true;
            }
        }
    }
    if (tool == names.pen or tool == names.pencil or tool == names.joint_fill or primitiveTool(tool) != null) {
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        if (!session.editableLayer(definition, editor.active_layer.*)) return error.LayerNotEditable;
        if (primitiveTool(tool) != null) settings.primitive_layer.* = editor.active_layer.*;
    }
    editor.gesture_kind.* = names.draw;
    editor.gesture_active.* = 1;
    editor.gesture_modifiers.* = @as(u8, if (shift) 1 else 0) | @as(u8, if (alt) 2 else 0) | @as(u8, if (control) 4 else 0);
    const press = gesture.Pointer{ .point = point, .screen = editor.gesture_start_screen.*, .modifiers = editor.gesture_modifiers.* };
    if (tool == names.pen) {
        const path_points = try draftPoints(tables);
        const constraint: PenConstraint = if (shift) .angle else .free;
        const target = penPosition(path_points, point, editor.view_zoom.*, constraint);
        if (target.closing) {
            try commitPath(tables, atoms, path_points, .closed);
            editor.gesture_active.* = 0;
            return true;
        }
        settings.pen_press_count.* = @intCast(path_points.len);
        settings.pen_press_point.* = point;
        try addDraft(session.drafts(tables), session.get(tables), target.point, 0, 1);
        return true;
    }
    if (tool == names.joint_fill) {
        editor.gesture_active.* = 0;
        const joint = geometry.pickJoint(bones, point, editor.view_zoom.*) orelse return true;
        const path_points = try draftPoints(tables);
        if (path_points.len >= 3 and path_points[0].joint_bone == joint.id and path_points[0].joint_end == joint.sub) {
            try finish(tables, atoms);
            return true;
        }
        for (path_points) |path_point| {
            if (path_point.joint_bone == joint.id and path_point.joint_end == joint.sub) return error.DuplicateJoint;
        }
        try addDraft(session.drafts(tables), session.get(tables), joint.point, joint.id, joint.sub);
        return true;
    }
    if (tool == names.pencil) {
        clear(session.drafts(tables), session.get(tables));
        errdefer {
            clear(session.drafts(tables), session.get(tables));
            editor.gesture_active.* = 0;
        }
        try addDraft(session.drafts(tables), session.get(tables), point, 0, 1);
        return true;
    }
    if (tool == names.edit_points) {
        const path = try editingPath(tables, atoms) orelse {
            editor.gesture_active.* = 0;
            return true;
        };
        if (pickPathPoint(session.get(tables), session.selections(tables), path, point)) |hit| {
            switch (hit) {
                .point => |picked| {
                    if (picked.handle == 0 and clicks >= 2) {
                        selectPoint(session.get(tables), session.observed(tables), session.selections(tables), picked.p.shape, picked.p.index, false, false);
                        editor.gesture_active.* = 0;
                        _ = try handleAction(tables, atoms, .from(Msg.figure_point_smooth));
                        return true;
                    }
                    settings.point_shape.* = picked.p.shape;
                    settings.point_index.* = picked.p.index;
                    settings.point_handle.* = picked.handle;
                    settings.point_anchor.* = picked.p.p;
                    settings.point_in.* = picked.p.in;
                    settings.point_out.* = picked.p.out;
                    settings.point_flags.* = picked.p.flags;
                    settings.point_width.* = picked.p.width;
                    const selected = pointSelected(session.get(tables), session.selections(tables), picked.p.shape, picked.p.index);
                    const subtract = alt and picked.handle == 0;
                    if (!selected or subtract) selectPoint(session.get(tables), session.observed(tables), session.selections(tables), picked.p.shape, picked.p.index, shift, subtract);
                },
                .segment => |segment| {
                    if (alt) {
                        try transport.send(tables, atoms, .{ .insert_point = .{
                            .doc = editor.doc.*,
                            .shape = segment.shape,
                            .segment = segment.index,
                            .t = segment.t,
                        } });
                        // Topology changes invalidate the selected numeric indices.
                        selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
                        editor.gesture_active.* = 0;
                        return true;
                    }
                    selectPoint(session.get(tables), session.observed(tables), session.selections(tables), segment.shape, segment.index, false, false);
                    selectPoint(session.get(tables), session.observed(tables), session.selections(tables), segment.shape, segment.next, true, false);
                    settings.point_shape.* = segment.shape;
                    settings.point_handle.* = 0;
                },
            }
            editor.gesture_kind.* = names.draw_point;
            try gesture.begin(gesture.get(tables), .{ .kind = .points, .doc = editor.doc.*, .pointer = press });
        } else {
            editor.gesture_kind.* = names.draw_marquee;
            if (!shift and !alt) selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
        }
        return true;
    }
    if (tool == names.gradient or tool == names.radial) {
        if (primaryShape(tables, atoms)) |shape| {
            const paint_id = if (settings.color_target.* == names.stroke) shape.stroke_paint else shape.fill_paint;
            // The handles the canvas shows, which a press picks: none until the host has said
            // where the paint lies (`askPaintHandles`), when a press drags a new gradient.
            const handles = if (paint_id != 0) paintHandles(settings, editor, shape.id, paint_id) else null;
            if (handles) |mapped| {
                const start = mapped.start;
                const end = mapped.end;
                settings.point_anchor.* = start;
                settings.point_in.* = end;
                if (geometry.distance(point, start) * editor.view_zoom.* < 8) {
                    editor.gesture_kind.* = names.draw_gradient_start;
                    editor.gesture_start.* = start;
                    editor.gesture_current.* = end;
                } else if (geometry.distance(point, end) * editor.view_zoom.* < 8) {
                    editor.gesture_kind.* = names.draw_gradient_end;
                    editor.gesture_start.* = start;
                    editor.gesture_current.* = end;
                }
            }
        }
        return true;
    }
    if (tool == names.eyedropper) {
        editor.gesture_active.* = 0;
        // The host finds the artwork under the press; `eyedropperAnswered` samples it.
        try asks.hitTest(tables, atoms, workspace.system(), .{ .purpose = .eyedropper_press, .point = point });
        return true;
    }
    if (tool == names.eraser) {
        errdefer editor.gesture_active.* = 0;
        editor.gesture_kind.* = names.draw_erase;
        try gesture.begin(gesture.get(tables), .{ .kind = .erase, .doc = editor.doc.*, .pointer = press });
        // The hovered shape is about to disappear, so it must not outlive the press.
        editor.hover_kind.* = session.none;
        editor.hover_id.* = 0;
        const erased = erasedShapes(tables);
        var rows = erased.query();
        while (rows.next()) |row| erased.free(row.handle);
        settings.eraser_sent.* = 0;
        settings.eraser_point.* = point;
        askErase(tables, atoms, point) catch |err| switch (err) {
            error.NotReady, error.Busy => {},
            else => gesture.reject(session.table(tables), gesture.get(tables), session.get(tables), session.feedback(tables), err),
        };
        _ = gesture.record(gesture.get(tables), press);
        return true;
    }
    return true;
}

/// The shapes an eraser stroke has claimed so far, a row each.
pub const ErasedRows = sequencer.Rows(session.Row(Erased));
pub fn erasedShapes(tables: *Table.Registry) ErasedRows {
    return .of(tables.findByName(Atom.from(erased_name)).?);
}
/// The colors used most recently, newest first, a row each.
pub const RecentRows = sequencer.Rows(session.Row(Recent));
pub fn recentColors(tables: *Table.Registry) RecentRows {
    return .of(tables.findByName(Atom.from(recent_colors_name)).?);
}
/// Artwork copied as text, in chunks of a row each.
pub const ClipboardRows = sequencer.Rows(session.Row(Clipboard));
/// The shapes the clipboard's question in flight copies, a row each (`askClipboard`).
pub const CopiedRows = sequencer.Rows(session.Row(Copied));
pub fn copiedShapes(tables: *Table.Registry) CopiedRows {
    return .of(tables.findByName(Atom.from(copied_name)).?);
}
pub fn clipboardChunks(tables: *Table.Registry) ClipboardRows {
    return .of(tables.findByName(Atom.from(clipboard_name)).?);
}

/// The shape a press at `point` would erase, of the shapes a hit test there found: only a
/// touched contour counts. A filled interior on top hides whatever lies beneath it.
pub fn eraserHover(found: []const api.Hit, point: session.Vec2) ?geometry.Hit {
    if (found.len == 0 or !found[0].outline) return null;
    return .{ .kind = names.shape, .id = found[0].object.id, .point = point };
}

/// Asks the host what lies under an eraser sample at `point`; `eraseAnswered` claims it.
fn askErase(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2) !void {
    try asks.hitTest(tables, atoms, workspace.system(), .{ .purpose = .erase, .point = point });
}

/// Claims every contour an eraser sample found, front to back, down to the first filled
/// interior, while the stroke that asked still samples. Stopping there keeps a shape from being
/// erased just for being revealed by the removal of a stroke drawn on top of it, and protects
/// artwork hidden behind a fill. A claim the stroke has not sent yet is sent by its next flush.
pub fn eraseAnswered(tables: *Table.Registry, answer: asks.Answer) void {
    const drag_state = gesture.get(tables);
    if (gesture.kindOf(drag_state) != .erase or gesture.phaseOf(drag_state) != .sampling) return;
    answer.failure.check() catch |err| switch (err) {
        // The next sample covers the span this one missed.
        error.NotReady, error.Busy => return,
        else => {
            gesture.reject(session.table(tables), drag_state, session.get(tables), session.feedback(tables), err);
            return;
        },
    };
    const erased = erasedShapes(tables);
    candidates: for (answer.hits()) |item| {
        // The instance can lag behind the latest preview and still report claimed shapes.
        var rows = erased.query();
        while (rows.next()) |row| {
            if (row.view.id.* == item.object.id) continue :candidates;
        }
        if (!item.outline) return;
        _ = erased.insert(Erased{ .id = item.object.id }) catch |err| {
            gesture.reject(session.table(tables), drag_state, session.get(tables), session.feedback(tables), err);
            return;
        };
        drag_state.sample_pending.* = 1;
    }
}

/// Runs for every pointer sample, before the gesture keeps only the latest one, so a
/// fast drag still erases along its whole path. An unavailable instance leaves the
/// sweep origin in place and the next sample covers the skipped span.
pub fn sweepEraser(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2) void {
    const drag_state = gesture.get(tables);
    if (gesture.kindOf(drag_state) != .erase or gesture.phaseOf(drag_state) != .sampling) return;
    const editor = session.get(tables);
    const settings = config(tables);
    const origin = settings.eraser_point.*;
    const moved_px = geometry.distance(origin, point) * editor.view_zoom.*;
    if (moved_px < eraser_spacing) return;
    const steps = std.math.ceil(moved_px / eraser_spacing);
    const delta = session.Vec2.sub(point, origin);
    var step: f32 = 1;
    while (step <= steps) : (step += 1) {
        const offset = session.Vec2.scale(delta, step / steps);
        const sample = session.Vec2.add(origin, offset);
        askErase(tables, atoms, sample) catch |err| switch (err) {
            error.NotReady, error.Busy => return,
            else => {
                gesture.reject(session.table(tables), gesture.get(tables), session.get(tables), session.feedback(tables), err);
                return;
            },
        };
    }
    settings.eraser_point.* = point;
}

pub fn previewEraser(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag) !void {
    const settings = config(tables);
    const erased = erasedShapes(tables);
    const count = erased.count();
    if (count == settings.eraser_sent.*) return;
    const allocator = (try tables.memory.frameScratchAllocator()).allocator;
    const ids = try allocator.alloc(u32, count);
    var filled: usize = 0;
    var rows = erased.query();
    while (rows.next()) |row| : (filled += 1) ids[filled] = row.view.id.*;
    try gesture.openTransaction(tables, atoms, names.erase);
    try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .delete_shapes = .{ .doc = drag.doc, .ids = ids } }});
    settings.eraser_sent.* = count;
}
fn selectPoint(editor: session.View, observed: session.ObservedView, selection_table: session.SelectionRows, shape: u32, index: u32, add: bool, subtract: bool) void {
    observed.selection_version.* +%= 1;
    if (!add and !subtract) selection.clear(editor, observed, selection_table);
    var rows = selection_table.query();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.* and row.view.kind.* == names.point and row.view.id.* == shape and row.view.sub.* == index) {
            if (subtract) selection_table.free(row.handle);
            return;
        }
    }
    if (!subtract) {
        _ = selection_table.insert(session.Selection{
            .doc = editor.doc.*,
            .kind = names.point,
            .id = shape,
            .sub = index,
            .primary = 1,
        }) catch return;
        editor.active_kind.* = names.point;
        editor.active_id.* = shape;
    }
}
pub fn pointerMove(tables: *Table.Registry, point: session.Vec2, shift: bool, alt: bool, control: bool) !bool {
    const editor = session.get(tables);
    if (!owns(editor.tool.*) or editor.gesture_active.* == 0) return false;
    const settings = config(tables);
    const tool = editor.tool.*;
    editor.gesture_current.* = point;
    if (editor.gesture_kind.* == names.draw_gradient_start) {
        editor.gesture_start.* = point;
        editor.gesture_current.* = settings.point_in.*;
    } else if (editor.gesture_kind.* == names.draw_gradient_end) editor.gesture_start.* = settings.point_anchor.*;
    editor.gesture_modifiers.* = @as(u8, if (shift) 1 else 0) | @as(u8, if (alt) 2 else 0) | @as(u8, if (control) 4 else 0);
    if (tool == names.pen) {
        const draft_table = session.drafts(tables);
        var rows = draft_table.query();
        while (rows.next()) |row| {
            if (row.view.doc.* == editor.doc.* and row.view.index.* == draft_table.count() - 1) {
                var delta = session.Vec2.sub(point, settings.pen_press_point.*);
                if (geometry.distance(delta, session.zero) * editor.view_zoom.* < 2) delta = session.zero;
                if (shift) delta = anglePoint(session.zero, delta);
                row.view.out.* = delta;
                row.view.in.* = if (alt) session.zero else session.Vec2.scale(delta, -1);
                row.view.flags.* = @intFromBool(!alt and geometry.distance(delta, session.zero) > 0);
            }
        }
    } else if (tool == names.pencil) {
        // Losing any sample, including during the release read, invalidates the
        // whole local stroke rather than allowing a truncated path to commit.
        errdefer {
            clear(session.drafts(tables), session.get(tables));
            editor.gesture_active.* = 0;
        }
        const path_points = try draftPoints(tables);
        if (path_points.len == 0 or geometry.distance(path_points[path_points.len - 1].p, point) * editor.view_zoom.* >= @max(0.5, settings.pencil_spacing.*)) {
            try addDraft(session.drafts(tables), session.get(tables), point, 0, 1);
        }
    }
    return true;
}

/// Points anchor or handle preview from the press-time point and the whole drag.
pub fn previewPoints(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag) !void {
    const editor = session.get(tables);
    const settings = config(tables);
    const alt = drag.latest.modifiers & gesture.Modifiers.alt != 0;
    const anchor_drag = settings.point_handle.* == 0;
    // Alt-press deselects the anchor; later modifier changes do not change that decision.
    if (anchor_drag and editor.gesture_modifiers.* & gesture.Modifiers.alt != 0) return;
    const moved_px = geometry.distance(drag.latest.point, drag.origin) * editor.view_zoom.*;
    if (moved_px < 2 and editor.tx_active.* == 0) return;
    if (anchor_drag) {
        const items = try selection.artworkItems(tables);
        const translation = session.Vec2.sub(drag.latest.point, drag.origin);
        try gesture.openTransaction(tables, atoms, names.vector_gesture);
        try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .transform_selection = .{
            .doc = drag.doc,
            .items = items,
            .pivot = session.zero,
            .translation = translation,
        } }});
        return;
    }
    var path_point = api.Point{ .p = settings.point_anchor.*, .in = settings.point_in.*, .out = settings.point_out.*, .flags = settings.point_flags.*, .width = settings.point_width.* };
    const delta = session.Vec2.sub(drag.latest.point, path_point.p);
    const mirrored = session.Vec2.scale(delta, -1);
    const mirror = settings.point_flags.* & 1 != 0 and !alt;
    if (alt) path_point.flags &= ~@as(u32, 1);
    if (settings.point_handle.* == 1) {
        path_point.in = delta;
        if (mirror) path_point.out = mirrored;
    } else {
        path_point.out = delta;
        if (mirror) path_point.in = mirrored;
    }
    try gesture.openTransaction(tables, atoms, names.vector_gesture);
    try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .set_points = .{
        .doc = drag.doc,
        .shape = settings.point_shape.*,
        .first = settings.point_index.*,
        .points = &.{path_point},
    } }});
}

pub const Transform = enum { rotate, scale };

/// A single frame covers editable paths and native primitives. Bone-driven
/// artwork keeps its selection outline and is edited through its skeleton.
pub fn selectionBounds(tables: *Table.Registry, atoms: *Atom.Registry) !?geometry.Bounds {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return selectionBoundsWithReads(&reads);
}

pub fn selectionBoundsWithReads(reads: *session.ReadContext) !?geometry.Bounds {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const items = try selection.artworkItems(tables);
    if (items.len == 0) return null;
    const shape_kind = names.shape;
    const path_kind = names.path;
    const line_kind = names.line;
    for (items) |item| {
        if (item.kind != shape_kind) return null;
    }
    const editor = session.get(tables);
    const definition = try reads.definition(editor.doc.*);
    const outline = try reads.outliner(editor.doc.*);
    var result: ?geometry.Bounds = null;
    var count: usize = 0;
    for (outline.items) |item| {
        if (item.object.kind != .shape) continue;
        const selected = selection.contains(session.get(tables), session.selections(tables), shape_kind, item.object.id);
        if (!selected) continue;
        const shape = session.findById(api.read.Shape, definition.shapes, item.object.id) orelse return error.MissingShape;
        if (!item.visible or item.locked) return null;
        if (shape.kind != path_kind and shape.kind != line_kind) return null;
        const contour = try preview.geometry(tables, atoms, shape.id);
        const box = geometry.bounds(contour.points) orelse return null;
        if (result) |*combined| {
            combined.min.x = @min(combined.min.x, box.min.x);
            combined.min.y = @min(combined.min.y, box.min.y);
            combined.max.x = @max(combined.max.x, box.max.x);
            combined.max.y = @max(combined.max.y, box.max.y);
        } else result = box;
        count += 1;
    }
    return if (count == items.len) result else null;
}

pub const SelectHit = union(enum) { none, scale: geometry.ScaleHandle, rotate: geometry.ScaleHandle, pivot };

pub fn selectionPivot(settings: ConfigView, observed: session.ObservedView, box: geometry.Bounds) session.Vec2 {
    const version = observed.selection_version.*;
    if (settings.custom_pivot.* != 0 and settings.pivot_version.* == version) return settings.pivot.*;
    return box.center();
}

fn pickSelectHandle(box: geometry.Bounds, pivot: session.Vec2, point: session.Vec2, zoom: f32) SelectHit {
    const resize = geometry.pickScaleHandle(box, point, zoom);
    if (resize != .none) return .{ .scale = resize };
    if (geometry.distance(pivot, point) * zoom <= 7) return .pivot;
    for (geometry.rotation_handles) |corner| {
        const location = geometry.rotationHandlePoint(box, corner, zoom);
        if (geometry.distance(location, point) * zoom <= 9) return .{ .rotate = corner };
    }
    return .none;
}

pub fn selectHandle(reads: *session.ReadContext, point: session.Vec2) !SelectHit {
    const tables = reads.tables;
    const editor = session.get(tables);
    if (editor.mode.* != names.design or editor.tool.* != names.select) return .none;
    const box = try selectionBoundsWithReads(reads) orelse return .none;
    const pivot = selectionPivot(config(tables), session.observed(tables), box);
    return pickSelectHandle(box, pivot, point, editor.view_zoom.*);
}

pub fn selectCursor(hit: SelectHit) os.CursorKind {
    return switch (hit) {
        .scale => |handle| switch (handle) {
            .top_left, .bottom_right => .resize_nwse,
            .top_right, .bottom_left => .resize_nesw,
            .top, .bottom => .resize_ns,
            .left, .right => .resize_ew,
            .none => .arrow,
        },
        .rotate => .hand,
        .pivot => .move,
        .none => .arrow,
    };
}

pub fn beginSelectTransform(tables: *Table.Registry, atoms: *Atom.Registry, press: gesture.Pointer) !bool {
    const editor = session.get(tables);
    if (editor.mode.* != names.design or editor.tool.* != names.select) return false;
    const box = try selectionBounds(tables, atoms) orelse return false;
    const pivot = selectionPivot(config(tables), session.observed(tables), box);
    const hit = pickSelectHandle(box, pivot, press.point, editor.view_zoom.*);
    const settings = config(tables);
    switch (hit) {
        .none => return false,
        .pivot => {
            const version = session.observed(tables).selection_version.*;
            settings.pivot_before.* = pivot;
            settings.pivot_custom_before.* = @intFromBool(settings.custom_pivot.* != 0 and settings.pivot_version.* == version);
            settings.pivot.* = pivot;
            settings.custom_pivot.* = settings.pivot_custom_before.*;
            settings.pivot_version.* = version;
            editor.gesture_kind.* = names.select_pivot;
            return true;
        },
        .scale, .rotate => |handle| {
            const kind: gesture.Kind = if (hit == .scale) .scale else .rotate;
            try gesture.begin(gesture.get(tables), .{ .kind = kind, .doc = editor.doc.*, .pointer = press });
            settings.transform_handle.* = @intFromEnum(handle);
            settings.transform_min.* = box.min;
            settings.transform_max.* = box.max;
            settings.transform_pivot.* = pivot;
            editor.gesture_kind.* = if (kind == .scale) names.select_scale else names.select_rotate;
        },
    }
    return true;
}

pub fn moveSelectPivot(editor: session.View, settings: ConfigView, point: session.Vec2) bool {
    if (editor.gesture_kind.* != names.select_pivot) return false;
    const delta = session.Vec2.sub(point, editor.gesture_start.*);
    settings.pivot.* = session.Vec2.add(settings.pivot_before.*, delta);
    settings.custom_pivot.* = if (delta.x == 0 and delta.y == 0) settings.pivot_custom_before.* else 1;
    return true;
}

pub fn cancelSelectPivot(editor: session.View, settings: ConfigView) void {
    if (editor.gesture_active.* == 0 or editor.gesture_kind.* != names.select_pivot) return;
    settings.pivot.* = settings.pivot_before.*;
    settings.custom_pivot.* = settings.pivot_custom_before.*;
}

const TransformValues = struct {
    pivot: session.Vec2,
    scale: session.Vec2 = session.one,
    rotation: f32 = 0,
    fn matrix(self: TransformValues) math.Affine2f {
        const from_pivot = math.Affine2f.fromTRS(-self.pivot.x, -self.pivot.y, 0, 1, 1);
        const to_pivot = math.Affine2f.fromTRS(self.pivot.x, self.pivot.y, self.rotation, self.scale.x, self.scale.y);
        return to_pivot.mul(from_pivot);
    }
};
fn selectionScale(settings: session.Row(Config), drag: gesture.Drag) TransformValues {
    const handle: geometry.ScaleHandle = @enumFromInt(settings.transform_handle.*);
    const box = geometry.Bounds{ .min = settings.transform_min.*, .max = settings.transform_max.* };
    const opposite_index = (@as(u32, settings.transform_handle.*) - 1 + 4) % geometry.scale_handles.len;
    const opposite = geometry.scale_handles[opposite_index];
    const pivot = if (drag.latest.modifiers & gesture.Modifiers.alt != 0) settings.transform_pivot.* else geometry.scaleHandlePoint(box, opposite);
    const location = geometry.scaleHandlePoint(box, handle);
    const start = session.Vec2.sub(location, pivot);
    const delta = session.Vec2.sub(drag.latest.point, drag.origin);
    const end = session.Vec2.add(start, delta);
    const horizontal = handle != .top and handle != .bottom;
    const vertical = handle != .left and handle != .right;
    var scale = session.one;
    if (horizontal and @abs(start.x) > 1e-6) scale.x = end.x / start.x;
    if (vertical and @abs(start.y) > 1e-6) scale.y = end.y / start.y;
    if (horizontal and vertical and drag.latest.modifiers & gesture.Modifiers.shift != 0) {
        const factor = if (@abs(scale.x - 1) >= @abs(scale.y - 1)) scale.x else scale.y;
        scale = .{ .x = factor, .y = factor };
    }
    return .{ .pivot = pivot, .scale = scale };
}

fn transformValues(settings: session.Row(Config), drag: gesture.Drag, transform: Transform) TransformValues {
    if (transform == .scale) return selectionScale(settings, drag);
    const pivot = settings.transform_pivot.*;
    const shift = drag.latest.modifiers & gesture.Modifiers.shift != 0;
    const start = session.Vec2.sub(drag.origin, pivot);
    const end = session.Vec2.sub(drag.latest.point, pivot);
    var result = TransformValues{ .pivot = pivot };
    const step = std.math.pi / 12.0;
    result.rotation = std.math.atan2(end.y, end.x) - std.math.atan2(start.y, start.x);
    // Crossing atan2's branch cut is a small turn, not a nearly full turn.
    // Normalize before snapping so a stationary result remains a true no-op.
    if (result.rotation > std.math.pi) result.rotation -= 2 * std.math.pi;
    if (result.rotation < -std.math.pi) result.rotation += 2 * std.math.pi;
    if (shift) result.rotation = @round(result.rotation / step) * step;
    return result;
}

pub const TransformFrame = struct { bounds: geometry.Bounds, matrix: math.Affine2f, rotation: f32 };
/// Display the latest pointer intent using the preview's absolute transform.
/// Reading this frame never starts, advances or commits a transaction.
pub fn selectionFrame(editor: session.View, state: gesture.View, settings: ConfigView, box: geometry.Bounds) ?TransformFrame {
    if (gesture.phaseOf(state) == .idle or gesture.intentOf(state) == .cancel or gesture.intentOf(state) == .failure) return null;
    if (editor.gesture_kind.* == names.duplicate_shapes) {
        const constraint: geometry.MoveConstraint = if (state.modifiers.* & gesture.Modifiers.shift != 0) .axis else .none;
        const delta = geometry.moveDelta(state.origin.*, state.latest.*, constraint);
        var matrix = math.Affine2f.identity;
        matrix.tx = delta.x;
        matrix.ty = delta.y;
        return .{ .bounds = box, .matrix = matrix, .rotation = 0 };
    }
    const transform: Transform = if (editor.gesture_kind.* == names.select_rotate) .rotate else if (editor.gesture_kind.* == names.select_scale) .scale else return null;
    const drag = gesture.Drag{
        .doc = state.doc.*,
        .origin = state.origin.*,
        .origin_screen = state.origin_screen.*,
        .latest = .{ .point = state.latest.*, .screen = state.latest_screen.*, .modifiers = state.modifiers.* },
    };
    const values = transformValues(settings, drag, transform);
    if (@abs(values.scale.x) < 0.001 or @abs(values.scale.y) < 0.001) return null;
    return .{ .bounds = .{ .min = settings.transform_min.*, .max = settings.transform_max.* }, .matrix = values.matrix(), .rotation = values.rotation };
}

/// Rotate or scale from the press-time geometry, including the final release sample.
pub fn previewTransform(tables: *Table.Registry, atoms: *Atom.Registry, drag: gesture.Drag, transform: Transform) !void {
    const settings = config(tables);
    const values = transformValues(settings, drag, transform);
    const items = try selection.artworkItems(tables);
    try gesture.openTransaction(tables, atoms, names.vector_gesture);
    // A collapsed axis cannot be applied; the reset alone shows the press-time artwork.
    if (@abs(values.scale.x) < 0.001 or @abs(values.scale.y) < 0.001) {
        try gesture.submitPreview(tables, atoms, .absolute, &.{});
        return;
    }
    try gesture.submitPreview(tables, atoms, .absolute, &.{.{ .transform_selection = .{
        .doc = drag.doc,
        .items = items,
        .pivot = values.pivot,
        .rotation = values.rotation,
        .scale = values.scale,
    } }});
}
const PreviewPath = struct { points: []api.read.Point, kind: PathKind = .open };

fn previewPath(tables: *Table.Registry) !PreviewPath {
    const editor = session.get(tables);
    const settings = config(tables);
    const allocator = try frameAllocator(tables);
    if (primitiveTool(editor.tool.*)) |kind| {
        const points = try figure.primitivePath(
            allocator,
            kind,
            editor.gesture_start.*,
            editor.gesture_current.*,
            editor.gesture_modifiers.* & 1 != 0,
            editor.gesture_modifiers.* & 2 != 0,
            settings.corner_radius.*,
            settings.polygon_sides.*,
        );
        return .{ .points = points, .kind = if (kind == .line) .open else .closed };
    }
    const path_points = try draftPoints(tables);
    if (editor.tool.* == names.joint_fill) {
        return .{ .points = path_points, .kind = if (path_points.len >= 3) .joint_fill else .open };
    }
    if (editor.tool.* != names.pencil or path_points.len < 2) return .{ .points = path_points };
    const raw = try allocator.alloc(session.Vec2, path_points.len);
    for (raw, path_points) |*position, path_point| position.* = path_point.p;
    const simplify = @max(0, settings.pencil_simplify.*) / editor.view_zoom.*;
    const fit_error = @max(0.01, settings.pencil_error.*) / editor.view_zoom.*;
    const fitted = try figure.fitPath(allocator, raw, simplify, fit_error);
    if (fitted.len > 2) {
        const last = fitted[fitted.len - 1];
        const distance = geometry.distance(fitted[0].p, last.p) * editor.view_zoom.*;
        if (distance <= settings.pencil_close.*) {
            const closing_delta = session.Vec2.sub(last.p, fitted[0].p);
            fitted[0].in = session.Vec2.add(closing_delta, last.in);
            return .{ .points = fitted[0 .. fitted.len - 1], .kind = .closed };
        }
    }
    return .{ .points = fitted };
}
pub fn creationBounds(tables: *Table.Registry) !?geometry.Bounds {
    const editor = session.get(tables);
    if (editor.gesture_active.* == 0 or editor.gesture_kind.* != names.draw) return null;
    if (primitiveTool(editor.tool.*) == null) return null;
    const path = try previewPath(tables);
    const points = path.points;
    if (points.len == 0) return null;
    var bounds = geometry.Bounds{ .min = points[0].p, .max = points[0].p };
    for (points[1..]) |point| {
        bounds.min.x = @min(bounds.min.x, point.p.x);
        bounds.min.y = @min(bounds.min.y, point.p.y);
        bounds.max.x = @max(bounds.max.x, point.p.x);
        bounds.max.y = @max(bounds.max.y, point.p.y);
    }
    return bounds;
}

pub fn pointerUp(tables: *Table.Registry, atoms: *Atom.Registry) !bool {
    const editor = session.get(tables);
    if (!owns(editor.tool.*)) return false;
    const tool = editor.tool.*;
    if (primitiveTool(tool) != null) {
        if (geometry.distance(editor.gesture_start.*, editor.gesture_current.*) * editor.view_zoom.* < 2) {
            const extent: f32 = if (editor.gesture_modifiers.* & 2 != 0) 50 else 100;
            const offset = session.Vec2{ .x = extent, .y = extent };
            editor.gesture_current.* = session.Vec2.add(editor.gesture_start.*, offset);
        }
        const path = try previewPath(tables);
        try commitPath(tables, atoms, path.points, path.kind);
    } else if (tool == names.pencil) {
        const path = try previewPath(tables);
        try commitPath(tables, atoms, path.points, path.kind);
        clear(session.drafts(tables), session.get(tables));
    } else if (tool == names.edit_points and editor.gesture_kind.* == names.draw_marquee) {
        const box = figure.dragBounds(editor.gesture_start.*, editor.gesture_current.*, false, false);
        const path = try editingPath(tables, atoms) orelse return true;
        for (path.points) |path_point| {
            if (path_point.p.x >= box.min.x and path_point.p.x <= box.max.x and path_point.p.y >= box.min.y and path_point.p.y <= box.max.y) {
                selectPoint(session.get(tables), session.observed(tables), session.selections(tables), path_point.shape, path_point.index, true, editor.gesture_modifiers.* & 2 != 0);
            }
        }
    } else if (tool == names.gradient or tool == names.radial) {
        if (primaryShape(tables, atoms)) |shape| try askGradient(tables, atoms, shape);
    }
    return true;
}

/// Asks where a released gradient drag's start and end lie in the paint's space, keeping what
/// the edit needs besides them; `gradientAnswered` sends it once both are answered. The canvas
/// holds its later input until then, so the next press sees the edit.
fn askGradient(tables: *Table.Registry, atoms: *Atom.Registry, shape: api.read.Shape) !void {
    const editor = session.get(tables);
    const settings = config(tables);
    const stroke = settings.color_target.* == names.stroke;
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const paint_id = if (stroke) shape.stroke_paint else shape.fill_paint;
    const existing = if (paint_id != 0) session.findById(api.read.Paint, definition.paints, paint_id) orelse return error.MissingPaint else null;
    const paint: ?u32 = if (paint_id != 0) paint_id else null;
    settings.gradient_shape.* = shape.id;
    settings.gradient_paint.* = paint_id;
    settings.gradient_stroke.* = @intFromBool(stroke);
    settings.gradient_kind.* = if (editor.tool.* == names.radial) names.radial else names.linear;
    settings.gradient_colors.* = if (existing) |found| .{ found.stop_colors[0], found.stop_colors[1] } else .{ settings.fill_color.*, settings.stroke_color.* };
    settings.gradient_answers.* = 0;
    errdefer settings.gradient_shape.* = 0;
    const start = editor.gesture_start.*;
    const end = editor.gesture_current.*;
    const asker = workspace.system();
    try asks.paintMapping(tables, atoms, asker, .{ .purpose = .gradient_start, .point = start, .value = shape.id }, shape.id, paint, start);
    try asks.paintMapping(tables, atoms, asker, .{ .purpose = .gradient_end, .point = end, .value = shape.id }, shape.id, paint, end);
}

/// Keeps a released gradient's start or end in the paint's space, and sends the paint's edit
/// once it has both. A failed answer drops the edit.
pub fn gradientAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const settings = config(tables);
    if (settings.gradient_shape.* == 0 or answer.value != settings.gradient_shape.*) return;
    const asked = asks.rows(tables);
    errdefer {
        settings.gradient_shape.* = 0;
        asks.forget(asked, .gradient_start);
        asks.forget(asked, .gradient_end);
    }
    try answer.failure.check();
    const mapped = answer.paint();
    const bind_point = mapped.bind_point orelse return error.InvalidGeometry;
    if (answer.purpose == .gradient_start) {
        settings.gradient_start.* = bind_point;
        settings.gradient_answers.* |= GradientAnswers.start;
    } else {
        settings.gradient_end.* = bind_point;
        settings.gradient_answers.* |= GradientAnswers.end;
    }
    if (settings.gradient_answers.* != GradientAnswers.start | GradientAnswers.end) return;
    const shape = settings.gradient_shape.*;
    settings.gradient_shape.* = 0;
    const editor = session.get(tables);
    try transport.send(tables, atoms, .{ .set_paint = .{
        .doc = editor.doc.*,
        .shape = shape,
        .id = settings.gradient_paint.*,
        .stroke = settings.gradient_stroke.* != 0,
        .kind = settings.gradient_kind.*,
        .start = settings.gradient_start.*,
        .end = settings.gradient_end.*,
        .colors = settings.gradient_colors.*,
    } });
}
// Actions, clipboard, and colors
/// What sampling a colour takes from the frontmost of the shapes a hit test found: the shape,
/// and its fill's or else its stroke's flat colour, or the paint (non-zero) whose colour at the
/// sampled point only the host can say (`sampledColor`).
pub const Sample = struct { shape: u32, color: session.Color, paint: u32 = 0 };

/// What sampling takes from the shapes `found`; null when it found none.
pub fn sampleOf(tables: *Table.Registry, atoms: *Atom.Registry, found: []const api.Hit) !?Sample {
    const editor = session.get(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    if (found.len == 0) return null;
    const shape = session.findById(api.read.Shape, definition.shapes, found[0].object.id) orelse return error.MissingShape;
    const filled = shape.fill_color[3] != 0 or shape.fill_paint != 0;
    const rgba = if (filled) shape.fill_color else shape.stroke_color;
    const paint_id = if (filled) shape.fill_paint else shape.stroke_paint;
    return .{ .shape = shape.id, .color = rgba, .paint = paint_id };
}

/// `sample`'s colour at `point` when it is flat; for a paint, null, having asked the host for the
/// paint's colour there for `purpose`, answered in `asker`'s inbox (`paintColor` reads it).
pub fn sampledColor(tables: *Table.Registry, atoms: *Atom.Registry, asker: sequencer.System, purpose: asks.Purpose, point: session.Vec2, sample: Sample) !?session.Color {
    if (sample.paint == 0) return sample.color;
    const question: asks.Question = .{ .purpose = purpose, .point = point, .value = sample.shape };
    try asks.paintMapping(tables, atoms, asker, question, sample.shape, sample.paint, point);
    return null;
}

/// The colour a paint mapping asked by `sampledColor` found.
pub fn paintColor(answer: asks.Answer) !session.Color {
    try answer.failure.check();
    const mapped = answer.paint();
    return mapped.color orelse error.InvalidGeometry;
}

/// The eyedropper's press gives the selection the colour of the artwork the host found under it,
/// or asks the paint's colour there (`eyedropperPaintAnswered`).
pub fn eyedropperAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    if (session.get(tables).tool.* != names.eyedropper) return;
    try answer.failure.check();
    const sample = try sampleOf(tables, atoms, answer.hits()) orelse return;
    const asker = workspace.system();
    const color = try sampledColor(tables, atoms, asker, .eyedropper_paint, answer.point, sample) orelse return;
    try color_picker.applyToSelection(tables, atoms, color);
}

/// The eyedropper's press gives the selection the colour of the paint it found.
pub fn eyedropperPaintAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    if (session.get(tables).tool.* != names.eyedropper) return;
    const color = try paintColor(answer);
    try color_picker.applyToSelection(tables, atoms, color);
}

pub fn rememberColor(recent: RecentRows, color: session.Color) !void {
    var rows = recent.query();
    var previous_index: u32 = 16;
    while (rows.next()) |row| {
        if (std.meta.eql(row.view.color.*, color)) {
            previous_index = row.view.index.*;
            break;
        }
    }
    if (previous_index == 0) return;
    rows = recent.query();
    while (rows.next()) |row| {
        if (std.meta.eql(row.view.color.*, color)) {
            row.view.index.* = 0;
        } else if (row.view.index.* < previous_index) row.view.index.* += 1;
        if (row.view.index.* >= 16) recent.free(row.handle);
    }
    if (previous_index < 16) return;
    _ = try recent.insert(Recent{ .color = color });
}
pub fn handleAction(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    const message = tag.to(Msg);
    switch (message) {
        .figure_edit_points_done => {
            if (editor.tool.* == names.edit_points) finishPointEditing(tables, atoms);
        },
        .figure_edit_points => {
            if (editor.active_kind.* != names.shape or !try beginPointEditing(tables, atoms, editor.active_id.*)) {
                prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Select an editable path first");
            }
        },
        .figure_tool_pen, .figure_tool_rect, .figure_tool_ellipse, .figure_tool_line, .figure_tool_polygon, .figure_tool_pencil, .figure_tool_joint_fill, .figure_tool_gradient, .figure_tool_radial, .figure_tool_eyedropper, .figure_tool_eraser => {
            const chosen_tool = workspace.toolOf(tag) orelse return false;
            if (!owns(chosen_tool)) return false;
            if (editor.tx_active.* != 0) try transport.send(tables, atoms, .{ .commit = .{ .doc = editor.doc.* } });
            if (editor.tool.* == names.edit_points) finishPointEditing(tables, atoms);
            editor.tx_active.* = 0;
            editor.gesture_active.* = 0;
            clear(session.drafts(tables), session.get(tables));
            weight.discard(weight.config(tables), weight.boneStates(tables));
            // Joint fill hangs artwork on joints, so it is a Rig tool; the rest draw in Design,
            // which starts with nothing chosen, as its tab does: a bone is not Design's to edit.
            const tool_mode = if (chosen_tool == names.joint_fill) names.rig else names.design;
            const entering_design = tool_mode == names.design and editor.mode.* != names.design;
            if (entering_design) selection.clear(session.get(tables), session.observed(tables), session.selections(tables));
            editor.mode.* = tool_mode;
            editor.reparent_active.* = 0;
            editor.tool.* = chosen_tool;
        },
        .figure_draft_backspace => {
            if (editor.tool.* != names.pen and editor.tool.* != names.joint_fill) return true;
            if (editor.gesture_active.* != 0) return true;
            const draft_table = session.drafts(tables);
            var rows = draft_table.read();
            while (rows.next()) |row| {
                if (row.view.doc.* == editor.doc.* and row.view.index.* == draft_table.count() - 1) {
                    draft_table.free(row.handle);
                    break;
                }
            }
        },
        .figure_polygon_more, .figure_polygon_less => {
            const sides = if (message == .figure_polygon_more) settings.polygon_sides.* +| 1 else settings.polygon_sides.* -| 1;
            settings.polygon_sides.* = std.math.clamp(sides, 3, 128);
        },
        .figure_layer_add => {
            try transport.send(tables, atoms, .{ .add_layer = .{ .doc = editor.doc.* } });
        },
        .figure_layer_delete => {
            const id = editor.active_layer.*;
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            var nonempty = false;
            for (definition.shapes) |shape| {
                if (shape.layer == id or (session.findById(api.read.Layer, definition.layers, shape.layer) orelse continue).parent == id) nonempty = true;
            }
            if (nonempty and settings.pending_delete_layer.* != id) {
                settings.pending_delete_layer.* = id;
                prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Layer contains shapes. Delete again to confirm; Esc cancels.");
                return true;
            }
            try transport.send(tables, atoms, .{ .delete_layer = .{
                .doc = editor.doc.*,
                .id = id,
                .confirmed = true,
            } });
            settings.pending_delete_layer.* = 0;
        },
        .figure_layer_up, .figure_layer_down => {
            try transport.send(tables, atoms, .{ .move_layer = .{
                .doc = editor.doc.*,
                .id = editor.active_layer.*,
                .direction = if (message == .figure_layer_up) 1 else -1,
            } });
        },
        .figure_shape_forward, .figure_shape_backward, .figure_shape_front, .figure_shape_back => {
            try transport.send(tables, atoms, .{ .order_shapes = .{
                .doc = editor.doc.*,
                .ids = try selection.selectedShapeIds(tables),
                .direction = if (message == .figure_shape_forward or message == .figure_shape_front) 1 else -1,
                .extreme = message == .figure_shape_front or message == .figure_shape_back,
            } });
        },
        .figure_shapes_to_layer => {
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            const layer = session.findById(api.read.Layer, definition.layers, editor.active_layer.*) orelse return error.MissingLayer;
            try prompts.show(tables.memory, tables, atoms, names.move_shapes_layer, atoms.lookup(layer.name).?);
        },
        .figure_shape_delete => {
            try transport.send(tables, atoms, .{ .delete_shapes = .{ .doc = editor.doc.*, .ids = try selection.selectedShapeIds(tables) } });
        },
        .figure_copy, .figure_cut, .figure_duplicate => {
            const use: ClipboardUse = switch (message) {
                .figure_cut => .cut,
                .figure_duplicate => .duplicate,
                else => .copy,
            };
            try askClipboard(tables, atoms, use);
        },
        .figure_paste => try pasteClipboard(tables, atoms, editor),
        .figure_path_closed => {
            const path = try editingPath(tables, atoms) orelse return error.SelectEditablePath;
            try transport.send(tables, atoms, .{ .set_shape = .{
                .doc = editor.doc.*,
                .id = path.shape.id,
                .closed = @intFromBool(path.shape.closed == 0),
            } });
        },
        .figure_point_delete, .figure_point_smooth, .figure_point_corner, .figure_point_make_smooth, .figure_point_mirror => try editSelectedPoints(tables, atoms, editor, message),
        .figure_fill_toggle, .figure_stroke_toggle => {
            const fill = message == .figure_fill_toggle;
            if (fill) settings.fill_enabled.* = 1 - settings.fill_enabled.* else settings.stroke_enabled.* = 1 - settings.stroke_enabled.*;
            const ids = try selection.selectedShapeIds(tables);
            for (ids) |id| {
                try transport.send(tables, atoms, .{ .set_shape = .{
                    .doc = editor.doc.*,
                    .id = id,
                    .fill_color = if (fill) (if (settings.fill_enabled.* != 0) settings.fill_color.* else .{ 0, 0, 0, 0 }) else null,
                    .stroke_color = if (!fill) (if (settings.stroke_enabled.* != 0) settings.stroke_color.* else .{ 0, 0, 0, 0 }) else null,
                    .fill_paint = if (fill) 0 else null,
                    .stroke_paint = if (!fill) 0 else null,
                } });
            }
        },
        else => return false,
    }
    return true;
}

/// Asks the host for the selected shapes as the clipboard keeps them, none when nothing is
/// selected; `clipboardAnswered` keeps them and goes on with `use`. The shapes asked for are kept
/// in `editor_figure_copied`, so a cut deletes exactly what it copied whatever the selection has
/// become by the answer. The canvas holds its own input until then.
fn askClipboard(tables: *Table.Registry, atoms: *Atom.Registry, use: ClipboardUse) !void {
    const editor = session.get(tables);
    const ids = try selection.selectedShapeIds(tables);
    // What is copied is kept with the question, so a cut deletes exactly it.
    const copied = copiedShapes(tables);
    copied.clear();
    for (ids) |id| _ = try copied.insert(Copied{ .id = id });
    const query: figure.Query = .{ .encode_shape_clipboard = .{ .definition = editor.doc.*, .ids = ids } };
    const question: asks.Question = .{ .purpose = .clipboard, .point = session.zero, .value = @intFromEnum(use) };
    const context = session.figureContext(tables, atoms);
    const asked = asks.rows(tables);
    const asker = system();
    try asks.ask(context, asked, editor, asker, query, question);
}

/// Keeps the copied shapes' bytes as the clipboard, in chunks of a row each, then deletes what
/// was copied for a cut, or pastes it for a duplicate.
fn clipboardAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    try answer.failure.check();
    const bytes = answer.bytes();
    const clipboard_table = clipboardChunks(tables);
    clipboard_table.clear();
    var offset: usize = 0;
    while (offset < bytes.len) {
        var chunk = Clipboard{ .index = @intCast(offset / 1024), .len = @intCast(@min(1024, bytes.len - offset)) };
        @memcpy(chunk.bytes[0..chunk.len], bytes[offset..][0..chunk.len]);
        _ = try clipboard_table.insert(chunk);
        offset += chunk.len;
    }
    const editor = session.get(tables);
    const use = std.enums.fromInt(ClipboardUse, answer.value) orelse .copy;
    switch (use) {
        .copy => {},
        .cut => {
            const copied = copiedShapes(tables);
            const allocator = try frameAllocator(tables);
            const ids = try allocator.alloc(u32, copied.count());
            var filled: usize = 0;
            var rows = copied.read();
            while (rows.next()) |row| : (filled += 1) ids[filled] = row.view.id.*;
            const doc = editor.doc.*;
            try transport.send(tables, atoms, .{ .delete_shapes = .{ .doc = doc, .ids = ids } });
        },
        .duplicate => try pasteClipboard(tables, atoms, editor),
    }
}

/// Pastes the clipboard's artwork into the active layer.
fn pasteClipboard(tables: *Table.Registry, atoms: *Atom.Registry, editor: session.View) !void {
    const clipboard_table = clipboardChunks(tables);
    const bytes = try (try frameAllocator(tables)).alloc(u8, @as(usize, clipboard_table.count()) * 1024);
    var len: usize = 0;
    var rows = clipboard_table.read();
    while (rows.next()) |row| {
        const offset = @as(usize, row.view.index.*) * 1024;
        if (row.view.len.* > 1024 or offset + row.view.len.* > bytes.len) return error.InvalidClipboard;
        @memcpy(bytes[offset..][0..row.view.len.*], row.view.bytes[0..row.view.len.*]);
        len = @max(len, offset + row.view.len.*);
    }
    if (len > 0) try transport.send(tables, atoms, .{ .paste_shapes = .{
        .doc = editor.doc.*,
        .layer = editor.active_layer.*,
        .bytes = bytes[0..len],
    } });
}

/// Deletes the edited path's selected anchors, or changes their handles: corners, smooth,
/// or mirrored.
fn editSelectedPoints(tables: *Table.Registry, atoms: *Atom.Registry, editor: session.View, message: Msg) !void {
    const path = try editingPath(tables, atoms) orelse return;
    const allocator = try frameAllocator(tables);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    var all_smooth = true;
    for (path.points) |point| {
        if (!pointSelected(session.get(tables), session.selections(tables), path.shape.id, point.index)) continue;
        try indices.append(allocator, point.index);
        if (point.flags & 1 == 0) all_smooth = false;
    }
    if (indices.items.len == 0) return;
    if (message == .figure_point_delete) {
        try transport.send(tables, atoms, .{ .delete_points = .{
            .doc = editor.doc.*,
            .shape = path.shape.id,
            .indices = indices.items,
        } });
        return;
    }
    // The scoped path can be updated atomically by one command and one undo step.
    const points = try commandPoints(allocator, path.points);
    for (indices.items) |index| {
        const point = &points[index];
        const corner = message == .figure_point_corner or (message == .figure_point_smooth and point.flags & 1 != 0);
        const independent = message == .figure_point_mirror and all_smooth;
        if (corner or independent) {
            point.flags &= ~@as(u32, 1);
            if (corner) {
                point.in = session.zero;
                point.out = session.zero;
            }
        } else {
            point.flags |= 1;
            var tangent = point.out;
            if (geometry.distance(tangent, session.zero) < 0.01) tangent = session.Vec2.scale(point.in, -1);
            if (geometry.distance(tangent, session.zero) < 0.01) tangent = .{ .x = 20, .y = 0 };
            point.out = tangent;
            point.in = session.Vec2.scale(tangent, -1);
        }
    }
    try transport.send(tables, atoms, .{ .set_points = .{
        .doc = editor.doc.*,
        .shape = path.shape.id,
        .points = points,
    } });
}
// Overlay
fn previewColor(rgba: session.Color, opacity: f32) roop.Color {
    const alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(rgba[3])) * opacity);
    return roop.rgba(rgba[0], rgba[1], rgba[2], alpha);
}

fn contrastsWithWhite(color: roop.Color) bool {
    const luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    const on_white = 1 - color.a + color.a * luminance;
    return on_white <= 0.3; // At least 3:1 contrast after compositing on white.
}

fn strokePreview(render_context: anytype, path_style: api.Style, color: roop.Color, width: f32) void {
    render_context.strokeColor(color);
    render_context.strokeWidth(width);
    if (path_style.cap == Atom.from("round")) render_context.lineCap(.round) else if (path_style.cap == Atom.from("square")) render_context.lineCap(.square) else render_context.lineCap(.butt);
    if (path_style.join == Atom.from("round")) render_context.lineJoin(.round) else if (path_style.join == Atom.from("bevel")) render_context.lineJoin(.bevel) else render_context.lineJoin(.miter);
    render_context.stroke();
}

fn renderPenDraft(tables: *Table.Registry, render_context: anytype) void {
    const editor = session.get(tables);
    const settings = config(tables);
    const points = draftPoints(tables) catch return;
    if (render_context.pathBudget().paths < 4) return;
    const zoom = editor.view_zoom.*;
    const accent = controls.edit;
    if (points.len == 0) {
        if (editor.hover_kind.* != names.pen_insert) return;
        const point = editor.hover_point.*;
        const radius = 5 / zoom;
        render_context.beginPath();
        render_context.circle(point.x, point.y, radius);
        render_context.fillColor(controls.paper);
        render_context.fill();
        render_context.strokeColor(accent);
        render_context.strokeWidth(1.5 / zoom);
        render_context.stroke();
        render_context.beginPath();
        render_context.moveTo(point.x - radius / 2, point.y);
        render_context.lineTo(point.x + radius / 2, point.y);
        render_context.moveTo(point.x, point.y - radius / 2);
        render_context.lineTo(point.x, point.y + radius / 2);
        render_context.stroke();
        return;
    }
    const closing = editor.gesture_active.* == 0 and editor.hover_kind.* == names.pen_close;
    const rubber_band = editor.gesture_active.* == 0 and (closing or editor.hover_kind.* == names.pen_cursor);
    render_context.beginPath();
    render_context.moveTo(points[0].p.x, points[0].p.y);
    for (points[1..], 1..) |point, index| {
        const previous = points[index - 1];
        const control_start = session.Vec2.add(previous.p, previous.out);
        const control_end = session.Vec2.add(point.p, point.in);
        render_context.bezierTo(control_start.x, control_start.y, control_end.x, control_end.y, point.p.x, point.p.y);
    }
    const last = points[points.len - 1];
    if (rubber_band) {
        const control_start = session.Vec2.add(last.p, last.out);
        const endpoint = if (closing) points[0] else api.read.Point{ .p = editor.hover_point.* };
        const control_end = session.Vec2.add(endpoint.p, endpoint.in);
        render_context.bezierTo(control_start.x, control_start.y, control_end.x, control_end.y, endpoint.p.x, endpoint.p.y);
    }
    const path_style = pathStyle(settings, .open);
    const stroke = previewColor(path_style.stroke_color, path_style.opacity);
    const visible_stroke = path_style.stroke_width * zoom >= 1 and contrastsWithWhite(stroke);
    // Substitute an editing guide for an unreadable draft stroke. Emitting one
    // stroke also avoids doubling variable-size geometry near the frame budget.
    const preview_color = if (visible_stroke) stroke else accent;
    const preview_width = if (visible_stroke) path_style.stroke_width else 1.5 / zoom;
    strokePreview(render_context, path_style, preview_color, preview_width);
    for (points, 0..) |point, index| {
        if (render_context.pathBudget().paths < 2) break;
        const radius = 3 / zoom;
        render_context.beginPath();
        render_context.rect(point.p.x - radius, point.p.y - radius, radius * 2, radius * 2);
        render_context.fillColor(if (index + 1 == points.len) accent else controls.paper);
        render_context.fill();
        render_context.strokeColor(accent);
        render_context.strokeWidth(controls.line_width / zoom);
        render_context.stroke();
    }
    if (closing and render_context.pathBudget().paths > 0) {
        render_context.beginPath();
        render_context.circle(points[0].p.x, points[0].p.y, 8 / zoom);
        render_context.strokeColor(accent);
        render_context.strokeWidth(2 / zoom);
        render_context.stroke();
    }
    if (editor.gesture_active.* != 0) {
        const handles = [_]session.Vec2{ session.Vec2.add(last.p, last.in), session.Vec2.add(last.p, last.out) };
        for (handles) |position| {
            if (geometry.distance(position, last.p) * zoom < 2 or render_context.pathBudget().paths < 2) continue;
            render_context.beginPath();
            render_context.moveTo(last.p.x, last.p.y);
            render_context.lineTo(position.x, position.y);
            render_context.strokeColor(accent);
            render_context.strokeWidth(controls.line_width / zoom);
            render_context.stroke();
            render_context.beginPath();
            render_context.circle(position.x, position.y, 3 / zoom);
            render_context.fillColor(controls.paper);
            render_context.fill();
            render_context.stroke();
        }
    }
}

pub fn renderOverlay(reads: *session.ReadContext, render_context: anytype) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const editor = session.get(tables);
    const settings = config(tables);
    if (editor.tool.* == names.pen) renderPenDraft(tables, render_context);
    const drawing_active = editor.gesture_active.* != 0 and editor.gesture_kind.* == names.draw;
    if (owns(editor.tool.*) and editor.tool.* != names.pen and (drawing_active or session.drafts(tables).count() > 0)) {
        const path = previewPath(tables) catch return;
        const path_points = path.points;
        if (path_points.len > 0 and render_context.pathBudget().paths > 4) {
            render_context.beginPath();
            render_context.moveTo(path_points[0].p.x, path_points[0].p.y);
            for (path_points[1..], 1..) |path_point, i| {
                const previous_point = path_points[i - 1];
                render_context.bezierTo(previous_point.p.x + previous_point.out.x, previous_point.p.y + previous_point.out.y, path_point.p.x + path_point.in.x, path_point.p.y + path_point.in.y, path_point.p.x, path_point.p.y);
            }
            if (path.kind != .open) {
                const previous_point = path_points[path_points.len - 1];
                const path_point = path_points[0];
                render_context.bezierTo(previous_point.p.x + previous_point.out.x, previous_point.p.y + previous_point.out.y, path_point.p.x + path_point.in.x, path_point.p.y + path_point.in.y, path_point.p.x, path_point.p.y);
                render_context.closePath();
            }
            if (primitiveTool(editor.tool.*) != null or editor.tool.* == names.pencil or editor.tool.* == names.joint_fill) {
                const path_style = pathStyle(settings, path.kind);
                const fill = previewColor(path_style.fill_color, path_style.opacity);
                if (path_style.fill_color[3] != 0) {
                    render_context.fillColor(fill);
                    render_context.fill();
                }
                const stroke = previewColor(path_style.stroke_color, path_style.opacity);
                const visible_fill = path.kind != .open and contrastsWithWhite(fill);
                const visible_stroke = path_style.stroke_width * editor.view_zoom.* >= 1 and contrastsWithWhite(stroke);
                if (!visible_fill and !visible_stroke) {
                    const guide_width = 1.5 / editor.view_zoom.*;
                    strokePreview(render_context, path_style, controls.edit, guide_width);
                } else if (path_style.stroke_color[3] != 0) {
                    strokePreview(render_context, path_style, stroke, path_style.stroke_width);
                }
            } else {
                render_context.strokeColor(controls.edit);
                render_context.strokeWidth(2 / editor.view_zoom.*);
                render_context.stroke();
            }
            if (editor.tool.* == names.joint_fill) {
                for (path_points, 0..) |path_point, index| {
                    if (render_context.pathBudget().paths < 2) break;
                    const radius: f32 = if (index == 0 and path_points.len >= 3) 6 else 4;
                    render_context.beginPath();
                    render_context.circle(path_point.p.x, path_point.p.y, radius / editor.view_zoom.*);
                    render_context.fillColor(controls.paper);
                    render_context.fill();
                    render_context.strokeColor(controls.edit);
                    render_context.strokeWidth(1.5 / editor.view_zoom.*);
                    render_context.stroke();
                }
            }
        }
    }
    if (editor.hover_kind.* == names.sample_color and render_context.pathBudget().paths >= 3) {
        const zoom = editor.view_zoom.*;
        const point = editor.hover_point.*;
        const x = point.x + 14 / zoom;
        const y = point.y + 14 / zoom;
        const size = 24 / zoom;
        render_context.beginPath();
        render_context.rect(x, y, size, size);
        render_context.fillColor(controls.paper);
        render_context.fill();
        const color = settings.sampled_color.*;
        render_context.fillColor(roop.rgba(color[0], color[1], color[2], color[3]));
        render_context.fill();
        render_context.strokeColor(controls.ink);
        render_context.strokeWidth(1.5 / zoom);
        render_context.stroke();
    }
    if (editor.tool.* == names.edit_points) {
        const maybe_path = editingPathWithReads(reads) catch return;
        const path = maybe_path orelse return;
        const zoom = editor.view_zoom.*;
        const accent = controls.edit;
        if (editor.hover_kind.* == names.path_segment and editor.hover_id.* == path.shape.id and editor.hover_sub.* < path.points.len and render_context.pathBudget().paths >= 1) {
            const index = editor.hover_sub.*;
            const next = (index + 1) % path.points.len;
            if (next != 0 or path.shape.closed != 0) {
                const start = path.points[index];
                const end = path.points[next];
                const control_start = session.Vec2.add(start.p, start.out);
                const control_end = session.Vec2.add(end.p, end.in);
                render_context.beginPath();
                render_context.moveTo(start.p.x, start.p.y);
                render_context.bezierTo(control_start.x, control_start.y, control_end.x, control_end.y, end.p.x, end.p.y);
                render_context.strokeColor(accent);
                render_context.strokeWidth(2 / zoom);
                render_context.stroke();
            }
        }
        for (path.points, 0..) |path_point, index| {
            if (render_context.pathBudget().paths < 7) break;
            if (showPointHandles(session.get(tables), session.selections(tables), path, index)) {
                const handles = [_]session.Vec2{ session.Vec2.add(path_point.p, path_point.in), session.Vec2.add(path_point.p, path_point.out) };
                for (handles) |position| {
                    if (geometry.distance(position, path_point.p) * zoom < 2) continue;
                    render_context.beginPath();
                    render_context.moveTo(path_point.p.x, path_point.p.y);
                    render_context.lineTo(position.x, position.y);
                    render_context.strokeColor(accent);
                    render_context.strokeWidth(controls.line_width / zoom);
                    render_context.stroke();
                    render_context.beginPath();
                    render_context.circle(position.x, position.y, 3 / zoom);
                    render_context.fillColor(controls.paper);
                    render_context.fill();
                    render_context.stroke();
                }
            }
            const selected = pointSelected(session.get(tables), session.selections(tables), path.shape.id, path_point.index);
            const hovered = editor.hover_kind.* == names.path_anchor and editor.hover_id.* == path.shape.id and editor.hover_sub.* == path_point.index;
            const radius: f32 = (if (hovered) @as(f32, 4.5) else 3.5) / zoom;
            render_context.beginPath();
            render_context.rect(path_point.p.x - radius, path_point.p.y - radius, radius * 2, radius * 2);
            render_context.fillColor(if (selected) accent else controls.paper);
            render_context.fill();
            render_context.strokeColor(accent);
            render_context.strokeWidth(controls.line_width / zoom);
            render_context.stroke();
        }
    }
    if ((editor.tool.* == names.gradient or editor.tool.* == names.radial) and editor.gesture_active.* == 0) {
        if (primaryShape(tables, atoms)) |shape| {
            const paint_id = if (settings.color_target.* == names.stroke) shape.stroke_paint else shape.fill_paint;
            const handles = if (paint_id != 0) paintHandles(settings, editor, shape.id, paint_id) else null;
            if (handles) |mapped| {
                const start = mapped.start;
                const end = mapped.end;
                render_context.beginPath();
                render_context.moveTo(start.x, start.y);
                render_context.lineTo(end.x, end.y);
                render_context.circle(start.x, start.y, 4 / editor.view_zoom.*);
                render_context.circle(end.x, end.y, 4 / editor.view_zoom.*);
                render_context.strokeColor(controls.caution);
                render_context.strokeWidth(2 / editor.view_zoom.*);
                render_context.stroke();
            }
        }
    }
    if ((editor.tool.* == names.gradient or editor.tool.* == names.radial) and editor.gesture_active.* != 0) {
        render_context.beginPath();
        render_context.moveTo(editor.gesture_start.x, editor.gesture_start.y);
        render_context.lineTo(editor.gesture_current.x, editor.gesture_current.y);
        render_context.circle(editor.gesture_start.x, editor.gesture_start.y, 4 / editor.view_zoom.*);
        render_context.circle(editor.gesture_current.x, editor.gesture_current.y, 4 / editor.view_zoom.*);
        render_context.strokeColor(controls.caution);
        render_context.strokeWidth(2 / editor.view_zoom.*);
        render_context.stroke();
    }
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ "fill", "stroke" });
    try session.prepareSingleton(Config, mem, atoms, tables, config_name);
    try session.prepareTable(Clipboard, mem, atoms, tables, clipboard_name, 256);
    try session.prepareTable(Copied, mem, atoms, tables, copied_name, copied_capacity);
    try session.prepareTable(Recent, mem, atoms, tables, recent_colors_name, 16);
    try session.prepareTable(Erased, mem, atoms, tables, erased_name, erased_capacity);
}
