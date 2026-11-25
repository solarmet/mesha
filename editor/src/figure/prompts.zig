const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const workspace = @import("workspace.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const resources = mesha.resources;
const roop = mesha.roop;
const zon = mesha.zon;
const session = @import("session.zig");
const drawing = @import("drawing.zig");
const color_picker = @import("color_picker.zig");
const selection = @import("selection.zig");
const pose = @import("pose.zig");
const weight = @import("weight.zig");
const action_palette = @import("../action_palette.zig");
const transport = @import("commands.zig");
const sketches = @import("sketches.zig");
const api = plugin.figure_api;
const filmstrip = @import("filmstrip.zig");

/// The palette answers a figure prompt to the canvas, which takes its prompts' replies.
fn promptReply() mesha.sequencer.ReplyTo {
    return mesha.sequencer.ReplyTo.of(workspace.system(), .from(workspace.Msg.figure_prompt_reply));
}
pub const owner = Atom.from("editor.figure.prompt");
/// A prompt entry's choice: what it does and the document it names.
const Choice = extern struct { action: u32 = 0, id: Atom = session.none };
/// `switch_document`'s choice that shows an open sketch, beside 1, which shows a loaded figure.
const open_sketch: u32 = 4;
/// How dragging a numeric field changes it, by horizontal travel. A two-part value is a
/// vector, shown as a field for each component: a drag changes the component it began on.
pub const Scrub = struct {
    per_pixel: f32,
    min: f32 = -std.math.inf(f32),
    max: f32 = std.math.inf(f32),
    decimals: u8 = 1,
    axes: enum { one, two } = .one,
};
pub const InspectorField = struct {
    name: []const u8,
    label: []const u8,
    hint: []const u8 = "",
    /// A heading shown above this row, starting a group.
    section: []const u8 = "",
    /// A click steps through these rather than opening a text field.
    choices: []const []const u8 = &.{},
    scrub: ?Scrub = null,

    /// True for a checkbox: a click flips it rather than opening a text field.
    pub fn isToggle(self: InspectorField) bool {
        return std.mem.startsWith(u8, self.hint, "true / false");
    }

    /// True for a value of two components, each shown, dragged and typed on its own.
    pub fn isVector(self: InspectorField) bool {
        const scrub = self.scrub orelse return false;
        return scrub.axes == .two;
    }
};
pub const defaults_kind = Atom.from("tool_defaults");
/// Tool options in the option bar. Field indices are `drawing.ToolOption` ordinals.
pub const tool_option_kind = Atom.from("tool_option");
const opacity_scrub = Scrub{ .per_pixel = 0.005, .min = 0, .max = 1, .decimals = 3 };
const stroke_scrub = Scrub{ .per_pixel = 0.1, .min = 0 };
const defaults_fields = [_]InspectorField{
    .{ .name = "fill_on", .label = "Fill enabled", .hint = "true / false; applies to new artwork only" },
    .{ .name = "fill_color", .label = "Fill RGBA", .hint = "Hex #RRGGBB or #RRGGBBAA; applies to new artwork only" },
    .{ .name = "stroke_on", .label = "Stroke enabled", .hint = "true / false; applies to new artwork only" },
    .{ .name = "stroke_color", .label = "Stroke RGBA", .hint = "Hex #RRGGBB or #RRGGBBAA; applies to new artwork only" },
    .{ .name = "stroke_width", .label = "Stroke width", .hint = "Finite width of at least 0; applies to new artwork only", .scrub = stroke_scrub },
    .{ .name = "layer", .label = "Target layer", .hint = "Name of an existing, visible, unlocked art layer" },
};

pub const InspectorTarget = struct { kind: Atom, id: u32 };
pub fn inspectorTarget(editor: session.View, settings: drawing.ConfigView) InspectorTarget {
    if (session.atRest(editor) and drawing.createsArtwork(editor.tool.*)) {
        return .{ .kind = defaults_kind, .id = 0 };
    }
    if (editor.tool.* == names.edit_points) {
        if (settings.edit_doc.* == editor.doc.* and settings.edit_shape.* != 0) {
            return .{ .kind = names.shape, .id = settings.edit_shape.* };
        }
    }
    return .{ .kind = editor.active_kind.*, .id = editor.active_id.* };
}
const bone_fields = [_]InspectorField{
    .{ .name = "name", .label = "Name", .hint = "A snake_case name" },
    .{ .name = "parent", .label = "Parent", .hint = "Existing bone name or none; cannot parent a bone to itself or its descendants" },
    .{ .name = "angle", .label = "Angle (degrees)", .hint = "A finite angle in degrees", .scrub = .{ .per_pixel = 0.5 } },
    .{ .name = "length", .label = "Length", .hint = "Finite length of at least 0", .scrub = .{ .per_pixel = 0.5, .min = 0 } },
    .{ .name = "local", .label = "Local", .hint = "Two finite coordinates: x,y", .scrub = .{ .per_pixel = 0.5, .axes = .two } },
    .{ .name = "scale", .label = "Scale", .hint = "Two finite scale values x,y, each with magnitude at least 0.000001", .scrub = .{ .per_pixel = 0.01, .min = 0.01, .decimals = 2, .axes = .two } },
    .{ .name = "connected", .label = "Connected", .hint = "true / false" },
    .{ .name = "deform", .label = "Deform", .hint = "true / false" },
    .{ .name = "static", .label = "Static", .hint = "true / false" },
    .{ .name = "stretchy", .label = "Stretchy", .hint = "true / false" },
};
pub fn boneFieldIndex(comptime name: []const u8) u32 {
    return comptime find: {
        for (bone_fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) break :find @intCast(index);
        }
        @compileError("Unknown bone inspector field: " ++ name);
    };
}

test "pose bone field indices" {
    try std.testing.expectEqual(@as(u32, 2), boneFieldIndex("angle"));
    try std.testing.expectEqual(@as(u32, 3), boneFieldIndex("length"));
    try std.testing.expectEqual(@as(u32, 4), boneFieldIndex("local"));
    try std.testing.expectEqual(@as(u32, 5), boneFieldIndex("scale"));
}

const shape_fields = [_]InspectorField{
    .{ .section = "General", .name = "name", .label = "Name", .hint = "A snake_case name" },
    .{ .name = "layer", .label = "Layer", .hint = "Name of an existing art layer (not a folder)" },
    .{ .name = "opacity", .label = "Opacity", .hint = "Finite value from 0 to 1", .scrub = opacity_scrub },
    .{ .name = "visible", .label = "Visible", .hint = "true / false" },
    .{ .section = "Fill", .name = "fill_on", .label = "Fill enabled", .hint = "true / false; false removes this shape's fill paint. Undo restores it." },
    .{ .name = "fill_color", .label = "Fill RGBA", .hint = "Hex #RRGGBB or #RRGGBBAA" },
    .{ .section = "Stroke", .name = "stroke_on", .label = "Stroke enabled", .hint = "true / false; false removes this shape's stroke paint. Undo restores it." },
    .{ .name = "stroke_color", .label = "Stroke RGBA", .hint = "Hex #RRGGBB or #RRGGBBAA" },
    .{ .name = "stroke_width", .label = "Stroke width", .hint = "Finite width of at least 0", .scrub = stroke_scrub },
    .{ .name = "stroke_glow_radius", .label = "Glow radius", .hint = "How far the glow bleeds outward from the stroke; 0 for none", .scrub = stroke_scrub },
    .{ .name = "stroke_glow_color", .label = "Glow RGBA", .hint = "Hex #RRGGBB or #RRGGBBAA" },
    .{ .name = "cap", .label = "Stroke cap", .hint = "butt, round or square", .choices = &.{ "butt", "round", "square" } },
    .{ .name = "join", .label = "Stroke join", .hint = "miter, round or bevel", .choices = &.{ "miter", "round", "bevel" } },
    .{ .name = "stroke_kind", .label = "Stroke kind", .hint = "line, square_line, circle or circle_fill", .choices = &.{ "line", "square_line", "circle", "circle_fill" } },
};
const layer_fields = [_]InspectorField{
    .{ .name = "clip_to_below", .label = "Clip to below", .hint = "true / false" },
    .{ .name = "name", .label = "Name", .hint = "A snake_case name" },
    .{ .name = "parent", .label = "Folder (none for root)", .hint = "Root-level folder name or none; folders cannot be nested" },
    .{ .name = "blend", .label = "Blend mode", .hint = "normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, add, hue, saturation, color or luminosity" },
    .{ .name = "opacity", .label = "Opacity", .hint = "Finite value from 0 to 1", .scrub = opacity_scrub },
    .{ .name = "visible", .label = "Visible", .hint = "true / false" },
    .{ .name = "locked", .label = "Locked", .hint = "true / false" },
    .{ .name = "order", .label = "Order", .hint = "A nonnegative integer" },
};
fn toolOptionScrub(option: drawing.ToolOption) Scrub {
    return switch (option) {
        .corner_radius => .{ .per_pixel = 0.5, .min = 0 },
        .polygon_sides => .{ .per_pixel = 0.1, .min = 3, .max = 128, .decimals = 0 },
        .pencil_spacing => .{ .per_pixel = 0.05, .min = 0.5, .decimals = 2 },
        .pencil_simplify => .{ .per_pixel = 0.05, .min = 0, .decimals = 2 },
        .pencil_error => .{ .per_pixel = 0.05, .min = 0.01, .decimals = 2 },
        .pencil_close => .{ .per_pixel = 0.5, .min = 0 },
    };
}

const tool_option_fields = blk: {
    const options = std.enums.values(drawing.ToolOption);
    var fields: [options.len]InspectorField = undefined;
    for (options, &fields) |option, *field| {
        const detail = option.details();
        field.* = .{ .name = @tagName(option), .label = detail.label, .hint = detail.range, .scrub = toolOptionScrub(option) };
    }
    break :blk fields;
};

/// The names the inspector's fields store as atoms: each field's own, and its choices.
/// Interned with the figure editor's names when it starts.
pub const field_vocabulary = blk: {
    @setEvalBranchQuota(100_000);
    var count: usize = 0;
    for ([_][]const InspectorField{ &defaults_fields, &tool_option_fields, &bone_fields, &shape_fields, &layer_fields }) |fields| {
        for (fields) |field| count += 1 + field.choices.len;
    }
    var vocabulary: [count][]const u8 = undefined;
    var index: usize = 0;
    for ([_][]const InspectorField{ &defaults_fields, &tool_option_fields, &bone_fields, &shape_fields, &layer_fields }) |fields| {
        for (fields) |field| {
            vocabulary[index] = field.name;
            index += 1;
            for (field.choices) |choice| {
                vocabulary[index] = choice;
                index += 1;
            }
        }
    }
    break :blk vocabulary;
};

/// The name of a prompt's stored field: one of its target's inspector fields, a tool or brush
/// option, or a point's axis. Found among the names it could be, so none is looked up.
fn fieldName(target_kind: Atom, field: Atom) ?[]const u8 {
    for (inspectorFields(target_kind)) |definition| {
        if (Atom.from(definition.name) == field) return definition.name;
    }
    if (session.enumFromAtom(drawing.ToolOption, field)) |option| return @tagName(option);
    if (session.enumFromAtom(weight.BrushOption, field)) |option| return @tagName(option);
    if (session.enumFromAtom(drawing.PointAxis, field)) |axis| return @tagName(axis);
    return null;
}

pub fn inspectorFields(target_kind: Atom) []const InspectorField {
    if (target_kind == defaults_kind) return &defaults_fields;
    if (target_kind == tool_option_kind) return &tool_option_fields;
    if (target_kind == Atom.from("bone")) return &bone_fields;
    if (target_kind == Atom.from("shape")) return &shape_fields;
    if (target_kind == Atom.from("layer")) return &layer_fields;
    return &.{};
}

/// Sets the status. `session_table` is the table the session's row is in (`session.table`),
/// which holds the text; a status that cannot be kept leaves the one before.
pub fn status(session_table: *Table, editor: session.View, feedback: session.FeedbackView, text: []const u8) void {
    feedback.prompt_error_owned.* = 0;
    session_table.assignString(editor.status, text) catch {};
}

/// Shows `text` for a few seconds. `feedback_table` is the table the feedback's row is in
/// (`session.feedbackTable`); information that cannot be kept is not shown.
pub fn inform(feedback_table: *Table, feedback: session.FeedbackView, text: []const u8) void {
    feedback_table.assignString(feedback.information, text) catch {
        feedback.information.* = .{};
        feedback.information_seconds.* = 0;
        return;
    };
    feedback.information_seconds.* = if (text.len == 0) 0 else 4;
}

/// Only the dedicated frame message advances this lifetime; rendering and command
/// acknowledgements cannot clear or resurrect information from a newer action.
pub fn tickInformation(feedback: session.FeedbackView, seconds: f32) void {
    if (!std.math.isFinite(seconds) or seconds <= 0) return;
    feedback.information_seconds.* = @max(0, feedback.information_seconds.* - seconds);
    if (feedback.information_seconds.* == 0) feedback.information.* = .{};
}

pub fn dismissError(editor: session.View, feedback: session.FeedbackView) void {
    feedback.prompt_error_owned.* = 0;
    editor.status.* = .{};
}

fn requireObject(comptime T: type, tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, object_id: u32) !T {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return requireReadObject(T, &reads, doc, object_id);
}

fn requireReadObject(comptime T: type, reads: *session.ReadContext, doc: Atom, object_id: u32) !T {
    const definition = try reads.definition(doc);
    const rows = if (T == api.read.Bone) definition.bones else if (T == api.read.Shape) definition.shapes else definition.layers;
    return session.findById(T, rows, object_id) orelse error.MissingSelection;
}

fn flagBit(field_name: []const u8) ?u32 {
    const flags = [_]struct { name: []const u8, bit: u32 }{
        .{ .name = "connected", .bit = session.BoneFlags.connected },
        .{ .name = "deform", .bit = session.BoneFlags.deform },
        .{ .name = "static", .bit = session.BoneFlags.static },
        .{ .name = "stretchy", .bit = session.BoneFlags.stretchy },
    };
    for (flags) |flag| if (std.mem.eql(u8, field_name, flag.name)) return flag.bit;
    return null;
}

pub fn valueText(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, object_id: u32, field_name: []const u8) ![]const u8 {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return valueTextWithReads(allocator, &reads, target_kind, object_id, field_name);
}

pub fn valueTextWithReads(allocator: std.mem.Allocator, reads: *session.ReadContext, target_kind: Atom, object_id: u32, field_name: []const u8) ![]const u8 {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const editor = session.get(tables);
    const doc = editor.doc.*;
    if (target_kind == tool_option_kind) {
        const option = std.meta.stringToEnum(drawing.ToolOption, field_name) orelse return error.MissingField;
        const settings = drawing.config(tables);
        return std.fmt.allocPrint(allocator, "{d}", .{option.value(settings)});
    }
    if (target_kind == defaults_kind) {
        const settings = drawing.config(tables);
        if (std.mem.eql(u8, field_name, "fill_on")) return if (settings.fill_enabled.* != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "stroke_on")) return if (settings.stroke_enabled.* != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "stroke_width")) return std.fmt.allocPrint(allocator, "{d}", .{settings.stroke_width.*});
        if (std.mem.eql(u8, field_name, "layer")) {
            if (editor.active_layer.* == 0) return "none";
            const layer = try requireReadObject(api.read.Layer, reads, doc, editor.active_layer.*);
            return atoms.lookup(layer.name) orelse "none";
        }
        if (std.mem.eql(u8, field_name, "stroke_color") or std.mem.eql(u8, field_name, "fill_color")) {
            const rgba = if (std.mem.eql(u8, field_name, "stroke_color")) settings.stroke_color.* else settings.fill_color.*;
            return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba[0], rgba[1], rgba[2], rgba[3] });
        }
        return error.MissingField;
    }
    if (target_kind == names.bone) {
        const bone = try requireReadObject(api.read.Bone, reads, doc, object_id);
        if (filmstrip.enabled(editor)) {
            if (std.mem.eql(u8, field_name, "angle") or std.mem.eql(u8, field_name, "length") or std.mem.eql(u8, field_name, "local") or std.mem.eql(u8, field_name, "scale")) return pose.editableTextWithReads(reads, object_id, field_name);
        }
        if (std.mem.eql(u8, field_name, "name")) return atoms.lookup(bone.name).?;
        if (std.mem.eql(u8, field_name, "parent")) {
            if (bone.parent == 0) return "none";
            const parent_bone = try requireReadObject(api.read.Bone, reads, doc, bone.parent);
            return atoms.lookup(parent_bone.name).?;
        }
        if (std.mem.eql(u8, field_name, "angle")) return std.fmt.allocPrint(allocator, "{d}", .{bone.rotation * 180 / std.math.pi});
        if (std.mem.eql(u8, field_name, "length")) return std.fmt.allocPrint(allocator, "{d}", .{bone.length});
        if (std.mem.eql(u8, field_name, "local")) return std.fmt.allocPrint(allocator, "{d},{d}", .{ bone.local.x, bone.local.y });
        if (std.mem.eql(u8, field_name, "scale")) return std.fmt.allocPrint(allocator, "{d},{d}", .{ bone.scale.x, bone.scale.y });
        if (flagBit(field_name)) |bit| return if (bone.flags & bit != 0) "true" else "false";
    } else if (target_kind == names.shape) {
        const definition = try reads.definition(doc);
        const shape = filmstrip.posedRow(session.get(tables), .shape, definition, try requireReadObject(api.read.Shape, reads, doc, object_id));
        if (std.mem.eql(u8, field_name, "binding")) return std.fmt.allocPrint(allocator, "{s} (bone {d})", .{ atoms.lookup(shape.binding) orelse "none", shape.bone });
        if (std.mem.eql(u8, field_name, "name")) return atoms.lookup(shape.name).?;
        if (std.mem.eql(u8, field_name, "layer")) {
            const layer = try requireReadObject(api.read.Layer, reads, doc, shape.layer);
            return atoms.lookup(layer.name).?;
        }
        if (std.mem.eql(u8, field_name, "fill_on")) return if (shape.fill_color[3] != 0 or shape.fill_paint != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "stroke_on")) return if (shape.stroke_color[3] != 0 or shape.stroke_paint != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "cap")) return atoms.lookup(shape.cap).?;
        if (std.mem.eql(u8, field_name, "join")) return atoms.lookup(shape.join).?;
        if (std.mem.eql(u8, field_name, "stroke_kind")) return atoms.lookup(shape.stroke_kind).?;
        if (std.mem.eql(u8, field_name, "visible")) return if (shape.visible != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "opacity")) return std.fmt.allocPrint(allocator, "{d}", .{shape.opacity});
        if (std.mem.eql(u8, field_name, "stroke_width")) return std.fmt.allocPrint(allocator, "{d}", .{shape.stroke_width});
        if (std.mem.eql(u8, field_name, "stroke_glow_radius")) return std.fmt.allocPrint(allocator, "{d}", .{shape.stroke_glow_radius});
        if (std.mem.eql(u8, field_name, "stroke_glow_color")) {
            const rgba = shape.stroke_glow_color;
            return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba[0], rgba[1], rgba[2], rgba[3] });
        }
        if (std.mem.eql(u8, field_name, "stroke_color") or std.mem.eql(u8, field_name, "fill_color")) {
            const rgba = if (std.mem.eql(u8, field_name, "stroke_color")) shape.stroke_color else shape.fill_color;
            return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba[0], rgba[1], rgba[2], rgba[3] });
        }
    } else if (target_kind == names.layer) {
        const definition = try reads.definition(doc);
        const layer = filmstrip.posedRow(session.get(tables), .layer, definition, try requireReadObject(api.read.Layer, reads, doc, object_id));
        if (std.mem.eql(u8, field_name, "name")) return atoms.lookup(layer.name).?;
        if (std.mem.eql(u8, field_name, "blend")) return atoms.lookup(layer.blend).?;
        if (std.mem.eql(u8, field_name, "parent")) {
            if (layer.parent == 0) return "none";
            const parent_layer = try requireReadObject(api.read.Layer, reads, doc, layer.parent);
            return atoms.lookup(parent_layer.name).?;
        }
        if (std.mem.eql(u8, field_name, "opacity")) return std.fmt.allocPrint(allocator, "{d}", .{layer.opacity});
        if (std.mem.eql(u8, field_name, "order")) return std.fmt.allocPrint(allocator, "{d}", .{layer.order});
        if (std.mem.eql(u8, field_name, "visible")) return if (layer.visible != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "clip_to_below")) return if (layer.clip_to_below != 0) "true" else "false";
        if (std.mem.eql(u8, field_name, "locked")) return if (layer.locked != 0) "true" else "false";
    }
    return "";
}

fn fieldPaint(tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, object_id: u32, field_name: []const u8) !?api.read.Paint {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return fieldPaintWithReads(&reads, target_kind, object_id, field_name);
}

fn fieldPaintWithReads(reads: *session.ReadContext, target_kind: Atom, object_id: u32, field_name: []const u8) !?api.read.Paint {
    const tables = reads.tables;
    if (target_kind != names.shape) return null;
    const fill = std.mem.eql(u8, field_name, "fill_color");
    if (!fill and !std.mem.eql(u8, field_name, "stroke_color")) return null;
    const editor = session.get(tables);
    const definition = try reads.definition(editor.doc.*);
    const shape = session.findById(api.read.Shape, definition.shapes, object_id) orelse return error.MissingSelection;
    const paint_id = if (fill) shape.fill_paint else shape.stroke_paint;
    if (paint_id == 0) return null;
    return session.findById(api.read.Paint, definition.paints, paint_id) orelse error.MissingPaint;
}

pub const PropertyValue = struct { label: []const u8, text: []const u8, color: ?session.Color = null };
pub fn propertyValue(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, object_id: u32, field: InspectorField) !PropertyValue {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return propertyValueWithReads(allocator, &reads, target_kind, object_id, field);
}

pub fn propertyValueWithReads(allocator: std.mem.Allocator, reads: *session.ReadContext, target_kind: Atom, object_id: u32, field: InspectorField) !PropertyValue {
    const atoms = reads.atoms;
    const fill = std.mem.eql(u8, field.name, "fill_color");
    if (try fieldPaintWithReads(reads, target_kind, object_id, field.name)) |paint| {
        const kind = atoms.lookup(paint.kind) orelse "gradient";
        const name = atoms.lookup(paint.name) orelse "unnamed";
        const paint_text = try std.fmt.allocPrint(allocator, "{s}: {s} #{d}", .{ kind, name, paint.id });
        return .{ .label = if (fill) "Fill paint" else "Stroke paint", .text = paint_text };
    }
    const text = try valueTextWithReads(allocator, reads, target_kind, object_id, field.name);
    const stroke = std.mem.eql(u8, field.name, "stroke_color");
    const glow = std.mem.eql(u8, field.name, "stroke_glow_color");
    const color: ?session.Color = if (fill or stroke or glow) try parseColor(text) else null;
    return .{ .label = field.label, .text = text, .color = color };
}

fn completion(allocator: std.mem.Allocator, label: []const u8, detail: []const u8, choice: Choice) !action_palette.Completion {
    var result = action_palette.Completion{ .label = try allocator.dupe(u8, label), .detail = try allocator.dupe(u8, detail) };
    @memcpy(result.data[0..@sizeOf(Choice)], std.mem.asBytes(&choice));
    return result;
}

/// Whether a figure or sketch goes by `name` already: a loaded figure, an open sketch, or a file
/// the resources catalog has whose `disk_present` says it was there when a request last read or
/// wrote it (nothing looks at the disk for this).
fn documentExists(tables: *Table.Registry, atoms: *Atom.Registry, name: Atom) bool {
    if (session.definitionInfo(tables, atoms, name) != null) return true;
    if (tables.findByName(Atom.from(api.sketches_table_name))) |open_sketches| {
        var sketch_query = open_sketches.readQuery(api.SketchView);
        while (sketch_query.next()) |entry| if (entry.view.sketch.* == name) return true;
    }
    if (tables.findByName(Atom.from(resources.document_assets_name))) |assets| {
        var asset_query = assets.query(resources.DocumentAssetView);
        while (asset_query.next()) |entry| if (entry.view.id.* == name and entry.view.disk_present.* != 0) return true;
    }
    return false;
}

/// Why a new figure or sketch may not be named `name`.
pub const NewNameRefusal = enum {
    /// It is not a snake_case name.
    invalid_name,
    /// A figure or sketch goes by it already (`documentExists`).
    taken,
};

/// Why a new figure or sketch may not be named `name`, as the `new` prompt and a path typed in
/// find-file both ask; null when it may.
pub fn newNameRefusal(tables: *Table.Registry, atoms: *Atom.Registry, name: []const u8) ?NewNameRefusal {
    if (!zon.isSnakeCaseAtom(name)) return .invalid_name;
    const id = Atom.from(name);
    if (documentExists(tables, atoms, id)) return .taken;
    return null;
}

pub fn newName(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) ![]const u8 {
    var serial: u32 = 1;
    while (true) : (serial += 1) {
        const text = try std.fmt.allocPrint(allocator, "figure_{d}", .{serial});
        if (!documentExists(tables, atoms, Atom.from(text))) return text;
    }
}

pub fn show(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, initial: []const u8) !void {
    const editor = session.get(tables);
    try showTarget(mem, tables, atoms, kind, initial, editor.active_kind.*, editor.active_id.*);
}

pub fn showTarget(
    mem: *memory.Memory,
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    kind: Atom,
    initial: []const u8,
    target_kind: Atom,
    object_id: u32,
) !void {
    try showCaptured(mem, tables, atoms, .{ .kind = kind, .target_kind = target_kind, .id = object_id }, initial);
}

const PromptTarget = struct {
    kind: Atom,
    target_kind: Atom,
    id: u32,
    field: Atom = session.none,
    part: session.ValuePart = .whole,
    anchor_index: u32 = 0,
};

pub fn showWeightNumeric(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const settings = weight.config(tables);
    const initial = try weight.numericText(tables, atoms);
    const kind = names.shape;
    try showCaptured(mem, tables, atoms, .{
        .kind = names.weight_numeric,
        .target_kind = kind,
        .id = settings.point_shape.*,
        .anchor_index = settings.point_index.*,
    }, initial);
}

pub fn showDrawingOption(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, option: drawing.ToolOption) !void {
    const settings = drawing.config(tables);
    const value = option.value(settings);
    var buffer: [48]u8 = undefined;
    const initial = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    const field = Atom.from(@tagName(option));
    const kind = names.tool_defaults;
    try showCaptured(mem, tables, atoms, .{ .kind = names.draw_option, .target_kind = kind, .id = 0, .field = field }, initial);
}

pub fn showPointCoordinate(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, axis: drawing.PointAxis) !void {
    const options = try drawing.pointOptions(tables, atoms) orelse return error.SelectEditablePath;
    const anchor = options.anchor orelse return error.SelectOneAnchor;
    const value = switch (axis) {
        .x => anchor.p.x,
        .y => anchor.p.y,
    };
    var buffer: [48]u8 = undefined;
    const initial = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    const field = Atom.from(@tagName(axis));
    const kind = names.shape;
    try showCaptured(mem, tables, atoms, .{
        .kind = names.point_coordinate,
        .target_kind = kind,
        .id = options.shape.id,
        .field = field,
        .anchor_index = anchor.index,
    }, initial);
}

pub fn showWeightOption(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, option: weight.BrushOption) !void {
    const scratch = try mem.frameScratchAllocator();
    const initial = try option.valueText(scratch.allocator, tables, atoms);
    const field = Atom.from(@tagName(option));
    const kind = names.weight;
    try showCaptured(mem, tables, atoms, .{ .kind = names.weight_option, .target_kind = kind, .id = 0, .field = field }, initial);
}

const DocumentCapture = struct { revision: u64, identity: ?api.DefinitionHandle };

/// Which document incarnation a prompt edits, so a later submit can refuse a replaced one.
fn currentDocumentCapture(tables: *Table.Registry, atoms: *Atom.Registry) !DocumentCapture {
    const editor = session.get(tables);
    if (editor.doc.* == session.none) return .{ .revision = 0, .identity = null };
    const definitions = try session.listDefinitions(tables, atoms);
    for (definitions) |entry| {
        if (entry.info.definition != editor.doc.* or !entry.info.editor_open) continue;
        return .{ .revision = entry.info.authored_revision, .identity = entry.handle };
    }
    return error.PromptDocumentChanged;
}

fn recordDocumentCapture(capture: session.ObservedView, document: DocumentCapture) void {
    capture.prompt_revision.* = document.revision;
    capture.prompt_identity_valid.* = @intFromBool(document.identity != null);
    if (document.identity) |handle| {
        capture.prompt_table.* = handle.table_index;
        capture.prompt_table_generation.* = handle.table_generation;
        capture.prompt_row.* = handle.row;
        capture.prompt_generation.* = handle.generation;
    }
}

/// True when the panel shows this field's row, and so can draw its text in place. Any other
/// field prompt uses the popup: an inline field with no row would take keys invisibly.
fn fieldHasPanelRow(editor: session.View, target: PromptTarget, field_name: []const u8) bool {
    if (session.atRest(editor)) return true;
    if (!filmstrip.enabled(editor) or target.target_kind != names.bone or target.id != editor.active_bone.*) return false;
    for ([_][]const u8{ "angle", "length", "local", "scale" }) |shown| {
        if (std.mem.eql(u8, shown, field_name)) return true;
    }
    return false;
}

fn showCaptured(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, target: PromptTarget, initial: []const u8) !void {
    // Reject before resetting completion storage or changing the captured target.
    if (action_palette.requestOpen(tables, atoms) or !action_palette.canPresent(tables, atoms)) return error.PromptBusy;
    const editor = session.get(tables);
    const document = try currentDocumentCapture(tables, atoms);
    const request = try buildRequest(mem, tables, atoms, target, initial);
    const capture = session.observed(tables);
    capture.prompt_anchor_index.* = target.anchor_index;
    recordDocumentCapture(session.observed(tables), document);
    editor.prompt_kind.* = target.kind;
    editor.prompt_doc.* = editor.doc.*;
    editor.prompt_id.* = target.id;
    editor.prompt_target_kind.* = target.target_kind;
    editor.prompt_mode.* = editor.mode.*;
    if (tables.findByName(Atom.from(filmstrip.name)) != null) {
        const settings = filmstrip.config(tables);
        editor.prompt_clip.* = settings.clip.*;
        editor.prompt_key_frame.* = settings.selected_frame.*;
        editor.prompt_key_pose.* = settings.loaded_pose.*;
        editor.prompt_key_selected.* = settings.key_selected.*;
    }
    try session.table(tables).assignString(editor.prompt_text, initial);
    editor.prompt_field.* = target.field;
    editor.prompt_part.* = @intFromEnum(target.part);
    const reply = promptReply();
    action_palette.request(mem, tables, .{ .present = .{ .completions = request, .reply = reply } });
}

fn present(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8, replace: bool) !void {
    if (!replace and (action_palette.requestOpen(tables, atoms) or !action_palette.canPresent(tables, atoms))) return error.PromptBusy;
    const editor = session.get(tables);
    if (editor.prompt_kind.* == session.none) return;
    const target = PromptTarget{
        .kind = editor.prompt_kind.*,
        .target_kind = editor.prompt_target_kind.*,
        .id = editor.prompt_id.*,
        .field = editor.prompt_field.*,
        .part = @enumFromInt(editor.prompt_part.*),
        .anchor_index = session.observed(tables).prompt_anchor_index.*,
    };
    const request = try buildRequest(mem, tables, atoms, target, query);
    if (replace) {
        action_palette.request(mem, tables, .{ .replace = .{ .completions = request } });
    } else {
        const reply = promptReply();
        action_palette.request(mem, tables, .{ .present = .{ .completions = request, .reply = reply } });
    }
}

fn buildRequest(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, target: PromptTarget, query: []const u8) !*action_palette.Completions {
    const editor = session.get(tables);
    const kind = target.kind;
    action_palette.resetCompletionArena(mem, .figure);
    const allocator = try action_palette.completionAllocator(mem, .figure);
    const field_name = if (kind == names.rename) "name" else fieldName(target.target_kind, target.field) orelse "";
    const option = if (kind == names.draw_option)
        std.meta.stringToEnum(drawing.ToolOption, field_name)
    else
        null;
    const option_details = if (option) |tool_option| tool_option.details() else null;
    const brush_option = if (kind == names.weight_option)
        std.meta.stringToEnum(weight.BrushOption, field_name)
    else
        null;
    var prompt_label: []const u8 = undefined;
    var value_hint: []const u8 = session.table(tables).textOf(editor.status.*);
    var target_available = true;
    if (action_palette.currentOwner(tables, atoms) == owner) {
        session.validatePromptDocument(tables, atoms) catch {
            target_available = false;
        };
    }
    const property: ?InspectorField = find: {
        if (kind != names.field and kind != names.rename) break :find null;
        const fields = inspectorFields(target.target_kind);
        for (fields) |field| if (std.mem.eql(u8, field.name, field_name)) break :find field;
        break :find null;
    };
    if (option_details) |detail| {
        prompt_label = try std.fmt.allocPrint(allocator, "Tool defaults - {s}: ", .{detail.label});
        value_hint = detail.range;
    } else if (brush_option) |brush| {
        const detail = brush.details();
        prompt_label = try std.fmt.allocPrint(allocator, "Weight brush - {s}: ", .{detail.label});
        value_hint = detail.hint;
    } else if (kind == names.point_coordinate) {
        const axis = if (target.field == names.x) "X" else "Y";
        prompt_label = try std.fmt.allocPrint(allocator, "Anchor {d} - {s}: ", .{ target.anchor_index, axis });
        value_hint = "Finite coordinate in bind-space pixels; document edits invalidate this prompt";
    } else if (kind == names.weight_numeric) {
        const name = if (target_available) valueText(allocator, tables, atoms, target.target_kind, target.id, "name") catch "unavailable" else "unavailable";
        prompt_label = try std.fmt.allocPrint(allocator, "{s}, anchor {d} - Weights: ", .{ name, target.anchor_index });
        value_hint = "bone=weight,...; at most four influences; locks retained; document edits invalidate this prompt";
    } else if (kind == names.test_rotation) {
        const name = if (target_available) valueText(allocator, tables, atoms, target.target_kind, target.id, "name") catch "unavailable" else "unavailable";
        prompt_label = try std.fmt.allocPrint(allocator, "Bone {s} #{d} - Test angle: ", .{ name, target.id });
        value_hint = "Finite absolute angle in degrees; temporary Test pose only";
    } else if (kind == names.color_hex or kind == names.color_opacity) {
        const picker = color_picker.config(tables);
        const name = atoms.lookup(picker.label.*) orelse "artwork";
        const channel: api.PaintChannel = @enumFromInt(picker.channel.*);
        const field_label = if (kind == names.color_hex) "Hex RGBA" else "Alpha (%)";
        prompt_label = try std.fmt.allocPrint(allocator, "{s} {s} - {s}: ", .{ @tagName(channel), name, field_label });
        value_hint = if (kind == names.color_hex) "#RRGGBB or #RRGGBBAA; edits the captured color target" else "0 to 100 percent; edits color alpha";
    } else if (kind == names.clip_select) {
        prompt_label = "Animate - Clip: ";
        value_hint = "Choose an existing clip; add clips in Properties";
    } else if (kind == names.clip_frame or kind == names.clip_fps) {
        const clip: ?api.read.Clip = found: {
            if (!target_available) break :found null;
            const definition = session.readDefinition(tables, atoms, editor.doc.*) catch break :found null;
            break :found session.findById(api.read.Clip, definition.clips, target.id);
        };
        const name = if (clip) |current| atoms.lookup(current.name) orelse "?" else "unavailable";
        const frame_field = kind == names.clip_frame;
        const label = if (frame_field) "Frame" else "FPS";
        prompt_label = try std.fmt.allocPrint(allocator, "Clip {s} #{d} - {s}: ", .{ name, target.id, label });
        value_hint = if (frame_field) "Integer frame; looping clips wrap, others clamp to their duration" else "Finite frames per second greater than 0";
    } else if (target.target_kind == defaults_kind and property != null) {
        const field = property.?;
        prompt_label = try std.fmt.allocPrint(allocator, "Tool defaults - {s}: ", .{field.label});
        value_hint = field.hint;
    } else if (property) |field| {
        var label = field.label;
        value_hint = field.hint;
        const paint = if (target_available) fieldPaint(tables, atoms, target.target_kind, target.id, field.name) catch |err| switch (err) {
            error.MissingSelection => null,
            else => return err,
        } else null;
        if (paint != null) {
            const fill = std.mem.eql(u8, field.name, "fill_color");
            label = if (fill) "Fill fallback RGBA" else "Stroke fallback RGBA";
            value_hint = "Hex #RRGGBB or #RRGGBBAA; changes fallback only. The gradient stays active; edit it with the gradient tools.";
        }
        const object_name = if (target_available) valueText(allocator, tables, atoms, target.target_kind, target.id, "name") catch |err| switch (err) {
            error.MissingSelection => "unavailable",
            else => return err,
        } else "unavailable";
        const object_kind = atoms.lookup(target.target_kind) orelse "object";
        prompt_label = try std.fmt.allocPrint(allocator, "{s} {s} #{d} - {s}: ", .{ object_kind, object_name, target.id, label });
    } else if (sketches.promptLabel(kind)) |sketch_prompt| {
        prompt_label = sketch_prompt.label;
        value_hint = sketch_prompt.hint;
    } else if (kind == names.switch_document) {
        prompt_label = "Switch to: ";
    } else {
        prompt_label = try std.fmt.allocPrint(allocator, "Figure {s}: ", .{atoms.lookup(kind) orelse "prompt"});
    }
    var entries: std.ArrayListUnmanaged(action_palette.Completion) = .empty;
    var tab: action_palette.Completions.Tab = .selected;
    const dialog = kind == names.conflict_dialog or kind == names.close_dialog;
    if (dialog) {
        const labels: []const []const u8 = if (kind == names.conflict_dialog) &.{ "Reload from disk", "Overwrite changed file", "Cancel" } else &.{ "Save changes", "Discard changes", "Cancel" };
        for (labels, 0..) |label, i| try entries.append(allocator, try completion(allocator, label, "", .{ .action = @intCast(i + 1) }));
    } else if (kind == names.clip_select) {
        if (target_available) {
            const definition = try session.readDefinition(tables, atoms, editor.doc.*);
            for (definition.clips) |clip| {
                const label = atoms.lookup(clip.name) orelse continue;
                if (std.mem.indexOf(u8, label, query) == null) continue;
                const entry = try completion(allocator, label, value_hint, .{ .action = clip.id });
                try entries.append(allocator, entry);
            }
        }
        if (entries.items.len == 0) {
            const entry = try completion(allocator, query, value_hint, .{});
            try entries.append(allocator, entry);
        }
    } else if (brush_option != null and brush_option.?.choices().len != 0) {
        const brush = brush_option.?;
        for (brush.choices()) |label| {
            if (std.mem.indexOf(u8, label, query) == null) continue;
            const entry = try completion(allocator, label, value_hint, .{ .action = 3 });
            try entries.append(allocator, entry);
        }
        if (entries.items.len == 0) {
            const entry = try completion(allocator, query, value_hint, .{ .action = 3 });
            try entries.append(allocator, entry);
        }
    } else if (kind == names.key_easing) {
        const labels = [_][]const u8{ "constant", "linear", "smooth" };
        for (labels) |label| {
            if (std.mem.indexOf(u8, label, query) != null) try entries.append(allocator, try completion(allocator, label, "Outgoing key easing", .{ .action = 3 }));
        }
    } else if (kind == names.pose_apply) {
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        for (definition.poses) |saved_pose| {
            const label = atoms.lookup(saved_pose.name) orelse continue;
            if (std.mem.indexOf(u8, label, query) != null) try entries.append(allocator, try completion(allocator, label, "Apply saved pose", .{ .action = saved_pose.id }));
        }
    } else if (kind == names.switch_document) {
        for (try session.listDefinitions(tables, atoms)) |entry| {
            const info = entry.info;
            const name = atoms.lookup(info.definition) orelse continue;
            if (std.mem.indexOf(u8, name, query) == null) continue;
            try entries.append(allocator, try completion(allocator, name, if (info.dirty) "Loaded, modified" else "Loaded", .{ .action = 1, .id = info.definition }));
        }
        if (tables.findByName(Atom.from(api.sketches_table_name))) |open_sketches| {
            var sketch_query = open_sketches.readQuery(api.SketchView);
            while (sketch_query.next()) |entry| {
                const name = atoms.lookup(entry.view.sketch.*) orelse continue;
                if (std.mem.indexOf(u8, name, query) == null) continue;
                try entries.append(allocator, try completion(allocator, name, if (entry.view.dirty.* != 0) "Sketch, open, modified" else "Sketch, open", .{ .action = open_sketch, .id = entry.view.sketch.* }));
            }
        }
    } else {
        const label = if (query.len == 0) "Enter a value" else query;
        const entry = try completion(allocator, label, value_hint, .{ .action = 3 });
        try entries.append(allocator, entry);
        // The one entry is the value typed, or what to do when there is none.
        tab = .nothing;
    }
    if (kind == names.switch_document) std.mem.sort(action_palette.Completion, entries.items, query, struct {
        fn less(exact: []const u8, lhs: action_palette.Completion, rhs: action_palette.Completion) bool {
            const left = std.mem.eql(u8, lhs.label, exact);
            const right = std.mem.eql(u8, rhs.label, exact);
            return if (left != right) left else std.mem.order(u8, lhs.label, rhs.label) == .lt;
        }
    }.less);
    const request = try allocator.create(action_palette.Completions);
    request.* = .{
        .owner = owner,
        .presentation = if (dialog) .dialog else if (kind == names.field and fieldHasPanelRow(session.get(tables), target, field_name)) .inline_field else .prompt,
        .prompt = prompt_label,
        .initial_query = try allocator.dupe(u8, query),
        .title = if (!dialog) "" else if (kind == names.conflict_dialog) "File changed on disk" else "Save changes?",
        .body = try allocator.dupe(u8, atoms.lookup(editor.doc.*) orelse "figure"),
        .default_entry = if (dialog) 2 else null,
        .tab = tab,
        .entries = try entries.toOwnedSlice(allocator),
    };
    try action_palette.ownRequestText(allocator, request);
    return request;
}

fn nextRequest(editor: session.View) !u32 {
    if (editor.request_serial.* >= 0x7fffffff) return error.CapacityExceeded;
    editor.request_serial.* += 1;
    editor.pending_request.* = editor.request_serial.*;
    return editor.pending_request.*;
}

/// Opens the figure `doc` in the editor: from the file at `path` when given, else from the
/// file the catalog has for it.
pub fn load(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, force: bool, path: ?[]const u8) void {
    const editor = session.get(tables);
    editor.pending_doc.* = doc;
    editor.pending_action.* = names.load_doc;
    editor.fit_pending.* = 1;
    const request = nextRequest(editor) catch |err| {
        editor.pending_action.* = session.none;
        editor.fit_pending.* = 0;
        status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        return;
    };
    const scope = resources.editorDocumentsScope(tables.memory);
    transport.send(tables, atoms, .{ .load_doc = .{ .scope = scope, .doc = doc, .request = request, .force = force, .path = path } }) catch |err| {
        editor.pending_action.* = session.none;
        editor.fit_pending.* = 0;
        status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
    };
}

/// Makes the new figure `doc` whose file is `path`, a file not there: nothing is written until
/// its first save, which writes there. The figure editor shows it once the host has made it.
pub fn createAt(tables: *Table.Registry, atoms: *Atom.Registry, doc: Atom, path: []const u8) !void {
    const scope = resources.editorDocumentsScope(tables.memory);
    try transport.send(tables, atoms, .{ .new_doc = .{ .scope = scope, .doc = doc, .path = path } });
}

/// Where a figure named `stem` saves when the person names no directory: beside `beside`, the
/// file the document already has, or else in the working directory, as a new text file does.
fn defaultFigurePath(buffer: []u8, beside: ?[]const u8, stem: []const u8) ![]const u8 {
    const extension = resources.figure_document_extension;
    const directory = if (beside) |file| std.fs.path.dirname(file) orelse "" else "";
    if (directory.len == 0) return std.fmt.bufPrint(buffer, "{s}{s}", .{ stem, extension });
    return std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ directory, stem, extension });
}

/// Saves the open figure to `path`; with none, to its own file, and a figure that has none
/// (a new one) to `<stem>.mshf` in the working directory.
pub fn save(tables: *Table.Registry, atoms: *Atom.Registry, path: ?[]const u8, overwrite: bool) !void {
    const editor = session.get(tables);
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    var default_path: [resources.max_path]u8 = undefined;
    const stem = atoms.lookup(editor.doc.*) orelse return error.InvalidName;
    const target_path = path orelse definition.path orelse try defaultFigurePath(&default_path, null, stem);
    try session.table(tables).assignString(editor.pending_path, target_path);
    const base = std.fs.path.basename(target_path);
    const extension = resources.figure_document_extension;
    if (!std.mem.endsWith(u8, base, extension) or base.len <= extension.len) return error.InvalidPath;
    editor.pending_target.* = atoms.intern(base[0 .. base.len - extension.len]);
    editor.pending_action.* = names.save_doc;
    editor.pending_doc.* = editor.doc.*;
    errdefer {
        editor.pending_action.* = session.none;
        editor.close_after_save.* = 0;
    }
    const request = try nextRequest(editor);
    try transport.send(tables, atoms, .{
        .save_doc = .{
            .doc = editor.doc.*,
            .request = request,
            .path = session.table(tables).textOf(editor.pending_path.*),
            .overwrite = overwrite,
        },
    });
}

pub fn requestClose(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const editor = session.get(tables);
    const definition = session.definitionInfo(tables, atoms, editor.doc.*) orelse return;
    if (definition.dirty) {
        try show(mem, tables, atoms, names.close_dialog, "");
    } else {
        try transport.send(tables, atoms, .{ .close_doc = .{ .doc = editor.doc.* } });
    }
}

fn parseNumber(text: []const u8) !f32 {
    const value = try std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t"));
    if (!std.math.isFinite(value)) return error.NonFiniteNumber;
    return value;
}

fn parseBoolean(text: []const u8) !u8 {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return 1;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return 0;
    return error.ExpectedBoolean;
}

fn parseOption(atoms: *Atom.Registry, text: []const u8, allowed: []const []const u8) !Atom {
    for (allowed) |option| if (std.mem.eql(u8, text, option)) return atoms.intern(text);
    return error.InvalidOption;
}

fn parseOpacity(text: []const u8) !f32 {
    const opacity = try parseNumber(text);
    if (opacity < 0 or opacity > 1) return error.InvalidOpacity;
    return opacity;
}

fn parseVector(text: []const u8) !session.Vec2 {
    var parts = std.mem.splitScalar(u8, text, ',');
    const x = try parseNumber(parts.next() orelse return error.ExpectedVector);
    const y = try parseNumber(parts.next() orelse return error.ExpectedVector);
    if (parts.next() != null) return error.ExpectedVector;
    return .{ .x = x, .y = y };
}

pub fn parseColor(text: []const u8) !session.Color {
    const value = if (std.mem.startsWith(u8, text, "#")) text[1..] else if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (value.len != 6 and value.len != 8) return error.ExpectedHexColor;
    var packed_rgba = try std.fmt.parseInt(u32, value, 16);
    if (value.len == 6) packed_rgba = (packed_rgba << 8) | 255;
    return .{ @truncate(packed_rgba >> 24), @truncate(packed_rgba >> 16), @truncate(packed_rgba >> 8), @truncate(packed_rgba) };
}

fn resolveObjectId(tables: *Table.Registry, atoms: *Atom.Registry, target_kind: api.ObjectKind, doc: Atom, text: []const u8) !u32 {
    const definition = try session.readDefinition(tables, atoms, doc);
    const object_name = atoms.intern(text);
    switch (target_kind) {
        .bone => for (definition.bones) |row| {
            if (row.name == object_name) return row.id;
        },
        .shape => for (definition.shapes) |row| {
            if (row.name == object_name) return row.id;
        },
        .layer => for (definition.layers) |row| {
            if (row.name == object_name) return row.id;
        },
        else => return error.MissingReference,
    }
    return error.MissingReference;
}

pub fn fieldCommand(tables: *Table.Registry, atoms: *Atom.Registry, editor: session.View, typed_text: []const u8) !api.Payload {
    const doc = editor.prompt_doc.*;
    try filmstrip.validatePrompt(tables, atoms);
    const object_id = editor.prompt_id.*;
    const target_exists = session.isValidObject(tables, atoms, doc, editor.prompt_target_kind.*, object_id);
    if (!target_exists) return error.PromptTargetMissing;
    const field_name = fieldName(editor.prompt_target_kind.*, editor.prompt_field.*) orelse return error.MissingField;
    const text = try wholeValueText(tables, atoms, editor, field_name, typed_text);
    if (std.mem.eql(u8, field_name, "name")) {
        if (!zon.isSnakeCaseAtom(text)) return error.InvalidName;
        const kind = session.enumFromAtom(api.ObjectKind, editor.prompt_target_kind.*) orelse return error.InvalidField;
        const existing = resolveObjectId(tables, atoms, kind, doc, text) catch |err| switch (err) {
            error.MissingReference => 0,
            else => return err,
        };
        if (existing != 0 and existing != object_id) return error.DuplicateName;
    }
    if (editor.prompt_target_kind.* == names.bone) {
        if (editor.prompt_mode.* == names.animate) return pose.fieldCommand(tables, atoms, object_id, field_name, text);
        var request = api.SetBone{ .doc = doc, .id = object_id };
        if (std.mem.eql(u8, field_name, "parent")) {
            const parent = if (std.mem.eql(u8, text, "none")) 0 else try resolveObjectId(tables, atoms, .bone, doc, text);
            if (parent != 0) {
                const definition = try session.readDefinition(tables, atoms, doc);
                var ancestor = parent;
                while (ancestor != 0) {
                    if (ancestor == object_id) return error.InvalidParent;
                    const bone = session.findById(api.read.Bone, definition.bones, ancestor) orelse return error.MissingReference;
                    ancestor = bone.parent;
                }
            }
            return .{ .reparent_bone = .{ .doc = doc, .id = object_id, .parent = parent } };
        }
        if (std.mem.eql(u8, field_name, "name")) {
            request.name = atoms.intern(text);
        } else if (std.mem.eql(u8, field_name, "angle")) {
            request.rotation = (try parseNumber(text)) * (std.math.pi / 180.0);
        } else if (std.mem.eql(u8, field_name, "length")) {
            request.length = try parseNumber(text);
            if (request.length.? < 0) return error.InvalidLength;
        } else if (std.mem.eql(u8, field_name, "local")) {
            request.local = try parseVector(text);
        } else if (std.mem.eql(u8, field_name, "scale")) {
            request.scale = try parseVector(text);
            if (@abs(request.scale.?.x) < 1e-6 or @abs(request.scale.?.y) < 1e-6) return error.InvalidTransform;
        } else if (flagBit(field_name)) |bit| {
            const bone = try requireObject(api.read.Bone, tables, atoms, doc, object_id);
            request.flags = if (try parseBoolean(text) != 0) bone.flags | bit else bone.flags & ~bit;
        } else return error.InvalidField;
        return .{ .set_bone = request };
    }
    if (editor.prompt_target_kind.* == names.shape) {
        var request = api.SetShape{ .doc = doc, .id = object_id };
        if (std.mem.eql(u8, field_name, "cap")) {
            request.cap = try parseOption(atoms, text, &.{ "butt", "round", "square" });
            return .{ .set_shape = request };
        }
        if (std.mem.eql(u8, field_name, "join")) {
            request.join = try parseOption(atoms, text, &.{ "miter", "round", "bevel" });
            return .{ .set_shape = request };
        }
        if (std.mem.eql(u8, field_name, "fill_on") or std.mem.eql(u8, field_name, "stroke_on")) {
            const settings = drawing.config(tables);
            const enabled = try parseBoolean(text) != 0;
            const shape = try requireObject(api.read.Shape, tables, atoms, doc, object_id);
            if (std.mem.eql(u8, field_name, "fill_on")) {
                request.fill_color = shape.fill_color;
                request.fill_paint = shape.fill_paint;
                if (!enabled) {
                    request.fill_color = .{ 0, 0, 0, 0 };
                    request.fill_paint = 0;
                } else if (shape.fill_paint == 0 and shape.fill_color[3] == 0) {
                    request.fill_color = settings.fill_color.*;
                }
            } else {
                request.stroke_color = shape.stroke_color;
                request.stroke_paint = shape.stroke_paint;
                if (!enabled) {
                    request.stroke_color = .{ 0, 0, 0, 0 };
                    request.stroke_paint = 0;
                } else if (shape.stroke_paint == 0 and shape.stroke_color[3] == 0) {
                    request.stroke_color = settings.stroke_color.*;
                }
            }
            return .{ .set_shape = request };
        }
        if (std.mem.eql(u8, field_name, "name")) {
            request.name = atoms.intern(text);
        } else if (std.mem.eql(u8, field_name, "layer")) {
            request.layer = try resolveObjectId(tables, atoms, .layer, doc, text);
            const layer = try requireObject(api.read.Layer, tables, atoms, doc, request.layer.?);
            if (layer.kind == names.folder) return error.ExpectedArtLayer;
        } else if (std.mem.eql(u8, field_name, "stroke_kind")) {
            request.stroke_kind = try parseOption(atoms, text, &.{ "line", "square_line", "circle", "circle_fill" });
        } else if (std.mem.eql(u8, field_name, "stroke_color")) {
            request.stroke_color = try parseColor(text);
        } else if (std.mem.eql(u8, field_name, "fill_color")) {
            request.fill_color = try parseColor(text);
        } else if (std.mem.eql(u8, field_name, "visible")) {
            request.visible = try parseBoolean(text);
        } else if (std.mem.eql(u8, field_name, "opacity")) {
            request.opacity = try parseOpacity(text);
        } else if (std.mem.eql(u8, field_name, "stroke_width")) {
            request.stroke_width = try parseNumber(text);
            if (request.stroke_width.? < 0) return error.InvalidStrokeWidth;
        } else if (std.mem.eql(u8, field_name, "stroke_glow_radius")) {
            request.stroke_glow_radius = try parseNumber(text);
            if (request.stroke_glow_radius.? < 0) return error.InvalidStrokeWidth;
        } else if (std.mem.eql(u8, field_name, "stroke_glow_color")) {
            request.stroke_glow_color = try parseColor(text);
        } else {
            return error.InvalidField;
        }
        return .{ .set_shape = request };
    }
    if (editor.prompt_target_kind.* == names.layer) {
        var request = api.SetLayer{ .doc = doc, .id = object_id };
        if (std.mem.eql(u8, field_name, "blend")) {
            const blend = std.meta.stringToEnum(roop.BlendMode, text) orelse return error.InvalidOption;
            if (blend == .unsupported) return error.InvalidOption;
            request.blend = atoms.intern(text);
            return .{ .set_layer = request };
        }
        if (std.mem.eql(u8, field_name, "parent")) {
            request.parent = if (std.mem.eql(u8, text, "none")) 0 else try resolveObjectId(tables, atoms, .layer, doc, text);
            if (request.parent.? != 0) {
                const layer = try requireObject(api.read.Layer, tables, atoms, doc, object_id);
                const parent = try requireObject(api.read.Layer, tables, atoms, doc, request.parent.?);
                const folder = names.folder;
                if (layer.kind == folder or parent.kind != folder or parent.parent != 0) return error.InvalidParent;
            }
            return .{ .set_layer = request };
        }
        if (std.mem.eql(u8, field_name, "name")) {
            request.name = atoms.intern(text);
        } else if (std.mem.eql(u8, field_name, "opacity")) {
            request.opacity = try parseOpacity(text);
        } else if (std.mem.eql(u8, field_name, "visible")) {
            request.visible = try parseBoolean(text);
        } else if (std.mem.eql(u8, field_name, "clip_to_below")) {
            request.clip_to_below = try parseBoolean(text);
        } else if (std.mem.eql(u8, field_name, "locked")) {
            request.locked = try parseBoolean(text);
        } else if (std.mem.eql(u8, field_name, "order")) {
            request.order = try std.fmt.parseInt(u32, text, 10);
        } else {
            return error.InvalidField;
        }
        return .{ .set_layer = request };
    }
    return error.MissingSelection;
}

pub fn editField(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, initial: ?[]const u8) !void {
    const editor = session.get(tables);
    const target = inspectorTarget(session.get(tables), drawing.config(tables));
    const fields = inspectorFields(target.kind);
    if (fields.len == 0) return;
    const index: u32 = @intCast(@min(editor.inspector_field.*, fields.len - 1));
    try editTarget(mem, tables, atoms, target.kind, target.id, index, .whole, initial);
}

/// A displayed inspector row owns its target even when bound artwork is selected.
pub fn editTarget(
    mem: *memory.Memory,
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    target_kind: Atom,
    object_id: u32,
    field_index: u32,
    part: session.ValuePart,
    initial: ?[]const u8,
) !void {
    const fields = inspectorFields(target_kind);
    if (fields.len == 0 or (object_id == 0 and target_kind != defaults_kind)) return;
    if (field_index >= fields.len) return error.MissingField;
    const field_definition = fields[field_index];
    const scratch = try mem.frameScratchAllocator();
    const whole_text = try valueText(scratch.allocator, tables, atoms, target_kind, object_id, field_definition.name);
    // One component of a vector is typed as a number, starting from its exact value.
    const edited_part: session.ValuePart = if (field_definition.isVector()) part else .whole;
    const current = switch (edited_part) {
        .whole => whole_text,
        .x => try std.fmt.allocPrint(scratch.allocator, "{d}", .{(try parseVector(whole_text)).x}),
        .y => try std.fmt.allocPrint(scratch.allocator, "{d}", .{(try parseVector(whole_text)).y}),
    };
    const value = initial orelse current;
    const field = Atom.from(field_definition.name);
    try showCaptured(mem, tables, atoms, .{ .kind = names.field, .target_kind = target_kind, .id = object_id, .field = field, .part = edited_part }, value);
}

/// The whole text of the prompted field's value, given `text` for the part the prompt edits:
/// `text` itself for a whole value, or the field's current vector with that component
/// replaced. A typed component then takes the same command and validation as a typed vector.
fn wholeValueText(tables: *Table.Registry, atoms: *Atom.Registry, editor: session.View, field_name: []const u8, text: []const u8) ![]const u8 {
    const part: session.ValuePart = @enumFromInt(editor.prompt_part.*);
    if (part == .whole) return text;
    const scratch = try tables.memory.frameScratchAllocator();
    const current_text = try valueText(scratch.allocator, tables, atoms, editor.prompt_target_kind.*, editor.prompt_id.*, field_name);
    var value = try parseVector(current_text);
    const component = try parseNumber(text);
    switch (part) {
        .whole => unreachable,
        .x => value.x = component,
        .y => value.y = component,
    }
    return std.fmt.allocPrint(scratch.allocator, "{d},{d}", .{ value.x, value.y });
}

/// A vector field's value, as its row shows it component by component.
pub fn vectorValueWithReads(allocator: std.mem.Allocator, reads: *session.ReadContext, target_kind: Atom, object_id: u32, field: InspectorField) !session.Vec2 {
    const text = try valueTextWithReads(allocator, reads, target_kind, object_id, field.name);
    return parseVector(text);
}

/// A checkbox or choice row: the same validation and command as typing the next value,
/// without a text field. Errors are the caller's to show; no prompt stays behind to retry.
pub fn stepField(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, object_id: u32, field: InspectorField) !void {
    if (action_palette.requestOpen(tables, atoms)) return error.PromptBusy;
    const editor = session.get(tables);
    const scratch = try mem.frameScratchAllocator();
    const document = try currentDocumentCapture(tables, atoms);
    const current = try valueText(scratch.allocator, tables, atoms, target_kind, object_id, field.name);
    var next: []const u8 = if (std.mem.eql(u8, current, "true")) "false" else "true";
    if (field.choices.len != 0) {
        const at = for (field.choices, 0..) |choice, index| {
            if (std.mem.eql(u8, choice, current)) break index;
        } else field.choices.len - 1;
        next = field.choices[(at + 1) % field.choices.len];
    }
    recordDocumentCapture(session.observed(tables), document);
    targetPromptAtField(tables, target_kind, object_id, field);
    defer editor.prompt_kind.* = session.none;
    try submit(mem, tables, atoms, .{ .action = 3 }, next);
}

/// Describes a field edit in the prompt's terms without opening a prompt.
fn targetPromptAtField(tables: *Table.Registry, target_kind: Atom, object_id: u32, field: InspectorField) void {
    const editor = session.get(tables);
    editor.prompt_kind.* = names.field;
    editor.prompt_doc.* = editor.doc.*;
    editor.prompt_id.* = object_id;
    editor.prompt_target_kind.* = target_kind;
    editor.prompt_field.* = Atom.from(field.name);
    editor.prompt_part.* = @intFromEnum(session.ValuePart.whole);
    editor.prompt_mode.* = editor.mode.*;
    if (tables.findByName(Atom.from(filmstrip.name)) != null) {
        const settings = filmstrip.config(tables);
        editor.prompt_clip.* = settings.clip.*;
        editor.prompt_key_frame.* = settings.selected_frame.*;
        editor.prompt_key_pose.* = settings.loaded_pose.*;
        editor.prompt_key_selected.* = settings.key_selected.*;
    }
}

pub fn scrubCommand(tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, object_id: u32, field: InspectorField, text: []const u8) !api.Payload {
    const editor = session.get(tables);
    if (action_palette.requestOpen(tables, atoms)) return error.PromptBusy;
    const document = try currentDocumentCapture(tables, atoms);
    recordDocumentCapture(session.observed(tables), document);
    targetPromptAtField(tables, target_kind, object_id, field);
    defer editor.prompt_kind.* = session.none;
    return fieldCommand(tables, atoms, editor, text);
}

pub fn parseScrubValue(settings: Scrub, text: []const u8) !session.Vec2 {
    return switch (settings.axes) {
        .one => .{ .x = try parseNumber(text), .y = 0 },
        .two => try parseVector(text),
    };
}

pub fn formatScrubValue(allocator: std.mem.Allocator, settings: Scrub, value: session.Vec2) ![]const u8 {
    return switch (settings.axes) {
        .one => std.fmt.allocPrint(allocator, "{d:.[1]}", .{ value.x, settings.decimals }),
        .two => std.fmt.allocPrint(allocator, "{d:.[2]},{d:.[2]}", .{ value.x, value.y, settings.decimals }),
    };
}

pub fn reopen(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry) void {
    const editor = session.get(tables);
    const text = session.table(tables).textOf(editor.prompt_text.*);
    present(mem, tables, atoms, text, false) catch |err| failPresentation(tables, atoms, err);
}

fn failPresentation(tables: *Table.Registry, atoms: *Atom.Registry, err: anyerror) void {
    // Rebuilding may have reset the completion arena: the palette closes the prompt in its
    // run this frame, before it draws, and its answer is acknowledged as any other.
    if (action_palette.currentOwner(tables, atoms) == owner) action_palette.request(tables.memory, tables, .{ .cancel = .{ .owner = owner } });
    const editor = session.get(tables);
    editor.prompt_kind.* = session.none;
    editor.close_after_save.* = 0;
    status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
}

/// The palette's event `received` in reply to a figure prompt; false for any other message.
pub fn handleMessage(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: mesha.sequencer.Message) bool {
    if (received.tag.to(workspace.Msg) != .figure_prompt_reply) return false;
    const response = action_palette.eventOf(received) catch |err| {
        received.unreadable(err);
        return true;
    };
    if (response.kind == .completed) action_palette.request(mem, tables, .{ .acknowledge = .{ .owner = owner } });
    const editor = session.get(tables);
    const feedback = session.feedback(tables);
    const text = std.mem.trim(u8, response.query, " \t");
    if (response.kind == .query_changed) {
        if (action_palette.currentOwner(tables, atoms) != owner) return true;
        session.table(tables).assignString(editor.prompt_text, text) catch {};
        present(mem, tables, atoms, text, true) catch |err| failPresentation(tables, atoms, err);
        return true;
    }
    // Late, behind a prompt opened since: `editor` describes that prompt, not this response.
    // Only figure's handler reads per-prompt state, and it never re-presents an answered prompt.
    if (action_palette.currentOwner(tables, atoms) == owner) return true;
    const choice = if (response.completion) |entry| std.mem.bytesToValue(Choice, entry.data[0..@sizeOf(Choice)]) else {
        if (feedback.prompt_error_owned.* != 0) dismissError(session.get(tables), session.feedback(tables));
        editor.prompt_kind.* = session.none;
        editor.close_after_save.* = 0;
        return true;
    };
    // An answer that cannot be kept leaves none: a reopen after asynchronous rejection starts
    // empty rather than restoring an earlier answer as if it were this one.
    session.table(tables).assignString(editor.prompt_text, text) catch {
        editor.prompt_text.* = .{};
    };
    const brush_choice = editor.prompt_kind.* == names.weight_option and
        (editor.prompt_field.* == names.bone or editor.prompt_field.* == names.mode or editor.prompt_field.* == names.falloff);
    const choice_text = editor.prompt_kind.* == names.key_easing or brush_choice;
    const submitted = if (choice_text) response.completion.?.label else text;
    submit(mem, tables, atoms, choice, submitted) catch |err| {
        status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        switch (err) {
            error.PromptDocumentChanged, error.PromptAnimationChanged, error.PromptTargetMissing, error.PromptTargetChanged => {
                editor.prompt_kind.* = session.none;
                editor.close_after_save.* = 0;
                return true;
            },
            else => {},
        }
        feedback.prompt_error_owned.* = 1;
        // From the response, not `prompt_text`, which may not have kept it.
        present(mem, tables, atoms, text, false) catch |present_error| failPresentation(tables, atoms, present_error);
        return true;
    };
    // A corrected or cancelled prompt dismisses only its own validation error.
    // Any intervening command/runtime error revokes this ownership in status().
    if (feedback.prompt_error_owned.* != 0) dismissError(session.get(tables), session.feedback(tables));
    return true;
}

fn submit(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, choice: Choice, text: []const u8) !void {
    const editor = session.get(tables);
    const kind = editor.prompt_kind.*;
    if (kind == session.none) return;
    try filmstrip.validatePrompt(tables, atoms);
    if (kind == names.clip_select) {
        if (choice.action == 0) return error.SelectClip;
        const definition = try session.readDefinition(tables, atoms, editor.prompt_doc.*);
        const clip = session.findById(api.read.Clip, definition.clips, choice.action) orelse return error.PromptTargetMissing;
        try filmstrip.selectClip(tables, atoms, clip.id);
        editor.prompt_kind.* = session.none;
    } else if (try filmstrip.submitPrompt(tables, atoms, kind, text)) {
        editor.prompt_kind.* = session.none;
    } else if (kind == names.pose_apply) {
        try filmstrip.editPose(tables, atoms, .{ .apply_pose = .{ .doc = editor.prompt_doc.*, .id = choice.action } });
        pose.config(tables).selected_pose.* = choice.action;
        editor.prompt_kind.* = session.none;
    } else if (try pose.submitPrompt(tables, atoms, kind, text)) {
        editor.prompt_kind.* = session.none;
    } else if (try weight.submitPrompt(tables, atoms, kind, text)) {
        editor.prompt_kind.* = session.none;
    } else if (try sketches.submitPrompt(tables, atoms, kind, text)) {
        editor.prompt_kind.* = session.none;
    } else if (kind == names.color_hex) {
        const rgba = try parseColor(text);
        try color_picker.apply(tables, atoms, rgba);
        editor.prompt_kind.* = session.none;
    } else if (kind == names.color_opacity) {
        const percent = try parseNumber(text);
        if (percent < 0 or percent > 100) return error.InvalidOpacity;
        var color = color_picker.config(tables).current.*;
        color[3] = @intFromFloat(@round(percent * 255 / 100));
        try color_picker.apply(tables, atoms, color);
        editor.prompt_kind.* = session.none;
    } else if (kind == names.move_shapes_layer) {
        const layer = try resolveObjectId(tables, atoms, .layer, editor.doc.*, text);
        try transport.send(tables, atoms, .{
            .move_shapes = .{ .doc = editor.doc.*, .ids = try selection.selectedShapeIds(tables), .layer = layer },
        });
        editor.prompt_kind.* = session.none;
    } else if (kind == names.point_coordinate) {
        const command = try drawing.pointCoordinateCommand(tables, atoms, text);
        try transport.send(tables, atoms, command);
        editor.prompt_kind.* = session.none;
    } else if (kind == names.draw_option) {
        const option = session.enumFromAtom(drawing.ToolOption, editor.prompt_field.*) orelse return error.MissingField;
        const settings = drawing.config(tables);
        try option.apply(settings, text);
        editor.prompt_kind.* = session.none;
    } else if (kind == names.switch_document) {
        editor.prompt_kind.* = session.none;
        if (choice.id == session.none) return error.MissingDocument;
        if (choice.action == open_sketch) {
            try sketches.open(tables, atoms, choice.id, null);
        } else {
            load(tables, atoms, choice.id, false, null);
        }
    } else if (kind == names.new) {
        if (newNameRefusal(tables, atoms, text)) |refusal| return switch (refusal) {
            .invalid_name => error.InvalidName,
            .taken => error.DuplicateDocument,
        };
        const scope = resources.editorDocumentsScope(tables.memory);
        try transport.send(tables, atoms, .{ .new_doc = .{ .scope = scope, .doc = atoms.intern(text) } });
    } else if (kind == names.save_as) {
        const frame_allocator = (try mem.frameScratchAllocator()).allocator;
        const extension = resources.figure_document_extension;
        const stem = if (std.mem.endsWith(u8, text, extension)) text[0 .. text.len - extension.len] else text;
        const path_buffer = try frame_allocator.alloc(u8, resources.max_path);
        // A name alone saves beside the figure's own file, or in the working directory.
        const definition = try session.readDefinition(tables, atoms, editor.doc.*);
        const path = if (std.mem.indexOfScalar(u8, text, '/') != null) text else try defaultFigurePath(path_buffer, definition.path, stem);
        try save(tables, atoms, path, false);
        editor.prompt_kind.* = session.none;
    } else if (kind == names.close_dialog) {
        editor.prompt_kind.* = session.none;
        if (choice.action == 1) {
            editor.close_after_save.* = 1;
            try save(tables, atoms, null, false);
        } else if (choice.action == 2) {
            try transport.send(tables, atoms, .{ .close_doc = .{ .doc = editor.doc.*, .discard = true } });
        }
    } else if (kind == names.conflict_dialog) {
        editor.prompt_kind.* = session.none;
        if (choice.action == 1) {
            load(tables, atoms, editor.doc.*, true, null);
        } else if (choice.action == 2) {
            try save(tables, atoms, session.table(tables).textOf(editor.pending_path.*), true);
        } else {
            editor.close_after_save.* = 0;
        }
    } else if (kind == names.rename) {
        editor.prompt_field.* = names.name;
        try transport.send(tables, atoms, try fieldCommand(tables, atoms, editor, text));
    } else if (kind == names.bone_values) {
        if (editor.active_bone.* == 0) return error.MissingBone;
        var pieces = std.mem.splitScalar(u8, text, ':');
        const angle = pieces.next().?;
        const length = pieces.next();
        if (pieces.next() != null) return error.ExpectedAngleLength;
        var request = api.SetBone{ .doc = editor.prompt_doc.*, .id = editor.active_bone.* };
        if (angle.len != 0) request.rotation = (try parseNumber(angle)) * (std.math.pi / 180.0);
        if (length) |v| if (v.len != 0) {
            request.length = try parseNumber(v);
            if (request.length.? < 0) return error.InvalidLength;
        };
        if (request.rotation == null and request.length == null) return error.ExpectedAngleLength;
        try transport.send(tables, atoms, .{ .set_bone = request });
    } else if (kind == names.field) {
        if (editor.prompt_target_kind.* == defaults_kind) {
            const field_name = fieldName(editor.prompt_target_kind.*, editor.prompt_field.*) orelse return error.MissingField;
            const settings = drawing.config(tables);
            if (std.mem.eql(u8, field_name, "fill_on")) {
                settings.fill_enabled.* = try parseBoolean(text);
            } else if (std.mem.eql(u8, field_name, "stroke_on")) {
                settings.stroke_enabled.* = try parseBoolean(text);
            } else if (std.mem.eql(u8, field_name, "fill_color")) {
                settings.fill_color.* = try parseColor(text);
            } else if (std.mem.eql(u8, field_name, "stroke_color")) {
                settings.stroke_color.* = try parseColor(text);
            } else if (std.mem.eql(u8, field_name, "stroke_width")) {
                const width = try parseNumber(text);
                if (width < 0) return error.InvalidStrokeWidth;
                settings.stroke_width.* = width;
            } else if (std.mem.eql(u8, field_name, "layer")) {
                const layer = try resolveObjectId(tables, atoms, .layer, editor.prompt_doc.*, text);
                const definition = try session.readDefinition(tables, atoms, editor.prompt_doc.*);
                const target_layer = session.findById(api.read.Layer, definition.layers, layer) orelse return error.MissingReference;
                if (target_layer.kind == names.folder) return error.ExpectedArtLayer;
                if (!session.editableLayer(definition, layer)) return error.LayerNotEditable;
                editor.active_layer.* = layer;
            } else return error.MissingField;
            editor.prompt_kind.* = session.none;
            return;
        }
        const payload = try fieldCommand(tables, atoms, editor, text);
        if (payload == .set_pose_channels) {
            try filmstrip.editPose(tables, atoms, payload);
        } else {
            try filmstrip.editLook(tables, atoms, payload);
        }
    }
}

test "scrub values round-trip through the text a typed edit would use" {
    const allocator = std.testing.allocator;
    const pair = Scrub{ .per_pixel = 0.01, .decimals = 2, .axes = .two };
    const text = try formatScrubValue(allocator, pair, .{ .x = 1.5, .y = -2.25 });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("1.50,-2.25", text);
    const parsed = try parseScrubValue(pair, text);
    try std.testing.expectEqual(@as(f32, -2.25), parsed.y);
}
