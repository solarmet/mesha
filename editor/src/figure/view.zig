//! What the figure editor shows around its document, kept in step with the editor each
//! frame: the tool dock's scroll, the sequencer panel while it animates, the attention
//! tweens, what the pointer is over on the canvas, and which pose the canvas shows. The
//! canvas reports the pointer; this system picks what is under it, and says so in the
//! status bar and the cursor.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const os = mesha.os;
const Atom = mesha.Atom;
const names = @import("names.zig");
const Table = mesha.Table;
const plugin = mesha.plugin;
const status_bar = @import("../status_bar.zig");
const panels_mod = mesha.panels;
const panel_frame = @import("../panel_frame.zig");
const sequencer = mesha.sequencer;
const editor_state = @import("../state.zig");
const action_palette = @import("../action_palette.zig");
const session = @import("session.zig");
const watches = @import("watches.zig");
const asks = @import("asks.zig");
const weight = @import("weight.zig");
const geometry = @import("geometry.zig");
const drawing = @import("drawing.zig");
const color_picker = @import("color_picker.zig");
const preview = @import("preview.zig");
const filmstrip = @import("filmstrip.zig");
const pose = @import("pose.zig");
const chrome = @import("chrome.zig");
const motion = @import("motion.zig");
const time = mesha.time;
const prompts = @import("prompts.zig");
const workspace = @import("workspace.zig");
const fixed_panels = @import("../fixed_panels.zig");
const figure_panels = @import("panels.zig");

const Log = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { hover };

// ---- the system -----------------------------------------------------------------------------

/// Runs last, after every system that changes what is shown. It claims no messages; its
/// inbox hears the steps of the tweens it asks the time system for, so the stage draws them.
pub fn system() sequencer.System {
    return .{
        .name = "figure_view",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claimsNothing,
        .active = workspace.shown,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_view.take_answers", .run = takeAnswers },
            .{ .name = "figure_view.arrange", .run = arrange },
            .{ .name = "figure_view.attend", .run = attend },
            .{ .name = "figure_view.track_hover", .run = trackHover },
            .{ .name = "figure_view.track_preview", .run = trackPreview },
            .{ .name = "figure_view.subscribe", .run = workspace.subscribe },
        },
    };
}

fn claimsNothing(tag: Atom) bool {
    _ = tag;
    return false;
}

const observed_table = Atom.from(session.observed_name);
const motion_table = Atom.from(session.motion_name);
const session_table = Atom.from(session.name);
const outliner_tab_table = Atom.from(session.outliner_tab_name);
const feedback_table = Atom.from(session.feedback_name);
const draw_table = Atom.from(drawing.config_name);
const preview_table = Atom.from(preview.name);
const time_commands = Atom.from(time.commands_table_name);
const app_state_table = Atom.from(editor_state.app_state_name);

/// Every frame, the same few rows: each kernel records only those it writes.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    // The sequencer panel is shown and closed with animating, and the canvas hover is the bar's.
    result.writeIfPresent(frame.tables, Atom.from(fixed_panels.shown_panels_table_name));
    result.writeIfPresent(frame.tables, Atom.from(plugin.panels.commands_table_name));
    result.writeIfPresent(frame.tables, Atom.from(status_bar.commands_table_name));
    // Errors, warnings and information are told in `*Messages*`.
    result.writeIfPresent(frame.tables, Atom.from(mesha.text_editor.commands_table_name));
    // The outliner's tab remembers where its list last started, which `arrange` settles.
    result.writeAll(&.{ observed_table, motion_table, session_table, outliner_tab_table, feedback_table, draw_table, preview_table, app_state_table, time_commands, workspace.time_subscriptions, workspace.input_subscriptions });
    // The hover asks the host what lies under the pointer.
    result.write(Atom.from(asks.name));
    result.writeIfPresent(frame.tables, Atom.from(mesha.figure.queries_table_name));
    result.readAll(&workspace.table_groups.state);
    // The weight brush's test pose is the canvas's while it is on.
    result.read(Atom.from(weight.bones_name));
    result.read(Atom.from(panels_mod.nodes_table_name));
    result.read(Atom.from(panels_mod.state_table_name));
    return result;
}

/// The answers to the hover's questions: the latest shows what the pointer is over.
fn takeAnswers(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    for (pass.frame.messages) |received| {
        const document = session.get(tables).doc.*;
        const asked = asks.rows(tables);
        const answer = asks.take(asked, document, received) orelse continue;
        const answered = switch (answer.purpose) {
            .hover => hoverAnswered(&reads, answer),
            .hover_paint => hoverPaintAnswered(&reads, answer),
            else => continue,
        };
        answered catch |err| {
            clearCanvasHover(tables);
            switch (err) {
                error.NotReady, error.Busy, error.MissingDefinition => {},
                else => prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err)),
            }
        };
    }
}

/// The tool dock's scroll for the stage's width, the sequencer panel open while the editor
/// animates, and where the outliner's list starts in its panel.
fn arrange(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    if (workspace.stageViewport(tables, atoms)) |stage| {
        const layout = geometry.stageLayout(stage, workspace.stageChrome(session.observed(tables)));
        const mode = session.get(tables).mode.*;
        chrome.syncDock(session.get(tables), session.observed(tables), chrome.dockRect(mode, layout.canvas).w);
    }
    syncSequencer(tables, atoms);
    if (panel_frame.contentRect(tables, atoms, Atom.from(workspace.outliner_id))) |outliner| {
        const scratch = try pass.frame.memory.frameScratchAllocator();
        figure_panels.settleOutlinerScroll(scratch.allocator, tables, atoms, outliner.w, outliner.h);
    }
}

/// Starts the tweens that draw attention to a new mode, tool, status or rejection.
fn attend(pass: *sequencer.Pass) !void {
    try motion.sync(pass.frame.tables, pass.frame.atoms, try pass.writeRows(time_commands, motion.RequestView));
}

/// Publishes the canvas's place for automation, then picks what the pointer is over.
fn trackHover(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const canvas_rect = workspace.canvasViewport(tables, atoms) orelse panels_mod.Rect{};
    // Automation consumes this update-owned projection instead of duplicating chrome insets.
    const observed = session.observed(tables);
    const layout_changed = observed.canvas_x.* != canvas_rect.x or observed.canvas_y.* != canvas_rect.y or
        observed.canvas_width.* != canvas_rect.w or observed.canvas_height.* != canvas_rect.h;
    observed.canvas_x.* = canvas_rect.x;
    observed.canvas_y.* = canvas_rect.y;
    observed.canvas_width.* = canvas_rect.w;
    observed.canvas_height.* = canvas_rect.h;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    const hover_layout: HoverLayout = if (layout_changed) .changed else .stable;
    syncCanvasHover(&reads, hover_layout);
}

/// Which pose the canvas shows, given everything this frame changed.
fn trackPreview(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    preview.sync(tables, atoms) catch |err| prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
}

// ---- the sequencer panel --------------------------------------------------------------------

/// Shows the sequencer below the figure stage while the editor animates, and closes it after.
fn syncSequencer(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const stage = Atom.from(workspace.canvas_id);
    const sequencer_panel = Atom.from(workspace.sequencer_id);
    if (!fixed_panels.panelShown(tables, stage)) return;
    const animating = session.get(tables).mode.* == names.animate;
    const shown = fixed_panels.panelShown(tables, sequencer_panel);
    if (animating and !shown) fixed_panels.showPanel(tables, atoms, sequencer_panel, .arranged, .keep);
    if (!animating and shown) fixed_panels.hidePanel(tables, sequencer_panel);
}

// ---- canvas hover ----------------------------------------------------------------------------

pub const canvas_hover_id = ui.ElementId{ .atom = Atom.from("figure.canvas.space") };

pub fn canvasOwnsHover(tables: *Table.Registry) bool {
    const owner = editor_state.hoveredElementId(tables) orelse return false;
    return std.meta.eql(owner, canvas_hover_id);
}

fn canvasHoverTool(tables: *Table.Registry) Atom {
    if (color_picker.samplingChannel(tables) != null) return names.eyedropper;
    if (session.get(tables).space_held.* != 0) return names.hand;
    return session.get(tables).tool.*;
}

pub fn setCanvasCursor(feedback: session.FeedbackView, kind: os.CursorKind) void {
    feedback.cursor_kind.* = @intFromEnum(kind);
}

pub fn clearCanvasHover(tables: *Table.Registry) void {
    const editor = session.get(tables);
    const feedback = session.feedback(tables);
    const had_object = editor.hover_id.* != 0 or feedback.hover_doc.* != session.none;
    const control_hover = editor.hover_kind.* == names.scale_handle or editor.hover_kind.* == names.rotate_handle or editor.hover_kind.* == names.pivot_handle or editor.hover_kind.* == names.sample_color;
    const sampling_hover = feedback.hover_doc.* != session.none and feedback.hover_tool.* == names.eyedropper;
    if ((control_hover or sampling_hover) and editor.gesture_active.* == 0) {
        setCanvasCursor(session.feedback(tables), .arrow);
    }
    feedback.hover_pending.* = 0;
    feedback.hover_doc.* = session.none;
    editor.hover_id.* = 0;
    editor.hover_kind.* = session.none;
    editor.hover_sub.* = 0;
    if (had_object and canvasOwnsHover(tables)) {
        status_bar.request(tables.memory, tables, .clear_hover);
    }
}

fn describeCanvasHover(reads: *session.ReadContext) !void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const editor = session.get(tables);
    if (editor.hover_kind.* == names.sample_color) {
        const settings = drawing.config(tables);
        const default_channel: session.api.PaintChannel = if (settings.color_target.* == names.stroke) .stroke else .fill;
        const channel = color_picker.samplingChannel(tables) orelse default_channel;
        const hint = if (channel == .stroke) "Click to apply this color to strokes" else "Click to apply this color to fills";
        setCanvasTooltip(tables, hint);
        return;
    }
    if (editor.hover_kind.* == names.pen_insert) {
        setCanvasTooltip(tables, "Click to insert an anchor on the selected path");
        return;
    }
    if (editor.hover_kind.* == names.pen_close) {
        setCanvasTooltip(tables, "Click to close path");
        return;
    }
    if (editor.hover_kind.* == names.pen_cursor) {
        setCanvasTooltip(tables, "Click: corner · Drag: curve · Shift: 45 degrees · Enter/Esc: finish open");
        return;
    }
    if (editor.hover_kind.* == names.path_anchor) {
        setCanvasTooltip(tables, "Drag selected anchors · Shift: add · Alt: subtract · Double-click: corner/smooth");
        return;
    }
    if (editor.hover_kind.* == names.path_handle) {
        setCanvasTooltip(tables, "Drag handle · Alt: break mirroring");
        return;
    }
    if (editor.hover_kind.* == names.path_segment) {
        setCanvasTooltip(tables, "Drag segment: move both anchors · Alt-click: insert anchor");
        return;
    }
    if (editor.hover_kind.* == names.scale_handle) {
        setCanvasTooltip(tables, "Resize selection · Shift: keep aspect · Alt: from pivot");
        return;
    }
    if (editor.hover_kind.* == names.rotate_handle) {
        setCanvasTooltip(tables, "Rotate selection · Shift: 15° steps");
        return;
    }
    if (editor.hover_kind.* == names.pivot_handle) {
        setCanvasTooltip(tables, "Drag pivot · Reselect artwork to reset");
        return;
    }
    if (editor.hover_id.* == 0) {
        // Blank canvas is still a valid hover sample, including its tool cursor.
        status_bar.request(tables.memory, tables, .clear_hover);
        return;
    }
    const definition = try reads.definition(editor.doc.*);
    const is_bone = editor.hover_kind.* == names.bone;
    const name = if (is_bone) name: {
        const bone = session.findById(session.api.read.Bone, definition.bones, editor.hover_id.*) orelse return error.MissingBone;
        break :name bone.name;
    } else name: {
        const shape = session.findById(session.api.read.Shape, definition.shapes, editor.hover_id.*) orelse return error.MissingShape;
        break :name shape.name;
    };
    const object_name = atoms.lookup(name) orelse if (is_bone) "Bone" else "Shape";
    var description: []const u8 = object_name;
    var buffer: [512]u8 = undefined;
    if (is_bone and filmstrip.enabled(editor)) {
        const settings = pose.config(tables);
        const frame = try tables.memory.frameScratchAllocator();
        const chain_capacity = pose.automaticChainCapacity(definition, settings.auto_chain_length.*);
        const chain = try frame.allocator.alloc(u32, chain_capacity);
        const count = if (settings.auto_ik.* != 0 and editor.hover_sub.* == 1)
            pose.automaticHoverChain(definition, editor.hover_id.*, settings.auto_chain_length.*, chain)
        else
            0;
        const intent = pose.hoverIntent(definition, editor.hover_id.*, editor.hover_sub.*, settings.auto_ik.* != 0, chain[0..count]);
        const boundary = if (count != 0 and count < settings.auto_chain_length.*) " (chain stops at rig boundary)" else "";
        description = std.fmt.bufPrint(&buffer, "{s}: {s}{s}", .{ object_name, intent, boundary }) catch object_name;
    }
    setCanvasTooltip(tables, description);
}

pub fn setCanvasTooltip(tables: *Table.Registry, text: []const u8) void {
    // The request's row owns a copy, including text formatted on a caller's stack.
    status_bar.request(tables.memory, tables, .{ .set_hover = text });
}

fn updateCanvasHover(reads: *session.ReadContext, screen_point: session.Vec2, constraint: drawing.PenConstraint) !void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const trace_zone = Log.zone(Zone.hover);
    defer trace_zone.end();
    const editor = session.get(tables);
    const document_point = workspace.screenToDocument(tables, atoms, screen_point.x, screen_point.y) orelse return;
    editor.hover_point.* = document_point;
    if (!canvasOwnsHover(tables) or action_palette.requestOpen(tables, atoms)) {
        clearCanvasHover(tables);
        return;
    }
    errdefer clearCanvasHover(tables);
    if (workspace.canvasViewport(tables, atoms)) |rect| if (!geometry.contains(rect, .{ .x = screen_point.x, .y = screen_point.y })) {
        clearCanvasHover(tables);
        setCanvasCursor(session.feedback(tables), .arrow);
        return;
    };
    preview.ready(tables, atoms) catch |err| switch (err) {
        error.NotReady, error.Busy => {
            clearCanvasHover(tables);
            setCanvasCursor(session.feedback(tables), .arrow);
            return;
        },
    };
    const evaluated_bones = (try preview.evaluation(tables, atoms)).bones;
    const hover_tool = canvasHoverTool(tables);
    if (hoverPicksArtwork(editor, hover_tool)) {
        // Select in Rig picks a bone before the artwork under it.
        if (hover_tool != names.eyedropper and editor.tool.* == names.select) {
            if (workspace.pickBoneAtRest(editor, evaluated_bones, document_point)) |bone| {
                try finishCanvasHover(reads, document_point, bone);
                return;
            }
        }
        // What lies under the pointer is the host's to find; `hoverAnswered` goes on.
        try asks.hitTest(tables, atoms, system(), .{ .purpose = .hover, .point = document_point });
        return;
    }
    const hit = if (session.atRest(editor) and editor.tool.* != names.weight) design: {
        if (editor.tool.* == names.edit_points) break :design try drawing.pointHover(tables, atoms, document_point);
        if (editor.tool.* == names.pen) {
            break :design try drawing.penHover(tables, atoms, document_point, constraint);
        }
        if (!session.bonesShown(editor)) break :design null;
        break :design geometry.pickBone(evaluated_bones, document_point, editor.view_zoom.*);
    } else geometry.pickBone(evaluated_bones, document_point, editor.view_zoom.*);
    try finishCanvasHover(reads, document_point, hit);
}

/// Whether the hover over the canvas is of the artwork the host finds under the pointer: while
/// sampling a colour, and at rest with a tool that picks artwork rather than bones or points.
fn hoverPicksArtwork(editor: session.View, hover_tool: Atom) bool {
    if (hover_tool == names.eyedropper) return true;
    if (!session.atRest(editor) or editor.tool.* == names.weight) return false;
    const tool = editor.tool.*;
    const picks_points = tool == names.edit_points or tool == names.pen;
    const picks_bones = tool == names.bone or tool == names.stick or tool == names.ik;
    return !picks_points and !picks_bones;
}

/// The hover the host's answer at `answer.point` makes, unless the canvas's hover context changed
/// since it was asked, a press took the pointer, or the canvas no longer has it.
fn hoverAnswered(reads: *session.ReadContext, answer: asks.Answer) !void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const editor = session.get(tables);
    if (!canvasOwnsHover(tables) or editor.gesture_active.* != 0) return;
    if (hoverContextChanged(tables)) return;
    try answer.failure.check();
    const found = answer.hits();
    const point = answer.point;
    const hover_tool = canvasHoverTool(tables);
    const hit = if (hover_tool == names.eyedropper) sample: {
        const sampled = try drawing.sampleOf(tables, atoms, found) orelse break :sample null;
        // A paint's colour there is the host's to say; `hoverPaintAnswered` shows it.
        const asker = system();
        const color = try drawing.sampledColor(tables, atoms, asker, .hover_paint, point, sampled) orelse return;
        drawing.config(tables).sampled_color.* = color;
        break :sample geometry.Hit{ .kind = names.sample_color, .id = sampled.shape, .point = point };
    } else if (editor.tool.* == names.eraser) drawing.eraserHover(found, point) else workspace.pickShape(found, point);
    try finishCanvasHover(reads, point, hit);
}

/// The colour of the paint under the pointer, as the host answered it, sampled as the hover,
/// unless the hover context changed since it was asked, a press took the pointer, or the canvas
/// no longer has it.
fn hoverPaintAnswered(reads: *session.ReadContext, answer: asks.Answer) !void {
    const tables = reads.tables;
    const editor = session.get(tables);
    if (!canvasOwnsHover(tables) or editor.gesture_active.* != 0) return;
    if (hoverContextChanged(tables)) return;
    if (canvasHoverTool(tables) != names.eyedropper) return;
    const color = try drawing.paintColor(answer);
    const settings = drawing.config(tables);
    settings.sampled_color.* = color;
    const hit = geometry.Hit{ .kind = names.sample_color, .id = answer.value, .point = answer.point };
    try finishCanvasHover(reads, answer.point, hit);
}

/// Shows `hit` as what the pointer at `document_point` is over, unless a handle of the
/// selection's is there, and the cursor and description that go with it.
fn finishCanvasHover(reads: *session.ReadContext, document_point: session.Vec2, hit: ?geometry.Hit) !void {
    const tables = reads.tables;
    const editor = session.get(tables);
    const hover_tool = canvasHoverTool(tables);
    const sampling_color = hover_tool == names.eyedropper;
    const transform_hit: drawing.SelectHit = if (sampling_color) .none else try drawing.selectHandle(reads, document_point);
    if (editor.tool.* == names.pen) {
        if (hit) |target| editor.hover_point.* = target.point;
    }
    switch (transform_hit) {
        .scale, .rotate => |corner| {
            editor.hover_kind.* = if (transform_hit == .scale) names.scale_handle else names.rotate_handle;
            editor.hover_id.* = 0;
            editor.hover_sub.* = @intFromEnum(corner);
        },
        .pivot => {
            editor.hover_kind.* = names.pivot_handle;
            editor.hover_id.* = 0;
            editor.hover_sub.* = 0;
        },
        .none => {
            editor.hover_kind.* = if (hit) |h| h.kind else session.none;
            editor.hover_id.* = if (hit) |h| h.id else 0;
            editor.hover_sub.* = if (hit) |h| h.sub else 0;
        },
    }
    try describeCanvasHover(reads);
    var cursor = if (hover_tool == names.select) drawing.selectCursor(transform_hit) else if (hover_tool == names.hand) os.CursorKind.hand else os.CursorKind.crosshair;
    if (!sampling_color and editor.tool.* == names.select and transform_hit == .none) {
        if (hit) |item| {
            if (item.kind == names.shape) {
                const definition = try reads.definition(editor.doc.*);
                if (session.findById(session.api.read.Shape, definition.shapes, item.id)) |shape| {
                    if (!workspace.followsBone(shape)) cursor = .move;
                }
            } else if (item.kind == names.bone and item.sub < 2) cursor = .move;
        }
    }
    if (!sampling_color and editor.tool.* == names.edit_points and hit != null) cursor = .move;
    setCanvasCursor(session.feedback(tables), cursor);
}

/// Asks for a pick at the saved pointer position, against the context as it stands now.
pub fn requestCanvasHover(tables: *Table.Registry) void {
    const editor = session.get(tables);
    const feedback = session.feedback(tables);
    feedback.hover_doc.* = editor.doc.*;
    feedback.hover_mode.* = editor.mode.*;
    feedback.hover_tool.* = canvasHoverTool(tables);
    feedback.hover_flags.* = editor.flags.*;
    feedback.hover_center.* = editor.view_center.*;
    feedback.hover_zoom.* = editor.view_zoom.*;
    feedback.hover_version.* = preview.state(tables).version.*;
    feedback.hover_pending.* = 1;
}

const HoverLayout = enum { stable, changed };

/// Whether what the canvas shows, or how, changed since the latest hover sample was asked for.
fn hoverContextChanged(tables: *Table.Registry) bool {
    const editor = session.get(tables);
    const feedback = session.feedback(tables);
    const preview_state = preview.state(tables);
    const hover_tool = canvasHoverTool(tables);
    return feedback.hover_doc.* != editor.doc.* or feedback.hover_mode.* != editor.mode.* or
        feedback.hover_tool.* != hover_tool or feedback.hover_flags.* != editor.flags.* or
        feedback.hover_center.x != editor.view_center.x or feedback.hover_center.y != editor.view_center.y or
        feedback.hover_zoom.* != editor.view_zoom.* or feedback.hover_version.* != preview_state.version.*;
}

fn syncCanvasHover(reads: *session.ReadContext, layout: HoverLayout) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    if (!canvasOwnsHover(tables)) {
        clearCanvasHover(tables);
        return;
    }
    if (workspace.canvasViewport(tables, atoms) == null) {
        clearCanvasHover(tables);
        return;
    }
    const editor = session.get(tables);
    const feedback = session.feedback(tables);
    const hover_tool = canvasHoverTool(tables);
    const context_changed = hoverContextChanged(tables);
    if (layout == .changed or action_palette.requestOpen(tables, atoms) or editor.gesture_active.* != 0) {
        clearCanvasHover(tables);
        return;
    }
    // A new tool or mode changes the answer with the pointer at rest, so it picks again. Other
    // context still only clears: a view or preview can change every frame, and a pick is costly.
    if (feedback.hover_tool.* != hover_tool or feedback.hover_mode.* != editor.mode.*) {
        requestCanvasHover(tables);
    } else if (context_changed) {
        clearCanvasHover(tables);
        return;
    }
    if (feedback.hover_pending.* != 0) {
        // A pose this frame changed is answered after the run: the pick waits for it.
        if (awaitingShownPose(tables, atoms)) return;
        const point = feedback.hover_screen.*;
        const constraint: drawing.PenConstraint = if (feedback.hover_shift.* != 0) .angle else .free;
        feedback.hover_pending.* = 0;
        updateCanvasHover(reads, point, constraint) catch |err| {
            clearCanvasHover(tables);
            prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        };
        return;
    }
    preview.ready(tables, atoms) catch {
        clearCanvasHover(tables);
        return;
    };
}

/// Whether the canvas has a definition to show in a pose the host has not answered yet, as
/// when this frame's run changed the pose.
fn awaitingShownPose(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    preview.ready(tables, atoms) catch return false;
    _ = preview.evaluation(tables, atoms) catch |err| return err == error.NotReady;
    return false;
}
