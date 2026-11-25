//! The figure system's contract: figures, the sketches that collect them, and the table rows that
//! draw them. A figure is rigged vector artwork: bones, layers of shapes bound to them, poses and
//! clips, kept in a document of its own (`read` describes its content). The runtime is
//! `mesha_runtime.figure` (`runtime/figure.zig`, `runtime/figure/`): host lifecycle and transport,
//! queries, evaluation, and preparing a pose for drawing, which only the host calls; a plugin,
//! the editor's figure editor included, reaches them through what is here, by command and by
//! query. What a prepared figure is (`Drawing`) and the one function that emits it into a roop
//! context (`draw`) are here, so whoever holds a `Drawing` draws it as the host does. Everything
//! here is a plain value, so a plugin, the editor and the MCP server name the same types and
//! submit the same commands.
//!
//! What a plugin does with it:
//!
//! - Loads a figure or a sketch by appending a `Command` (`appendRequest`) whose payload is a
//!   `LoadDoc` or `LoadSketch`, and hears the outcome as a `Result` message at the command's
//!   `reply`. The result's `definition_handle` is what it later releases the load by.
//! - Draws figures by giving a table of its own the instance columns (`instance_fields`,
//!   `initInstanceSchema`) and registering the table (`RuntimeOperation.register_table`,
//!   `appendRuntimeRequest`). The host draws each row that names a definition and writes back only
//!   `figure_instance_status`.
//! - Releases what it loaded (`release_loaded_definition`, `release_loaded_sketch`) and unregisters
//!   its table when it goes.
//!
//! What an editor does besides: edits a document with the other `Payload` commands, each a
//! validated change that is one undo step, or several between `begin` and `commit`; a gesture
//! transaction takes `preview` commands that redo the change as a drag moves. It reads what the
//! host knows of each document from `figure_definitions` (`listDefinitions`, `definitionInfo`,
//! `resolveDefinition`, `definitionDiagnostics`). What it reads of a posed figure every frame (the
//! authored document, the pose's bones, its drawing, its extent, its weights, its contours) it
//! asks for with a `Watch`, a row of `subscriptions.figure` its kernel appends each run, and
//! reads back from `figure_published` (`published`), which the host writes for every watch each
//! time it publishes a change. What it asks once (a hit test, a paint mapping, a transient pose, a shape
//! copy) it asks with a `QueryCommand`, a row of `commands.figure_queries` (`appendQuery`), and
//! hears as a `QueryAnswer` message in its inbox once the host has synchronized.
//! What needs no document store is here as pure functions over plain values: the paths drawing
//! tools make (`primitivePath`, `fitPath`, `pathCubic`, `dragBounds`), the outliner's tree of a
//! read definition (`projectOutliner`), copying a pose from one rig to another
//! (`capturePoseClipboard`, `remapPoseClipboard`), and drawing a prepared figure (`draw`).
//!
//! Requests are rows of `commands.figure` (`HostRequest`). The host admits each when it applies the
//! row, after the frame's run, so an appended request is not yet done: wait for its `Result`, or
//! read its status. A request is known by its document's key and its `request` number, which must
//! not repeat while the host runs.
//!
//! A document is addressed by its store key, an atom: its id in a process scope (see
//! `isProcessScope`), where the demo's and the editor's documents live, and a hash of its id and
//! scope in any other. The host publishes what it holds in `figure_catalog`, `figure_definitions`,
//! `figure_observed` and `figure_published`, after it applies the frame's commands: a kernel reads
//! them as of the previous frame's commands.
//!
//! Error values are numbered per image: a plugin built apart from the host reads a failure by its
//! name (`Result.diagnostic`, `RuntimeResult.failure_name`) or as a `Failure`, a value that means
//! the same in every image, never by comparing `outcome.failure`.
//! The layouts of what crosses between the host and a plugin here (`Command`, `Result`,
//! `DefinitionInfo`, `Watch`, `Published` and what it points at, `QueryCommand`, `QueryAnswer`)
//! are hashed into `plugin.abi_fingerprint`, so a plugin built against other layouts is refused
//! when it loads: a change to one needs the host and the plugins rebuilt together.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const math = @import("../core/math.zig");
const Table = @import("../core/table.zig");
const resources_api = @import("resources.zig");
const sequencer = @import("../core/sequencer.zig");
/// The value types a document's authored content is read as (`figure/read.zig`).
pub const read = @import("figure/read.zig");
const paths = @import("figure/path.zig");
const pose_clipboard = @import("figure/pose_clipboard.zig");
const drawing = @import("figure/drawing.zig");
const watch = @import("figure/watch.zig");
const query = @import("figure/query.zig");

/// The points of a primitive a drag draws (`figure/path.zig`). The caller owns the slice.
pub const primitivePath = paths.primitivePath;
/// The path a pencil stroke draws, thinned and fitted with cubics (`figure/path.zig`). The caller
/// owns the slice.
pub const fitPath = paths.fitPath;
/// The position along the path segment between two points (`figure/path.zig`).
pub const pathCubic = paths.pathCubic;
/// The box a drag spans (`figure/path.zig`).
pub const dragBounds = paths.dragBounds;
/// A definition's rows as the tree an outliner shows (`read.projectOutliner`).
pub const projectOutliner = read.projectOutliner;
/// A definition's working pose and its rig, to paste onto another figure
/// (`figure/pose_clipboard.zig`). The caller owns the clipboard's slices.
pub const capturePoseClipboard = pose_clipboard.capture;
/// A copied pose as inputs for a definition whose rig matches it by name
/// (`figure/pose_clipboard.zig`). The caller owns the inputs' slices.
pub const remapPoseClipboard = pose_clipboard.remap;
/// A figure prepared for drawing, which `draw` emits (`figure/drawing.zig`). Its owner frees it
/// with `Drawing.deinit`.
pub const Drawing = drawing.Drawing;
/// What a `Drawing` is prepared for: the transform and tolerances of the context it will be drawn
/// into (`figure/drawing.zig`).
pub const DrawParams = drawing.DrawParams;
/// Emits a `Drawing` into a roop context, whole or not at all (`figure/drawing.zig`).
pub const draw = drawing.draw;
/// What filling and stroking one flattened path takes of a context's budget
/// (`figure/drawing.zig`).
pub const geometryCost = drawing.geometryCost;
/// The geometry of a run of paths checked against a context's budget: how `draw` admits a
/// drawing and the host measures one (`figure/drawing.zig`).
pub const GeometryAdmission = drawing.GeometryAdmission;
/// `subscriptions.figure`, the table of watches (`figure/watch.zig`).
pub const watches_table_name = watch.watches_table_name;
/// The table of watches, a row per `Watch` (`figure/watch.zig`).
pub const Watches = watch.Watches;
/// A posed figure a system reads every frame, and what it wants of it (`figure/watch.zig`).
pub const Watch = watch.Watch;
/// What a `Watch` asks to be published (`figure/watch.zig`).
pub const Wants = watch.Wants;
/// `figure_published`, the table of the host's answers to watches (`figure/watch.zig`).
pub const published_table_name = watch.published_table_name;
/// A row of `figure_published` (`figure/watch.zig`).
pub const PublishedView = watch.PublishedView;
/// What the host published for one watch, valid until it next publishes a change
/// (`figure/watch.zig`).
pub const Published = watch.Published;
/// A subscriber's answer to its watch by key, at the host's latest publication
/// (`figure/watch.zig`).
pub const published = watch.published;
/// `commands.figure_queries`, the table of questions the figure host answers once
/// (`figure/query.zig`).
pub const queries_table_name = query.queries_table_name;
/// The table of queries, a row per `QueryCommand` (`figure/query.zig`).
pub const Queries = query.Queries;
/// Which question a `Query` asks (`figure/query.zig`).
pub const QueryKind = query.QueryKind;
/// A one-off question for the figure host (`figure/query.zig`).
pub const Query = query.Query;
/// A row of `commands.figure_queries`: a question and where its answer goes (`figure/query.zig`).
pub const QueryCommand = query.QueryCommand;
/// The head of an answer to a query, and the readers of what follows it (`figure/query.zig`).
pub const QueryAnswer = query.QueryAnswer;
/// Validates a query and appends it to `commands.figure_queries` (`figure/query.zig`).
pub const appendQuery = query.appendQuery;

/// A memory scope's id: its name and generation. A document's store lives in a scope and ends with
/// it.
pub const ScopeId = resources_api.ScopeId;
/// The name of the application scope, which lives until shutdown; see
/// `resources.kApplicationScope`.
pub const kApplicationScope = resources_api.kApplicationScope;
/// The application scope's id, where a plugin's figures load; see `resources.applicationScope`.
pub const applicationScope = resources_api.applicationScope;
/// The id of the scope that holds figure documents opened for authoring; see
/// `resources.editorDocumentsScope`.
pub const editorDocumentsScope = resources_api.editorDocumentsScope;
/// Whether a scope lives as long as the process, as the two above do. A document in one keeps its
/// plain id as its store key; see `resources.isProcessScope`.
pub const isProcessScope = resources_api.isProcessScope;
/// What resources calls to ask about and release the figure stores of a scope it closes
/// (`resources.ScopeStores`). The host wires the figure library's; a plugin has no use for it.
pub const ScopeStoresHook = resources_api.ScopeStores;
/// How closing a resource scope ended (`resources.ResourceScopeCloseResult`).
pub const ScopeCloseResult = resources_api.ResourceScopeCloseResult;
/// A position or an offset, two `f32`s, in a document's units unless a field says otherwise.
pub const Vec2 = math.Vec2f;
/// A colour as red, green, blue and alpha bytes.
pub const Color = [4]u8;
/// The atom that names nothing, 0: an absent name, clip, member or plugin.
pub const none: Atom = @enumFromInt(0);
/// A request that names only its document: `commit`, `cancel`, `preview_reset`, `undo` and `redo`.
/// `doc` is the document's store key and `request` the requester's number for the request (see
/// `Payload`).
pub const Doc = struct { doc: Atom, request: u32 = 0 };
/// Makes a new figure document with the logical id `doc`, a snake_case name, in `scope`. It has no
/// undo history, and the editor holds it open until a `CloseDoc`. Its store key, which later
/// requests and the result name, is `doc` itself in a process scope.
pub const NewDoc = struct {
    /// The scope the document is made in.
    scope: ScopeId,
    /// The document's logical id.
    doc: Atom,
    /// The requester's number for the request (see `Payload`).
    request: u32 = 0,
    /// The file the document will be saved to, absolute (`resources.isAbsolutePath`), named
    /// `<doc>.mshf` and shorter than `resources.max_path`; null for none. It is recorded as the
    /// document's file at once (`read.Definition.path`, `definitionPath`), so a save naming no
    /// path writes it; nothing is written and the resources catalog claims nothing until that
    /// save. Copied when appended.
    path: ?[]const u8 = null,
};
/// Ends the editor's hold on `doc`. Unsaved edits refuse it unless `discard`, which drops them. The
/// document is unloaded unless a loader still holds it, when it stays, at its last loaded or saved
/// content after a `discard`. A close asked while the document's save is in flight waits for the
/// save; a `discard` then, or any close during a load, is refused `Busy`.
pub const CloseDoc = struct { doc: Atom, request: u32 = 0, discard: bool = false };
/// Loads the figure `doc` into `scope` from its file: `path` when given (absolute, or relative to
/// the working directory when resources reads it; its name is `<doc>.mshf`), else `<plugin's
/// directory>/assets/figures/<doc>.mshf` when `plugin` names one, else the file the catalog has
/// for `doc`. At most one of `path` and `plugin`. The file the document keeps once loaded is the
/// catalog's, absolute (`resources.DocumentAssetView.path`).
///
/// `editor_open` says whose hold the load takes: true the editor's, ended by `CloseDoc`; false a
/// loader's, ended by `RuntimeOperation.release_loaded_definition` with the handle the result
/// gives. A document already loaded only takes the hold, unless `force`, which reads its file
/// again. A loader's hold from a load naming `plugin` is let go of when that plugin goes
/// (`RuntimeOperation.release_plugin_loads`); `plugin` names the directory the file is in, not the
/// asker, so a load by `path` or naming another plugin is not.
///
/// The result arrives once the file is read, a frame or more later; at once for a document already
/// loaded.
pub const LoadDoc = struct { scope: ScopeId, doc: Atom, request: u32 = 0, force: bool = false, editor_open: bool = true, plugin: Atom = none, path: ?[]const u8 = null };
/// Saves `doc` to `path` (absolute, or relative to the working directory when resources writes it,
/// and kept absolute), or to the file it has when `path` is null. A path whose name is another
/// id's (`<id>.mshf`, snake_case) is a Save As: once written the document goes by that id, and
/// results and `figure_observed` name both. Saving under a new name does not replace a file already
/// there unless `overwrite`. The result arrives when the file is written.
pub const SaveDoc = struct { doc: Atom, request: u32 = 0, path: ?[]const u8 = null, overwrite: bool = false };
/// The table of open sketches, a `SketchView` row each. A sketch is a named, ordered collection of
/// figures, its members (`runtime/figure/sketch.zig`): each member is an ordinary figure document.
/// Sketches live in a process scope, and `doc` in a sketch request is the sketch's id.
pub const sketches_table_name = "figure_sketches";
/// The table of open sketches' members, a `SketchMemberView` row each.
pub const sketch_members_table_name = "figure_sketch_members";
/// A row of `figure_sketches`, as a view reads it.
pub const SketchView = struct {
    /// The sketch's id.
    sketch: *Atom,
    /// The process scope its members load in.
    scope: *Atom,
    /// A `read.State`: loading, ready or failed.
    state: *u32,
    /// The sketch's file, absolute as the catalog keeps it (`resources.DocumentAssetView.path`)
    /// once it is read or saved; before its first save, the file it was made to be saved to
    /// (`NewSketch.path`), absolute too. Empty while it has neither.
    path: []const u8,
    /// Whether membership has edits not yet saved.
    dirty: *u8,
    /// Nonzero while the editor holds the sketch open.
    editor_open: *u8,
    /// Nonzero while a loader holds it (a load with `editor_open` false).
    runtime_held: *u8,
    /// Why its last load or save failed; empty when none did.
    error_text: []const u8,
};
/// A row of `figure_sketch_members`: the member `member` of `sketch` is drawn by the figure
/// document `figure`, at `order` among the sketch's members, from 0.
pub const SketchMemberView = struct { sketch: *Atom, order: *u32, member: *Atom, figure: *Atom };
/// Loads the sketch's file, then each member's figure with the same hold. Its file is found as a
/// figure's (`LoadDoc`), named `<doc>.mshs`; each member's figure is `<figure>.mshf` beside it.
/// `editor_open` chooses the hold as for a figure; a loader's is ended by
/// `RuntimeOperation.release_loaded_sketch`, and goes with `plugin` as a figure's does.
pub const LoadSketch = struct { scope: ScopeId, doc: Atom, request: u32 = 0, editor_open: bool = true, plugin: Atom = none, path: ?[]const u8 = null };
/// Where a sketch's member figure named `figure_name` is: `<figure_name>.mshf` in the directory of
/// the sketch's file, `sketch_path`, absolute when that is, as a sketch's recorded file is; in the
/// working directory when `sketch_path` names no directory, as a relative path a save is given
/// may. None for a sketch without a file. The path is written into `buffer`, which
/// `resources.max_path` bytes hold for a recorded file; `error.NoSpaceLeft` when it does not fit.
pub fn sketchMemberPath(buffer: []u8, sketch_path: []const u8, figure_name: []const u8) error{NoSpaceLeft}!?[]const u8 {
    if (sketch_path.len == 0) return null;
    const extension = resources_api.figure_document_extension;
    const directory = std.fs.path.dirname(sketch_path) orelse
        return try std.fmt.bufPrint(buffer, "{s}{s}", .{ figure_name, extension });
    return try std.fmt.bufPrint(buffer, "{s}/{s}{s}", .{ directory, figure_name, extension });
}
/// A sketch with one new, empty member, `member`, whose figure is `<doc>_<member>`.
pub const NewSketch = struct {
    /// The process scope the sketch's members are made in.
    scope: ScopeId,
    /// The sketch's id.
    doc: Atom,
    /// The requester's number for the request (see `Payload`).
    request: u32 = 0,
    /// The name of the sketch's first member.
    member: Atom,
    /// The file the sketch will be saved to, absolute (`resources.isAbsolutePath`), named
    /// `<doc>.mshs` and shorter than `resources.max_path`; null for none. It is recorded as the sketch's file at once
    /// (`SketchView.path`), so a `SaveSketch` naming no path writes it and its members' figures
    /// beside it; nothing is written until then, as for `NewDoc.path`. Copied when appended.
    path: ?[]const u8 = null,
};
/// Saves the sketch's file, and first each member figure with edits or without a file, which
/// is saved beside the sketch. `path` is where a sketch without a file goes.
pub const SaveSketch = struct { doc: Atom, request: u32 = 0, path: ?[]const u8 = null };
/// Closes the editor's hold on the sketch and its members' figures.
pub const CloseSketch = struct { doc: Atom, request: u32 = 0, discard: bool = false };
/// Adds `member` last, its figure `<doc>_<member>`: empty, or a copy of member `copy_of`'s.
pub const AddSketchMember = struct { doc: Atom, request: u32 = 0, member: Atom, copy_of: Atom = none };
/// Renames `member` to `name`, which no other member may have. Its figure keeps its id.
pub const RenameSketchMember = struct { doc: Atom, request: u32 = 0, member: Atom, name: Atom };
/// Drops `member` and closes the editor's hold on its figure, whose file stays. Refused while the
/// figure has unsaved edits, and for a sketch's last member.
pub const RemoveSketchMember = struct { doc: Atom, request: u32 = 0, member: Atom };
/// Moves `member` one place earlier (a negative `direction`) or later (a positive one); 0, or a
/// move past either end, does nothing. The first member is the one an instance row naming none
/// draws.
pub const MoveSketchMember = struct { doc: Atom, request: u32 = 0, member: Atom, direction: i32 };
/// Adds a bone. The result's `created_id` is its id. `doc` is the document's store key and
/// `request` the requester's number for the request (see `Payload`).
pub const AddBone = struct {
    /// The document's store key.
    doc: Atom,
    /// The requester's number for the request.
    request: u32 = 0,
    /// The parent bone's id; 0 makes a root.
    parent: u32 = 0,
    /// Where it starts, in its parent's space; ignored when `connected`.
    local: Vec2 = .{ .x = 0, .y = 0 },
    /// Its rotation in its parent's space, in radians.
    rotation: f32 = 0,
    /// Its length.
    length: f32 = 0,
    /// Its name; none gives it `bone_<id>`.
    name: Atom = none,
    /// Starts it at its parent's tip. Ignored for a root.
    connected: bool = false,
    /// `read.BoneFlags` bits, 2 (`deform`) by default. The `connected` bit is taken from
    /// `connected`, not from here.
    flags: u32 = 2,
    /// Also adds a `bone_stroke` shape that draws the bone, named `<bone>_stroke`, with the stroke
    /// look of a shape on the parent bone when there is one.
    make_stroke: bool = false,
    /// The layer the stroke goes in; 0 for the document's first layer.
    layer: u32 = 0,
    /// The stroke's `read.Shape.stroke_kind`.
    stroke_kind: Atom = Atom.from("line"),
};
/// Sets the fields given of bone `id`; a null leaves its field as it is. A connected bone's `local`
/// stays zero. The parent is changed by `ReparentBone`. `doc` is the document's store key and
/// `request` the requester's number for the request (see `Payload`).
pub const SetBone = struct {
    /// The document's store key.
    doc: Atom,
    /// The requester's number for the request.
    request: u32 = 0,
    /// The bone.
    id: u32,
    /// A new name.
    name: ?Atom = null,
    /// Where it starts, in its parent's space.
    local: ?Vec2 = null,
    /// Its rotation in its parent's space, in radians.
    rotation: ?f32 = null,
    /// Its length.
    length: ?f32 = null,
    /// Its scale in its parent's space.
    scale: ?Vec2 = null,
    /// All its `read.BoneFlags` bits.
    flags: ?u32 = null,
};
/// Deletes bone `id`. Its children move to its parent, staying where they are at rest, or with
/// `delete_branch` go with it. Shapes bound to a deleted bone are unbound where the working pose
/// has them, and IK controllers whose chain held one are deleted with their pose rows.
pub const DeleteBone = struct { doc: Atom, request: u32 = 0, id: u32, delete_branch: bool = false };
/// Gives bone `id` the parent `parent`, 0 making it a root; a parent among its own descendants is
/// refused. `keep_world` keeps it where it is in the rest pose by changing its local transform; a
/// root is never connected.
pub const ReparentBone = struct { doc: Atom, request: u32 = 0, id: u32, parent: u32, keep_world: bool = true };
/// Copies bone `id` and its descendants, mirrored left to right about the bone's origin at rest,
/// with their bone strokes. A copy's name swaps a `left_`/`right_` prefix or an `_l`/`_r` suffix,
/// or gains `_mirror`. The result's `created_id` is the copy of `id`.
pub const MirrorBranch = struct { doc: Atom, request: u32 = 0, id: u32 };
/// Sets the fields given of layer `id`; a null leaves its field as it is (see `read.Layer`).
/// `parent` moves it into a folder, or out with 0. `before` moves it among its parent's layers to
/// just beneath the layer `before`, or to the front with 0. Moving a layer needs it and its new
/// folder unlocked.
pub const SetLayer = struct { clip_to_below: ?u8 = null, before: ?u32 = null, doc: Atom, request: u32 = 0, id: u32, parent: ?u32 = null, name: ?Atom = null, blend: ?Atom = null, visible: ?u8 = null, locked: ?u8 = null, opacity: ?f32 = null, order: ?u32 = null };
/// Sets the fields given of shape `id`; a null leaves its field as it is (see `read.Shape` for
/// each). Refused when the shape's layer, or the layer it moves to, is locked. `doc` is the
/// document's store key and `request` the requester's number for the request (see `Payload`).
pub const SetShape = struct {
    /// The document's store key.
    doc: Atom,
    /// The requester's number for the request.
    request: u32 = 0,
    /// The shape.
    id: u32,
    /// A new name.
    name: ?Atom = null,
    /// 0 hides it.
    visible: ?u8 = null,
    /// 0 to 1.
    opacity: ?f32 = null,
    /// The stroke's width.
    stroke_width: ?f32 = null,
    /// The stroke's solid colour. The stroke's paint, if any, still applies: `SetShapeColor` also
    /// detaches it.
    stroke_color: ?Color = null,
    /// How far the stroke's glow reaches; 0 for none.
    stroke_glow_radius: ?f32 = null,
    /// The glow's colour.
    stroke_glow_color: ?Color = null,
    /// The fill's solid colour; see `stroke_color`.
    fill_color: ?Color = null,
    /// How a primitive is drawn.
    stroke_kind: ?Atom = null,
    /// The layer it is in.
    layer: ?u32 = null,
    /// How an open stroke ends.
    cap: ?Atom = null,
    /// How a stroke turns a corner.
    join: ?Atom = null,
    /// Nonzero closes the path.
    closed: ?u8 = null,
    /// The paint that fills it; 0 for none.
    fill_paint: ?u32 = null,
    /// The paint that strokes it; 0 for none.
    stroke_paint: ?u32 = null,
};
/// Which of a shape's two colours: its `fill` or its `stroke`.
pub const PaintChannel = enum { fill, stroke };
/// Gives the shapes `ids` one solid colour for `target`, detaching the paint they had there. All or
/// none: a missing shape or a locked layer refuses the whole request.
pub const SetShapeColor = struct { doc: Atom, request: u32 = 0, ids: []const u32, target: PaintChannel, color: Color };
/// A path point as a command gives it: `read.Point` without its shape, index and weights.
pub const Point = struct {
    /// The point's position, in bind space.
    p: Vec2 = .{ .x = 0, .y = 0 },
    /// The arriving segment's handle, as an offset from `p`.
    in: Vec2 = .{ .x = 0, .y = 0 },
    /// The leaving segment's handle, as an offset from `p`.
    out: Vec2 = .{ .x = 0, .y = 0 },
    /// Bits kept with the point.
    flags: u32 = 0,
    /// A width at the point.
    width: f32 = 1,
    /// For a `joint_fill`, the bone whose end the point sits at.
    joint_bone: u32 = 0,
    /// For a `joint_fill`, 0 for that bone's origin and 1 for its tip.
    joint_end: u8 = 1,
};
/// The look a new shape starts with; see `read.Shape` for each field.
pub const Style = struct {
    /// The fill's colour; transparent by default, so the shape is not filled.
    fill_color: Color = .{ 0, 0, 0, 0 },
    /// The stroke's colour.
    stroke_color: Color = .{ 148, 82, 210, 255 },
    /// The stroke's width.
    stroke_width: f32 = 2,
    /// How an open stroke ends.
    cap: Atom = Atom.from("round"),
    /// How a stroke turns a corner.
    join: Atom = Atom.from("round"),
    /// 0 to 1.
    opacity: f32 = 1,
};
/// Adds a shape to `layer`, in front of the layer's others, with 2 to 16384 `points`. A name of
/// none gives it `shape`, made unique. The result's `created_id` is its id. Refused when the layer
/// is locked.
pub const AddShape = struct { doc: Atom, request: u32 = 0, layer: u32, name: Atom = none, kind: Atom = Atom.from("path"), closed: u8 = 0, style: Style = .{}, points: []const Point };
/// Puts the layers `ids`, none of them a folder, into a new folder where the frontmost of them was,
/// keeping their order. `name` of none gives it `folder`, made unique. The result's `created_id` is
/// the folder's id.
pub const GroupLayers = struct { doc: Atom, request: u32 = 0, ids: []const u32, name: Atom = none };
/// Dissolves the folder `id`: its layers take its place at the root, in their order.
pub const UngroupLayer = struct { doc: Atom, request: u32 = 0, id: u32 };
/// Adds a layer in front of the others, in the folder `parent` or at the root with 0. `name` of
/// none gives it `layer`, made unique. The result's `created_id` is its id.
pub const AddLayer = struct { doc: Atom, request: u32 = 0, name: Atom = none, kind: Atom = Atom.from("vector"), parent: u32 = 0 };
/// Deletes layer `id`, with the layers in it when it is a folder, and their shapes. When any shape
/// would go it is refused unless `confirmed`. It deletes locked layers too.
pub const DeleteLayer = struct { doc: Atom, request: u32 = 0, id: u32, confirmed: bool = false };
/// Swaps layer `id` with its neighbour among its parent's layers: `direction` 1 toward the front,
/// -1 toward the back; any other value is refused. At the end already, nothing changes.
pub const MoveLayer = struct { doc: Atom, request: u32 = 0, id: u32, direction: i32 };
/// A request that names shapes of one document: `delete_shapes` deletes `ids`, all or none, refused
/// when a layer of theirs is locked.
pub const Shapes = struct { doc: Atom, request: u32 = 0, ids: []const u32 };
/// Moves the shapes `ids` within their layers: `direction` 1 toward the front, -1 toward the back,
/// one place, or all the way with `extreme`.
pub const OrderShapes = struct { doc: Atom, request: u32 = 0, ids: []const u32, direction: i32, extreme: bool = false };
/// Moves the shapes `ids` to `layer`, in front of what it holds. Neither layer may be locked.
pub const MoveShapes = struct { doc: Atom, request: u32 = 0, ids: []const u32, layer: u32 };
/// Replaces the points of `shape` from index `first` on with `points`, each keeping the bone
/// weights its place had. The range must lie within the path: this does not add points.
pub const SetPoints = struct { doc: Atom, request: u32 = 0, shape: u32, first: u32 = 0, points: []const Point };
/// Splits the path's segment `segment`, which runs from the point of that index to the next, at
/// `t`, strictly between 0 and 1, without changing its curve. The new point's weights are the two
/// ends' interpolated, at most four bones. A closed path's last segment runs back to its first
/// point.
pub const InsertPoint = struct { doc: Atom, request: u32 = 0, shape: u32, segment: u32, t: f32 = 0.5 };
/// Deletes the points of `shape` at `indices`. A path keeps at least 2 points and a `joint_fill` 3,
/// or the request is refused.
pub const DeletePoints = struct { doc: Atom, request: u32 = 0, shape: u32, indices: []const u32 };
/// Scales by `scale` and rotates by `rotation` radians about `pivot`, then moves by `translation`,
/// the selected shapes and points, in bind space: bindings, weights and the working pose are left
/// as they are. An item's `kind` is `shape` or `point` (`sub` its index). A shape's paints move
/// with it, a shared one copied first so other shapes keep theirs; a `line` primitive selected
/// whole becomes a path, and a bone stroke or joint fill is refused. Neither scale may be 0. The
/// identity transform changes nothing.
pub const TransformSelection = struct { doc: Atom, request: u32 = 0, items: []const Selection, pivot: Vec2, translation: Vec2 = .{ .x = 0, .y = 0 }, rotation: f32 = 0, scale: Vec2 = .{ .x = 1, .y = 1 } };
/// Gives `shape` a two-stop gradient as its fill, or its stroke with `stroke`. `id` 0 makes a paint
/// and another id replaces that paint, for every shape that uses it. `start` and `end` are in the
/// paint's own space, which `transform` maps to bind space; null keeps the replaced paint's, or is
/// the identity. The result's `created_id` is the paint's id.
pub const SetPaint = struct { doc: Atom, request: u32 = 0, id: u32 = 0, shape: u32, stroke: bool = false, kind: Atom = Atom.from("linear"), start: Vec2, end: Vec2, transform: ?[6]f32 = null, colors: [2]Color = .{ .{ 255, 255, 255, 255 }, .{ 0, 0, 0, 255 } } };
/// Adds to `layer` the shapes in `bytes`, a figure file as an `encode_shape_clipboard` query answers
/// it, each moved by `delta`, with copies of their paints. The result's `created_id` is the
/// first new shape's id. Refused when a shape in it is bound.
pub const PasteShapes = struct { doc: Atom, request: u32 = 0, layer: u32, bytes: []const u8, delta: Vec2 = .{ .x = 16, .y = 16 } };
/// Copies the shapes `ids`, each a path or a `line` and named once, moved by `delta` in bind space,
/// into their own layers in front of what is there, keeping their order, bindings and weights. A
/// paint several of them share is copied once. The result's `created_id` is the first of `ids.len`
/// consecutive new shape ids, given in the sources' stacking order; the paints' ids follow. Every
/// application takes ids of its own, a gesture's repeated previews too. An empty `ids` does
/// nothing.
pub const DuplicateShapes = struct { doc: Atom, request: u32 = 0, ids: []const u32, delta: Vec2 = .{ .x = 0, .y = 0 } };
/// One selected thing: `kind` is the atom `shape`, `bone` or `point`, `id` the shape's or bone's
/// id, and `sub` a point's index in the shape `id`.
pub const Selection = struct { kind: Atom, id: u32, sub: u32 = 0 };
/// Deletes the selected shapes and bones, bones deepest first, each as `DeleteBone` without
/// `delete_branch`. An item of another kind refuses the request.
pub const DeleteSelection = struct { doc: Atom, request: u32 = 0, items: []const Selection };
/// The space a `MoveSelection`'s delta is in. `working`: the document's, as the working pose shows
/// the shapes, so a bound shape moves on screen by the delta. `bind`: bind space, added to the
/// points as they are, skipping bone strokes and joint fills.
pub const MoveCoordinatePolicy = enum { working, bind };
/// Moves the selected shapes by `delta`; items of other kinds are ignored. A moved shape's paints
/// go with it, a shared one copied first. Under `working` a bone stroke becomes a `line` bound to
/// its bone, so the bone stays.
pub const MoveSelection = struct { doc: Atom, request: u32 = 0, items: []const Selection, delta: Vec2, coordinate_policy: MoveCoordinatePolicy = .working };
/// Binds the shapes `ids` to `bone`, so they move as it does. Their points stay in bind space. An
/// earlier binding is dropped first, at the rest pose.
pub const BindRigid = struct { doc: Atom, request: u32 = 0, ids: []const u32, bone: u32 };
/// Binds the shapes `ids` as skin, weighting each point to the bones near it. `bones` are the
/// candidates, every deform bone when empty. `method` must be `auto`. `chain_local` keeps to the
/// nearest bone and those joined to it; `envelope` leaves out bones farther than it; `epsilon`
/// (above 0) and `exponent` (above 0, at most 16) shape how weight falls with distance. A `line`
/// primitive becomes a path first.
pub const BindSkinned = struct { doc: Atom, request: u32 = 0, ids: []const u32, bones: []const u32 = &.{}, method: Atom = Atom.from("auto"), chain_local: bool = true, envelope: ?f32 = null, epsilon: f32 = 0.001, exponent: f32 = 2 };
/// Unbinds the shapes `ids`, leaving them as the pose `pose` shows them: `rest`, or `current` for
/// the working pose. A skinned path unbound at `current` may become a polyline.
pub const Unbind = struct { doc: Atom, request: u32 = 0, ids: []const u32, pose: Atom = Atom.from("rest") };
/// One bone's share of a point: `weight` 0 to 1.
pub const Influence = struct { bone: u32, weight: f32 };
/// Sets the weights of point `index` of the skinned path `shape` to `influences`, normalized. Bones
/// in `locked_bones` keep the weight they have.
pub const SetWeights = struct { doc: Atom, request: u32 = 0, shape: u32, index: u32, influences: []const Influence, locked_bones: []const u32 = &.{} };
/// One dab of a weight brush on the skinned path `shape`, for `bone`. `indices` are the points it
/// touches, each once, and `factors` the brush's falloff at each, 0 to 1, which the caller
/// computes. `mode` is `add`, `subtract`, `replace` (toward `value`) or `smooth` (toward the
/// neighbours' mean); `strength` and `value` are 0 to 1. Bones in `locked_bones` keep their weight.
pub const PaintWeights = struct { doc: Atom, request: u32 = 0, shape: u32, bone: u32, indices: []const u32, factors: []const f32, strength: f32 = 0.1, mode: Atom = Atom.from("add"), value: f32 = 1, locked_bones: []const u32 = &.{} };
/// The most dabs a `PaintWeightsBatch` holds.
pub const max_weight_batch_dabs: usize = 256;
/// The most point and factor pairs a batch's dabs hold together.
pub const max_weight_batch_pairs: usize = 65536;
/// The most locked bones a batch names.
pub const max_weight_batch_locks: usize = 4096;
/// One dab of a batch: a `PaintWeights` without its document and locks.
pub const WeightDab = struct { shape: u32, bone: u32, indices: []const u32, factors: []const f32, strength: f32 = 0.1, mode: Atom = Atom.from("add"), value: f32 = 1 };
/// Several dabs applied in order as one change, sharing `locked_bones`: a stroke's dabs between two
/// frames.
pub const PaintWeightsBatch = struct { doc: Atom, request: u32 = 0, dabs: []const WeightDab, locked_bones: []const u32 = &.{} };
/// Checks a batch's sizes: `error.InvalidDab` for no dabs, more than the limits above, or a dab
/// whose `indices` and `factors` differ in length.
pub fn validateWeightBatch(batch: PaintWeightsBatch) !void {
    if (batch.dabs.len == 0 or batch.dabs.len > max_weight_batch_dabs or batch.locked_bones.len > max_weight_batch_locks) return error.InvalidDab;
    var pairs: usize = 0;
    for (batch.dabs) |dab| {
        if (dab.indices.len != dab.factors.len or dab.indices.len > max_weight_batch_pairs - pairs) return error.InvalidDab;
        pairs += dab.indices.len;
    }
}
/// Adds points to the paths `ids` so no segment is longer than `spacing`, above 0, without changing
/// their curves: more points for skinning to bend.
pub const SubdivideForDeform = struct { doc: Atom, request: u32 = 0, ids: []const u32, spacing: f32 };
/// What a pose gives one bone: each value set replaces the bone's own, and a null leaves it (see
/// `read.PoseChannel`).
pub const PoseChannels = struct { bone: u32, rotation: ?f32 = null, local: ?Vec2 = null, scale: ?Vec2 = null, length: ?f32 = null };
/// Replaces, in pose `pose` (0 the working pose), what the pose gives each bone listed: a bone
/// listed with every value null loses its channel. Bones not listed keep theirs. A bone may be
/// listed once.
pub const SetPoseChannels = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, channels: []const PoseChannels };
/// What a pose gives one IK controller; see `read.PoseIK` for each field. `target` is in the
/// document's space when `pinned`, else in the space of the chain's parent.
pub const PoseIK = struct { ik: u32, target: Vec2 = .{ .x = 0, .y = 0 }, target_rotation: f32 = 0, enabled: u8 = 1, pinned: u8 = 0, bend_side: i32 = 0, pole_angle: f32 = std.math.pi / 2.0 };
/// Replaces everything pose `pose` holds with `channels` and `ik`: its other bone channels,
/// controller rows and property values are cleared.
pub const SetPose = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, channels: []const PoseChannels, ik: []const PoseIK };
/// Clears pose `pose`: all of it with `bone` 0, or one bone's channels and the rows of the
/// controllers whose chain holds it.
pub const ResetPose = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, bone: u32 = 0 };
/// Adds an IK controller over the `chain` bones ending at `end_bone` (see `read.IK`). With `enable`
/// the working pose gets its row, with the target where the chain's end is. The result's
/// `created_id` is the controller's id.
pub const AddIK = struct { doc: Atom, request: u32 = 0, name: Atom = none, end_bone: u32, chain: u32 = 2, bend: i32 = 0, flags: u32 = 0, enable: bool = true };
/// Sets the fields given of controller `id`; a null leaves its field as it is.
pub const SetIK = struct { doc: Atom, request: u32 = 0, id: u32, name: ?Atom = null, end_bone: ?u32 = null, chain: ?u32 = null, bend: ?i32 = null, flags: ?u32 = null };
/// Deletes controller `id` and its row in every pose.
pub const DeleteIK = struct { doc: Atom, request: u32 = 0, id: u32 };
/// Sets controller `id`'s target, its rotation, or both, in pose `pose`, and enables it there. A
/// controller with no row in the pose starts pinned where the chain's end is.
pub const SetIKTarget = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, id: u32, target: ?Vec2 = null, target_rotation: ?f32 = null };
/// Names a controller in a pose. `pin_ik` enables it pinned where the chain's end is now.
/// `unpin_ik` writes the solved chain into the pose's bone channels and disables it, so the pose
/// looks the same.
pub const PinIK = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, id: u32 };
/// Copies pose `source` (0 the working pose) into pose `id`, renaming it `name`, or with `id` 0
/// into a new pose called `name`. The result's `created_id` is the pose's id.
pub const SavePose = struct { doc: Atom, request: u32 = 0, source: u32 = 0, id: u32 = 0, name: Atom };
/// Renames the saved pose `id`.
pub const NamePose = struct { doc: Atom, request: u32 = 0, id: u32, name: Atom };
/// Copies the saved pose `id` over pose `destination`, 0 the working pose, replacing what it held.
pub const ApplyPose = struct { doc: Atom, request: u32 = 0, id: u32, destination: u32 = 0 };
/// Deletes the saved pose `id`. While a clip's key uses it the request is refused, unless
/// `delete_keys` deletes those keys too.
pub const DeletePose = struct { doc: Atom, request: u32 = 0, id: u32, delete_keys: bool = false };
/// Swaps pose `pose`'s left and right: each bone's and controller's values go to its partner, found
/// by name (`left_`/`right_`, `_l`/`_r`), mirrored. Refused unless the rig itself is mirrored so.
pub const MirrorPose = struct { doc: Atom, request: u32 = 0, pose: u32 = 0 };
/// The families of definition rows a pose may give property values to.
pub const PropertyFamily = enum(u32) { bone, layer, shape, point, paint };
/// The fields of each family a pose may set, in the order an editor lists them: what changes
/// how the figure looks, never its structure. Bone transforms and IK have their own channels.
pub const animatable_fields = .{
    .bone = .{"display_color"},
    .layer = .{ "opacity", "visible", "blend", "clip_to_below" },
    .shape = .{ "fill_color", "stroke_color", "stroke_width", "stroke_glow_radius", "stroke_glow_color", "opacity", "visible", "closed", "cap", "join", "fill_paint", "stroke_paint", "start", "end" },
    .point = .{ "p", "in", "out", "width" },
    .paint = .{ "start", "end", "transform", "stop_colors" },
};
/// The size of a pose property's value: room for the largest animatable field's bytes.
pub const property_value_bytes = 32;
/// A value a pose gives one property of one definition row: `target` is the row's id, a point's
/// shape, and `index` a point's index in it. Only the fields in `animatable_fields` may be set (see
/// `runtime/figure/properties.zig`); `value` is the field's own bytes, as `propertyValue` makes
/// them.
pub const PoseProperty = struct { family: PropertyFamily, target: u32, index: u32 = 0, field: Atom, value: [property_value_bytes]u8 };
/// A field's value as a pose property's bytes: the value's own bytes, zeros after. `value`'s type
/// must be the field's, and no larger than `property_value_bytes`.
pub fn propertyValue(value: anytype) [property_value_bytes]u8 {
    comptime std.debug.assert(@sizeOf(@TypeOf(value)) <= property_value_bytes);
    var bytes: [property_value_bytes]u8 = @splat(0);
    @memcpy(bytes[0..@sizeOf(@TypeOf(value))], std.mem.asBytes(&value));
    return bytes;
}
/// A pose property's bytes as the field's type `T`, which the reader knows from the property's
/// family and field.
pub fn propertyAs(comptime T: type, bytes: [property_value_bytes]u8) T {
    return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
}
/// Sets property values in `pose` (0 the working pose), each replacing any it had; all or none
/// apply. A value for a field that is not animatable, of a row that does not exist, or out of the
/// field's range refuses the request.
pub const SetPoseProperties = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, properties: []const PoseProperty };

/// The pose properties an edit of a row's look stands for, so an editor animating the figure can
/// give a pose the edit instead of the definition. Null when the edit also changes what a pose may
/// not: a name, a parent, a lock; and for any edit but `set_shape`, `set_layer` and
/// `set_shape_color`. A solid color detaches the channel's paint, as `SetShapeColor` does. The rows
/// are the caller's, to free with `allocator`.
pub fn animatedProperties(allocator: std.mem.Allocator, edit: PreviewEdit) !?[]PoseProperty {
    var rows: std.ArrayListUnmanaged(PoseProperty) = .empty;
    errdefer rows.deinit(allocator);
    switch (edit) {
        .set_shape => |request| if (!try collect(allocator, .shape, request.id, request, &rows)) return null,
        .set_layer => |request| if (!try collect(allocator, .layer, request.id, request, &rows)) return null,
        .set_shape_color => |request| for (request.ids) |id| {
            const color_field: Atom = if (request.target == .fill) Atom.from("fill_color") else Atom.from("stroke_color");
            const paint_field: Atom = if (request.target == .fill) Atom.from("fill_paint") else Atom.from("stroke_paint");
            try rows.append(allocator, .{ .family = .shape, .target = id, .field = color_field, .value = propertyValue(request.color) });
            try rows.append(allocator, .{ .family = .shape, .target = id, .field = paint_field, .value = propertyValue(@as(u32, 0)) });
        },
        else => return null,
    }
    if (rows.items.len == 0) return null;
    return try rows.toOwnedSlice(allocator);
}

/// Appends a row for each field `request` sets; false when one it sets is not animatable.
fn collect(allocator: std.mem.Allocator, comptime family: PropertyFamily, target: u32, request: anytype, rows: *std.ArrayListUnmanaged(PoseProperty)) !bool {
    const animatable = @field(animatable_fields, @tagName(family));
    inline for (@typeInfo(@TypeOf(request)).@"struct".fields) |field| {
        if (comptime isAddress(field.name)) continue;
        if (@field(request, field.name)) |value| {
            const keyable = comptime for (animatable) |name| {
                if (std.mem.eql(u8, name, field.name)) break true;
            } else false;
            if (!keyable) return false;
            try rows.append(allocator, .{ .family = family, .target = target, .field = Atom.from(field.name), .value = propertyValue(value) });
        }
    }
    return true;
}

/// The fields that say which row an edit is for, not what it changes.
fn isAddress(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "doc") or std.mem.eql(u8, name, "request") or std.mem.eql(u8, name, "id");
}
/// Removes `field` of a row from `pose`, or every field of the row with `field` none.
pub const ClearPoseProperty = struct { doc: Atom, request: u32 = 0, pose: u32 = 0, family: PropertyFamily, target: u32, index: u32 = 0, field: Atom = none };
/// Adds a clip called `name`, `frames` frames long at `fps` frames a second, looping when `loop` is
/// nonzero. The result's `created_id` is its id. A clip's id never changes; a key is addressed by
/// its clip and frame.
pub const AddClip = struct { doc: Atom, request: u32 = 0, name: Atom, fps: f32 = 12, frames: u32 = 1, loop: u8 = 1 };
/// Sets the fields given of clip `id`; a null leaves its field as it is.
pub const SetClip = struct { doc: Atom, request: u32 = 0, id: u32, name: ?Atom = null, fps: ?f32 = null, frames: ?u32 = null, loop: ?u8 = null };
/// Deletes clip `id` and its keys. The poses the keys used stay in the document.
pub const DeleteClip = struct { doc: Atom, request: u32 = 0, id: u32 };
/// Copies clip `id` as `name`, a snake_case name no clip has, with its keys, each on a copy of its
/// pose named `<name>_f<frame>`. The result's `created_id` is the new clip's id.
pub const DuplicateClip = struct { doc: Atom, request: u32 = 0, id: u32, name: Atom };
/// Saves the working pose as a new pose, named `<clip's name>_f<frame>`, and keys it at `frame` of
/// `clip`, which must be inside the clip and hold no key. The result's `created_id` is the pose's
/// id.
pub const CaptureClipKey = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32, easing: Atom = Atom.from("linear") };
/// Keys the saved pose `pose` at `frame` of `clip`, which must be inside the clip and hold no key.
/// `easing` is as `read.ClipKey` has it.
pub const AddClipKey = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32, pose: u32, easing: Atom = Atom.from("linear") };
/// Changes the key at `frame` of `clip`: `new_frame` moves it, `pose` gives it another pose,
/// `easing` another easing; a null leaves its field.
pub const SetClipKey = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32, new_frame: ?u32 = null, pose: ?u32 = null, easing: ?Atom = null };
/// Deletes the key at `frame` of `clip`. Its pose stays in the document.
pub const DeleteClipKey = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32 };
/// Makes the key at `frame` last `hold` frames, at least 1, before the next key or the clip's end:
/// later keys move and the clip grows or shrinks by the difference.
pub const SetClipHold = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32, hold: u32 };
/// Copies the working pose over the pose of the key at `frame` of `clip`: what keeps a key up to
/// date as its pose is edited. In a gesture, send it after the working pose's edits.
pub const SyncClipKey = struct { doc: Atom, request: u32 = 0, clip: u32, frame: u32 };
/// What a transaction is for. `edit`: every command in it is validated as it is applied. `gesture`:
/// a drag; it takes `preview` commands, which are not validated one by one (a preview that does not
/// compile leaves the last good figure showing, see `DefinitionInfo.preview_invalid`), and its
/// `commit` validates the document, cancelling the transaction when that fails. A gesture needs a
/// document that is ready.
pub const TransactionKind = enum { edit, gesture };
/// How much undo history the host keeps, across all documents together: `unbounded`, the default,
/// where history grows with every edit until a document closes or memory runs out, or at most
/// `bytes`, the oldest steps going first. The host sets it with the runtime's
/// `setHistoryRetention`.
pub const HistoryRetention = union(enum) { unbounded, bytes: usize };
/// Opens a transaction on `doc`: the commands that follow are one undo step, called `label`, until
/// `commit` keeps them or `cancel` takes them back. One transaction is open at a time across all
/// documents; while it is, commands for other documents, new documents, loads and closes are
/// refused, and so is a save of the document itself.
pub const Begin = struct { doc: Atom, request: u32 = 0, label: Atom = Atom.from("edit"), kind: TransactionKind = .edit };
/// How a `Preview` applies its edits: `absolute` first puts the document back as it was when the
/// gesture began, so each preview stands for the whole drag so far; `incremental` adds them to what
/// earlier previews did.
pub const PreviewMode = enum { absolute, incremental };
/// The commands a `Preview` may carry: edits of one document, never a transaction's own commands or
/// a document's loading, saving or closing. Each variant is the `Payload` command of the same name.
pub const PreviewEdit = union(enum) {
    /// See `SetBone`.
    set_bone: SetBone,
    /// See `SetShape`.
    set_shape: SetShape,
    /// See `SetShapeColor`.
    set_shape_color: SetShapeColor,
    /// See `MoveSelection`.
    move_selection: MoveSelection,
    /// See `DuplicateShapes`.
    duplicate_shapes: DuplicateShapes,
    /// See `SetPoints`.
    set_points: SetPoints,
    /// See `TransformSelection`.
    transform_selection: TransformSelection,
    /// See `SetPoseChannels`.
    set_pose_channels: SetPoseChannels,
    /// See `SetIKTarget`.
    set_ik_target: SetIKTarget,
    /// See `SetPoseProperties`.
    set_pose_properties: SetPoseProperties,
    /// See `SyncClipKey`.
    sync_clip_key: SyncClipKey,
    /// See `PaintWeightsBatch`.
    paint_weights_batch: PaintWeightsBatch,
    /// See `SetLayer`.
    set_layer: SetLayer,
    /// See `Shapes`.
    delete_shapes: Shapes,
};
/// The most edits one `Preview` carries.
pub const max_preview_edits = 2;
/// A drag's change so far, inside a gesture transaction: applies `edits` as `mode` says, without
/// validating the document. Each edit names the preview's `doc` and a `request` of 0. An `absolute`
/// preview with no edits only puts the document back.
pub const Preview = struct { doc: Atom, request: u32 = 0, mode: PreviewMode = .absolute, edits: []const PreviewEdit };

fn finitePreview(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.math.isFinite(value),
        .optional => if (value) |inner| finitePreview(inner) else true,
        .array, .pointer => blk: {
            for (value) |item| if (!finitePreview(item)) break :blk false;
            break :blk true;
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (!finitePreview(@field(value, field.name))) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

/// Checks a preview before it is pushed or applied: `error.InvalidPreview` for more than
/// `max_preview_edits` edits, an `incremental` preview with none, or an edit naming another
/// document or a nonzero request; `error.NonFiniteNumber` for a NaN or an infinity anywhere in an
/// edit; `error.InvalidDab` for a weight batch `validateWeightBatch` refuses.
pub fn validatePreview(preview: Preview) !void {
    if (preview.edits.len > max_preview_edits or (preview.edits.len == 0 and preview.mode == .incremental)) return error.InvalidPreview;
    for (preview.edits) |edit| switch (edit) {
        inline else => |value| {
            if (value.doc != preview.doc or value.request != 0) return error.InvalidPreview;
            if (@TypeOf(value) == PaintWeightsBatch) {
                try validateWeightBatch(value);
            } else if (!finitePreview(value)) return error.NonFiniteNumber;
        },
    };
}
/// A command to the figure system: the request's operation and its values. Every variant names its
/// document as `doc`, the store key (the logical id for the four that open a store: `new_doc`,
/// `load_doc`, `load_sketch`, `new_sketch`), and carries `request`, the requester's number for it.
/// A document's key and a request number identify the request in `figure_requests`, in its `Result`
/// and to a status poll, so a number must not repeat for a document while the host runs. Slices are
/// borrowed until `appendRequest` returns, which copies them. Except for the document and sketch
/// lifecycle and the transaction commands, a command needs its document ready and is refused while
/// another document's transaction is open; applied outside a transaction it is one undo step of its
/// own, and a command that changes nothing adds none.
pub const Payload = union(enum) {
    /// See `NewDoc`.
    new_doc: NewDoc,
    /// See `LoadDoc`.
    load_doc: LoadDoc,
    /// See `SaveDoc`.
    save_doc: SaveDoc,
    /// See `CloseDoc`.
    close_doc: CloseDoc,
    /// See `LoadSketch`.
    load_sketch: LoadSketch,
    /// See `NewSketch`.
    new_sketch: NewSketch,
    /// See `SaveSketch`.
    save_sketch: SaveSketch,
    /// See `CloseSketch`.
    close_sketch: CloseSketch,
    /// See `AddSketchMember`.
    add_sketch_member: AddSketchMember,
    /// See `RenameSketchMember`.
    rename_sketch_member: RenameSketchMember,
    /// See `RemoveSketchMember`.
    remove_sketch_member: RemoveSketchMember,
    /// See `MoveSketchMember`.
    move_sketch_member: MoveSketchMember,
    /// See `AddBone`.
    add_bone: AddBone,
    /// See `SetBone`.
    set_bone: SetBone,
    /// See `DeleteBone`.
    delete_bone: DeleteBone,
    /// See `ReparentBone`.
    reparent_bone: ReparentBone,
    /// See `MirrorBranch`.
    mirror_branch: MirrorBranch,
    /// See `AddLayer`.
    add_layer: AddLayer,
    /// See `GroupLayers`.
    group_layers: GroupLayers,
    /// See `UngroupLayer`.
    ungroup_layer: UngroupLayer,
    /// See `SetLayer`.
    set_layer: SetLayer,
    /// See `DeleteLayer`.
    delete_layer: DeleteLayer,
    /// See `MoveLayer`.
    move_layer: MoveLayer,
    /// See `AddShape`.
    add_shape: AddShape,
    /// See `SetShape`.
    set_shape: SetShape,
    /// Deletes the shapes named; see `Shapes`.
    delete_shapes: Shapes,
    /// See `OrderShapes`.
    order_shapes: OrderShapes,
    /// See `MoveShapes`.
    move_shapes: MoveShapes,
    /// See `SetPoints`.
    set_points: SetPoints,
    /// See `InsertPoint`.
    insert_point: InsertPoint,
    /// See `DeletePoints`.
    delete_points: DeletePoints,
    /// See `TransformSelection`.
    transform_selection: TransformSelection,
    /// See `SetPaint`.
    set_paint: SetPaint,
    /// See `PasteShapes`.
    paste_shapes: PasteShapes,
    /// See `MoveSelection`.
    move_selection: MoveSelection,
    /// See `BindRigid`.
    bind_rigid: BindRigid,
    /// See `BindSkinned`.
    bind_skinned: BindSkinned,
    /// See `Unbind`.
    unbind: Unbind,
    /// See `PaintWeights`.
    paint_weights: PaintWeights,
    /// See `SetWeights`.
    set_weights: SetWeights,
    /// See `SubdivideForDeform`.
    subdivide_for_deform: SubdivideForDeform,
    /// See `SetPoseChannels`.
    set_pose_channels: SetPoseChannels,
    /// See `SetPose`.
    set_pose: SetPose,
    /// See `ResetPose`.
    reset_pose: ResetPose,
    /// See `AddIK`.
    add_ik: AddIK,
    /// See `SetIK`.
    set_ik: SetIK,
    /// See `DeleteIK`.
    delete_ik: DeleteIK,
    /// See `SetIKTarget`.
    set_ik_target: SetIKTarget,
    /// Enables a controller pinned where its chain's end is; see `PinIK`.
    pin_ik: PinIK,
    /// Writes a controller's solved chain into the pose and disables it; see `PinIK`.
    unpin_ik: PinIK,
    /// See `SavePose`.
    save_pose: SavePose,
    /// See `NamePose`.
    name_pose: NamePose,
    /// See `ApplyPose`.
    apply_pose: ApplyPose,
    /// See `DeletePose`.
    delete_pose: DeletePose,
    /// See `MirrorPose`.
    mirror_pose: MirrorPose,
    /// See `SetPoseProperties`.
    set_pose_properties: SetPoseProperties,
    /// See `ClearPoseProperty`.
    clear_pose_property: ClearPoseProperty,
    /// See `AddClip`.
    add_clip: AddClip,
    /// See `SetClip`.
    set_clip: SetClip,
    /// See `DeleteClip`.
    delete_clip: DeleteClip,
    /// See `DuplicateClip`.
    duplicate_clip: DuplicateClip,
    /// See `CaptureClipKey`.
    capture_clip_key: CaptureClipKey,
    /// See `AddClipKey`.
    add_clip_key: AddClipKey,
    /// See `SetClipKey`.
    set_clip_key: SetClipKey,
    /// See `DeleteClipKey`.
    delete_clip_key: DeleteClipKey,
    /// See `SetClipHold`.
    set_clip_hold: SetClipHold,
    /// See `SyncClipKey`.
    sync_clip_key: SyncClipKey,
    /// See `Begin`.
    begin: Begin,
    /// Ends the document's transaction, keeping its changes as one undo step. A gesture's is
    /// validated first, and cancelled when it does not validate.
    commit: Doc,
    /// Ends the document's transaction, taking its changes back. Without one open it does nothing.
    cancel: Doc,
    /// Puts the document back as it was when its gesture began, keeping the gesture open.
    preview_reset: Doc,
    /// Takes back the document's latest undo step.
    undo: Doc,
    /// Applies again the step last undone.
    redo: Doc,
    /// See `PaintWeightsBatch`.
    paint_weights_batch: PaintWeightsBatch,
    /// See `DeleteSelection`.
    delete_selection: DeleteSelection,
    /// See `DuplicateShapes`.
    duplicate_shapes: DuplicateShapes,
    /// See `SetShapeColor`.
    set_shape_color: SetShapeColor,
    /// See `Preview`.
    preview: Preview,

    /// The fields that mean the same in every variant that has them, as the document addressed and
    /// the requester's number for it: each is one column of `commands.figure` named for the field,
    /// where any other field is a column of its own variant (`sequencer.Commands`).
    pub const shared_columns = [_][]const u8{ "doc", "request", "clip", "shape", "scope", "member", "path", "editor_open", "discard", "plugin", "direction" };
};
fn jsonValue(comptime T: type, allocator: std.mem.Allocator, atoms: *Atom.Registry, value: std.json.Value) !T {
    if (T == Atom) return if (value == .string) atoms.intern(value.string) else error.ExpectedAtomString;
    // Never read from a command: `decode` overwrites this with the scope the host resolved.
    if (T == ScopeId) return .{ .atom = none, .generation = 0 };
    if (T == Vec2) {
        if (value != .array or value.array.items.len != 2) return error.ExpectedVector;
        return .{ .x = try jsonValue(f32, allocator, atoms, value.array.items[0]), .y = try jsonValue(f32, allocator, atoms, value.array.items[1]) };
    }
    return switch (@typeInfo(T)) {
        .optional => |info| if (value == .null) null else try jsonValue(info.child, allocator, atoms, value),
        .bool => if (value == .bool) value.bool else error.ExpectedBoolean,
        .@"enum" => if (value == .string) std.meta.stringToEnum(T, value.string) orelse error.InvalidEnum else error.ExpectedString,
        .@"union" => |info| blk: {
            if (value != .object or value.object.count() != 1) return error.ExpectedVariant;
            inline for (info.fields) |field| {
                if (value.object.get(field.name)) |inner| {
                    const decoded = try jsonValue(field.type, allocator, atoms, inner);
                    break :blk @unionInit(T, field.name, decoded);
                }
            }
            return error.InvalidVariant;
        },
        .int => if (value == .integer) std.math.cast(T, value.integer) orelse error.InvalidInteger else if (value == .bool and T == u8) @intFromBool(value.bool) else error.ExpectedInteger,
        .float => blk: {
            const n: T = switch (value) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => return error.ExpectedNumber,
            };
            if (!std.math.isFinite(n)) return error.NonFiniteNumber;
            break :blk n;
        },
        .array => |info| blk: {
            if (value != .array or value.array.items.len != info.len) return error.ExpectedArray;
            var out: T = undefined;
            for (value.array.items, 0..) |v, i| out[i] = try jsonValue(info.child, allocator, atoms, v);
            break :blk out;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("command pointers must be slices");
            if (info.child == u8) {
                if (value != .string) return error.ExpectedString;
                break :blk try allocator.dupe(u8, value.string);
            }
            if (value != .array) return error.ExpectedArray;
            const out = try allocator.alloc(info.child, value.array.items.len);
            errdefer allocator.free(out);
            for (out, value.array.items) |*dest, src| dest.* = try jsonValue(info.child, allocator, atoms, src);
            break :blk out;
        },
        .@"struct" => |info| blk: {
            if (value != .object) return error.ExpectedObject;
            var out: T = undefined;
            inline for (info.fields) |field| {
                if (value.object.get(field.name)) |v| @field(out, field.name) = try jsonValue(field.type, allocator, atoms, v) else if (field.default_value_ptr) |p| @field(out, field.name) = @as(*const field.type, @ptrCast(@alignCast(p))).* else return error.MissingField;
            }
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                var known = false;
                inline for (info.fields) |field| if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                    known = true;
                };
                if (!known) return error.UnknownField;
            }
            break :blk out;
        },
        else => @compileError("unsupported command JSON type " ++ @typeName(T)),
    };
}

/// Reads a command from JSON, as the MCP server takes it: an object with `op`, the variant's name,
/// and the variant's fields beside it or under `fields`; a field left out takes its default, an
/// atom is a string, a `Vec2` a pair of numbers, and an optional may be null. `doc` and `request`
/// are the caller's, never read from the JSON, and neither is `scope`, which the host resolved.
/// Atoms are interned in `atoms` and slices allocated in `allocator`, which should be an arena:
/// nothing frees them one by one.
///
/// Errors name what was wrong: `MissingOperation`, `UnknownOperation`, `MissingField`,
/// `UnknownField`, `DuplicateField`, `InvalidDocument` (a `doc` that is not interned),
/// `NonFiniteNumber`, `InvalidPreview` and `InvalidDab` for a preview or weight batch over its
/// limits, and `Expected...`/`Invalid...` for a value of the wrong JSON type or range.
pub fn decode(allocator: std.mem.Allocator, atoms: *Atom.Registry, scope: ScopeId, doc: Atom, request: u32, command: std.json.Value) !Payload {
    if (command != .object) return error.ExpectedObject;
    const op = command.object.get("op") orelse return error.MissingOperation;
    if (op != .string) return error.ExpectedOperation;
    var fields: std.json.ObjectMap = .empty;
    defer fields.deinit(allocator);
    var iterator = command.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "op")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "fields")) {
            if (entry.value_ptr.* != .object) return error.ExpectedObject;
            var nested = entry.value_ptr.object.iterator();
            while (nested.next()) |field| {
                if (fields.contains(field.key_ptr.*) or std.mem.eql(u8, field.key_ptr.*, "doc") or std.mem.eql(u8, field.key_ptr.*, "request")) return error.DuplicateField;
                try fields.put(allocator, field.key_ptr.*, field.value_ptr.*);
            }
        } else {
            if (fields.contains(entry.key_ptr.*) or std.mem.eql(u8, entry.key_ptr.*, "doc") or std.mem.eql(u8, entry.key_ptr.*, "request")) return error.DuplicateField;
            try fields.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    if (std.mem.eql(u8, op.string, "preview")) {
        if (fields.get("edits")) |edits| {
            if (edits != .array) return error.ExpectedArray;
            if (edits.array.items.len > max_preview_edits) return error.InvalidPreview;
        }
    }
    if (std.mem.eql(u8, op.string, "paint_weights_batch")) {
        if (fields.get("dabs")) |dabs| {
            if (dabs != .array) return error.ExpectedArray;
            if (dabs.array.items.len == 0 or dabs.array.items.len > max_weight_batch_dabs) return error.InvalidDab;
            var pairs: usize = 0;
            for (dabs.array.items) |dab| {
                if (dab != .object) return error.ExpectedObject;
                const indices = dab.object.get("indices") orelse return error.MissingField;
                const factors = dab.object.get("factors") orelse return error.MissingField;
                if (indices != .array or factors != .array) return error.ExpectedArray;
                if (indices.array.items.len != factors.array.items.len or indices.array.items.len > max_weight_batch_pairs - pairs) return error.InvalidDab;
                pairs += indices.array.items.len;
            }
        }
        if (fields.get("locked_bones")) |locks| {
            if (locks != .array) return error.ExpectedArray;
            if (locks.array.items.len > max_weight_batch_locks) return error.InvalidDab;
        }
    }
    try fields.put(allocator, "doc", .{ .string = atoms.lookup(doc) orelse return error.InvalidDocument });
    try fields.put(allocator, "request", .{ .integer = request });
    if (fields.contains("scope")) return error.UnknownField;
    inline for (std.meta.fields(Payload)) |variant| if (std.mem.eql(u8, op.string, variant.name)) {
        var value = blk: {
            if (@hasField(variant.type, "scope")) {
                try fields.put(allocator, "scope", .null);
            }
            break :blk try jsonValue(variant.type, allocator, atoms, .{ .object = fields });
        };
        if (@hasField(variant.type, "scope")) value.scope = scope;
        return @unionInit(Payload, variant.name, value);
    };
    return error.UnknownOperation;
}

/// A document's revision number, which goes up with each change to its authored content. A compiled
/// generation and every read say which revision they are of.
pub const Revision = u32;
/// Why a request, a query or a render failed. A request the host refuses or fails maps its reason
/// to one of these; `Result.diagnostic` keeps the reason itself, which is often more exact
/// (`InvalidInput` stands for every reason with no member of its own).
pub const Error = error{
    /// The scope named by the request is closed, closing or replaced.
    StaleScope,
    /// The request needs a process scope: sketches live only there.
    UnsupportedScope,
    /// The figure system is not running, or `commands.figure` does not exist.
    NotInitialized,
    /// No document has that key.
    MissingDefinition,
    /// The document is still loading, or has no compiled generation to read.
    NotReady,
    /// A `DefinitionHandle` that names no document now.
    InvalidHandle,
    /// No room: the request table holds only unfinished requests, or a table or the document limit
    /// is full.
    CapacityExceeded,
    /// An allocation failed.
    OutOfMemory,
    /// A bone id that names no bone.
    MissingBone,
    /// A controller id that names no controller.
    MissingIK,
    /// A pose id that names no saved pose.
    MissingPose,
    /// A clip id that names no clip. Also the status of an instance row whose clip its definition
    /// lacks.
    MissingClip,
    /// The request's values were refused, for a reason the diagnostic names.
    InvalidInput,
    /// A query's or a render's options are out of range, or a runtime request's correlation names
    /// no caller.
    InvalidOptions,
    /// The document has work in flight (a load, a save, a transaction), or its key and request
    /// number are already in use.
    Busy,
    /// Unsaved edits. Nothing in the engine returns it: a close refused for unsaved edits is
    /// `InvalidInput`, its diagnostic `UnsavedChanges`.
    Dirty,
    /// A discard found no loaded or saved content to go back to.
    NoBaseline,
    /// Going back to the loaded or saved content failed. Nothing in the engine returns it.
    BaselineRestoreFailed,
    /// The file could not be read or written: not found, too large, changed on disk, or its
    /// directory is missing.
    IoFailed,
    /// The document's content does not compile; its catalog row's error text says why.
    CompileFailed,
    /// A render needs more than the drawing context's budget leaves it, or an edit more undo
    /// history than retention allows.
    BudgetExceeded,
    /// The authored content is not what a read expects: a shape or paint that is not there, a
    /// broken hierarchy.
    InvalidGeometry,
};
/// An `Error` as a value that means the same in every image: what a publication carries in
/// place of an error, whose values are numbered per image. `none` is no failure; every other
/// value is the member of `Error` of its name, and its number never changes, so a value written
/// by the host reads the same in a plugin built apart from it. `failureOf` makes one and
/// `check` turns it back into the reading image's `Error`.
pub const Failure = enum(u8) {
    none = 0,
    stale_scope = 1,
    unsupported_scope = 2,
    not_initialized = 3,
    missing_definition = 4,
    not_ready = 5,
    invalid_handle = 6,
    capacity_exceeded = 7,
    out_of_memory = 8,
    missing_bone = 9,
    missing_ik = 10,
    missing_pose = 11,
    missing_clip = 12,
    invalid_input = 13,
    invalid_options = 14,
    busy = 15,
    dirty = 16,
    no_baseline = 17,
    baseline_restore_failed = 18,
    io_failed = 19,
    compile_failed = 20,
    budget_exceeded = 21,
    invalid_geometry = 22,

    /// Nothing for `none`, and otherwise the member of `Error` the failure is.
    pub fn check(failure: Failure) Error!void {
        return switch (failure) {
            .none => {},
            .stale_scope => error.StaleScope,
            .unsupported_scope => error.UnsupportedScope,
            .not_initialized => error.NotInitialized,
            .missing_definition => error.MissingDefinition,
            .not_ready => error.NotReady,
            .invalid_handle => error.InvalidHandle,
            .capacity_exceeded => error.CapacityExceeded,
            .out_of_memory => error.OutOfMemory,
            .missing_bone => error.MissingBone,
            .missing_ik => error.MissingIK,
            .missing_pose => error.MissingPose,
            .missing_clip => error.MissingClip,
            .invalid_input => error.InvalidInput,
            .invalid_options => error.InvalidOptions,
            .busy => error.Busy,
            .dirty => error.Dirty,
            .no_baseline => error.NoBaseline,
            .baseline_restore_failed => error.BaselineRestoreFailed,
            .io_failed => error.IoFailed,
            .compile_failed => error.CompileFailed,
            .budget_exceeded => error.BudgetExceeded,
            .invalid_geometry => error.InvalidGeometry,
        };
    }
};
/// `err` as a `Failure`, to cross into another image.
pub fn failureOf(err: Error) Failure {
    return switch (err) {
        error.StaleScope => .stale_scope,
        error.UnsupportedScope => .unsupported_scope,
        error.NotInitialized => .not_initialized,
        error.MissingDefinition => .missing_definition,
        error.NotReady => .not_ready,
        error.InvalidHandle => .invalid_handle,
        error.CapacityExceeded => .capacity_exceeded,
        error.OutOfMemory => .out_of_memory,
        error.MissingBone => .missing_bone,
        error.MissingIK => .missing_ik,
        error.MissingPose => .missing_pose,
        error.MissingClip => .missing_clip,
        error.InvalidInput => .invalid_input,
        error.InvalidOptions => .invalid_options,
        error.Busy => .busy,
        error.Dirty => .dirty,
        error.NoBaseline => .no_baseline,
        error.BaselineRestoreFailed => .baseline_restore_failed,
        error.IoFailed => .io_failed,
        error.CompileFailed => .compile_failed,
        error.BudgetExceeded => .budget_exceeded,
        error.InvalidGeometry => .invalid_geometry,
    };
}

test "every figure error crosses as a failure and back as itself" {
    const members = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(members.len + 1, @typeInfo(Failure).@"enum".fields.len);
    inline for (members) |member| {
        const err = @field(Error, member.name);
        const failure = failureOf(err);
        try std.testing.expect(failure != .none);
        try std.testing.expectError(err, failure.check());
    }
    try Failure.none.check();
}
/// A pose given whole by its caller: what each bone, controller and property takes, by the rows'
/// ids, each row at most once and every number finite. Bones and controllers not listed are as at
/// rest. The slices are borrowed for the call.
pub const CustomInputs = struct { channels: []const PoseChannels = &.{}, ik: []const PoseIK = &.{}, properties: []const PoseProperty = &.{} };
/// Which document a catalog row is, across renames: its catalog table and row with their
/// generations. It only identifies: a handle whose row was removed or reused resolves to nothing
/// (`InvalidHandle`). A load's `Result` gives the handle that releases the load.
pub const DefinitionHandle = struct { table_index: u32, table_generation: u32, row: u32, generation: u32 };
/// A document in the catalog: its handle and what is known of it.
pub const DefinitionEntry = struct { handle: DefinitionHandle, info: DefinitionInfo };
/// What the host knows of one document, as of the call or the publication that made it.
pub const DefinitionInfo = struct {
    /// The document's store key.
    definition: Atom,
    /// Incarnation owning the store; it says whose `definition` key this is.
    scope: ScopeId,
    /// `loading` while its file is read, `failed` when the load failed, else `ready`.
    state: enum { loading, ready, failed },
    /// The revision of its authored content.
    authored_revision: Revision,
    /// The revision of the compiled generation queries and rendering use; null when there is none.
    /// Behind `authored_revision` while a newer revision does not compile.
    effective_revision: ?Revision,
    /// The latest revision that did not compile; null when none failed.
    rejected_revision: ?Revision,
    /// The revision of the content last loaded or saved, which a discard goes back to; null when
    /// there is none.
    baseline_revision: ?Revision,
    /// Whether the editor holds the document open.
    editor_open: bool,
    /// Whether a loader holds it (a load with `editor_open` false).
    runtime_load_held: bool,
    /// 1 while a load, a save or a probe of its file is in flight, else 0.
    pending_io: u32,
    /// Whether it has edits not yet saved.
    dirty: bool,
    /// Whether its history has a step to undo.
    can_undo: bool,
    /// Whether its history has an undone step to redo.
    can_redo: bool,
    /// Whether a transaction is open on it.
    transaction_open: bool,
    /// The open gesture's authored revision could not replace its last-good compile.
    preview_invalid: bool = false,
};
/// A name for a schema of exactly the instance fields. Nothing in the engine registers a schema
/// under it.
pub const instance_schema_name = "mesha.FigureInstance";
/// One instance column: its name, its type, and how the inspector shows it.
pub const InstanceField = struct {
    /// The column's name, which rendering finds it by.
    name: []const u8,
    /// The column's type.
    field_type: Table.FieldType,
    /// How a table view edits the cell.
    view: Table.ViewKind,
};
/// The columns of a figure instance row. Any table may carry them, alongside columns of its own; a
/// registered table (`RuntimeOperation.register_table`) draws each row that names a definition. A
/// missing cell reads as its default: rest pose, time 0, no blend, scale 1, white tint, opacity 1,
/// z 0, unflipped; a row without `position` or `figure_instance_definition` is not drawn. The
/// client owns every cell but `figure_instance_status`, which the Figure system writes.
pub const instance_fields = [_]InstanceField{
    // World units; z is unused, so tables keep their own vec3 positions.
    .{ .name = "position", .field_type = .vec3f, .view = .{ .vector = .{ .components = 3 } } },
    .{ .name = "figure_instance_definition", .field_type = .atom, .view = .atom },
    // Where the definition names a sketch, the member to draw; none or an unknown name draws
    // its first member. Ignored for a figure.
    .{ .name = "figure_instance_member", .field_type = .atom, .view = .atom },
    // A clip name; none or an unknown name poses the rest rig.
    .{ .name = "figure_instance_clip", .field_type = .atom, .view = .atom },
    // Seconds into the clip, wrapped by a looping clip and held at the end of another.
    .{ .name = "figure_instance_time", .field_type = .f32, .view = .{ .float_slider = .{ .min = 0, .max = 60 } } },
    .{ .name = "figure_instance_blend_clip", .field_type = .atom, .view = .atom },
    .{ .name = "figure_instance_blend_time", .field_type = .f32, .view = .{ .float_slider = .{ .min = 0, .max = 60 } } },
    // Weight of the blend clip: 0 shows only the clip, 1 only the blend clip.
    .{ .name = "figure_instance_blend", .field_type = .f32, .view = .{ .float_slider = .{ .min = 0, .max = 1 } } },
    .{ .name = "figure_instance_scale", .field_type = .f32, .view = .{ .float_slider = .{ .min = 0.01, .max = 8 } } },
    // Radians, about the figure's origin.
    .{ .name = "figure_instance_rotation", .field_type = .f32, .view = .{ .float_slider = .{ .min = -std.math.pi, .max = std.math.pi } } },
    .{ .name = "figure_instance_flip", .field_type = .tag, .view = .checkbox },
    .{ .name = "figure_instance_tint", .field_type = .color, .view = .color },
    .{ .name = "figure_instance_opacity", .field_type = .f32, .view = .{ .float_slider = .{ .min = 0, .max = 1 } } },
    // Draw order across every registered table: lower z draws first.
    .{ .name = "figure_instance_z", .field_type = .f32, .view = .{ .float_slider = .{ .min = -1000, .max = 1000 } } },
    // Bumped by the client when the row's latest change is a jump, not motion: drawing between
    // two states of the row then shows the newer rather than passing through the ones between.
    .{ .name = "figure_instance_cut", .field_type = .i32, .view = .int },
    // Written by the Figure system as it draws: none once drawn, `MissingClip` when drawn at rest
    // for a clip its definition lacks, else why the row was not drawn: culled, transparent
    // (opacity 0, how a client hides a row), empty, or an `Error`'s name.
    .{ .name = "figure_instance_status", .field_type = .atom, .view = .atom },
};

/// The type of a table's `position` column: rendering reads either, taking x and y; a table keeps
/// the one it has.
pub const InstancePosition = enum { vec3f, vec2f };

/// Builds in `schema` a schema of exactly the instance fields, `position` as `position` says, for
/// `Schema.addFields` to union into a table's own. It interns the columns' names in `atoms`. The
/// caller deinitializes the schema; on an error it is already deinitialized.
pub fn initInstanceSchema(schema: *Table.Schema, allocator: std.mem.Allocator, atoms: *Atom.Registry, position: InstancePosition) !void {
    try schema.init(allocator, atoms, instance_fields.len);
    errdefer schema.deinit();
    for (instance_fields) |field| {
        try atoms.tryInternAll(&.{field.name});
        const is_position = std.mem.eql(u8, field.name, "position");
        const field_type: Table.FieldType = if (is_position and position == .vec2f) .vec2f else field.field_type;
        const view: Table.ViewKind = if (field_type == .vec2f) .{ .vector = .{ .components = 2 } } else field.view;
        try schema.addFieldTypeFallible(field.name, field_type, field_type.size(), view);
    }
}

/// A clip pose as instance rows carry it. A clip of none, or a name the definition lacks,
/// samples the rest rig.
pub const ClipPose = struct {
    /// The clip, by name; none for the rest rig.
    clip: Atom = none,
    /// Seconds into `clip`, wrapped by a looping clip and held at the end of another. Must be
    /// finite.
    time: f32 = 0,
    /// A second clip to blend toward; none for no blend.
    blend_clip: Atom = none,
    /// Seconds into `blend_clip`.
    blend_time: f32 = 0,
    /// Weight of `blend_clip`, clamped to 0..1.
    blend: f32 = 0,
};
/// What to pose a definition as, for a synchronous query or render. Nothing is created and no
/// clock advances: the caller owns the pose.
pub const Pose = union(enum) {
    /// The rig as authored, no pose applied.
    rest,
    /// The definition's authored working pose (pose ID zero), for editors. Runtime rows never
    /// read it.
    working,
    /// The saved pose of this id; `MissingPose` when there is none.
    saved_pose: u32,
    /// A pose the caller gives whole.
    custom_inputs: CustomInputs,
    /// A clip, or two blended, at a time.
    clip: ClipPose,
};
/// A definition, by its store key, and the pose to show it in.
pub const PosedFigure = struct { definition: Atom, pose: Pose = .rest };
/// Where registered instance rows land on screen: `world_to_screen` maps world units to the drawing
/// context's, and rows whose figure lies wholly outside `visible`, a rectangle in world units, are
/// culled.
pub const View = struct { world_to_screen: math.Affine2f, visible: Bounds };
/// One instance row as the Figure system reads it, each missing cell at its default.
pub const InstanceRow = struct {
    /// A figure, or a sketch whose member `member` is drawn.
    definition: Atom,
    /// The member to draw when `definition` is a sketch; none or an unknown name draws the first.
    member: Atom = none,
    /// The pose, as the row's clip columns give it.
    clip: ClipPose,
    /// Where the figure's origin is, in world units.
    position: Vec2,
    /// The figure's size, 1 as authored.
    scale: f32 = 1,
    /// Radians, about the figure's origin.
    rotation: f32 = 0,
    /// Mirrors the figure left to right, in its own space.
    flip: bool = false,
    /// Multiplies the artwork's colours; its alpha multiplies the opacity.
    tint: Color = .{ 255, 255, 255, 255 },
    /// 0 to 1, clamped; 0 hides the row.
    opacity: f32 = 1,
    /// Draw order across every registered table: lower draws first.
    z: f32 = 0,

    /// The row as a posed figure: its definition in its clip pose.
    pub fn figure(row: InstanceRow) PosedFigure {
        return .{ .definition = row.definition, .pose = .{ .clip = row.clip } };
    }
    /// The figure's space to world units: scale and rotation about the figure's origin, then the
    /// position. The flip is `placement`'s.
    pub fn toWorld(row: InstanceRow) math.Affine2f {
        return math.Affine2f.fromTRS(row.position.x, row.position.y, row.rotation, row.scale, row.scale);
    }
    /// Where rendering puts the row: `toWorld` taken on to the screen by `world_to_screen`, with
    /// the row's flip.
    pub fn placement(row: InstanceRow, world_to_screen: math.Affine2f) Placement {
        return .{ .transform = math.Affine2f.mul(world_to_screen, row.toWorld()), .flip = row.flip };
    }
    /// The row's render options: its tint, its opacity clamped to 0..1, and `reserve`.
    pub fn options(row: InstanceRow, reserve: Reserve) RenderOptions {
        return .{ .tint = row.tint, .opacity = std.math.clamp(row.opacity, 0, 1), .reserve = reserve };
    }
};

/// Why an instance row was or was not drawn, found by drawing a snapshot and written back to the
/// row's `figure_instance_status` later, where its table can be written. `table`, `row` and
/// `generation` name the row; a row since removed or reused is skipped.
pub const InstanceStatus = struct { table: Atom, row: u32, generation: u32, status: Atom };

/// What one pass over the registered tables did: rows `drawn`, rows `culled` (outside the view,
/// transparent or empty), rows `failed` (their status says why), and how much of the drawing budget
/// was `consumed`.
pub const RenderSummary = struct { drawn: u32 = 0, culled: u32 = 0, failed: u32 = 0, consumed: Reserve = .{} };

/// Where a render puts a figure: `transform` takes the figure's space to the drawing context's, and
/// `flip` first mirrors the figure left to right.
pub const Placement = struct { transform: math.Affine2f = .identity, flip: bool = false };
/// Amounts of a drawing context's path budget, field for field what roop's `pathBudget` counts. As
/// a render option: how much to leave unused for the caller's own drawing. As a result: how much a
/// render used.
pub const Reserve = struct { draws: usize = 0, uniforms: usize = 0, gpu_points: usize = 0, shapes: usize = 0, gpu_vertices: usize = 0, cpu_vertices: usize = 0, indirect_draws: usize = 0 };
/// How a render colours a figure. `color_override` replaces every colour's red, green and blue,
/// keeping each one's alpha: a silhouette. `tint` multiplies the colours, its alpha the opacity.
/// `opacity` is 0 to 1, or the render is refused `InvalidOptions`. `reserve` is budget to leave
/// unused.
pub const RenderOptions = struct { color_override: ?[3]u8 = null, tint: Color = .{ 255, 255, 255, 255 }, opacity: f32 = 1, reserve: Reserve = .{} };
/// A render's stats with the evaluation it drew from, for overlays. The caller owns `evaluation`
/// and frees it with `Evaluation.deinit`.
pub const RenderedEvaluation = struct { stats: RenderStats, evaluation: Evaluation };
/// What a render used of the drawing budget, and the revision of the generation it drew.
pub const RenderStats = struct { consumed: Reserve, effective_revision: Revision };
/// A bone as a pose leaves it, in the figure's space: its `world` transform, where it starts
/// (`origin`) and ends (`tip`), its `world_rotation` in radians and its posed `length`, with its
/// `id`, `name` and `parent` id.
pub const EvaluatedBone = struct { id: u32, name: Atom, parent: u32, length: f32, world: math.Affine2f, origin: Vec2, tip: Vec2, world_rotation: f32 };
/// How a controller's solve went: `id` is the controller, `error_distance` how far the solved
/// chain's end is from its target, in the units of the chain's parent space, and `passes` how many
/// iterations the solver took, 0 when it solved in closed form or the target was out of reach.
pub const EvaluatedIK = struct { id: u32, error_distance: f64, passes: u8 };
/// A figure posed: every bone's transform and what made it. A copy in the caller's allocator,
/// pointing at no table or cache; free it with `deinit` and the same allocator, or reset the arena
/// it is in.
pub const Evaluation = struct {
    /// The revision of the generation that was posed.
    effective_revision: Revision,
    /// Every bone, parents before children.
    bones: []const EvaluatedBone,
    /// For each of `bones`, the transform that carries bind space to where the pose puts what
    /// follows the bone.
    skin: []const math.Affine2f,
    /// For each bone, the rotation, position, scale and length the pose came to, IK solved.
    channels: []const PoseChannels,
    /// The controllers that solved.
    ik: []const EvaluatedIK,
    /// Frees the four slices with `allocator`, the one the evaluation was made with.
    pub fn deinit(self: *Evaluation, allocator: std.mem.Allocator) void {
        allocator.free(self.bones);
        allocator.free(self.skin);
        allocator.free(self.channels);
        allocator.free(self.ik);
        self.* = undefined;
    }
};
/// An authoring request and where its result goes: a message at `reply` whose payload is a
/// `Result`. The default `reply` names no inbox, for a sender that waits on nothing and polls or
/// reads tables instead.
pub const Command = struct { payload: Payload, reply: sequencer.ReplyTo = .{} };
/// A command's kind: the tag of its `Payload`.
pub const Operation = std.meta.Tag(Payload);
/// How an authoring request ended: the payload of the message at its `Command.reply`, and what a
/// status poll returns.
pub const Result = struct {
    /// The request's number.
    request: u32,
    /// The store key the request named.
    definition: Atom,
    /// The key the document goes by now, which differs after a Save As.
    current_definition: Atom,
    /// The document's catalog identity when the request ended, never as of a later publication;
    /// null when it holds none, as after a refusal.
    definition_handle: ?DefinitionHandle = null,
    /// NUL-padded, at most 159 bytes; precise domain/Resource failure reason. A longer reason
    /// keeps what precedes its first `: ` (as `id_taken: `), then `…`, then its end, so the
    /// name of the file it ends with survives a long path. An image other than the host's
    /// reads this, never `outcome.failure`: error values are numbered per image.
    diagnostic: [160]u8 = @splat(0),
    /// The command's kind.
    operation: Operation,
    /// The document's revision when the request ended; 0 for a refusal.
    revision: Revision,
    /// The id of what the command made: a bone, a shape, a layer, a paint, a pose, a clip or a
    /// controller. Null for a command that makes nothing.
    created_id: ?u32 = null,
    /// Success, or the failure as an `Error`, which only the host's image may name or compare.
    outcome: union(enum) { success, failure: Error },
};
/// A change of one document's revisions, with the name it had before a rename. Nothing in the
/// engine makes or reads one.
pub const Change = struct { definition: Atom, previous_definition: ?Atom = null, authored_revision: Revision, effective_revision: ?Revision, rejected_revision: ?Revision };
/// The families of rows an outliner lists and a hit names.
pub const ObjectKind = enum { bone, ik, layer, shape, pose, clip };
/// One row of a document: its family and its id.
pub const ObjectId = struct { kind: ObjectKind, id: u32 };
/// One line of an outliner: the row, the row it sits under (a layer's folder, a shape's layer, a
/// bone's parent; null at the top), its name, and whether it shows and is locked once its ancestors
/// are counted in.
pub const OutlinerItem = struct { object: ObjectId, parent: ?ObjectId, name: Atom, visible: bool, locked: bool };
/// What a hit test found. `outline` says a point query touched the shape's contour rather than only
/// its filled interior; rectangle queries leave it false. A `hit_test` query finds shapes and leaves
/// `sub` and `distance` 0.
pub const Hit = struct { object: ObjectId, sub: u32 = 0, distance: f32 = 0, outline: bool = false };
/// An axis-aligned rectangle, `min` its least x and y and `max` its greatest.
pub const Bounds = struct { min: Vec2, max: Vec2 };
/// What to hit: the shapes under `point` within `tolerance`, or with `rectangle` the shapes a
/// marquee touches, when `point` is ignored. All in the figure's space; `tolerance` is 0 or more.
/// Shapes on locked layers count only with `include_locked`; hidden ones never.
pub const HitQuery = struct { point: Vec2 = .{ .x = 0, .y = 0 }, tolerance: f32, rectangle: ?Bounds = null, include_locked: bool = false };
/// A shape's contour as a pose leaves it, as points of a polyline in the figure's space, with the
/// revision it is of. The caller frees `points` with the allocator the query was given.
pub const ShapeGeometry = struct { effective_revision: Revision, points: []const Vec2 };
/// A document's rows as a tree, at `revision`: layers back to front, a folder before the layers in
/// it, each layer followed by its shapes; then the bones, parents before children; then clips,
/// poses and controllers. The caller frees `items`.
pub const Outliner = struct { revision: Revision, items: []const OutlinerItem };
/// The shapes a hit test found, frontmost first, with the revision they are of. The caller frees
/// `items`.
pub const Hits = struct { effective_revision: Revision, items: []const Hit };
/// The authored document as the figure file it would save as (`runtime/figure/file.zig`): rig,
/// artwork, weights, poses and clips, not runtime state. `bytes` are the caller's, in the allocator
/// the read was given.
pub const DefinitionSnapshot = struct { revision: Revision, bytes: []const u8 };

/// Where a shape's paint lies in a pose, for a gradient tool. `start` and `end` are the paint's
/// endpoints as posed, in the figure's space; null when no paint was named. `bind_point` is the
/// query's point carried back to the paint's own space, or to bind space when no paint was named,
/// null without a point; `color` is the paint's colour there, null unless both a paint and a point
/// were given.
pub const PaintMapping = struct {
    /// The revision of the generation that was read.
    effective_revision: u64,
    /// The paint's start as posed.
    start: ?Vec2 = null,
    /// The paint's end as posed.
    end: ?Vec2 = null,
    /// The query's point in the paint's space.
    bind_point: ?Vec2 = null,
    /// The paint's colour at that point.
    color: ?Color = null,
};
/// A shape a drag draws, which `primitivePath` turns into path points.
pub const Primitive = enum { rect, ellipse, line, polygon };

/// A point's skin weights: up to four bones by their ids, and each one's weight. A slot with weight
/// 0 has bone 0.
pub const WeightInfluences = struct { bones: [4]u32 = @splat(0), weights: [4]f32 = @splat(0) };
/// A point of a skinned shape as a pose leaves it: its shape and index, where it is in the figure's
/// space, and its weights.
pub const WeightPoint = struct { shape: u32, index: u32, position: Vec2, influences: WeightInfluences };
/// A place along a skinned shape's contour, between its points, as a pose leaves it, with the
/// weights interpolated there.
pub const WeightSample = struct { position: Vec2, influences: WeightInfluences };
/// A run of a `WeightGeometry`'s `points` or `samples`: `len` of them from `start`.
pub const WeightRange = struct { start: usize, len: usize };
/// One skinned shape of a `WeightGeometry`: its id, which `points` and `samples` are its, whether a
/// weight overlay shows it (`overlay_visible`: a path on a visible layer) and whether a brush may
/// paint it (`brush_eligible`: that layer also unlocked).
pub const WeightShape = struct { id: u32, brush_eligible: bool, overlay_visible: bool, points: WeightRange, samples: WeightRange };
/// How finely a weight read samples the contours.
pub const WeightQuery = struct {
    /// Figure-local tolerance, or device tolerance when sample_transform is supplied.
    tolerance: f32 = 0.25,
    /// The figure's space to the device's, when `tolerance` is in device units.
    sample_transform: ?math.Affine2f = null,
    /// False leaves `samples` empty: the points alone.
    include_samples: bool = true,
};
/// The points and contour samples, in a pose, of every skinned shape that is not itself hidden, for
/// a weight overlay and brush. The caller owns the three slices and frees them with `deinit`.
pub const WeightGeometry = struct {
    /// The revision of the generation that was read.
    effective_revision: u64,
    /// The tolerance the contours were sampled at, in the figure's space.
    tolerance: f32,
    /// The skinned shapes, each naming its runs of the two slices below.
    shapes: []WeightShape,
    /// The shapes' points.
    points: []WeightPoint,
    /// The shapes' contour samples.
    samples: []WeightSample,
    /// Frees the three slices with `allocator`, the one the read was given.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.shapes);
        allocator.free(self.points);
        allocator.free(self.samples);
        self.* = undefined;
    }
};
/// A definition's error and warning text; both empty when it has none. The slices are borrowed
/// from the table the call read; `definitionDiagnostics` says how long they last.
pub const DefinitionDiagnostics = struct { error_text: []const u8 = "", warning_text: []const u8 = "" };

/// A bone of a copied pose: the bone's name and its parent's, its rest values (which a paste
/// checks, value for value, against the rig it lands on) and what the working pose gave it, `mask`
/// saying which values as `read.Channels` does.
pub const PoseClipboardBone = struct {
    /// The bone's name.
    name: Atom = none,
    /// Its parent's name; none for a root.
    parent: Atom = none,
    /// The bone's own `local`.
    rest_local: Vec2 = Vec2{ .x = 0, .y = 0 },
    /// The bone's own rotation.
    rest_rotation: f32 = 0,
    /// The bone's own scale.
    rest_scale: Vec2 = Vec2{ .x = 1, .y = 1 },
    /// The bone's own length.
    rest_length: f32 = 0,
    /// The bone's `read.BoneFlags`.
    flags: u32 = 0,
    /// `read.Channels` bits: which of the four values below the pose set.
    mask: u32 = 0,
    /// The pose's rotation.
    rotation: f32 = 0,
    /// The pose's position.
    local: Vec2 = Vec2{ .x = 0, .y = 0 },
    /// The pose's scale.
    scale: Vec2 = Vec2{ .x = 1, .y = 1 },
    /// The pose's length.
    length: f32 = 0,
};
/// A controller of a copied pose: its name, its end bone's name and its own settings, which a paste
/// checks against the rig it lands on, and the working pose's row for it when `present` is nonzero.
pub const PoseClipboardIK = struct {
    /// The controller's name.
    name: Atom = none,
    /// Its end bone's name.
    end: Atom = none,
    /// Its chain's length.
    chain: u32 = 0,
    /// Its allowed bend.
    bend: i32 = 0,
    /// Its `read.IKFlags`.
    flags: u32 = 0,
    /// Nonzero when the pose had a row for it: the fields below.
    present: u8 = 0,
    /// As `read.PoseIK.target`.
    target: Vec2 = Vec2{ .x = 0, .y = 0 },
    /// As `read.PoseIK.target_rotation`.
    target_rotation: f32 = 0,
    /// As `read.PoseIK.enabled`.
    enabled: u8 = 1,
    /// As `read.PoseIK.pinned`.
    pinned: u8 = 0,
    /// As `read.PoseIK.bend_side`.
    bend_side: i32 = 0,
    /// As `read.PoseIK.pole_angle`.
    pole_angle: f32 = std.math.pi / 2.0,
};

/// A copied working pose, with enough of its rig to paste it onto another figure whose rig matches
/// by name. `capturePoseClipboard` returns it, the slices the caller's; `remapPoseClipboard`
/// borrows it.
pub const PoseClipboard = struct {
    /// Every bone of the rig it was copied from.
    bones: []const PoseClipboardBone,
    /// Every controller of that rig.
    ik: []const PoseClipboardIK,
    /// Frees both slices with `allocator`, the one the capture was given.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.bones);
        allocator.free(self.ik);
        self.* = undefined;
    }
};
/// Why a pose could not be copied or pasted: no memory, a parent or end bone that is not there
/// (`MissingBone`), a name two rows share, a bone or controller the target rig lacks, or a rig
/// whose rest values or settings differ.
pub const PoseClipboardError = error{ OutOfMemory, MissingBone, AmbiguousPoseClipboardName, MissingPoseClipboardBone, MissingPoseClipboardIK, IncompatiblePoseClipboardRig };

/// `figure_catalog`, one row holding the catalog's version. With `figure_definitions` and
/// `figure_observed` it is what the figure host publishes of its committed documents, which
/// systems read and follow by version: versions refer to committed state and start at 1, and a
/// reader keeps the version it last followed.
pub const catalog_table_name = "figure_catalog";
/// The one row of `figure_catalog`: `version` moves whenever the set of documents or any one's
/// `DefinitionInfo` changes.
pub const CatalogView = struct { version: *u64 };
/// `figure_observed`, a row per document name the host follows across renames; see `ObservedView`.
pub const observed_table_name = "figure_observed";
/// A row of `figure_observed`.
pub const ObservedView = struct {
    /// The name followed.
    requested: *Atom,
    /// The name it goes by now, after any rename.
    definition: *Atom,
    /// The name it went by before its latest rename, or none.
    previous: *Atom,
    /// Whether a definition goes by it now; `handle` says which incarnation.
    present: *bool,
    /// The catalog identity of the document that goes by it; meaningful while `present`.
    handle: *DefinitionHandle,
    /// The version of its latest change.
    version: *u64,
};

/// `figure_definitions`, a row per document the host holds: what is known of it and its error and
/// warning text (`DefinitionsView`). The host writes it as it publishes `figure_catalog`, after it
/// applies the frame's commands, and removes the row of a document it no longer holds. Read it
/// with `listDefinitions`, `definitionInfo`, `resolveDefinition` and `definitionDiagnostics`.
pub const definitions_table_name = "figure_definitions";
/// A row of `figure_definitions`.
pub const DefinitionsView = struct {
    /// The document's store key.
    definition: *Atom,
    /// Which catalog row the document is; a row of this table is found by it across renames.
    handle: *DefinitionHandle,
    /// What the host knew of the document at its latest publication.
    info: *DefinitionInfo,
    /// Why its latest revision does not compile or load, in this table's payloads; empty when
    /// nothing failed.
    error_text: *Table.String,
    /// What its compile warned of, in this table's payloads; empty when nothing did.
    warning_text: *Table.String,
    /// Its file, in this table's payloads: the one it was read from or last saved to, or the one
    /// it was made to be saved to (`NewDoc.path`); empty when it has none.
    path: *Table.String,
};

fn definitionsTable(context: Context) Error!*Table {
    const name = Atom.from(definitions_table_name);
    return context.tables.findByName(name) orelse error.NotInitialized;
}

/// The row of `definitions` for the document `definition`; null when the host holds none by it.
fn definitionRow(definitions: *Table, definition: Atom) ?DefinitionsView {
    var rows = definitions.query(DefinitionsView);
    while (rows.next()) |row| {
        if (row.view.definition.* == definition) return row.view;
    }
    return null;
}

/// Every document the host held at its latest publication, in the order of `figure_definitions`.
/// The caller owns the slice. `NotInitialized` before the host made the table.
pub fn listDefinitions(context: Context, allocator: std.mem.Allocator) Error![]DefinitionEntry {
    const definitions = try definitionsTable(context);
    const entries = try allocator.alloc(DefinitionEntry, definitions.liveCount());
    errdefer allocator.free(entries);
    var rows = definitions.query(DefinitionsView);
    var index: usize = 0;
    while (rows.next()) |row| {
        entries[index] = .{ .handle = row.view.handle.*, .info = row.view.info.* };
        index += 1;
    }
    return entries[0..index];
}

/// What the host knew of the document `definition` at its latest publication. `MissingDefinition`
/// when it held none by that key, `NotInitialized` before it made `figure_definitions`.
pub fn definitionInfo(context: Context, definition: Atom) Error!DefinitionInfo {
    const definitions = try definitionsTable(context);
    const row = definitionRow(definitions, definition) orelse return error.MissingDefinition;
    return row.info.*;
}

/// The key the document `handle` names went by at the host's latest publication, after any rename.
/// `InvalidHandle` when no document it held is that one, `NotInitialized` before it made
/// `figure_definitions`.
pub fn resolveDefinition(context: Context, handle: DefinitionHandle) Error!Atom {
    const definitions = try definitionsTable(context);
    var rows = definitions.query(DefinitionsView);
    while (rows.next()) |row| {
        if (std.meta.eql(row.view.handle.*, handle)) return row.view.definition.*;
    }
    return error.InvalidHandle;
}

/// The document `definition`'s error and warning text at the host's latest publication. The slices
/// are `figure_definitions`' payloads, valid until the host next publishes. `MissingDefinition`
/// when it held none by that key, `NotInitialized` before it made the table.
pub fn definitionDiagnostics(context: Context, definition: Atom) Error!DefinitionDiagnostics {
    const definitions = try definitionsTable(context);
    const row = definitionRow(definitions, definition) orelse return error.MissingDefinition;
    const error_text = definitions.textOf(row.error_text.*);
    const warning_text = definitions.textOf(row.warning_text.*);
    return .{ .error_text = error_text, .warning_text = warning_text };
}

/// The document `definition`'s file at the host's latest publication (`DefinitionsView.path`):
/// empty when it has none. The slice is `figure_definitions`' payload, valid until the host next
/// publishes. `MissingDefinition` when it held none by that key, `NotInitialized` before it made
/// the table.
pub fn definitionPath(context: Context, definition: Atom) Error![]const u8 {
    const definitions = try definitionsTable(context);
    const row = definitionRow(definitions, definition) orelse return error.MissingDefinition;
    return definitions.textOf(row.path.*);
}

/// The authoring families' table names, by family. Each open document has its own table under
/// each, so a name selects a table only together with a document (Table RPC's `doc`). Figure
/// files and published tables keep these strings.
pub const family_table_names = struct {
    /// A row per bone (`read.Bone`).
    pub const bones = "figure_bones";
    /// A row per layer or folder (`read.Layer`).
    pub const layers = "figure_layers";
    /// A row per shape (`read.Shape`).
    pub const shapes = "figure_shapes";
    /// A row per path point (`read.Point`).
    pub const points = "figure_points";
    /// A row per gradient (`read.Paint`).
    pub const paints = "figure_paints";
    /// A row per IK controller (`read.IK`).
    pub const ik = "figure_ik";
    /// A row per saved pose (`read.Pose`).
    pub const poses = "figure_poses";
    /// A row per bone a pose gives values (`read.PoseChannel`).
    pub const pose_channels = "figure_pose_channels";
    /// A row per controller a pose gives a target (`read.PoseIK`).
    pub const pose_ik = "figure_pose_ik";
    /// A row per property value a pose gives (`read.PoseProperty`).
    pub const pose_properties = "figure_pose_properties";
    /// A row per clip (`read.Clip`).
    pub const clips = "figure_clips";
    /// A row per clip key (`read.ClipKey`).
    pub const clip_keys = "figure_clip_keys";
    /// Chunks of bytes kept with a document, a row each of up to 1024. Nothing in the engine fills
    /// it.
    pub const passthrough = "figure_passthrough";
};
/// Each document's bone transforms in its working pose, a row per bone with its origin, tip and
/// rotation, for inspection: a table per document, like the families'.
pub const bone_world_table_name = "figure_bone_world";
/// Every name that selects a table only together with a document: the families' and the bone
/// world's.
pub const document_table_names = names: {
    const families = @typeInfo(family_table_names).@"struct".decls;
    var names: [families.len + 1][]const u8 = undefined;
    for (families, 0..) |family, index| names[index] = @field(family_table_names, family.name);
    names[families.len] = bone_world_table_name;
    break :names names;
};
/// Names that select a table only together with a document, so tooling must not offer them
/// as ordinary table names. Resolving one to a table is host-side inspection, not client API.
pub fn isDocumentTableName(name: []const u8) bool {
    for (document_table_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

test {
    _ = read;
    _ = paths;
    _ = pose_clipboard;
    _ = drawing;
    _ = watch;
    _ = query;
}

test "the reserved figure document table names are recognized" {
    const reserved = [_][]const u8{ "figure_bones", "figure_layers", "figure_shapes", "figure_points", "figure_paints", "figure_ik", "figure_poses", "figure_pose_channels", "figure_pose_ik", "figure_pose_properties", "figure_clips", "figure_clip_keys", "figure_passthrough", "figure_bone_world" };
    try std.testing.expectEqual(reserved.len, document_table_names.len);
    for (reserved) |name| try std.testing.expect(isDocumentTableName(name));
    for ([_][]const u8{ "figure_", "figure_unknown", "figure_bonesx", "figure_bone_world_", "figure_documents", "" }) |near_miss| {
        try std.testing.expect(!isDocumentTableName(near_miss));
    }
}

/// What a runtime request asks: a change to loads' holds or to which tables are drawn. It edits no
/// document and adds no undo step.
pub const RuntimeOperation = union(enum) {
    /// Ends the loader's hold a load with `editor_open` false took, by the handle its `Result`
    /// gave. The document is unloaded once nothing else holds it: not the editor, a load or save in
    /// flight, or, outside a process scope, unsaved edits. `InvalidHandle` for a handle that names
    /// no document; `Busy` when the release fails otherwise.
    release_loaded_definition: struct { definition: DefinitionHandle },
    /// Drops the loader's hold on a sketch and on its members' figures.
    release_loaded_sketch: struct { sketch: Atom },
    /// Draws the named table's instance rows in every render pass until unregistered. Its rows
    /// name definitions by logical id, loaded in `scope`; null is the application scope.
    /// Registering a name again replaces its scope; the table need not exist yet.
    register_table: struct { table: Atom, scope: ?ScopeId = null },
    /// Stops drawing the named table's rows. A name that is not registered is not an error.
    unregister_table: struct { table: Atom },
    /// The plugin `plugin` is gone: drops every loader's hold its figure and sketch loads put
    /// on a document and it has not released, in flight or installed and unread, since it has
    /// no handle to release them by. The host appends it when a plugin's row goes, and when its
    /// init fails, after the plugin's own `plugin_deinit` requests, so what the plugin released
    /// itself is not released twice; a library rebuilt in place keeps its holds. A load counts
    /// as the plugin's by `LoadDoc.plugin` and `LoadSketch.plugin`, the plugin whose directory
    /// the file is in, not by which plugin asked: a load by `path`, or one naming another
    /// plugin, is not released with it.
    release_plugin_loads: struct { plugin: Atom },
};
/// A runtime request's kind: the tag of its `RuntimeOperation`.
pub const RuntimeOperationTag = std.meta.Tag(RuntimeOperation);
/// A runtime request's identity: `caller`, an atom the requester chooses for itself and never none,
/// and its `request` number, which must not repeat for that caller while the host keeps the earlier
/// request's result.
pub const RuntimeRequestId = struct { caller: Atom, request: u32 };
/// A runtime request's number, and where its result goes, a message whose payload is a
/// `RuntimeResult`.
pub const RuntimeCorrelation = struct { id: RuntimeRequestId, reply: sequencer.ReplyTo = .{} };
/// A runtime request: what it asks, and whether anyone hears how it ended.
pub const RuntimeCommand = struct {
    /// What it asks.
    operation: RuntimeOperation,
    /// Null is fire-and-forget: no durable request row.
    correlation: ?RuntimeCorrelation = null,
};
/// One request to the figure host system, a row of `commands.figure`.
pub const HostRequest = union(enum) { authoring: Command, runtime: RuntimeCommand };
/// The figure host system's command table, which a caller pushes requests to.
pub const commands_table_name = "commands.figure";
/// `commands.figure` as a typed command table of `HostRequest` rows; `appendRequest` and
/// `appendRuntimeRequest` push to it.
pub const Requests = sequencer.Commands(HostRequest);
/// Room for the name of any `Error` and the zero that ends it.
pub const failure_name_capacity = longest: {
    var longest: usize = 0;
    for (@typeInfo(Error).error_set.?) |field| longest = @max(longest, field.name.len);
    break :longest longest + 1;
};
/// How a correlated runtime request ended: the payload of the message at its
/// `RuntimeCorrelation.reply`, and what a status poll returns.
pub const RuntimeResult = struct {
    /// The request's identity.
    id: RuntimeRequestId,
    /// The request's kind.
    operation: RuntimeOperationTag,
    /// Only the host's image may name or compare `failure`: error values are numbered per
    /// image, so another image reads `failure_name`.
    outcome: union(enum) { success, failure: Error },
    /// The failure's error name, NUL-padded, which the host fills in; empty on success.
    failure_name: [failure_name_capacity]u8 = @splat(0),
};
/// Where a correlated runtime request is: `pending` while it waits in `commands.figure`, then
/// `completed` with its result. The runtime's `runtimeRequestStatus` reads it.
pub const RuntimeRequestStatus = union(enum) { pending, completed: RuntimeResult };

/// Which way an IK chain bends. `side` is the sign of the cross product of the chain's start to its
/// target and its start to its middle joint: positive is counter-clockwise, not left on screen.
/// `pole_angle` is the direction from the start to that joint, in radians. Both are in the space
/// the chain is solved in, its parent's.
pub const BendReference = struct { side: enum { negative, positive } = .positive, pole_angle: f64 = std.math.pi / 2.0 };
/// What a `solve_transient_pose` query asks: how a chain of bones would turn to reach a
/// point, without a controller and without changing the document. It is what dragging a bone's tip
/// asks.
pub const TransientPoseQuery = struct {
    /// The pose to start from. A chain bone may not be in the chain of a controller these inputs
    /// enable.
    inputs: CustomInputs,
    /// Eligible bone IDs in root-to-tip order. Boundaries/conflicts are rejected.
    chain: []const u32,
    /// Where the chain's end should reach, in the figure's space.
    target: Vec2,
    /// The bend to keep; null infers it from the starting pose.
    reference: ?BendReference = null,
};
/// The answer: a rotation for each bone of the chain. The caller owns `channels` and frees them
/// with `deinit`.
pub const TransientPoseSolution = struct {
    /// A channel for each bone of the chain, in the chain's order, only its rotation set.
    channels: []const PoseChannels,
    /// The bend the solve took.
    reference: BendReference,
    /// Where the chain's end came to, in the figure's space.
    endpoint: Vec2,
    /// Actual document-space endpoint residual after FK reconstruction.
    error_distance: f64,
    /// Frees `channels` with `allocator`, the one the query was given.
    pub fn deinit(self: *TransientPoseSolution, allocator: std.mem.Allocator) void {
        allocator.free(self.channels);
        self.* = undefined;
    }
};

/// What a figure call works over: the host's memory, its tables and its atoms. All three outlive
/// the call; none is owned.
pub const Context = struct {
    /// The engine's memory, where the figure system keeps its state.
    memory: *@import("../core/memory.zig").Memory,
    /// The table registry that holds the figure tables and `commands.figure`.
    tables: *@import("../core/table.zig").Registry,
    /// The atom registry names are interned in.
    atoms: *Atom.Registry,
};

test "figure evaluation snapshot uses caller allocator" {
    const a = std.testing.allocator;
    var snapshot: Evaluation = .{
        .effective_revision = 7,
        .bones = try a.alloc(EvaluatedBone, 1),
        .skin = try a.alloc(std.meta.Elem(@FieldType(Evaluation, "skin")), 0),
        .channels = try a.alloc(PoseChannels, 0),
        .ik = try a.alloc(EvaluatedIK, 0),
    };
    snapshot.deinit(a);
}

test "figure typed read DTOs stay value-only" {
    inline for (.{ read.Bone, read.Shape, read.Point, read.PoseChannel, read.ClipKey }) |T| {
        inline for (std.meta.fields(T)) |field| try std.testing.expect(@typeInfo(field.type) != .pointer);
    }
    try std.testing.expect(!@hasField(read.Bone, "doc"));
}

/// Whether layer `id` of `data` may be edited: it, and each folder above it, is visible, unlocked
/// and has an opacity above 0. False for an id that names no layer of `data`, and true for 0, which
/// is no layer. It reads only `data`, a copy the caller holds.
pub fn editableLayer(data: read.Definition, id: u32) bool {
    var current = id;
    var depth: usize = 0;
    while (current != 0 and depth <= data.layers.len) : (depth += 1) {
        var found = false;
        for (data.layers) |layer| {
            if (layer.id != current) continue;
            if (layer.visible == 0 or layer.locked != 0 or layer.opacity <= 0) return false;
            current = layer.parent;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return current == 0;
}

test "editableLayer copied snapshot inherits visibility lock and opacity" {
    var layers = [_]read.Layer{ .{ .id = 1 }, .{ .id = 2, .parent = 1 } };
    var data = std.mem.zeroes(read.Definition);
    data.layers = &layers;
    try std.testing.expect(editableLayer(data, 2));
    layers[0].locked = 1;
    try std.testing.expect(!editableLayer(data, 2));
    layers[0].locked = 0;
    layers[0].visible = 0;
    try std.testing.expect(!editableLayer(data, 2));
    layers[0].visible = 1;
    layers[0].opacity = 0;
    try std.testing.expect(!editableLayer(data, 2));
    layers[0].opacity = 1;
    layers[0].parent = 2;
    try std.testing.expect(!editableLayer(data, 2));
    try std.testing.expect(!editableLayer(data, 99));
}

/// What refuses a request before it is pushed: an invalid payload, no `commands.figure`
/// (`NotInitialized`), or no room for its row. The host refuses others when it applies it.
pub const AppendError = error{ InvalidInput, NotInitialized, OutOfMemory };
/// As `AppendError`, for a runtime request; `InvalidOptions` is a correlation naming no caller.
pub const AppendRuntimeError = error{ InvalidOptions, NotInitialized, OutOfMemory };

/// Validates a request and appends it to `commands.figure`, copying its slices. The figure host
/// system admits it when it applies the row, after the frame's run; a request it refuses then is
/// answered with a failure `Result`, keeps no row in `figure_requests` and one in
/// `figure_refusals`, where a status poll finds it. A kernel may call it when its system declares
/// `commands.figure` written.
pub fn appendRequest(context: Context, command: Command) AppendError!void {
    switch (command.payload) {
        .paint_weights_batch => |batch| validateWeightBatch(batch) catch return error.InvalidInput,
        .preview => |preview| validatePreview(preview) catch return error.InvalidInput,
        .load_doc => |load| validateLoadSource(load.doc, load.plugin, load.path, resources_api.figure_document_extension) catch return error.InvalidInput,
        .load_sketch => |load| validateLoadSource(load.doc, load.plugin, load.path, resources_api.sketch_document_extension) catch return error.InvalidInput,
        .new_doc => |new| validateNewPath(new.doc, new.path, resources_api.figure_document_extension) catch return error.InvalidInput,
        .new_sketch => |new| validateNewPath(new.doc, new.path, resources_api.sketch_document_extension) catch return error.InvalidInput,
        else => {},
    }
    const request_rows = Requests.of(context.memory, context.tables, commands_table_name);
    request_rows.tryPush(.{ .authoring = command }) catch |err| return appendError(err);
}

/// As `appendRequest`, for a runtime request, whose refusal is answered with a failure
/// `RuntimeResult`, or logged when it asked for none. Runtime requests are rows of the same table,
/// applied in order with the authoring ones.
pub fn appendRuntimeRequest(context: Context, command: RuntimeCommand) AppendRuntimeError!void {
    if (command.correlation) |correlation| {
        if (correlation.id.caller == none) return error.InvalidOptions;
    }
    const request_rows = Requests.of(context.memory, context.tables, commands_table_name);
    request_rows.tryPush(.{ .runtime = command }) catch |err| return appendError(err);
}

/// A load names its file by `path` or by `plugin`, not both; a path's name is `doc`'s with
/// `extension`. Atoms hash their text, so `doc` is compared without the registry.
fn validateLoadSource(doc: Atom, plugin: Atom, path: ?[]const u8, extension: []const u8) error{InvalidLoadSource}!void {
    const file_path = path orelse return;
    if (plugin != none) return error.InvalidLoadSource;
    const name = std.fs.path.basename(file_path);
    if (!std.mem.endsWith(u8, name, extension)) return error.InvalidLoadSource;
    const stem = name[0 .. name.len - extension.len];
    if (stem.len == 0 or Atom.from(stem) != doc) return error.InvalidLoadSource;
}

/// A new document's file, when it names one, is absolute, named `doc`'s with `extension` and
/// shorter than `resources.max_path`.
fn validateNewPath(doc: Atom, path: ?[]const u8, extension: []const u8) error{ InvalidLoadSource, NameTooLong, NotAbsolute }!void {
    const file_path = path orelse return;
    if (file_path.len >= resources_api.max_path) return error.NameTooLong;
    if (!resources_api.isAbsolutePath(file_path)) return error.NotAbsolute;
    try validateLoadSource(doc, none, file_path, extension);
}

test "a new document's path is absolute, of its stem and extension" {
    const fresh = Atom.from("fresh");
    const extension = resources_api.figure_document_extension;
    try validateNewPath(fresh, null, extension);
    try validateNewPath(fresh, "/x/fresh.mshf", extension);
    try validateNewPath(fresh, "C:/x/fresh.mshf", extension);
    try std.testing.expectError(error.NotAbsolute, validateNewPath(fresh, "fresh.mshf", extension));
    try std.testing.expectError(error.InvalidLoadSource, validateNewPath(fresh, "/x/other.mshf", extension));
}

test "a load naming both a plugin and a path, or a path of another stem, is refused" {
    const memory_mod = @import("../core/memory.zig");
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 8);
    defer tables.deinit();
    try Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, commands_table_name);
    const context: Context = .{ .memory = &memory, .tables = &tables, .atoms = &atoms };
    const scope = applicationScope(&memory);
    const blue = Atom.from("blue");
    const demo = Atom.from("demo");

    try appendRequest(context, .{ .payload = .{ .load_doc = .{ .scope = scope, .doc = blue } } });
    try appendRequest(context, .{ .payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .plugin = demo } } });
    try appendRequest(context, .{ .payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .path = "art/blue.mshf" } } });
    try appendRequest(context, .{ .payload = .{ .load_sketch = .{ .scope = scope, .doc = blue, .path = "/home/someone/blue.mshs" } } });
    const both: Payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .plugin = demo, .path = "art/blue.mshf" } };
    try std.testing.expectError(error.InvalidInput, appendRequest(context, .{ .payload = both }));
    const other_stem: Payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .path = "art/red.mshf" } };
    try std.testing.expectError(error.InvalidInput, appendRequest(context, .{ .payload = other_stem }));
    const sketch_as_figure: Payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .path = "art/blue.mshs" } };
    try std.testing.expectError(error.InvalidInput, appendRequest(context, .{ .payload = sketch_as_figure }));
    const figure_as_sketch: Payload = .{ .load_sketch = .{ .scope = scope, .doc = blue, .path = "art/blue.mshf" } };
    try std.testing.expectError(error.InvalidInput, appendRequest(context, .{ .payload = figure_as_sketch }));
    const no_stem: Payload = .{ .load_doc = .{ .scope = scope, .doc = blue, .path = "art/.mshf" } };
    try std.testing.expectError(error.InvalidInput, appendRequest(context, .{ .payload = no_stem }));
    // Only the four admitted loads were pushed.
    const rows = Requests.of(&memory, &tables, commands_table_name);
    try std.testing.expectEqual(@as(u32, 4), rows.count());
}

fn appendError(err: anyerror) error{ NotInitialized, OutOfMemory } {
    return switch (err) {
        error.MissingTable => error.NotInitialized,
        else => error.OutOfMemory,
    };
}
