const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;
const panels_mod = mesha.panels;
const plugin = mesha.plugin;
const roop = mesha.roop;
const controls = @import("../ui/style.zig").canvas_controls;
const style = @import("../ui/style.zig");
const figure = mesha.figure;
const geometry = @import("geometry.zig");
const session = @import("session.zig");
const weight = @import("weight.zig");
const drawing = @import("drawing.zig");
const preview = @import("preview.zig");
const selection = @import("selection.zig");
const pose = @import("pose.zig");
const gesture = @import("gesture.zig");
const filmstrip = @import("filmstrip.zig");

const Log = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { read_definition, render_evaluated, bones, selection_outline, drawing_overlay };

pub fn overlayCapacity(budget: anytype) bool {
    inline for (std.meta.fields(@TypeOf(preview.ui_reserve))) |field| {
        const reserve = @field(preview.ui_reserve, field.name);
        if (@field(budget, field.name) <= reserve + 128) return false;
    }
    return true;
}

pub const RenderResult = struct {
    overlay_limited: bool = false,
    main_error: ?anyerror = null,
    fallback_error: ?anyerror = null,
    onion_error: ?anyerror = null,
    weight_error: ?anyerror = null,
    weight_brush_reach: ?u32 = null,
};

fn renderHoverContour(tables: *Table.Registry, atoms: *Atom.Registry, render_context: *roop.Context, shape: session.api.read.Shape, zoom: f32) bool {
    const contour = preview.geometry(tables, atoms, shape.id) catch return false;
    const points = contour.points;
    if (points.len < 2) return false;
    const budget = render_context.pathBudget();
    if (!overlayCapacity(budget)) return true;
    // Round joins and two round caps bound both open and closed contours.
    // Keep ordinary chrome capacity available even for densely sampled curves.
    const vertex_bound = (points.len + 2) * (budget.stroke_divisions + 3) * 6;
    if (budget.paths == 0 or budget.points < points.len or
        budget.commands < points.len + 2 or budget.gpu_points - preview.ui_reserve.gpu_points < points.len or
        budget.gpu_vertices - preview.ui_reserve.gpu_vertices < vertex_bound) return true;
    const closed = shape.closed != 0 or shape.kind == names.joint_fill or
        shape.stroke_kind == names.circle or shape.stroke_kind == names.circle_fill;
    render_context.beginPath();
    render_context.moveTo(points[0].x, points[0].y);
    for (points[1..]) |point| render_context.lineTo(point.x, point.y);
    if (closed) render_context.closePath();
    render_context.strokeColor(controls.selection);
    render_context.strokeWidth(controls.line_width / zoom);
    render_context.stroke();
    return false;
}

fn renderSelectionFrame(editor: session.View, drag: gesture.View, draw_settings: drawing.ConfigView, observed: session.ObservedView, render_context: *roop.Context, box: geometry.Bounds, zoom: f32) bool {
    const initial_budget = render_context.pathBudget();
    if (!overlayCapacity(initial_budget)) return true;
    const frame = drawing.selectionFrame(editor, drag, draw_settings, box);
    const source_box = if (frame) |value| value.bounds else box;
    const matrix = if (frame) |value| value.matrix else math.Affine2f.identity;
    var points: [geometry.scale_handles.len]session.Vec2 = undefined;
    for (geometry.scale_handles, &points) |handle, *point| {
        const location = geometry.scaleHandlePoint(source_box, handle);
        point.* = matrix.apply(location);
    }
    const frame_bounds = geometry.bounds(&points) orelse return false;
    const accent = controls.selection;
    const handle_fill = controls.paper;
    render_context.beginPath();
    render_context.moveTo(points[0].x, points[0].y);
    for (points[1..]) |point| render_context.lineTo(point.x, point.y);
    render_context.closePath();
    render_context.strokeColor(accent);
    render_context.strokeWidth(controls.line_width / zoom);
    render_context.stroke();
    const size = 7 / zoom;
    for (geometry.scale_handles, points) |handle, point| {
        if (!geometry.scaleHandleEnabled(source_box, handle)) continue;
        const handle_budget = render_context.pathBudget();
        if (!overlayCapacity(handle_budget)) return true;
        render_context.beginPath();
        render_context.rect(point.x - size * 0.5, point.y - size * 0.5, size, size);
        render_context.fillColor(handle_fill);
        render_context.fill();
        render_context.strokeColor(accent);
        render_context.strokeWidth(controls.line_width / zoom);
        render_context.stroke();
    }
    const pivot_budget = render_context.pathBudget();
    if (!overlayCapacity(pivot_budget)) return true;
    const source_pivot = drawing.selectionPivot(draw_settings, observed, box);
    const pivot = if (editor.gesture_kind.* == names.duplicate_shapes) matrix.apply(source_pivot) else source_pivot;
    render_context.beginPath();
    render_context.circle(pivot.x, pivot.y, 4 / zoom);
    render_context.fillColor(handle_fill);
    render_context.fill();
    render_context.strokeColor(accent);
    render_context.strokeWidth(controls.line_width / zoom);
    render_context.stroke();
    render_context.beginPath();
    render_context.moveTo(pivot.x - 7 / zoom, pivot.y);
    render_context.lineTo(pivot.x + 7 / zoom, pivot.y);
    render_context.moveTo(pivot.x, pivot.y - 7 / zoom);
    render_context.lineTo(pivot.x, pivot.y + 7 / zoom);
    render_context.stroke();
    if (editor.gesture_active.* == 0 and editor.hover_kind.* == names.rotate_handle) {
        const rotation_budget = render_context.pathBudget();
        if (!overlayCapacity(rotation_budget)) return true;
        const corner: geometry.ScaleHandle = @enumFromInt(editor.hover_sub.*);
        const location = geometry.rotationHandlePoint(box, corner, zoom);
        render_context.beginPath();
        render_context.moveTo(location.x + 4 / zoom, location.y - 3 / zoom);
        render_context.bezierTo(location.x - 5 / zoom, location.y - 8 / zoom, location.x - 8 / zoom, location.y + 5 / zoom, location.x + 2 / zoom, location.y + 5 / zoom);
        render_context.moveTo(location.x, location.y - 4 / zoom);
        render_context.lineTo(location.x + 4 / zoom, location.y - 3 / zoom);
        render_context.lineTo(location.x + 3 / zoom, location.y + 1 / zoom);
        render_context.strokeWidth(1.5 / zoom);
        render_context.stroke();
    }
    var text_buffer: [96]u8 = undefined;
    const label = if (frame != null and editor.gesture_kind.* == names.select_rotate) angle: {
        const degrees = frame.?.rotation * 180 / std.math.pi;
        break :angle std.fmt.bufPrint(&text_buffer, "{d:.1} deg", .{degrees}) catch "Rotate";
    } else if ((editor.gesture_kind.* == names.move_shapes or editor.gesture_kind.* == names.duplicate_shapes) and (editor.gesture_active.* != 0 or gesture.busy(drag))) move: {
        const constraint: geometry.MoveConstraint = if (drag.modifiers.* & gesture.Modifiers.shift != 0) .axis else .none;
        const delta = geometry.moveDelta(drag.origin.*, drag.latest.*, constraint);
        break :move std.fmt.bufPrint(&text_buffer, "dx {d:.1}  dy {d:.1}", .{ delta.x, delta.y }) catch "Move";
    } else size_label: {
        const width = geometry.distance(points[0], points[2]);
        const height = geometry.distance(points[2], points[4]);
        break :size_label std.fmt.bufPrint(&text_buffer, "{d:.1} x {d:.1}", .{ width, height }) catch "Resize";
    };
    const center = frame_bounds.center();
    return renderBadge(render_context, .{ .x = center.x, .y = frame_bounds.max.y }, label);
}

pub fn renderBadge(render_context: *roop.Context, position: session.Vec2, label: []const u8) bool {
    const badge_budget = render_context.pathBudget();
    // Text emits six CPU vertices per glyph; retain the ordinary UI reserve too.
    const required_vertices = preview.ui_reserve.cpu_vertices + label.len * 6;
    if (!overlayCapacity(badge_budget) or badge_budget.cpu_vertices < required_vertices) return true;
    const text_size = render_context.measureText(style.ui_font, label);
    const width = text_size.w + 12;
    const current_transform = render_context.currentTransform();
    const world_to_screen = roop.transform.toAffine(current_transform);
    const anchor = world_to_screen.apply(position);
    const ascender = render_context.fontAscender(style.ui_font);
    const baseline = (21 - text_size.h) * 0.5 + ascender;
    render_context.save();
    defer render_context.restore();
    // Roop's incremental transforms premultiply. Place this pixel-sized badge
    // explicitly in screen space so zoom does not also scale its translation.
    render_context.setTransform(.{ 1, 0, 0, 1, anchor.x - width * 0.5, anchor.y + 12 });
    render_context.beginPath();
    render_context.roundedRect(0, 0, width, 21, 3);
    render_context.fillColor(controls.selection);
    render_context.fill();
    render_context.fontFace(style.ui_font);
    render_context.textAlign(.{ .left = true });
    render_context.fillColor(controls.paper);
    _ = render_context.text(6, baseline, label);
    return false;
}

/// The derived bounds, with a frame label the way Figma names a frame above its corner.
fn renderBoundsFrame(editor: session.View, atoms: *Atom.Registry, render_context: *roop.Context, extent: session.api.Bounds, zoom: f32) bool {
    if (!overlayCapacity(render_context.pathBudget())) return true;
    const size = math.Vec2f.sub(extent.max, extent.min);
    render_context.beginPath();
    render_context.rect(extent.min.x, extent.min.y, size.x, size.y);
    render_context.strokeColor(controls.frame);
    render_context.strokeWidth(controls.line_width / zoom);
    render_context.stroke();
    var text_buffer: [160]u8 = undefined;
    const document_name = atoms.lookup(editor.doc.*) orelse "figure";
    const label = std.fmt.bufPrint(&text_buffer, "{s}  {d:.0} x {d:.0}", .{ document_name, size.x, size.y }) catch document_name;
    const budget = render_context.pathBudget();
    if (budget.cpu_vertices < preview.ui_reserve.cpu_vertices + label.len * 6) return true;
    const world_to_screen = roop.transform.toAffine(render_context.currentTransform());
    const corner = world_to_screen.apply(extent.min);
    render_context.save();
    defer render_context.restore();
    render_context.setTransform(.{ 1, 0, 0, 1, corner.x, corner.y - 6 });
    render_context.fontFace(style.ui_font);
    render_context.textAlign(.{ .left = true });
    render_context.fillColor(controls.muted);
    _ = render_context.text(0, 0, label);
    return false;
}

pub fn render(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, render_context: *roop.Context) RenderResult {
    var result = RenderResult{};
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    const editor = session.get(tables);
    const stage_rect = panels_mod.Rect{ .w = viewport.width, .h = viewport.height };
    const layout = geometry.stageLayout(stage_rect, @import("workspace.zig").stageChrome(session.observed(tables)));
    const rect = layout.canvas;
    // Stage background and document viewport.
    const maybe_definition = blk: {
        const zone = Log.zone(Zone.read_definition);
        defer zone.end();
        break :blk reads.definition(editor.doc.*) catch null;
    };
    render_context.fontFace(style.ui_font);
    render_context.beginPath();
    render_context.rect(0, 0, viewport.width, viewport.height);
    render_context.fillColor(roop.rgba(110, 114, 122, 255));
    render_context.fill();
    if (maybe_definition) |definition| {
        const zoom = editor.view_zoom.*;
        if (rect.w > 0 and rect.h > 0 and std.math.isFinite(zoom) and zoom > 0 and std.math.isFinite(editor.view_center.x * zoom) and std.math.isFinite(editor.view_center.y * zoom)) {
            render_context.save();
            render_context.intersectScissor(rect.x, rect.y, rect.w, rect.h, 0);
            render_context.beginPath();
            render_context.rect(rect.x, rect.y, rect.w, rect.h);
            render_context.fillColor(controls.paper);
            render_context.fill();
            // Context helpers pre-multiply; install the explicit camera matrix so
            // the rendered pixels agree with hit testing at every zoom/pan.
            const context_affine = roop.transform.toAffine(render_context.currentTransform());
            const matrix = geometry.drawTransform(context_affine, rect, editor.view_center.*, zoom);
            render_context.setTransform(roop.transform.fromAffine(matrix));
            if (editor.flags.* & 1 != 0) {
                const step = geometry.gridStep(zoom);
                const left = geometry.toDocument(rect, editor.view_center.*, zoom, .{ .x = rect.x, .y = rect.y });
                const right = geometry.toDocument(rect, editor.view_center.*, zoom, .{ .x = rect.x + rect.w, .y = rect.y + rect.h });
                const nx: usize = @intFromFloat(@min(512, @ceil(rect.w / (step * zoom)) + 2));
                const ny: usize = @intFromFloat(@min(512, @ceil(rect.h / (step * zoom)) + 2));
                render_context.beginPath();
                for (0..nx) |i| {
                    const x = (@floor(left.x / step) + @as(f32, @floatFromInt(i))) * step;
                    render_context.moveTo(x, left.y);
                    render_context.lineTo(x, right.y);
                }
                for (0..ny) |i| {
                    const y = (@floor(left.y / step) + @as(f32, @floatFromInt(i))) * step;
                    render_context.moveTo(left.x, y);
                    render_context.lineTo(right.x, y);
                }
                render_context.strokeColor(roop.rgba(175, 179, 189, 24));
                render_context.strokeWidth(controls.line_width / zoom);
                render_context.stroke();
            }
            if (session.figureExtent(session.observed(tables), session.get(tables))) |extent| {
                const limited = renderBoundsFrame(session.get(tables), atoms, render_context, extent, zoom);
                result.overlay_limited = result.overlay_limited or limited;
            }
            render_context.beginPath();
            render_context.moveTo(-10 / zoom, 0);
            render_context.lineTo(10 / zoom, 0);
            render_context.moveTo(0, -10 / zoom);
            render_context.lineTo(0, 10 / zoom);
            render_context.strokeColor(controls.muted);
            render_context.strokeWidth(controls.line_width / zoom);
            render_context.stroke();
            // Render the main evaluation once, then onion skins and authoring overlays.
            const scratch = mem.frameScratchAllocator() catch |err| {
                result.main_error = err;
                render_context.restore();
                return result;
            };
            const frame_allocator = scratch.allocator;
            preview.ready(tables, atoms) catch |err| switch (err) {
                error.NotReady, error.Busy => {
                    render_context.restore();
                    return result;
                },
            };
            const rendered = blk: {
                const zone = Log.zone(Zone.render_evaluated);
                defer zone.end();
                break :blk preview.renderEvaluated(tables, atoms, render_context) catch |err| {
                    result.main_error = err;
                    render_context.restore();
                    return result;
                };
            };
            result.main_error = rendered.render_error;
            result.fallback_error = rendered.fallback_error;
            // The host's, until it next publishes a change, which is after this drawing.
            const evaluation = rendered.evaluation orelse {
                render_context.restore();
                return result;
            };
            filmstrip.renderOnionSkins(tables, render_context) catch |err| {
                result.onion_error = err;
            };
            const world = evaluation.bones;
            const pose_settings = pose.config(tables);
            const drag_busy = gesture.busy(gesture.get(tables));
            const can_hover_bones = editor.mode.* == names.rig or filmstrip.enabled(editor);
            const hovering = editor.gesture_active.* == 0 and !drag_busy and can_hover_bones and editor.hover_kind.* == names.bone;
            const wants_hover_chain = hovering and filmstrip.enabled(editor) and editor.hover_sub.* == 1 and pose_settings.auto_ik.* != 0;
            const automatic = editor.gesture_kind.* == names.pose_auto_ik and (editor.gesture_active.* != 0 or drag_busy);
            // Highlighting only: without frame space the bones draw plain, not fail.
            var chain: []const u32 = &.{};
            if (automatic) {
                if (pose.dragChain(pose.dragChainLinks(tables), frame_allocator)) |drag_chain| {
                    chain = drag_chain.bones;
                } else |_| {}
            } else if (wants_hover_chain) {
                const capacity = pose.automaticChainCapacity(definition, pose_settings.auto_chain_length.*);
                if (frame_allocator.alloc(u32, capacity)) |hover_chain| {
                    const hover_count = pose.automaticHoverChain(definition, editor.hover_id.*, pose_settings.auto_chain_length.*, hover_chain);
                    chain = hover_chain[0..hover_count];
                } else |_| {}
            }

            {
                const zone = Log.zone(Zone.bones);
                defer zone.end();
                // Bone handles, hover chains and constraint feedback.
                if (session.bonesShown(editor)) for (world) |bone| {
                    const remaining = render_context.pathBudget();
                    if (!overlayCapacity(remaining)) {
                        result.overlay_limited = true;
                        break;
                    }
                    const screen_origin = geometry.toScreen(rect, editor.view_center.*, zoom, bone.origin);
                    const screen_tip = geometry.toScreen(rect, editor.view_center.*, zoom, bone.tip);
                    if (!std.math.isFinite(screen_origin.x) or !std.math.isFinite(screen_origin.y) or !std.math.isFinite(screen_tip.x) or !std.math.isFinite(screen_tip.y)) continue;
                    if (@max(screen_origin.x, screen_tip.x) < rect.x - 8 or
                        @min(screen_origin.x, screen_tip.x) > rect.x + rect.w + 8 or
                        @max(screen_origin.y, screen_tip.y) < rect.y - 8 or
                        @min(screen_origin.y, screen_tip.y) > rect.y + rect.h + 8) continue;
                    const selected = selection.contains(session.get(tables), session.selections(tables), names.bone, bone.id) or (editor.tool.* == names.weight and weight.config(tables).bone.* == bone.id);
                    const hovered = hovering and editor.hover_id.* == bone.id;
                    const in_chain = std.mem.indexOfScalar(u32, chain, bone.id) != null;
                    if (hovered or in_chain) {
                        render_context.beginPath();
                        if (in_chain or editor.hover_sub.* == 2) {
                            render_context.moveTo(bone.origin.x, bone.origin.y);
                            render_context.lineTo(bone.tip.x, bone.tip.y);
                        }
                        const handle = if (hovered and editor.hover_sub.* == 0) bone.origin else bone.tip;
                        render_context.circle(handle.x, handle.y, 8 / zoom);
                        if (chain.len != 0 and chain[0] == bone.id) render_context.circle(bone.origin.x, bone.origin.y, 9 / zoom);
                        render_context.strokeColor(controls.target);
                        render_context.strokeWidth(2 / zoom);
                        render_context.stroke();
                    }
                    const delta = math.Vec2f.sub(bone.tip, bone.origin);
                    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
                    const normal = if (length > 0) math.Vec2f{ .x = -delta.y / length * 3 / zoom, .y = delta.x / length * 3 / zoom } else session.zero;
                    render_context.beginPath();
                    render_context.moveTo(bone.tip.x, bone.tip.y);
                    render_context.lineTo(bone.origin.x + normal.x, bone.origin.y + normal.y);
                    render_context.lineTo(bone.origin.x - normal.x, bone.origin.y - normal.y);
                    render_context.closePath();
                    render_context.fillColor(if (selected) controls.selected_bone_wash else controls.bone_wash);
                    render_context.fill();
                    render_context.strokeColor(if (selected) controls.caution else controls.ink);
                    render_context.strokeWidth(controls.line_width / zoom);
                    render_context.stroke();
                    render_context.beginPath();
                    render_context.circle(bone.tip.x, bone.tip.y, 4 / zoom);
                    render_context.fillColor(if (selected) controls.caution else controls.joint);
                    render_context.fill();
                    const has_controller = for (definition.ik) |controller| {
                        if (controller.end_bone == bone.id) break true;
                    } else false;
                    if (has_controller) {
                        render_context.beginPath();
                        render_context.circle(bone.tip.x, bone.tip.y, 7 / zoom);
                        render_context.strokeColor(controls.selection);
                        render_context.strokeWidth(2 / zoom);
                        render_context.stroke();
                    }
                    if (bone.parent == 0) {
                        render_context.beginPath();
                        render_context.circle(bone.origin.x, bone.origin.y, 4 / zoom);
                        render_context.fillColor(controls.caution);
                        render_context.fill();
                    }
                };
                if (automatic and pose_settings.has_target.* != 0 and overlayCapacity(render_context.pathBudget())) {
                    const target = pose_settings.last_target.*;
                    const achieved = pose_settings.achieved.*;
                    render_context.beginPath();
                    render_context.moveTo(target.x, target.y);
                    render_context.lineTo(achieved.x, achieved.y);
                    render_context.circle(achieved.x, achieved.y, 6 / zoom);
                    render_context.moveTo(target.x - 9 / zoom, target.y);
                    render_context.lineTo(target.x + 9 / zoom, target.y);
                    render_context.moveTo(target.x, target.y - 9 / zoom);
                    render_context.lineTo(target.x, target.y + 9 / zoom);
                    render_context.strokeColor(if (pose_settings.residual.* * zoom > 2) controls.caution else controls.target);
                    render_context.strokeWidth(2 / zoom);
                    render_context.stroke();
                }
                if (session.bonesShown(editor) and filmstrip.enabled(editor)) angle_badge: {
                    const active_bone = session.findById(session.api.EvaluatedBone, world, editor.active_bone.*) orelse break :angle_badge;
                    const channels = pose.readSolvedChannels(evaluation, active_bone.id) catch break :angle_badge;
                    const degrees = channels.rotation * 180 / std.math.pi;
                    if (!std.math.isFinite(degrees)) break :angle_badge;
                    var label_buffer: [64]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buffer, "Angle {d:.1} deg", .{degrees}) catch break :angle_badge;
                    const limited = renderBadge(render_context, active_bone.tip, label);
                    result.overlay_limited = result.overlay_limited or limited;
                }
            }
            {
                const zone = Log.zone(Zone.selection_outline);
                defer zone.end();
                const hovering_shape = editor.mode.* == names.design and editor.tool.* == names.select and
                    editor.gesture_active.* == 0 and !drag_busy and editor.hover_kind.* == names.shape;
                if (hovering_shape and !selection.contains(session.get(tables), session.selections(tables), names.shape, editor.hover_id.*)) {
                    if (session.findById(session.api.read.Shape, definition.shapes, editor.hover_id.*)) |shape| {
                        const limited = renderHoverContour(tables, atoms, render_context, shape, zoom);
                        result.overlay_limited = result.overlay_limited or limited;
                    }
                }
                var selected_rows = session.selections(tables).read();
                const shape_kind = names.shape;
                const has_shape = while (selected_rows.next()) |row| {
                    if (row.view.doc.* == editor.doc.* and row.view.kind.* == shape_kind) break true;
                } else false;
                // Weight's heat contour already marks its targets without covering them.
                if (has_shape and editor.tool.* != names.weight) {
                    const select_box = if (editor.mode.* == names.design and editor.tool.* == names.select)
                        drawing.selectionBoundsWithReads(&reads) catch null
                    else
                        null;
                    if (select_box) |box| {
                        const limited = renderSelectionFrame(session.get(tables), gesture.get(tables), drawing.config(tables), session.observed(tables), render_context, box, zoom);
                        result.overlay_limited = result.overlay_limited or limited;
                    } else {
                        const outline = reads.outliner(editor.doc.*) catch null;
                        if (outline) |items| for (items.items) |item| {
                            if (item.object.kind != .shape or !item.visible or item.locked or !selection.contains(session.get(tables), session.selections(tables), names.shape, item.object.id) or !overlayCapacity(render_context.pathBudget())) continue;
                            const shape_geometry = preview.geometry(tables, atoms, item.object.id) catch continue;
                            if (geometry.bounds(shape_geometry.points)) |bounds| {
                                render_context.beginPath();
                                render_context.rect(
                                    bounds.min.x - 3 / zoom,
                                    bounds.min.y - 3 / zoom,
                                    bounds.max.x - bounds.min.x + 6 / zoom,
                                    bounds.max.y - bounds.min.y + 6 / zoom,
                                );
                                render_context.strokeColor(controls.caution);
                                render_context.strokeWidth(1.5 / zoom);
                                render_context.stroke();
                            }
                        };
                    }
                }
                if (editor.gesture_active.* != 0) {
                    if (editor.gesture_kind.* == names.construct) {
                        render_context.beginPath();
                        const rig_options = session.rigOptions(tables);
                        if (rig_options.head.* != 0 and editor.tool.* == names.stick) {
                            const delta = math.Vec2f.sub(editor.gesture_current.*, editor.gesture_start.*);
                            render_context.circle(
                                (editor.gesture_start.x + editor.gesture_current.x) * 0.5,
                                (editor.gesture_start.y + editor.gesture_current.y) * 0.5,
                                @sqrt(delta.x * delta.x + delta.y * delta.y) * 0.5,
                            );
                        } else {
                            render_context.moveTo(editor.gesture_start.x, editor.gesture_start.y);
                            render_context.lineTo(editor.gesture_current.x, editor.gesture_current.y);
                        }
                        render_context.strokeColor(controls.edit);
                        render_context.strokeWidth(3 / zoom);
                        render_context.stroke();
                        if (editor.snap_kind.* != session.none and editor.snap_kind.* != names.none) {
                            render_context.beginPath();
                            render_context.circle(editor.snap_point.x, editor.snap_point.y, 7 / zoom);
                            render_context.moveTo(editor.snap_point.x - 12 / zoom, editor.snap_point.y);
                            render_context.lineTo(editor.snap_point.x + 12 / zoom, editor.snap_point.y);
                            render_context.moveTo(editor.snap_point.x, editor.snap_point.y - 12 / zoom);
                            render_context.lineTo(editor.snap_point.x, editor.snap_point.y + 12 / zoom);
                            render_context.strokeColor(controls.target);
                            render_context.strokeWidth(controls.line_width / zoom);
                            render_context.stroke();
                        }
                        const construction_delta = math.Vec2f.sub(editor.gesture_current.*, editor.gesture_start.*);
                        const length = geometry.distance(editor.gesture_start.*, editor.gesture_current.*);
                        const angle = std.math.atan2(construction_delta.y, construction_delta.x) * 180 / std.math.pi;
                        const snap = atoms.lookup(editor.snap_kind.*) orelse "none";
                        const label = std.fmt.allocPrint(frame_allocator, "L {d:.1}  {d:.1} deg  Snap: {s}", .{ length, angle, snap }) catch "Constructing";
                        const limited = renderBadge(render_context, editor.gesture_current.*, label);
                        result.overlay_limited = result.overlay_limited or limited;
                    } else if (editor.gesture_kind.* == names.marquee) {
                        render_context.beginPath();
                        render_context.rect(
                            @min(editor.gesture_start.x, editor.gesture_current.x),
                            @min(editor.gesture_start.y, editor.gesture_current.y),
                            @abs(editor.gesture_current.x - editor.gesture_start.x),
                            @abs(editor.gesture_current.y - editor.gesture_start.y),
                        );
                        render_context.fillColor(controls.selection_wash);
                        render_context.fill();
                        render_context.strokeColor(controls.selection);
                        render_context.strokeWidth(controls.line_width / zoom);
                        render_context.stroke();
                    }
                }
            }
            {
                const zone = Log.zone(Zone.drawing_overlay);
                defer zone.end();
                drawing.renderOverlay(&reads, render_context);
                const creation_bounds = drawing.creationBounds(tables) catch null;
                if (creation_bounds) |bounds| {
                    const creation_size = session.Vec2.sub(bounds.max, bounds.min);
                    const label = std.fmt.allocPrint(frame_allocator, "{d:.1} x {d:.1}", .{ creation_size.x, creation_size.y }) catch "Size";
                    const center = bounds.center();
                    const limited = renderBadge(render_context, .{ .x = center.x, .y = bounds.max.y }, label);
                    result.overlay_limited = result.overlay_limited or limited;
                }
                const weight_result = weight.renderOverlay(tables, atoms, render_context);
                result.overlay_limited = result.overlay_limited or weight_result.limited;
                result.weight_error = weight_result.diagnostic;
                result.weight_brush_reach = weight_result.brush_reach;
            }
            render_context.restore();
        }
    }
    return result;
}
