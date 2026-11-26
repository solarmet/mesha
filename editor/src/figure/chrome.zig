//! Stage-local controls. Layout and scroll state belong to update, not presentation.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const roop = mesha.roop;
const keybinds = mesha.keybinds;
const session = @import("session.zig");
const workspace = @import("workspace.zig");
const os = mesha.os;
const geometry = @import("geometry.zig");
const pose = @import("pose.zig");
const drawing = @import("drawing.zig");
const prompts = @import("prompts.zig");
const selection = @import("selection.zig");
const weight = @import("weight.zig");
const filmstrip = @import("filmstrip.zig");
const gesture = @import("gesture.zig");
const canvas = @import("canvas.zig");
const motion = @import("motion.zig");
const figure = mesha.figure;
const math = mesha.math;
const editor_state = @import("../state.zig");
const editor_mod = @import("../editor.zig");
const editor_modes = @import("../modes.zig");
const fixed_panels = @import("../fixed_panels.zig");
const button = @import("../ui/button.zig");
const vector_field = ui.vector_field;
const style = @import("../ui/style.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const sketches = @import("sketches.zig");
const status_bar = @import("../status_bar.zig");
const transport_fixture = @import("transport_fixture.zig");

const Log = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { status };

pub const Group = enum { select, create, rig, utility };
const Selector = enum { tool, auto_ik, none };
pub const Tool = struct {
    label: []const u8,
    action: []const u8,
    value: []const u8 = "",
    icon: ?button.icons.Icon = null,
    hint: []const u8 = "",
    group: Group = .select,
    selector: Selector = .tool,
};
const design_tools = [_]Tool{
    .{ .label = "Select", .action = @tagName(workspace.Msg.figure_tool_select), .value = "select", .icon = .cursor_default, .hint = "Select and move artwork" },
    .{ .label = "Hand", .action = @tagName(workspace.Msg.figure_tool_hand), .value = "hand", .icon = .hand_back_left, .hint = "Drag to pan the canvas" },
    .{ .label = "Pen", .action = @tagName(drawing.Msg.figure_tool_pen), .value = "pen", .icon = .pen, .group = .create, .hint = "Place path anchors" },
    .{ .label = "Pencil", .action = @tagName(drawing.Msg.figure_tool_pencil), .value = "pencil", .icon = .pencil, .group = .create, .hint = "Draw a freehand path" },
    .{ .label = "Rectangle", .action = @tagName(drawing.Msg.figure_tool_rect), .value = "rect", .icon = .rectangle_outline, .group = .create, .hint = "Drag to draw a rectangle" },
    .{ .label = "Ellipse", .action = @tagName(drawing.Msg.figure_tool_ellipse), .value = "ellipse", .icon = .ellipse_outline, .group = .create, .hint = "Drag to draw an ellipse" },
    .{ .label = "Line", .action = @tagName(drawing.Msg.figure_tool_line), .value = "line", .icon = .vector_line, .group = .create, .hint = "Drag to draw a line" },
    .{ .label = "Polygon", .action = @tagName(drawing.Msg.figure_tool_polygon), .value = "polygon", .icon = .vector_polygon, .group = .create, .hint = "Drag to draw a regular polygon" },
    .{ .label = "Gradient", .action = @tagName(drawing.Msg.figure_tool_gradient), .value = "gradient", .icon = .gradient_horizontal, .group = .utility, .hint = "Edit linear paint coordinates" },
    .{ .label = "Radial", .action = @tagName(drawing.Msg.figure_tool_radial), .value = "radial", .icon = .circle_opacity, .group = .utility, .hint = "Edit radial paint coordinates" },
    .{ .label = "Eyedropper", .action = @tagName(drawing.Msg.figure_tool_eyedropper), .value = "eyedropper", .icon = .eyedropper, .group = .utility, .hint = "Pick artwork color" },
    .{ .label = "Eraser", .action = @tagName(drawing.Msg.figure_tool_eraser), .value = "eraser", .icon = .eraser, .group = .utility, .hint = "Drag over strokes to delete them" },
};
const rig_tools = [_]Tool{
    .{ .label = "Select", .action = @tagName(workspace.Msg.figure_tool_select), .value = "select", .icon = .cursor_default, .hint = "Select and move bones; click artwork to bind it" },
    .{ .label = "Hand", .action = @tagName(workspace.Msg.figure_tool_hand), .value = "hand", .icon = .hand_back_left, .hint = "Drag to pan the canvas" },
    .{ .label = "Bone", .action = @tagName(workspace.Msg.figure_tool_bone), .value = "bone", .icon = .bone, .group = .rig, .hint = "Construct or adjust bones" },
    .{ .label = "Stick", .action = @tagName(workspace.Msg.figure_tool_stick), .value = "stick", .icon = .human_male, .group = .rig, .hint = "Construct bones with linked artwork" },
    .{ .label = "IK", .action = @tagName(pose.Msg.figure_tool_ik), .value = "ik", .icon = .vector_link, .group = .rig, .hint = "Choose an end joint for an IK chain" },
    .{ .label = "Joint fill", .action = @tagName(drawing.Msg.figure_tool_joint_fill), .value = "joint_fill", .icon = .format_color_fill, .group = .rig, .hint = "Create artwork following selected joints" },
    .{ .label = "Weight brush", .action = @tagName(weight.Msg.figure_mode_weight), .value = "weight", .icon = .brush, .group = .utility, .hint = "Paint weights on selected artwork" },
};
const animate_tools = [_]Tool{
    .{ .label = "Select", .action = @tagName(workspace.Msg.figure_tool_select), .value = "select", .icon = .cursor_default, .hint = "Drag joints and bones" },
    .{ .label = "Hand", .action = @tagName(workspace.Msg.figure_tool_hand), .value = "hand", .icon = .hand_back_left, .hint = "Drag to pan the canvas" },
    .{ .label = "Auto IK / FK", .action = @tagName(pose.Msg.figure_pose_auto_ik), .icon = .vector_link, .selector = .auto_ik, .hint = "Toggle automatic IK; off uses FK" },
    .{ .label = "Longer chain", .action = @tagName(pose.Msg.figure_pose_chain_more), .icon = .plus, .selector = .none, .hint = "Increase automatic IK chain length" },
    .{ .label = "Shorter chain", .action = @tagName(pose.Msg.figure_pose_chain_less), .icon = .minus, .selector = .none, .hint = "Decrease automatic IK chain length" },
};
const modes = [_]Tool{
    .{ .label = "Design", .action = @tagName(workspace.Msg.figure_mode_design), .value = "design", .hint = "Draw and edit artwork" },
    .{ .label = "Rig", .action = @tagName(workspace.Msg.figure_mode_rig), .value = "rig", .hint = "Build bones, bind artwork and paint weights" },
    .{ .label = "Animate", .action = @tagName(filmstrip.Msg.figure_mode_animate), .value = "animate", .hint = "Pose the figure and key its clips" },
};
const utilities = [_]Tool{
    .{ .label = "Fit", .action = @tagName(workspace.Msg.figure_view_fit), .icon = .fit_to_screen, .hint = "Fit document to the canvas" },
    .{ .label = "Undo", .action = @tagName(workspace.Msg.figure_undo), .icon = .undo, .hint = "Undo the last document edit" },
    .{ .label = "Redo", .action = @tagName(workspace.Msg.figure_redo), .icon = .redo, .hint = "Redo the last undone edit" },
    .{ .label = "Save", .action = @tagName(workspace.Msg.figure_save), .icon = .content_save, .hint = "Save the document" },
};
/// The panels beside the stage, each lit while it is shown.
const panel_toggles = [_]struct { tool: Tool, panel: Atom }{
    .{ .tool = .{ .label = "Layers", .action = @tagName(workspace.Msg.figure_toggle_layers), .icon = .layers, .hint = "Show or hide the Layers panel" }, .panel = workspace.outliner_panel.id },
    .{ .tool = .{ .label = "Properties", .action = @tagName(workspace.Msg.figure_toggle_properties), .icon = .cog, .hint = "Show or hide the Properties panel" }, .panel = workspace.inspector_panel.id },
};
pub const tool_size: f32 = 40;
pub const tool_gap: f32 = 4;
pub const group_gap: f32 = 9;
pub const dock_padding: f32 = 6;
pub const dock_margin: f32 = 12;

fn tools(mode: Atom) []const Tool {
    if (mode == names.design) return &design_tools;
    if (mode == names.rig) return &rig_tools;
    if (mode == names.animate) return &animate_tools;
    return &.{};
}

fn toolLeft(entries: []const Tool, index: usize) f32 {
    var left = dock_padding;
    for (entries[0..index], 0..) |entry, i| {
        left += tool_size + tool_gap;
        if (entry.group != entries[i + 1].group) left += group_gap;
    }
    return left;
}

fn dockContentWidth(mode: Atom) f32 {
    const entries = tools(mode);
    if (entries.len == 0) return 0;
    const last_left = toolLeft(entries, entries.len - 1);
    return last_left + tool_size + dock_padding;
}

/// The selected tool's place in the current dock row, null when the row has no button for it.
pub fn selectedToolLeft(mode: Atom, tool: Atom) ?f32 {
    // Editing points is a state of Select, which stays the lit button.
    const shown_tool = if (tool == Atom.from("edit_points")) Atom.from("select") else tool;
    const entries = tools(mode);
    for (entries, 0..) |entry, i| {
        if (entry.selector != .tool) continue;
        if (Atom.from(entry.value) == shown_tool) return toolLeft(entries, i);
    }
    return null;
}

pub fn modeSlot(mode: Atom) ?f32 {
    for (modes, 0..) |entry, i| {
        if (Atom.from(entry.value) == mode) return @floatFromInt(i);
    }
    return null;
}

/// Floats at the bottom center of the canvas, in the same space as `canvas_rect`. Pass the global
/// canvas for input bounds or the local one for rendering.
pub fn dockRect(mode: Atom, canvas_rect: panels_mod.Rect) panels_mod.Rect {
    const height = tool_size + 2 * dock_padding;
    const width = @min(dockContentWidth(mode), canvas_rect.w - 2 * dock_margin);
    if (width <= 0 or canvas_rect.h < height + 2 * dock_margin) return .{};
    return .{
        .x = canvas_rect.x + (canvas_rect.w - width) * 0.5,
        .y = canvas_rect.y + canvas_rect.h - height - dock_margin,
        .w = width,
        .h = height,
    };
}

pub fn maxDockScroll(mode: Atom, width: f32) f32 {
    return @max(0, dockContentWidth(mode) - width);
}

/// Wheel navigation may hide the current tool; choosing a tool or mode reveals it in update.
pub fn syncDock(editor: session.View, observed: session.ObservedView, width: f32) void {
    const maximum = maxDockScroll(editor.mode.*, width);
    var scroll = if (std.math.isFinite(observed.tools_scroll.*)) observed.tools_scroll.* else 0;
    scroll = std.math.clamp(scroll, 0, maximum);
    if (observed.tools_reveal.* != 0 or observed.tools_mode.* != editor.mode.* or observed.tools_tool.* != editor.tool.*) {
        scroll = 0;
        const entries = tools(editor.mode.*);
        for (entries, 0..) |entry, i| {
            const value = Atom.from(entry.value);
            if (entry.selector != .tool or editor.tool.* != value) continue;
            const left = toolLeft(entries, i);
            if (left + tool_size > width) scroll = left + tool_size - width;
            break;
        }
        observed.tools_mode.* = editor.mode.*;
        observed.tools_tool.* = editor.tool.*;
        observed.tools_reveal.* = 0;
    }
    observed.tools_scroll.* = std.math.clamp(scroll, 0, maximum);
}

const Scope = enum { header, dock, timeline };
pub fn actionButton(tree: *ui.Tree, shortcuts: *editor_mod.Shortcuts, scope: Scope, entry: Tool, options: button.Options) void {
    const scope_name = std.fmt.allocPrint(tree.frame_allocator.allocator, "figure.{s}", .{@tagName(scope)}) catch return;
    boundActionButton(tree, shortcuts, scope_name, entry, options);
}

/// A tooltip names the chord `figure`'s keymap gives the button's action.
pub fn boundActionButton(tree: *ui.Tree, shortcuts: *editor_mod.Shortcuts, scope: []const u8, entry: Tool, options: button.Options) void {
    const action = Atom.from(entry.action);
    const click = workspace.to(tree, action, {});
    const id_text = std.fmt.allocPrint(tree.frame_allocator.allocator, "{s}.{s}", .{ scope, entry.action }) catch return;
    const id = Atom.from(id_text);
    const short_name = editor_modes.shortName("figure", entry.action);
    const action_id: plugin.action_api.ActionId = .{ editor_modes.figure, Atom.from(short_name) };
    const shortcut = shortcuts.text(editor_modes.figure, action_id);
    const tooltip = if (shortcut) |keys|
        std.fmt.allocPrint(tree.frame_allocator.allocator, "{s} ({s}) - {s}", .{ entry.label, keys, entry.hint }) catch entry.label
    else
        std.fmt.allocPrint(tree.frame_allocator.allocator, "{s} - {s}", .{ entry.label, entry.hint }) catch entry.label;
    var configured = options;
    configured.label = entry.label;
    configured.icon = entry.icon;
    configured.tooltip = tooltip;
    button.render(tree, id, click, configured);
}

/// Passive text still needs an inert click route to take part in the hover hits
/// `ui.Tree.commit` writes.
pub fn hoverRegion(tree: *ui.Tree, text: []const u8) void {
    tree.onClick(workspace.to(tree, .from(workspace.Msg.figure_chrome_info), {}), .left);
    tree.trackHover(text);
}

pub const header_padding: f32 = 4;
pub const header_gap: f32 = 4;
const mode_button_width: f32 = 84;

/// Where a mode button sits at a possibly fractional slot, matching `renderHeader`'s row.
fn modeSlotRect(header: panels_mod.Rect, slot: f32) panels_mod.Rect {
    const first_left = header.x + header_padding;
    return .{
        .x = first_left + slot * (mode_button_width + header_gap),
        .y = header.y + header_padding,
        .w = mode_button_width,
        .h = header.h - 2 * header_padding,
    };
}

/// The active mark in flight. The destination is already lit in the same accent, so it lands
/// without a seam; translucency keeps the labels it crosses readable.
fn renderTravelingMark(rect: panels_mod.Rect, clip: panels_mod.Rect, ctx: *roop.Context) void {
    ctx.save();
    defer ctx.restore();
    ctx.intersectScissor(clip.x, clip.y, clip.w, clip.h, 0);
    var color = style.col.accent_deep;
    color.a = 0.75;
    ctx.beginPath();
    ctx.roundedRect(rect.x, rect.y, rect.w, rect.h, style.metric.button_radius);
    ctx.fillColor(color);
    ctx.fill();
}

fn renderModeGlide(motion_view: session.MotionView, editor: session.View, header: panels_mod.Rect, ctx: *roop.Context) void {
    const shown_slot = motion_view.mode_slot.*;
    const slot = modeSlot(editor.mode.*) orelse return;
    if (shown_slot == slot) return;
    renderTravelingMark(modeSlotRect(header, shown_slot), header, ctx);
}

fn renderToolGlide(editor: session.View, motion_view: session.MotionView, observed: session.ObservedView, dock: panels_mod.Rect, ctx: *roop.Context) void {
    const shown_left = motion_view.tool_left.*;
    const left = selectedToolLeft(editor.mode.*, editor.tool.*) orelse return;
    if (shown_left == left) return;
    const scroll = observed.tools_scroll.*;
    const rect = panels_mod.Rect{
        .x = dock.x + shown_left - scroll,
        .y = dock.y + dock_padding,
        .w = tool_size,
        .h = tool_size,
    };
    renderTravelingMark(rect, dock, ctx);
}

/// The figure stage's place in its panel's header: the open document's name after the title,
/// and a "*" right after it while it has unsaved work.
pub fn renderDecoration(tree: *ui.Tree, tables: *Table.Registry) void {
    const editor = session.get(tables);
    const open_name = tree.atoms.lookup(editor.doc.*);
    const name = open_name orelse "No document";
    const name_color = if (open_name != null) style.col.text else style.col.text_dim;
    tree.rect("figure.decoration.inset", .{ .size = .{ .w = .{ .fixed = 2 }, .h = .fill } });
    tree.text("figure.decoration.name", name, .{ .font = style.ui_font, .color = name_color });
    if (editor.dirty.* != 0) tree.text("figure.decoration.unsaved", "*", .{ .font = style.ui_font, .color = style.col.accent_bright });
}

fn renderHeader(tree: *ui.Tree, tables: *Table.Registry, shortcuts: *editor_mod.Shortcuts, rect: panels_mod.Rect) void {
    const editor = session.get(tables);
    const available = session.definitionInfo(tables, tree.atoms, editor.doc.*) != null;
    if (tree.beginRect("figure.header", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = rect.h } }, .padding = header_padding, .gap = header_gap, .bg = style.col.sidebar, .clip_content = true })) {
        defer tree.endRect();
        for (modes) |mode| {
            const value = Atom.from(mode.value);
            actionButton(tree, shortcuts, .header, mode, .{ .variant = .tab, .size = .{ .w = .{ .fixed = mode_button_width }, .h = .fill }, .selected = editor.mode.* == value, .enabled = available });
        }
        tree.rect("figure.header.space", .{ .size = .{ .w = .fill, .h = .fill } });
        sketches.renderMembers(tree, tables);
        const zoom = std.fmt.allocPrint(tree.frame_allocator.allocator, "{d:.0}%", .{editor.view_zoom.* * 100}) catch "Zoom";
        tree.text("figure.header.zoom", zoom, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .{ .fixed = 64 } } });
        const utility_side = rect.h - 2 * header_padding;
        for (utilities) |entry| actionButton(tree, shortcuts, .header, entry, .{ .variant = .icon_only, .icon_only_side = utility_side, .enabled = available });
        for (panel_toggles) |toggle| {
            const shown = fixed_panels.panelShown(tables, toggle.panel);
            actionButton(tree, shortcuts, .header, toggle.tool, .{ .variant = .icon_only, .icon_only_side = utility_side, .selected = shown });
        }
    }
}

fn renderDock(tree: *ui.Tree, tables: *Table.Registry, shortcuts: *editor_mod.Shortcuts, rect: panels_mod.Rect) void {
    const editor = session.get(tables);
    const observed = session.observed(tables);
    const available = session.definitionInfo(tables, tree.atoms, editor.doc.*) != null;
    const content_width = dockContentWidth(editor.mode.*);
    const maximum = maxDockScroll(editor.mode.*, rect.w);
    const stored_scroll = if (std.math.isFinite(observed.tools_scroll.*)) observed.tools_scroll.* else 0;
    const scroll = std.math.clamp(stored_scroll, 0, maximum);
    if (tree.beginRect("figure.dock", .{ .size = .{ .w = .{ .fixed = rect.w }, .h = .{ .fixed = rect.h } }, .clip_content = true, .scroll = .horizontal, .scroll_offset = scroll })) {
        defer tree.endRect();
        // Clicks between the buttons land on the dock, not on the canvas beneath it.
        const consume = workspace.to(tree, .from(workspace.Msg.figure_chrome_info), {});
        tree.onClick(consume, .left);
        tree.onScroll(workspace.to(tree, .from(workspace.Msg.figure_scroll), workspace.ScrollSurface.dock));
        if (tree.beginRect("figure.dock.content", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .{ .fixed = content_width }, .h = .fill }, .padding = dock_padding, .gap = tool_gap })) {
            defer tree.endRect();
            const entries = tools(editor.mode.*);
            const settings = pose.config(tables);
            for (entries, 0..) |entry, i| {
                if (i != 0 and entry.group != entries[i - 1].group) {
                    const separator_id = ui.ElementId{ .atom = names.@"figure.dock.separator", .extra = i };
                    tree.rect(separator_id, .{ .size = .{ .w = .{ .fixed = group_gap - tool_gap }, .h = .{ .fixed = tool_size * 0.5 } } });
                }
                const value = Atom.from(entry.value);
                const selected = switch (entry.selector) {
                    .tool => editor.tool.* == value or (value == Atom.from("select") and editor.tool.* == Atom.from("edit_points")),
                    .auto_ik => settings.auto_ik.* != 0,
                    .none => false,
                };
                const drawing_settings = drawing.config(tables);
                const locked = entry.selector == .tool and drawing_settings.locked_tool.* == value;
                var tool_entry = entry;
                if (locked) tool_entry.hint = "Locked: keep drawing; choose another tool to unlock";
                actionButton(tree, shortcuts, .dock, tool_entry, .{ .variant = .icon_only, .enabled = available, .selected = selected, .badge = if (locked) .lock else .none });
            }
        }
    }
}

/// Keeps what the frame's rendering found in the feedback's row: its failures and a limited
/// overlay, which `motion.sync` tells the person, and a brush out of reach, the status bar's.
pub fn noteRendering(feedback: session.FeedbackView, result: canvas.RenderResult) void {
    feedback.render_artwork_error.* = if (result.main_error) |err| @intFromError(err) else 0;
    feedback.render_evaluation_error.* = if (result.fallback_error) |err| @intFromError(err) else 0;
    feedback.render_onion_error.* = if (result.onion_error) |err| @intFromError(err) else 0;
    feedback.render_weights_error.* = if (result.weight_error) |err| @intFromError(err) else 0;
    feedback.render_overlay_limited.* = @intFromBool(result.overlay_limited);
    const reach = result.weight_brush_reach orelse 1;
    feedback.brush_reaches_nothing.* = @intFromBool(reach == 0);
}

/// What the status bar says about the current tool and gesture. Formatted into `allocator`.
pub fn statusHint(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) []const u8 {
    const editor = session.get(tables);
    const settings = pose.config(tables);
    var hint: []const u8 = "Space or middle drag: pan   Wheel: pan   Ctrl+wheel: zoom   Shift+1: fit   Ctrl+K: search";
    if (editor.tool.* == names.ik and settings.ik_end.* != 0) {
        hint = std.fmt.allocPrint(allocator, "IK end {d}, chain {d} | Up/Down adjust; Enter commit; Esc cancel", .{ settings.ik_end.*, settings.ik_chain.* }) catch "IK draft";
    }
    if (editor.tool.* == names.weight) {
        hint = "Drag: paint brush bone   Click other artwork: select   Alt-click: choose bone   Ctrl-click: inspect anchor   Esc: cancel stroke";
    }
    if (editor.mode.* == names.animate) {
        const constraint = pose.constraintText(tables, atoms);
        if (constraint.len != 0) hint = constraint;
    }
    if (editor.mode.* == names.animate) {
        const animation = filmstrip.config(tables);
        const has_selected_key = (filmstrip.selectedKey(tables, atoms) catch null) != null;
        const auto_key = if (animation.playing.* != 0) "Auto-key: locked (playing)" else if (has_selected_key) "Auto-key: selected key" else "Auto-key: working only; +Key captures";
        hint = std.fmt.allocPrint(allocator, "{s} | {s}", .{ auto_key, hint }) catch auto_key;
    }
    if (editor.reparent_active.* != 0) hint = "Pick a new parent; empty space makes a root. Esc cancels.";
    const drawing_settings = drawing.config(tables);
    if (drawing.primitiveTool(editor.tool.*) != null) {
        hint = if (drawing_settings.locked_tool.* == editor.tool.*)
            "Locked tool | Shift: constrain  Alt: from center  Esc: cancel drag | Choose another tool to unlock"
        else
            "Shift: constrain  Alt: from center  Click: default size | Double-tap tool shortcut to keep drawing";
    }
    if (editor.tool.* == names.joint_fill) {
        const count = drawing.draftCount(session.get(tables), session.drafts(tables));
        const instruction = if (count >= 3) "Enter or first joint: close fill" else "Pick at least three distinct joints";
        hint = std.fmt.allocPrint(allocator, "{d} joints | {s} | Backspace: remove last | Esc: cancel", .{ count, instruction }) catch "Joint fill";
    }
    if (drawing_settings.creation_request.* != 0) hint = "Creating shape; waiting for acknowledgement";
    if (drawing_settings.pending_delete_layer.* != 0) hint = "Layer contains artwork. Delete again to confirm; Esc cancels.";
    const drag = gesture.get(tables);
    const intent = gesture.intentOf(drag);
    const pose_drag = gesture.kindOf(drag) == .pose;
    if (pose_drag and intent == .commit) {
        hint = "Finishing pose edit; waiting for acknowledgement";
    } else if (intent == .none and editor.gesture_active.* != 0 and editor.gesture_kind.* == names.pose_auto_ik) {
        const limited = settings.residual.* * editor.view_zoom.* > 2;
        hint = std.fmt.allocPrint(allocator, "Auto IK: {d} bones | target cross / solved ring | residual {d:.2}{s}", .{ pose.dragChainLength(pose.dragChainLinks(tables)), settings.residual.*, if (limited) " (reach limited)" else "" }) catch "Auto IK";
    }
    if (editor.gesture_active.* != 0 and editor.gesture_kind.* == names.construct) {
        const delta = math.Vec2f.sub(editor.gesture_current.*, editor.gesture_start.*);
        const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
        const angle_radians = std.math.atan2(delta.y, delta.x);
        const angle_degrees = angle_radians * 180 / std.math.pi;
        const snap = atoms.lookup(editor.snap_kind.*) orelse "none";
        hint = std.fmt.allocPrint(allocator, "Length {d:.2}  Angle {d:.2} deg  Snap: {s}   Alt bypasses snap; Enter commits chain; Esc rolls it back", .{ length, angle_degrees, snap }) catch "Constructing bone";
    }
    if (session.feedback(tables).brush_reaches_nothing.* != 0) {
        hint = "Brush reaches no anchors on this path: move over an anchor, widen Radius, or Add anchors along path";
    }
    return hint;
}

const option_button_width: f32 = 96;
const option_field_width: f32 = 112;
const option_stepper_width: f32 = 32;

pub const OptionButton = struct {
    label: []const u8,
    hint: []const u8,
    enabled: bool = true,
    selected: bool = false,
    width: f32 = option_button_width,
};

/// Every button in the options bar shares one width, so a row of them reads as a set.
/// `action` is a tool family's `Msg` tag; its name is the button's id.
pub fn optionButton(tree: *ui.Tree, action: anytype, options: OptionButton) void {
    const id = @tagName(action);
    const action_atom = Atom.from(action);
    const click = workspace.to(tree, action_atom, {});
    button.render(tree, id, click, .{
        .label = options.label,
        .tooltip = options.hint,
        .enabled = options.enabled,
        .selected = options.selected,
        .variant = .text_only,
        .size = .{ .w = .{ .fixed = options.width }, .h = .fill },
    });
}

/// Room for an anchor's two coordinates in the options bar.
const point_position_width: f32 = 176;

pub const OptionField = struct {
    label: []const u8,
    value: []const u8,
    hint: []const u8,
    enabled: bool = true,
    cursor: os.CursorKind = .arrow,
};

/// A label beside a value that opens for editing when pressed. `id` also keys its children.
pub fn optionField(tree: *ui.Tree, id: []const u8, click: ui.Target, options: OptionField) void {
    const element = tree.toElementId(id);
    if (!tree.beginRect(element, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .hug, .h = .fill }, .gap = 4, .cursor = options.cursor })) return;
    defer tree.endRect();
    if (options.enabled) {
        tree.onClick(click, .left);
        tree.trackHover(options.hint);
    }
    const label_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 1 };
    const frame_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 2 };
    const value_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 3 };
    tree.text(label_id, options.label, .{ .font = style.ui_font, .color = style.col.text_dim });
    if (tree.beginRect(frame_id, style.fieldFrame(.idle, .{ .w = .{ .fixed = option_field_width }, .h = .fill }))) {
        defer tree.endRect();
        const value_color = if (options.enabled) style.col.text else style.col.text_disabled;
        tree.text(value_id, options.value, .{ .font = style.ui_font, .color = value_color });
    }
}

pub fn actionField(tree: *ui.Tree, action: anytype, options: OptionField) void {
    const id = @tagName(action);
    const action_atom = Atom.from(action);
    const click = workspace.to(tree, action_atom, {});
    optionField(tree, id, click, options);
}

fn renderPoseOptions(tree: *ui.Tree, tables: *Table.Registry) void {
    const atoms = tree.atoms;
    const settings = pose.config(tables);
    const automatic = settings.auto_ik.* != 0;
    optionButton(tree, pose.Msg.figure_pose_auto_ik, .{ .label = if (automatic) "Auto IK" else "FK", .hint = "Toggle automatic IK / FK joint dragging", .selected = automatic });
    const chain_text = std.fmt.allocPrint(tree.frame_allocator.allocator, "Auto chain: {d}", .{settings.auto_chain_length.*}) catch "Auto chain";
    tree.text("figure.options.pose.chain", chain_text, .{ .font = style.ui_font, .color = style.col.text_dim });
    optionButton(tree, pose.Msg.figure_pose_chain_less, .{ .label = "-", .hint = "Shorten automatic IK preference; minimum 1 bone", .enabled = settings.auto_chain_length.* > 1, .width = option_stepper_width });
    optionButton(tree, pose.Msg.figure_pose_chain_more, .{ .label = "+", .hint = "Lengthen automatic IK preference; the rig's root still ends the chain", .enabled = settings.auto_chain_length.* < std.math.maxInt(u32), .width = option_stepper_width });
    const controller = pose.activeController(tables, atoms) catch null;
    optionButton(tree, pose.Msg.figure_ik_pin, .{ .label = "Pin", .hint = "Pin the selected endpoint's authored IK controller", .enabled = controller != null });
    optionButton(tree, pose.Msg.figure_ik_unpin, .{ .label = "Unpin", .hint = "Unpin the authored controller and bake FK", .enabled = controller != null });
    if (controller) |selected| {
        const controller_name = atoms.lookup(selected.name) orelse "?";
        const controller_label = std.fmt.allocPrint(tree.frame_allocator.allocator, "Controller: {s}, chain {d}", .{ controller_name, selected.chain }) catch "Controller";
        tree.text("figure.options.pose.controller", controller_label, .{ .font = style.ui_font, .color = style.col.text_dim });
    }
}

fn renderAnimateOptions(tree: *ui.Tree, tables: *Table.Registry) void {
    const atoms = tree.atoms;
    const allocator = tree.frame_allocator.allocator;
    const settings = filmstrip.config(tables);
    const clip = filmstrip.clipRow(tables, atoms);
    const clip_name = if (clip) |current| atoms.lookup(current.name) orelse "?" else "Choose...";
    const frame_value = std.fmt.allocPrint(allocator, "{d}", .{settings.frame.*}) catch "?";
    const fps_value = if (clip) |current| std.fmt.allocPrint(allocator, "{d}", .{current.fps}) catch "?" else "--";
    actionField(tree, filmstrip.Msg.figure_clip_select, .{ .label = "Clip", .value = clip_name, .hint = "Choose a clip by name" });
    actionField(tree, filmstrip.Msg.figure_frame_seek, .{ .label = "Frame", .value = frame_value, .hint = "Seek to a frame; looping clips wrap, others clamp", .enabled = clip != null });
    actionField(tree, filmstrip.Msg.figure_clip_fps, .{ .label = "FPS", .value = fps_value, .hint = "Set clip frames per second; pause playback to edit", .enabled = clip != null and settings.playing.* == 0 });
}

fn renderPointOptions(tree: *ui.Tree, tables: *Table.Registry) void {
    const atoms = tree.atoms;
    const maybe_options = drawing.pointOptions(tables, atoms) catch return;
    const options = maybe_options orelse return;
    const allocator = tree.frame_allocator.allocator;
    const selected = options.selected_count != 0;
    const smooth = selected and options.smooth_count == options.selected_count;
    const corner = selected and options.corner_count == options.selected_count;
    const mixed = selected and !smooth and options.smooth_count != 0;
    optionButton(tree, drawing.Msg.figure_point_corner, .{ .label = "Corner", .hint = "Remove handles from selected anchors", .enabled = selected, .selected = corner });
    optionButton(tree, drawing.Msg.figure_point_make_smooth, .{ .label = "Smooth", .hint = "Create symmetric handles on selected anchors", .enabled = selected, .selected = smooth });
    optionButton(tree, drawing.Msg.figure_point_mirror, .{ .label = if (mixed) "Mirror: mixed" else "Mirror", .hint = "Toggle symmetric handles; turning off keeps their positions", .enabled = selected, .selected = smooth });
    optionButton(tree, drawing.Msg.figure_path_closed, .{ .label = if (options.shape.closed != 0) "Open path" else "Close path", .hint = "Toggle the closing segment without moving anchors" });
    // The one selected anchor's position, a vector as every panel shows one.
    tree.text("figure.options.point.label", "Anchor", .{ .font = style.ui_font, .color = style.col.text_dim });
    if (tree.beginRect("figure.options.point.position", .{ .size = .{ .w = .{ .fixed = point_position_width }, .h = .fill } })) {
        defer tree.endRect();
        if (vector_field.begin(tree, "figure.options.point.vector")) {
            defer tree.endRect();
            const vector_style = style.vectorFieldStyle();
            const axes = [_]struct { action: drawing.Msg, hint: []const u8 }{
                .{ .action = .figure_point_x, .hint = "Set one selected anchor's X in bind-space pixels" },
                .{ .action = .figure_point_y, .hint = "Set one selected anchor's Y in bind-space pixels" },
            };
            for (axes, 0..) |axis, component_index| {
                const text = shown: {
                    const anchor = options.anchor orelse break :shown "-";
                    const number = if (component_index == 0) anchor.p.x else anchor.p.y;
                    break :shown vector_field.formatNumber(allocator, number, vector_field.shown_decimals) catch "?";
                };
                const click: ?ui.Target = if (options.anchor != null) workspace.to(tree, Atom.from(axis.action), {}) else null;
                vector_field.component(tree, @tagName(axis.action), .{
                    .index = component_index,
                    .text = text,
                    .click = click,
                    .tooltip = axis.hint,
                    .text_color = if (options.anchor != null) style.col.text else style.col.text_disabled,
                }, vector_style);
            }
        }
    }
    optionButton(tree, drawing.Msg.figure_edit_points_done, .{ .label = "Done", .hint = "Leave Edit points and select the path (Enter / Esc)" });
}

fn renderJointFillOptions(tree: *ui.Tree, tables: *Table.Registry) void {
    const atoms = tree.atoms;
    const allocator = tree.frame_allocator.allocator;
    const fields = prompts.inspectorFields(prompts.defaults_kind);
    for (fields, 0..) |field, index| {
        if (!std.mem.eql(u8, field.name, "fill_color")) continue;
        const value = prompts.propertyValue(allocator, tables, atoms, prompts.defaults_kind, 0, field) catch break;
        const settings = drawing.config(tables);
        const action = Atom.from(workspace.Msg.figure_inspector_field);
        const item = session.ItemEvent{ .kind = prompts.defaults_kind, .id = 0, .field = @intCast(index) };
        const click = workspace.to(tree, action, item);
        optionField(tree, "figure.joint_fill.color", click, .{
            .label = if (settings.fill_enabled.* == 0) "Fill off" else "Fill",
            .value = value.text,
            .hint = "Fill color for new artwork; keeps the picked joints",
        });
        break;
    }
    const count = drawing.draftCount(session.get(tables), session.drafts(tables));
    const count_text = std.fmt.allocPrint(allocator, "Joints: {d}", .{count}) catch "Joints";
    tree.text("figure.joint_fill.count", count_text, .{ .font = style.ui_font, .color = style.col.text_dim });
    optionButton(tree, workspace.Msg.figure_chain_finish, .{ .label = "Close (Enter)", .hint = "Close the fill after picking at least three distinct joints", .enabled = count >= 3 });
}

fn renderRigOptions(tree: *ui.Tree, options: session.RigOptionsView, stick_tool: bool) void {
    optionButton(tree, workspace.Msg.figure_rig_connected, .{ .label = "Connected", .hint = "Connect new bones at the previous tip; off allows a gap while retaining the parent", .selected = options.connected.* != 0 });
    if (stick_tool) optionButton(tree, workspace.Msg.figure_stick_head, .{ .label = "Head", .hint = "Create a filled head disc between the Stick endpoints", .selected = options.head.* != 0 });
    tree.text("figure.options.snap", "Snap", .{ .font = style.ui_font, .color = style.col.text_dim });
    optionButton(tree, workspace.Msg.figure_snap_joints, .{ .label = "Joints", .hint = "Snap endpoints to visible bone joints; Alt bypasses snapping", .selected = options.snap_joints.* != 0 });
    optionButton(tree, workspace.Msg.figure_snap_midpoints, .{ .label = "Midpoints", .hint = "Snap endpoints to visible bone midpoints", .selected = options.snap_midpoints.* != 0 });
    optionButton(tree, workspace.Msg.figure_snap_axes, .{ .label = "Axes", .hint = "Snap near horizontal, vertical and 45-degree directions", .selected = options.snap_axes.* != 0 });
    optionButton(tree, workspace.Msg.figure_snap_lengths, .{ .label = "Lengths", .hint = "Match visible bone lengths", .selected = options.snap_lengths.* != 0 });
    optionButton(tree, workspace.Msg.figure_snap_grid, .{ .label = "Grid", .hint = "Snap endpoints to the grid, including when the grid is hidden", .selected = options.snap_grid.* != 0 });
}

fn renderWeightOptions(tree: *ui.Tree, tables: *Table.Registry) void {
    const atoms = tree.atoms;
    const settings = weight.config(tables);
    const brush_modes = [_]struct { action: weight.Msg, label: []const u8, value: []const u8 }{
        .{ .action = weight.Msg.figure_weight_mode_add, .label = "Add", .value = "add" },
        .{ .action = weight.Msg.figure_weight_mode_subtract, .label = "Subtract", .value = "subtract" },
        .{ .action = weight.Msg.figure_weight_mode_replace, .label = "Replace", .value = "replace" },
        .{ .action = weight.Msg.figure_weight_mode_smooth, .label = "Smooth", .value = "smooth" },
    };
    for (brush_modes) |mode| {
        const value_atom = Atom.from(mode.value);
        optionButton(tree, mode.action, .{ .label = mode.label, .hint = "Brush mode", .selected = settings.brush_mode.* == value_atom });
    }
    const replacing = settings.brush_mode.* == names.replace;
    for (weight.brush_options) |option| {
        if (option == .mode or (option == .value and !replacing)) continue;
        const detail = option.details();
        const value = option.valueText(tree.frame_allocator.allocator, tables, atoms) catch "?";
        actionField(tree, detail.action, .{ .label = detail.label, .value = if (value.len == 0) "Choose..." else value, .hint = detail.hint });
    }
}

fn renderOptions(tree: *ui.Tree, tables: *Table.Registry, height: f32) void {
    if (!tree.beginRect("figure.options", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = height } }, .padding = 4, .gap = 6, .bg = style.col.sidebar, .clip_content = true })) return;
    defer tree.endRect();
    const editor = session.get(tables);
    if (editor.mode.* == names.animate) {
        renderAnimateOptions(tree, tables);
        tree.rect("figure.options.animate.divider", .{ .size = .{ .w = .{ .fixed = 1 }, .h = .{ .fixed = 18 } }, .bg = style.col.region_border });
        renderPoseOptions(tree, tables);
        return;
    }
    if (editor.tool.* == names.weight) {
        renderWeightOptions(tree, tables);
        return;
    }
    if (!session.atRest(editor)) return;
    if (editor.tool.* == names.edit_points) {
        renderPointOptions(tree, tables);
    } else if (editor.tool.* == names.joint_fill) {
        renderJointFillOptions(tree, tables);
    } else if (editor.tool.* == names.bone) {
        renderRigOptions(tree, session.rigOptions(tables), false);
    } else if (editor.tool.* == names.stick) {
        renderRigOptions(tree, session.rigOptions(tables), true);
    } else {
        const settings = drawing.config(tables);
        for (drawing.toolOptions(editor.tool.*)) |option| {
            const detail = option.details();
            const value_text = std.fmt.allocPrint(tree.frame_allocator.allocator, "{d}", .{option.value(settings)}) catch continue;
            const item = session.ItemEvent{ .kind = prompts.tool_option_kind, .id = 0, .field = @intFromEnum(option) };
            const click = workspace.to(tree, .from(workspace.Msg.figure_tool_option), item);
            optionField(tree, @tagName(detail.action), click, .{ .label = detail.label, .value = value_text, .hint = "Drag to change: Shift x10, Ctrl x0.1. Click to type.", .cursor = .resize_ew });
        }
    }
}

/// The region that owns canvas hover and shows the cursor the last hover pick chose.
fn renderCanvasSpace(tree: *ui.Tree, feedback: session.FeedbackView, height: f32) void {
    const canvas_cursor: os.CursorKind = @enumFromInt(feedback.cursor_kind.*);
    if (tree.beginRect("figure.canvas.space", .{ .size = .{ .w = .fill, .h = .{ .fixed = height } }, .cursor = canvas_cursor })) {
        tree.trackHover("");
        tree.onClick(workspace.to(tree, .from(workspace.Msg.figure_pointer_down), {}), .all);
        tree.onScroll(workspace.to(tree, .from(workspace.Msg.figure_scroll), workspace.ScrollSurface.canvas));
        tree.endRect();
    }
}

/// One-pixel lines between the regions of the window. Drawn over them, so each region can fill
/// its whole rectangle without knowing what it borders.
pub fn renderRegionBorders(layout: geometry.StageLayout, ctx: *roop.Context) void {
    const lines = [_]panels_mod.Rect{
        .{ .x = layout.header.x, .y = layout.header.y + layout.header.h - 1, .w = layout.header.w, .h = 1 },
        .{ .x = layout.options.x, .y = layout.options.y + layout.options.h - 1, .w = layout.options.w, .h = 1 },
        .{ .x = layout.status.x, .y = layout.status.y, .w = layout.status.w, .h = 1 },
    };
    for (lines) |line| {
        if (line.w <= 0 or line.h <= 0) continue;
        ctx.beginPath();
        ctx.rect(line.x, line.y, line.w, line.h);
        ctx.fillColor(style.col.region_border);
        ctx.fill();
    }
}

pub fn render(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: *roop.Context, result: canvas.RenderResult) void {
    if (viewport.width <= 0 or viewport.height <= 0) return;
    const local_stage = panels_mod.Rect{ .w = viewport.width, .h = viewport.height };
    const stage_chrome = workspace.stageChrome(session.observed(tables));
    const layout = geometry.stageLayout(local_stage, stage_chrome);
    noteRendering(session.feedback(tables), result);
    const scratch = mem.frameScratchAllocator() catch return;
    var tree = ui.Tree.init(scratch, atoms, 128) catch return;
    // One lookup of the keys for every button's tooltip.
    var shortcuts = editor_mod.Shortcuts.of(scratch.allocator, tables);
    const hovered = editor_state.hoveredElementId(tables);
    const hits = editor_state.hitRegions(tables, atoms);
    const hit_depth = editor_mod.kHitDepth;
    if (stage_chrome.focus == .off) {
        if (tree.beginRect("figure.chrome", .{ .size = .{ .w = .fill, .h = .fill }, .clip_content = true })) {
            defer tree.endRect();
            renderHeader(&tree, tables, &shortcuts, layout.header);
            renderOptions(&tree, tables, layout.options.h);
            renderCanvasSpace(&tree, session.feedback(tables), layout.canvas.h);
        }
        const center_h = layout.header.h + layout.options.h + layout.canvas.h;
        tree.commit(.{ .root_size = .{ .x = layout.header.w, .y = center_h }, .origin = .{ .x = layout.header.x, .y = layout.header.y }, .offset = .{ .x = viewport.x, .y = viewport.y }, .hovered = hovered, .depth = hit_depth }, ctx, hits, editor_sequencer.redrawInbox());
        renderModeGlide(session.motion(tables), session.get(tables), layout.header, ctx);
        const hint = statusHint(scratch.allocator, tables, atoms);
        status_bar.render(scratch, tables, atoms, layout.status, hint, motion.statusLook(session.motion(tables)), ctx, hits, hit_depth);
        renderRegionBorders(layout, ctx);
    } else {
        renderCanvasSpace(&tree, session.feedback(tables), layout.canvas.h);
        tree.commit(.{ .root_size = .{ .x = layout.canvas.w, .y = layout.canvas.h }, .origin = .{ .x = layout.canvas.x, .y = layout.canvas.y }, .offset = .{ .x = viewport.x, .y = viewport.y }, .hovered = hovered, .depth = hit_depth }, ctx, hits, editor_sequencer.redrawInbox());
    }
    const editor = session.get(tables);
    const dock = dockRect(editor.mode.*, layout.canvas);
    if (dock.w <= 0) return;
    var dock_tree = ui.Tree.init(scratch, atoms, 128) catch return;
    renderDock(&dock_tree, tables, &shortcuts, dock);
    dock_tree.commit(.{ .root_size = .{ .x = dock.w, .y = dock.h }, .origin = .{ .x = dock.x, .y = dock.y }, .offset = .{ .x = viewport.x, .y = viewport.y }, .hovered = hovered, .depth = hit_depth + 1 }, ctx, hits, editor_sequencer.redrawInbox());
    renderToolGlide(session.get(tables), session.motion(tables), session.observed(tables), dock, ctx);
}

test "drawing header zoom text remains frame owned after helper and rail construction" {
    var mem: memory.Memory = undefined;
    mem.init(std.testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 96);
    defer tables.deinit();
    var transport: transport_fixture.Transport = undefined;
    try transport.init(&mem, &atoms, &tables);
    defer transport.deinit();
    const editor = session.get(&tables);
    editor.view_zoom.* = 1.25;

    const capacity = 384;
    const storage = try std.testing.allocator.alloc(u8, @sizeOf(ui.Element) * capacity + 128 * 1024);
    defer std.testing.allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const scratch = memory.Scratch{ .allocator = fixed.allocator() };
    var tree = try ui.Tree.init(scratch, &atoms, capacity);
    const layout = geometry.stageLayout(.{ .w = 1500, .h = 1050 }, .{});
    var shortcuts = editor_mod.Shortcuts.of(scratch.allocator, &tables);
    renderHeader(&tree, &tables, &shortcuts, layout.header);
    renderDock(&tree, &tables, &shortcuts, dockRect(editor.mode.*, layout.canvas));
    const more_frame_storage = try scratch.allocator.alloc(u8, 4096);
    @memset(more_frame_storage, 0xa5);
    const zoom_id = names.@"figure.header.zoom";
    const first_address = @intFromPtr(storage.ptr);
    const last_address = first_address + storage.len;
    var found = false;
    for (tree.elements[0..tree.count]) |element| switch (element) {
        .text => |text| {
            if (text.params.id.atom != zoom_id) continue;
            const address = @intFromPtr(text.str.ptr);
            try std.testing.expect(address >= first_address and address + text.str.len <= last_address);
            try std.testing.expectEqualStrings("125%", text.str);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}
