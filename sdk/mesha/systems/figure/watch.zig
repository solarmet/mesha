//! Watches: how a system reads a posed figure every frame without calling into the host. A
//! system's kernel appends a `Watch` to `subscriptions.figure` (`Watches`) each run, naming a
//! definition, a pose and what it wants of it; the figure host answers every watch each time it
//! synchronizes, after it applies the frame's commands, with a row of `figure_published`
//! (`Published`), which the system reads back with `published`. So a kernel reads, as of the
//! previous frame's commands, what it watched in its previous run.
//!
//! The host publishes only a change: when every watch is what it was at its latest publication
//! (the same values, its slices' contents included, of the same subscribers) and nothing it
//! answers from moved (the catalog's version, and each watched definition's authored and
//! effective revisions), it leaves `figure_published` and the memory its rows point at as they
//! are, and does not touch the table.
//!
//! A watch is the subscriber's standing wish: its rows last until its system runs again or is
//! switched off, and a system that stops appending one stops being answered. After the
//! subscriptions are reset, as when a plugin loads, a subscriber that has not run since keeps its
//! answers, answered again from what it last watched; one that has run, or was retired, has only
//! what it appended since.
const std = @import("std");
const Atom = @import("../../core/atom.zig").Atom;
const Table = @import("../../core/table.zig");
const sequencer = @import("../../core/sequencer.zig");
const figure = @import("../figure.zig");

/// `subscriptions.figure`, the table of `Watch` rows the figure host answers.
pub const watches_table_name = "subscriptions.figure";
/// The table of watches: a row per watch, its slices copied into the table's payloads, and the
/// sequencer names its subscriber, the system whose run appended it.
pub const Watches = sequencer.Subscribed(Watch);

/// What a watch asks the host to publish; each is computed only when asked for.
pub const Wants = struct {
    /// The authored document, as `Published.content`.
    definition: bool = false,
    /// The pose's bones, as `Published.evaluation`.
    evaluation: bool = false,
    /// The pose prepared for drawing, as `Published.drawing`.
    drawing: bool = false,
    /// The figure's extent over its rest pose and saved poses, as `Published.bounds`.
    bounds: bool = false,
    /// The skinned shapes' points and samples in the pose, as `Published.weights`.
    weights: bool = false,
    /// The contours of `Watch.contours` in the pose, as `Published.contours`.
    contours: bool = false,
};

/// A row of `subscriptions.figure`: a definition in a pose, and what its subscriber wants of it.
/// Its slices are copied into the table when it is appended; the subscriber's own may go after.
pub const Watch = struct {
    /// The subscriber's own number for the watch, which `published` finds its answer by. Distinct
    /// among one subscriber's watches; two subscribers may use the same.
    key: u32,
    /// The definition's store key.
    definition: Atom,
    /// What to pose it as.
    pose: figure.Pose = .rest,
    /// What to publish.
    wants: Wants = .{},
    /// What the drawing is prepared for: the transform it will be drawn under and the context's
    /// tolerances (`Drawing`). The drawing places the figure at its origin, unflipped.
    draw: figure.DrawParams = .{},
    /// How the drawing colours the figure. Its `reserve` is ignored: `figure.draw` takes the
    /// reserve where the drawing is drawn.
    options: figure.RenderOptions = .{},
    /// How finely the weights are sampled.
    weight: figure.WeightQuery = .{},
    /// The shapes, by id, whose contours to publish, in the order `Published.contours` gives
    /// them.
    contours: []const u32 = &.{},
    /// How far a contour may stray from the shape's true outline, in the figure's space. 0 or
    /// more.
    contour_tolerance: f32 = 0.25,
};

/// `figure_published`, a row per watch the figure host answered at its latest publication:
/// `subscriber`, `key` and the `Published` answer. The host replaces every row each time it
/// publishes a change, and leaves them as they are otherwise.
pub const published_table_name = "figure_published";

/// A row of `figure_published`.
pub const PublishedView = struct {
    /// The system whose watch the row answers.
    subscriber: *Atom,
    /// The watch's `key`.
    key: *u32,
    /// The answer.
    published: *Published,
};

/// What the figure host published for one watch. Everything it points at is the host's memory,
/// valid until the host next publishes a change (at the earliest after it applies the next
/// frame's commands; a publication that would change nothing is skipped and leaves it valid):
/// a kernel copies what it keeps past its run, and never frees or writes any of it.
///
/// The content stands apart from the rest: it is the authored document whenever the host holds
/// it and it was asked for, whether or not any generation compiled and whether or not the pose
/// evaluates. `failure` is about the rest. When it is not `none`, everything but `content` is
/// null or empty, and `content` is null too only when the document itself could not be read, as
/// for `missing_definition`. So `content` set with `failure` set reads "the content is here, the
/// rest failed". Otherwise each pointer is set when its want was asked for, and null or empty
/// when it was not.
pub const Published = struct {
    /// The system whose watch this answers.
    subscriber: Atom,
    /// The watch's `key`.
    key: u32,
    /// The watch's definition.
    definition: Atom,
    /// Why what was asked for is not here: `missing_definition` for a definition the host does
    /// not hold (no content either), the content's own failure (no content), or, with the
    /// content still here, `not_ready` for a definition with no compiled generation, a pose's
    /// failure (`missing_pose`, `invalid_input`, ...), or that of the evaluation, the bounds or
    /// the weights. `none` when everything asked for but the drawing is here.
    failure: figure.Failure,
    /// The revision of the compiled generation everything but `content` is of: the last one
    /// that compiled, which stays behind the authored revision while a newer one does not. 0
    /// when `failure` is not `none`, and when only the content was asked for.
    revision: figure.Revision,
    /// The authored document as it stands, at its own `revision`, which is ahead of `revision`
    /// while the authored one does not compile; here though no generation ever compiled or the
    /// pose failed (see `failure`).
    content: ?*const figure.read.Definition = null,
    /// The pose's bones.
    evaluation: ?*const figure.Evaluation = null,
    /// The pose prepared for drawing with the watch's `draw` and `options`; null as well when
    /// it could not be prepared, which `drawing_failure` says why.
    drawing: ?*const figure.Drawing = null,
    /// Why the drawing could not be prepared (`invalid_options` for options or parameters out of
    /// range, ...); `none` when it was or was not asked for.
    drawing_failure: figure.Failure = .none,
    /// The figure's extent over its rest pose and saved poses; null as well for a figure that
    /// draws nothing in any pose.
    bounds: ?figure.Bounds = null,
    /// The skinned shapes' points and contour samples in the pose.
    weights: ?*const figure.WeightGeometry = null,
    /// A contour per id of the watch's `contours`, in that order; a shape the definition does
    /// not have, or whose contour cannot be read, has no points.
    contours: []const figure.ShapeGeometry = &.{},
};

/// The answer to `subscriber`'s watch `key` at the host's latest publication; null when there is
/// none, as before the host first answers a watch or after its subscriber dropped it, or without
/// `figure_published`. A kernel that calls it declares `figure_published` read. What the answer
/// points at is valid until the host next publishes a change.
pub fn published(tables: *Table.Registry, subscriber: Atom, key: u32) ?Published {
    const found = tables.findByName(Atom.from(published_table_name)) orelse return null;
    var rows = found.readQuery(PublishedView);
    while (rows.next()) |row| {
        const same_subscriber = row.view.subscriber.* == subscriber;
        const same_key = row.view.key.* == key;
        if (same_subscriber and same_key) return row.view.published.*;
    }
    return null;
}
