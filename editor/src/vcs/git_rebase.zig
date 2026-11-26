//! vcs-git's rebases: the rebase menu (`r` in mode `vcs_git`) and the rebase list, the third
//! page vcs-git owns (`page.Page`), `editor/assets/documents/vcs-git-rebase.org`: a line
//! that says what is rebased onto what, a line of what to press, and one table of the list over
//! the source `vcs-git.rebase` (`action`, `hash`, `subject`), oldest first, as git's own todo
//! list is. A part of the panel's system (`git_status.zig`): the list and its state are this
//! file's tables, while the jobs, their ends and what is told are the panel's
//! (`git_status.Work`).
//!
//! - `r i` rebases the commits after the commit under the cursor (a recent commit, a row of the
//!   log), or, off a commit, those of `HEAD` not in a branch read in a prompt of the branches
//!   (`git_branch.askListing`; a branch listed by the commit it is at, a full hash typed, or any
//!   other revision typed found by one `rev-parse --verify`):
//!   one program lists them (`git.Command.rebase_commits`), of the base and of `HEAD` where the
//!   status says it is, both by full hash, kept with the list (`ListRow.base`, `head`), at most
//!   `max_rebase_commits`; a rebase that would list more is refused and told, never begun on a
//!   list cut short, as a commit left out of a list is lost. The list's rows are
//!   `editor_vcs_git_rebase` (`RebaseRow`), every commit a `pick`; with `-a` (`--autosquash`)
//!   on, a `fixup! ` or `squash! ` commit is put after the commit its subject names, marked
//!   `fixup` or `squash`, as git's own list would have it.
//! - In the rebase view (mode `vcs_rebase`, under `vcs`) the keys of `vcs` move through the page
//!   but `p`, which with `r`, `e`, `s`, `f` and `k` sets the action of the row under the cursor
//!   (pick, reword, edit, squash, fixup, drop): a write of that row's `action`, the rows being
//!   the list's one record. `M-p` and `M-n` move the row up and down, its cells swapped with its
//!   neighbour's, the cursor following the commit. RET shows the row's commit in the diff panel.
//!   `C-c C-c` begins: one program, `rebase -i <switches> <base>`, the list on its input
//!   (`git.rebaseList`, a `reword` written as `pick` then `break`), which git hands its sequence
//!   editor, the host, to write over its own, with `rebase.missingCommitsCheck=error`; the view
//!   goes back to the status, the rows kept until git began (`refreshEnded`: a rebase in progress
//!   after the refresh that follows, a stop on a conflict too, or git ended well); git refusing to
//!   begin (unstaged changes without `-A`) shows the list again as it was left. Refused and told
//!   before anything runs: a list made where `HEAD` no longer is, as the status says (a commit
//!   made or a branch switched to since: its commits would be lost or replayed elsewhere; git's
//!   own check refuses a list missing a commit when the status was not read since, which is
//!   told), and a first commit kept marked `squash` or `fixup`, as git would refuse it; then the
//!   status is read again (`verifying`), and the list given to git only once that refresh ends
//!   with `HEAD` where it was. A list git did not run keeps the status's line saying so for as
//!   long as that rebase lasts (`rebase_refused`), offering `r a` alone, and `r r`, `r s` and
//!   `r e` then tell that and run nothing; every rebase command runs with the same check
//!   (`git.writeRebase`), so where the panel does not know (after a restart) git refuses again
//!   rather than run the short list, and that refusal is told the same. `C-c C-k`
//!   or `q` leaves, running nothing.
//! - A rebase stopped (on a conflict, an `edit`, a `break`) shows in the status with what to
//!   press (`git_status`'s operation line): `r r` goes on (`rebase --continue`), `r s` skips the
//!   commit (`--skip`), `r a` gives the rebase up after a dialog (`--abort`); each given no
//!   input, so git keeps its own messages. A reword stops after its commit: `c w` rewords
//!   `HEAD` (`commit --amend --only`), then `r r`. `r e` shows what is left of the list on the
//!   page, read with one program (`git.Command.rebase_todo`), a line git wrote that is no
//!   commit's (`break`, `exec`) kept as it is; `C-c C-c` then writes the list back
//!   (`rebase --edit-todo`, the list on its input) and `r r` goes on, refused while `HEAD` is no
//!   longer where it was as the rest was read (the rebase moved on), and shown again when git
//!   does not take it.
//! - The list written replaces git's own: what git's configuration would have added to its list
//!   (`update-ref` lines of `rebase.updateRefs`, the order `rebase.autoSquash` makes) is not in
//!   it; `-a` rearranges the page's list itself.
//! - The menu's switches, `-a` `--autosquash` and `-A` `--autostash`, start off at each showing.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const keybinds = mesha.keybinds;
const git = @import("git.zig");
const status = @import("git_status.zig");
const vcs_page = @import("page.zig");
const git_branch = @import("git_branch.zig");
const git_diff = @import("git_diff.zig");
const table_view = @import("../table_view.zig");
const transient = @import("../transient.zig");
const modes = @import("../modes.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");

// ---- the messages, the actions and their keys --------------------------------------------------

/// What the panel's system takes for rebases: the menu's action and answer, the rebase view's
/// keys and its page's clicks.
pub const Msg = enum(u64) {
    /// `r`: shows the rebase menu.
    vcs_git_rebase_menu = Atom.from("vcs_git_rebase_menu").value(),
    /// The rebase menu's answer, a `transient.Chosen`.
    vcs_git_rebase_chosen = Atom.from("vcs_git_rebase_chosen").value(),
    /// The rebase view's keys: the action of the row under the cursor.
    vcs_rebase_pick = Atom.from("vcs_rebase_pick").value(),
    vcs_rebase_reword = Atom.from("vcs_rebase_reword").value(),
    vcs_rebase_edit = Atom.from("vcs_rebase_edit").value(),
    vcs_rebase_squash = Atom.from("vcs_rebase_squash").value(),
    vcs_rebase_fixup = Atom.from("vcs_rebase_fixup").value(),
    vcs_rebase_drop = Atom.from("vcs_rebase_drop").value(),
    /// `M-p` and `M-n`: the row under the cursor moved up and down.
    vcs_rebase_move_up = Atom.from("vcs_rebase_move_up").value(),
    vcs_rebase_move_down = Atom.from("vcs_rebase_move_down").value(),
    /// `C-c C-c`: the rebase begins with the list.
    vcs_rebase_begin = Atom.from("vcs_rebase_begin").value(),
    /// `C-c C-k` and `q`: the list is left, nothing run.
    vcs_rebase_leave = Atom.from("vcs_rebase_leave").value(),
    /// A click on a line of the rebase page, a `document.Click`.
    vcs_git_rebase_click = Atom.from("vcs_git_rebase_click").value(),
    /// A click on a heading's fold mark of the rebase page, a `document.Click`.
    vcs_git_rebase_toggle = Atom.from("vcs_git_rebase_toggle").value(),
    /// The wheel over the rebase page, an `input.MouseScrollMsg`.
    vcs_git_rebase_wheel = Atom.from("vcs_git_rebase_wheel").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The action of mode `vcs_git` that shows the rebase menu; its key is `r`.
pub const rebase_action: plugin.action_api.Def = .{ .name = "rebase", .tag = @tagName(Msg.vcs_git_rebase_menu), .doc = "Show the menu of rebase commands" };

/// The actions of mode `vcs_rebase`, the rebase view's.
pub const rebase_actions = [_]plugin.action_api.Def{
    .{ .name = "pick", .tag = @tagName(Msg.vcs_rebase_pick), .doc = "Keep the commit at the cursor" },
    .{ .name = "reword", .tag = @tagName(Msg.vcs_rebase_reword), .doc = "Keep the commit at the cursor and stop after it, to reword it with c w" },
    .{ .name = "edit", .tag = @tagName(Msg.vcs_rebase_edit), .doc = "Keep the commit at the cursor and stop on it, to change it" },
    .{ .name = "squash", .tag = @tagName(Msg.vcs_rebase_squash), .doc = "Fold the commit at the cursor into the one before, joining their messages" },
    .{ .name = "fixup", .tag = @tagName(Msg.vcs_rebase_fixup), .doc = "Fold the commit at the cursor into the one before, keeping that one's message" },
    .{ .name = "drop", .tag = @tagName(Msg.vcs_rebase_drop), .doc = "Leave the commit at the cursor out" },
    .{ .name = "move_up", .tag = @tagName(Msg.vcs_rebase_move_up), .doc = "Move the commit at the cursor up the list" },
    .{ .name = "move_down", .tag = @tagName(Msg.vcs_rebase_move_down), .doc = "Move the commit at the cursor down the list" },
    .{ .name = "begin", .tag = @tagName(Msg.vcs_rebase_begin), .doc = "Begin the rebase with this list" },
    .{ .name = "leave", .tag = @tagName(Msg.vcs_rebase_leave), .doc = "Leave the list, running nothing" },
};

/// The keys of mode `vcs_rebase`, over `vcs`'s: `p` is pick here, `C-p` moves up.
pub const rebase_keys = [_]keybinds.KeyDef{
    .{ .chord = "p", .action = .{ "vcs_rebase", "pick" } },
    .{ .chord = "r", .action = .{ "vcs_rebase", "reword" } },
    .{ .chord = "e", .action = .{ "vcs_rebase", "edit" } },
    .{ .chord = "s", .action = .{ "vcs_rebase", "squash" } },
    .{ .chord = "f", .action = .{ "vcs_rebase", "fixup" } },
    .{ .chord = "k", .action = .{ "vcs_rebase", "drop" } },
    .{ .chord = "M-p", .action = .{ "vcs_rebase", "move_up" } },
    .{ .chord = "M-n", .action = .{ "vcs_rebase", "move_down" } },
    .{ .chord = "C-c C-c", .action = .{ "vcs_rebase", "begin" } },
    .{ .chord = "C-c C-k", .action = .{ "vcs_rebase", "leave" } },
    .{ .chord = "q", .action = .{ "vcs_rebase", "leave" } },
};

/// Offers the actions of mode `vcs_rebase`, `inbox`'s.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    for (rebase_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_rebase, inbox, &.{.{ .def = def }});
}

// ---- the menu ------------------------------------------------------------------------------------

/// The rebase menu's items, by their ids.
pub const MenuItem = enum(u32) {
    interactive = 1,
    @"continue",
    skip,
    abort,
    edit_rest,
    autosquash,
    autostash,
};

/// The rebase menu: its switches, beginning one, and going on with one in progress.
pub const menu: ui.transient.Menu = .{
    .title = "Rebase",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.toggle("-a", "Autosquash", "--autosquash", @intFromEnum(MenuItem.autosquash)),
            ui.transient.Item.toggle("-A", "Autostash", "--autostash", @intFromEnum(MenuItem.autostash)),
        } },
        .{ .title = "Rebase", .items = &.{
            ui.transient.Item.command("i", "interactively, after the commit at the cursor", @intFromEnum(MenuItem.interactive)),
        } },
        .{ .title = "In progress", .items = &.{
            ui.transient.Item.command("r", "Continue", @intFromEnum(MenuItem.@"continue")),
            ui.transient.Item.command("s", "Skip", @intFromEnum(MenuItem.skip)),
            ui.transient.Item.command("a", "Abort", @intFromEnum(MenuItem.abort)),
            ui.transient.Item.command("e", "Edit the rest of the list", @intFromEnum(MenuItem.edit_rest)),
        } },
    },
};

/// Shows the rebase menu, its switches off; its answer comes as `vcs_git_rebase_chosen`.
pub fn presentMenu(work: status.Work) void {
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_rebase_chosen));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = &menu, .reply = reply });
}

// ---- the tables and the page ---------------------------------------------------------------------

/// `editor_vcs_git_rebase`: the list, a row a line, oldest first (`RebaseRow`): the source
/// `vcs-git.rebase`.
pub const list_table_name = "editor_vcs_git_rebase";
/// `editor_vcs_git_rebase_view`: what the list is of and where it stands, and the page's cursor,
/// scroll and view (`document.StateRow`); one row (`ListRow`).
pub const view_table_name = "editor_vcs_git_rebase_view";
/// `editor_vcs_git_rebase_folds`: the rebase page's folds (`document.FoldRow`).
pub const folds_table_name = "editor_vcs_git_rebase_folds";

const list_table = Atom.from(list_table_name);
const view_table = Atom.from(view_table_name);
const folds_table = Atom.from(folds_table_name);

/// The rebase page, `editor/assets/documents/vcs-git-rebase.org`, compiled in.
pub const rebase_document = @embedFile("vcs_git_rebase_document");

/// The rebase page: its state in `editor_vcs_git_rebase_view`, its folds in
/// `editor_vcs_git_rebase_folds`.
pub const page: vcs_page.Page = .{
    .document = vcs_page.parsePage(rebase_document, "vcs-git-rebase.org"),
    .name = "vcs_git_rebase_document",
    .state_table = view_table,
    .folds_table = folds_table,
    .tags = .{
        .click = Atom.from(Msg.vcs_git_rebase_click),
        .toggle = Atom.from(Msg.vcs_git_rebase_toggle),
        .wheel = Atom.from(Msg.vcs_git_rebase_wheel),
    },
    .resize_reader_name = "vcs_git_rebase_resizes",
    .moved_under_sentence = "The rebase list changed under the cursor",
};

/// The names the rebase adds to the system's `names`.
pub const names = page.names();

/// The name the list is published as.
pub const source_name = "vcs-git.rebase";

/// The most commits a list holds: `git.max_rebase_commits`.
pub const max_commits = git.max_rebase_commits;
/// The most lines the list holds: what is left of a rebase in progress may hold a line of git's
/// own (a `break` after each reword) beside each commit.
pub const max_lines = 2 * max_commits;

/// A row of `editor_vcs_git_rebase`, its text made displayable for the shown columns: the
/// action, the short hash and the subject, then what the list is written from, data only.
pub const RebaseRow = struct {
    /// The action as `git.RebaseAction.word` writes it; for a line of git's own, its first word.
    action: []const u8,
    /// The commit's hash as short as git keeps it unambiguous; empty for a line of git's own.
    hash: []const u8,
    /// The commit's subject; for a line of git's own, what follows its first word.
    subject: []const u8,
    /// The hash the list names the commit by, as git gave it.
    full_hash: []const u8,
    /// A line of git's own, whole, written back as it is; empty for a commit's.
    line: []const u8,
};

/// The fields of `editor_vcs_git_rebase`, in order; the first three are shown.
const list_fields = [_][]const u8{ "action", "hash", "subject", "full_hash", "line" };
const list_shown = list_fields[0..3];

/// Where the list stands.
pub const Phase = enum(u8) {
    /// None is shown or asked.
    none,
    /// The commits of a new rebase are asked for.
    listing,
    /// A new rebase's list is shown: `C-c C-c` begins it.
    editing,
    /// What is left of a rebase in progress is asked for.
    reading,
    /// What is left of a rebase in progress is shown: `C-c C-c` writes it back.
    editing_rest,
    /// A new rebase's list was given to git, which has not answered: the rows are kept until
    /// git began it.
    begun,
    /// git answered the new rebase (`ListRow.outcome`): the refresh after it tells whether it
    /// began, which clears the rows, or not, which shows them again (`refreshEnded`).
    begun_answered,
    /// What is left of a rebase in progress was given to git, which has not answered: the rows
    /// are kept until it took them.
    rest_given,
    /// `C-c C-c` on a new rebase's list: the status is read again first, and the list begun
    /// only when that refresh ends with `HEAD` where the list was made (`refreshEnded`).
    verifying,
    /// `C-c C-c` on the rest of a list: likewise, `HEAD` and the commit the rebase stopped on as
    /// they were when the rest was read.
    verifying_rest,
};

/// How git answered the command that began a list.
pub const Outcome = enum(u8) { succeeded, failed };

/// The row of `editor_vcs_git_rebase_view`, but the page's fields (`document.StateRow`).
pub const ListRow = struct {
    /// A `Phase`.
    phase: *u8,
    /// Counts the lists asked: an answer of an earlier one is dropped.
    serial: *u32,
    /// The commit a new rebase is onto, a full hash, as git is given it.
    base: *Table.String,
    /// The base as a person reads it: a branch's name, or a commit's short hash.
    base_shown: *Table.String,
    /// The commit `HEAD` was at as the list was made, or as the rest of one was read, a full
    /// hash: the list is begun only while the status still says `HEAD` is there.
    head: *Table.String,
    /// The menu's arguments, each followed by the separator.
    arguments: *Table.String,
    /// An `Outcome`: how git answered the command that began the list, in `begun_answered`.
    outcome: *u8,
    /// The commit the rebase in progress was stopped on (the status's `operation_commit`) as
    /// the rest of its list was read: written back only while it still is.
    stopped: *Table.String,
    /// 1 from a `rebase --continue` or `--skip` that failed to the end of the refresh after it,
    /// which tells a list git refused again (`refreshEnded`).
    go_on_failed: *u8,
    /// The page's `page.MovedUnder`.
    cursor_moved_under: *u8,
};

/// `ListRow` read, its text as slices of the table's.
pub const ListRead = struct {
    phase: *u8,
    serial: *u32,
    base: []const u8,
    base_shown: []const u8,
    head: []const u8,
    arguments: []const u8,
    outcome: *u8,
    stopped: []const u8,
    go_on_failed: *u8,
    cursor_moved_under: *u8,
};

/// Makes the rebase's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ list_table_name, view_table_name, folds_table_name });
    var rows: Table.Schema = undefined;
    try rows.init(scratch.allocator, atoms, list_fields.len);
    defer rows.deinit();
    for (list_fields) |field| try rows.addFieldFallible(field, Table.String, .text_field);
    _ = try tables.ensure(&rows, max_lines, list_table, .durable);

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 10 + std.meta.fields(document.StateRow).len);
    defer state.deinit();
    try state.addFieldFallible("phase", u8, .int);
    try state.addFieldFallible("serial", u32, .int);
    try state.addFieldFallible("base", Table.String, .text_field);
    try state.addFieldFallible("base_shown", Table.String, .text_field);
    try state.addFieldFallible("head", Table.String, .text_field);
    try state.addFieldFallible("arguments", Table.String, .text_field);
    try state.addFieldFallible("outcome", u8, .int);
    try state.addFieldFallible("stopped", Table.String, .text_field);
    try state.addFieldFallible("go_on_failed", u8, .int);
    try state.addFieldFallible("cursor_moved_under", u8, .int);
    try document.addStateFields(&state);
    const defaults = .{
        .phase = @as(u8, @intFromEnum(Phase.none)),
        .serial = @as(u32, 0),
        .base = Table.String{},
        .base_shown = Table.String{},
        .head = Table.String{},
        .arguments = Table.String{},
        .outcome = @as(u8, @intFromEnum(Outcome.succeeded)),
        .stopped = Table.String{},
        .go_on_failed = @as(u8, 0),
        .cursor_moved_under = @as(u8, 0),
        .document_block = document.initial_state.document_block,
        .document_row = document.initial_state.document_row,
        .document_row_id = document.initial_state.document_row_id,
        .document_row_generation = document.initial_state.document_row_generation,
        .document_index = document.initial_state.document_index,
        .document_landing = document.initial_state.document_landing,
        .document_scroll = document.initial_state.document_scroll,
        .document_view_width = document.initial_state.document_view_width,
        .document_view_height = document.initial_state.document_view_height,
        .document_warned = document.initial_state.document_warned,
    };
    _ = try tables.ensureSingleton(&state, view_table, defaults, .durable);

    var folds: Table.Schema = undefined;
    try folds.init(scratch.allocator, atoms, 1);
    defer folds.deinit();
    try document.addFoldFields(&folds);
    _ = try tables.ensure(&folds, max_folds, folds_table, .durable);
}

/// The most headings the rebase page keeps folded: its text has none.
const max_folds = 16;

/// What the rebase reads and writes, for the panel's system's access: its list, and its page's
/// state, folds and what its text reads.
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.write(list_table);
    page.declareAccess(result, tables);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s, which `claims` took. The page's clicks and wheel are taken in the rebase view
/// before this (`git_status.Work.takeOnPage`); come in another view, they do nothing, and so do
/// the view's keys.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    const message = received.tag.to(Msg);
    switch (message) {
        .vcs_git_rebase_menu => return presentMenu(work),
        .vcs_git_rebase_chosen => {
            const chosen = try received.payloadAs(transient.Chosen);
            if (chosen.cancelled != 0) return;
            const item = std.enums.fromInt(MenuItem, chosen.id) orelse return;
            return choose(work, item, chosen.state);
        },
        .vcs_git_rebase_click, .vcs_git_rebase_toggle, .vcs_git_rebase_wheel, _ => return,
        else => {},
    }
    if (status.viewOf(work.state.view.*) != .rebase) return;
    switch (message) {
        .vcs_rebase_pick => try setAction(work, .pick),
        .vcs_rebase_reword => try setAction(work, .reword),
        .vcs_rebase_edit => try setAction(work, .edit),
        .vcs_rebase_squash => try setAction(work, .squash),
        .vcs_rebase_fixup => try setAction(work, .fixup),
        .vcs_rebase_drop => try setAction(work, .drop),
        .vcs_rebase_move_up => try moveRow(work, .up),
        .vcs_rebase_move_down => try moveRow(work, .down),
        .vcs_rebase_begin => try begin(work),
        .vcs_rebase_leave => try leave(work),
        else => {},
    }
}

/// What the rebase command chosen does, with the switches `state` has on.
fn choose(work: status.Work, item: MenuItem, state: ui.transient.State) !void {
    if (work.rootUnknown()) return;
    const allocator = try work.scratch();
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    try ui.transient.writeArguments(&menu, &state, process.argument_separator, &arguments.writer);
    switch (item) {
        .interactive => {
            if (refusedWhileRebasing(work)) return;
            switch (try work.commitAtCursor()) {
                .commit => |hash| _ = try listCommits(work, .{ .hash = hash, .shown = hash[0..@min(hash.len, 7)] }, arguments.written()),
                .none => try git_branch.askListing(work, .rebase_base, arguments.written(), .refs),
                .changed => {},
            }
        },
        // Given no input, so git keeps its messages; not run on a list git did not run.
        .@"continue" => if (!listNotRun(work)) try work.runCommand(.rebase_continue, ""),
        .skip => if (!listNotRun(work)) try work.runCommand(.rebase_skip, ""),
        .abort => {
            if (!rebasing(work)) return work.tell("No rebase is in progress");
            try git_branch.askFirst(work, .rebase_abort, .{ .title = "Abort the rebase?", .body = "HEAD goes back to before it began: what it rewrote so far, and the change it stopped on, are thrown away", .confirm = "Abort" }, .{});
        },
        .edit_rest => if (!listNotRun(work)) try askRest(work),
        .autosquash, .autostash => {},
    }
}

/// Whether the last refresh found a rebase in progress.
fn rebasing(work: status.Work) bool {
    return work.state.operation.* == @intFromEnum(git.Operation.rebasing);
}

/// Whether a rebase is in progress, so that no new list is made: told with what the person can
/// do, `r e` for the rest of its list, or, for a list git did not run, what `listNotRun` tells.
fn refusedWhileRebasing(work: status.Work) bool {
    if (!rebasing(work)) return false;
    if (!listNotRun(work)) work.tell("A rebase is in progress: r e edits the rest of its list");
    return true;
}

/// The commit a rebase is onto: its full hash, and how a person reads it.
pub const Base = struct {
    /// A full hash.
    hash: []const u8,
    /// A branch's name, or a short hash.
    shown: []const u8,
};

/// Asks for the commits a rebase of `HEAD`, where the status says it is, onto `base` lists, one
/// program, which show as the list as they answer (`takeList`); `arguments`, the menu's, are
/// kept for its beginning. Both commits are full hashes, kept with the list, so what is begun is
/// what was listed. Refused and told for a base git cannot be given, with no commit, or while a
/// rebase is in progress.
pub fn listCommits(work: status.Work, base: Base, arguments: []const u8) !git_branch.Outcome {
    if (work.rootUnknown()) return .ran;
    if (refusedWhileRebasing(work)) return .ran;
    const allocator = try work.scratch();
    const head = try allocator.dupe(u8, work.cells.textOf(work.state.oid.*));
    if (head.len == 0) {
        work.tell("There is no commit to rebase");
        return .ran;
    }
    const command: git.Command = .{ .rebase_commits = .{ .base = base.hash, .head = head } };
    if (!git.passes(command)) {
        work.tell("git cannot be given that revision: it begins with - or holds a control character");
        return .refused;
    }
    const kept_base = try allocator.dupe(u8, base.hash);
    const kept_shown = try ui.displayText(allocator, base.shown);
    const kept_arguments = try allocator.dupe(u8, arguments);
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    const cells = try work.writeCells(view_table);
    try cells.assignString(listed.base, kept_base);
    try cells.assignString(listed.base_shown, kept_shown);
    try cells.assignString(listed.head, head);
    try cells.assignString(listed.arguments, kept_arguments);
    listed.serial.* +%= 1;
    listed.phase.* = @intFromEnum(Phase.listing);
    // Written again: the command's slices were copied, the table's text moved meanwhile.
    try work.queueRead(.rebase_list, .{ .rebase_commits = .{ .base = kept_base, .head = head } }, listed.serial.*);
    return .ran;
}

/// `r e`: asks for what is left of the rebase in progress, one program, which shows on the page
/// as it answers (`takeRest`).
fn askRest(work: status.Work) !void {
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    listed.serial.* +%= 1;
    listed.phase.* = @intFromEnum(Phase.reading);
    try work.queueRead(.rebase_todo, .rebase_todo, listed.serial.*);
}

/// A give-up (`C-g`) or a change of project moved the panel's generation on: a list asked and
/// not answered never will be.
pub fn abandon(work: status.Work) !void {
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    const phase = std.enums.fromInt(Phase, listed.phase.*) orelse .none;
    switch (phase) {
        .listing, .reading => listed.phase.* = @intFromEnum(Phase.none),
        // Whether git took the list is not known: it stays, and is begun again only while the
        // status says HEAD is where it was listed at.
        .begun, .begun_answered => listed.phase.* = @intFromEnum(Phase.editing),
        .rest_given => listed.phase.* = @intFromEnum(Phase.editing_rest),
        // The refresh asked will not end: nothing is begun.
        .verifying => listed.phase.* = @intFromEnum(Phase.editing),
        .verifying_rest => listed.phase.* = @intFromEnum(Phase.editing_rest),
        .none, .editing, .editing_rest => {},
    }
}

/// Forgets the list, as the panel's data of another repository is: its rows, where it stands and
/// the page's cursor; a rebase view shown goes back to the status.
pub fn forget(work: status.Work) !void {
    try clearList(work);
    if (status.viewOf(work.state.view.*) == .rebase) work.state.view.* = @intFromEnum(status.View.status);
}

/// The list let go: no rows, nothing asked, the cursor at the page's start.
fn clearList(work: status.Work) !void {
    const rows = try work.pass.writeTable(list_table);
    rows.clear();
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    listed.phase.* = @intFromEnum(Phase.none);
    listed.serial.* +%= 1;
    document.setCursor(try vcs_page.stateOf(work.pass, page), .{});
    try publish(work, .{});
}

// ---- the answers ---------------------------------------------------------------------------------

/// The commits of a new rebase, `said`, null for a failure: the list, every commit a `pick`
/// (rearranged as `--autosquash` would when it is among the arguments), shown in the rebase
/// view, the cursor on its first row. Refused and told, the view as it was, for more commits than
/// the list holds, for none, or for what could not be read as commits. An answer of an earlier
/// ask is dropped.
pub fn takeList(work: status.Work, epoch: u32, said: ?[]const u8) !void {
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    if (epoch != listed.serial.* or listed.phase.* != @intFromEnum(Phase.listing)) return;
    listed.phase.* = @intFromEnum(Phase.none);
    const bytes = said orelse return work.tell("git log failed; $ shows why");
    const allocator = try work.scratch();
    const commits = try allocator.alloc(git.LogEntry, max_commits + 1);
    const parsed = git.parseLog(bytes, commits);
    const read = try work.pass.readSingleton(view_table, ListRead);
    const shown_base = try allocator.dupe(u8, read.base_shown);
    if (parsed.unread != 0) return work.tell("git log's answer could not be read as commits: nothing to rebase");
    if (parsed.commits.seen > max_commits) {
        const sentence = std.fmt.comptimePrint("More than {d} commits would be rebased; the list holds at most {d}: rebase from a later commit", .{ max_commits, max_commits });
        return work.tell(sentence);
    }
    if (parsed.commits.seen == 0) {
        const sentence = try std.fmt.allocPrint(allocator, "Nothing to rebase: HEAD has no commits after {s}", .{shown_base});
        return work.tell(sentence);
    }
    const lines = try allocator.alloc(Line, parsed.commits.kept);
    for (commits[0..parsed.commits.kept], lines) |commit, *line| {
        line.* = .{ .action = .pick, .hash = commit.short_hash, .full_hash = commit.hash, .subject = commit.subject };
    }
    if (git.hasArgument(read.arguments, "--autosquash")) try autosquash(allocator, lines);
    try writeList(work, lines);
    listed.phase.* = @intFromEnum(Phase.editing);
    const count = if (lines.len == 1) "1 commit" else try std.fmt.allocPrint(allocator, "{d} commits", .{lines.len});
    try publish(work, .{ .count = count, .onto = shown_base });
    try showList(work);
}

/// What is left of the rebase in progress, `said` (what its sequence editor printed), null for a
/// failure: shown in the rebase view, a line of git's own kept as it is. Refused and told for
/// more lines than the list holds, or none.
pub fn takeRest(work: status.Work, epoch: u32, said: ?[]const u8) !void {
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    if (epoch != listed.serial.* or listed.phase.* != @intFromEnum(Phase.reading)) return;
    listed.phase.* = @intFromEnum(Phase.none);
    const bytes = said orelse {
        // git refuses to show a list that lacks commits it listed: one it did not run.
        if (atOntoUnrun(work)) {
            work.state.rebase_refused.* = 1;
            work.tell(refused_sentence);
            return work.publish();
        }
        return work.tell("git rebase --edit-todo failed (is a rebase in progress?); $ shows why");
    };
    const allocator = try work.scratch();
    const entries = try allocator.alloc(git.RebaseEntry, max_lines);
    const counted = git.parseTodo(bytes, entries);
    if (counted.seen > max_lines) {
        const sentence = std.fmt.comptimePrint("The rest of the rebase holds more than {d} lines; the list holds at most {d}", .{ max_lines, max_lines });
        return work.tell(sentence);
    }
    if (counted.seen == 0) return work.tell("Nothing is left of the rebase's list: r r goes on");
    // The rest is of the rebase stopped where HEAD is now: written back only while it is.
    const head = try allocator.dupe(u8, work.cells.textOf(work.state.oid.*));
    const stopped = try allocator.dupe(u8, work.cells.textOf(work.state.operation_commit.*));
    const cells = try work.writeCells(view_table);
    try cells.assignString(listed.head, head);
    try cells.assignString(listed.stopped, stopped);
    const lines = try allocator.alloc(Line, counted.kept);
    for (entries[0..counted.kept], lines) |entry, *line| {
        line.* = .{ .action = entry.action, .hash = entry.hash, .full_hash = entry.hash, .subject = entry.subject };
    }
    try writeList(work, lines);
    listed.phase.* = @intFromEnum(Phase.editing_rest);
    const count = try std.fmt.allocPrint(allocator, "the {d} lines left", .{lines.len});
    try publish(work, .{ .count = count, .onto = "the commits rebased so far" });
    try showList(work);
}

/// A line of the list as it is written into the table.
const Line = struct {
    action: git.RebaseAction,
    /// The short hash shown; empty for a line of git's own.
    hash: []const u8,
    /// The hash the list is written with.
    full_hash: []const u8,
    /// The subject; for a line of git's own, the whole line.
    subject: []const u8,
};

/// Writes `lines` as the list's rows, in order, a cell only where it changed.
fn writeList(work: status.Work, lines: []const Line) !void {
    const allocator = try work.scratch();
    const rows = try work.writeCells(list_table);
    const handles = try table_view.rowsInOrder(rows, @intCast(lines.len), allocator);
    for (lines, handles) |line, handle| {
        const shown = try shownOf(allocator, line);
        try rows.setString(handle, "action", shown.action);
        try rows.setString(handle, "hash", shown.hash);
        try rows.setString(handle, "subject", shown.subject);
        try rows.setString(handle, "full_hash", line.full_hash);
        try rows.setString(handle, "line", if (line.action == .kept) line.subject else "");
    }
}

/// What a row shows of `line`: a line of git's own split at its first word.
fn shownOf(allocator: std.mem.Allocator, line: Line) !struct { action: []const u8, hash: []const u8, subject: []const u8 } {
    if (line.action != .kept) {
        const subject = try ui.displayText(allocator, line.subject);
        return .{ .action = line.action.word(), .hash = line.hash, .subject = subject };
    }
    const whole = try ui.displayText(allocator, line.subject);
    const word_end = std.mem.indexOfAny(u8, whole, " \t") orelse whole.len;
    const rest = std.mem.trimStart(u8, whole[word_end..], " \t");
    return .{ .action = whole[0..word_end], .hash = "", .subject = rest };
}

/// The rebase view shown, its cursor on the list's first row.
fn showList(work: status.Work) !void {
    work.enterView(.rebase);
    const laid_out = try vcs_page.laidOut(work.pass, page);
    const block = tableBlock(laid_out) orelse return;
    const first = document.rowAt(block.table.?.table, 0) orelse return;
    const state = try vcs_page.stateOf(work.pass, page);
    document.setCursor(state, document.cursorOnRow(laid_out, block.key, first));
}

/// What the page's line says the list is of.
const Said = struct {
    /// How many commits, or lines, are rebased.
    count: []const u8 = "",
    /// What onto.
    onto: []const u8 = "",
};

/// Publishes what the rebase page shows: the list as `vcs-git.rebase`, and what it is of.
fn publish(work: status.Work, said: Said) !void {
    const publishing = try document_sources.Publishing.of(work.pass) orelse return;
    const publisher = status.vcs_git_root;
    publishing.publishSource(publisher, .{ .name = source_name, .table = list_table, .shown = list_shown });
    publishing.publishValue(publisher, "vcs-git.rebase-count", said.count);
    publishing.publishValue(publisher, "vcs-git.rebase-onto", said.onto);
}

/// The page's table block, while it shows.
fn tableBlock(laid_out: document.Layout) ?document.Block {
    for (laid_out.shown) |index| {
        const block = laid_out.blocks[index];
        const table = block.table orelse continue;
        if (std.mem.eql(u8, table.source, source_name)) return block;
    }
    return null;
}

/// `--autosquash` done to `lines`, every one a `pick` in git's order: a commit whose subject
/// begins `fixup! ` or `squash! ` is put after the commit its subject then names (by its
/// subject, or a hash it begins), after any put there before it, and marked `fixup` or
/// `squash`; one that names no commit of the list stays where it is.
fn autosquash(allocator: std.mem.Allocator, lines: []Line) !void {
    const placed = try allocator.alloc(bool, lines.len);
    @memset(placed, false);
    const targets = try allocator.alloc(?usize, lines.len);
    for (lines, targets, 0..) |*line, *target, index| {
        target.* = null;
        const marked = squashMark(line.subject) orelse continue;
        for (lines[0..index], 0..) |earlier, earlier_index| {
            const named = std.mem.eql(u8, earlier.subject, marked.named) or
                (marked.named.len >= 4 and std.mem.startsWith(u8, earlier.full_hash, marked.named));
            if (!named) continue;
            target.* = earlier_index;
            line.action = marked.action;
            break;
        }
    }
    var order: std.ArrayList(Line) = .empty;
    for (targets, 0..) |target, index| {
        if (target != null) continue;
        try appendWithFolds(allocator, &order, lines, targets, index);
    }
    @memcpy(lines, order.items);
}

/// Appends `lines[index]` and, after it, each line folded into it, each followed by its own.
fn appendWithFolds(allocator: std.mem.Allocator, order: *std.ArrayList(Line), lines: []const Line, targets: []const ?usize, index: usize) !void {
    try order.append(allocator, lines[index]);
    for (targets, 0..) |target, folded| {
        if (target != index) continue;
        try appendWithFolds(allocator, order, lines, targets, folded);
    }
}

/// What a `fixup! ` or `squash! ` subject marks: the action and the subject or hash it names,
/// its marks all taken off; null for another subject.
fn squashMark(subject: []const u8) ?struct { action: git.RebaseAction, named: []const u8 } {
    const marks = [_]struct { prefix: []const u8, action: git.RebaseAction }{
        .{ .prefix = "fixup! ", .action = .fixup },
        .{ .prefix = "squash! ", .action = .squash },
    };
    var action: ?git.RebaseAction = null;
    var named = subject;
    outer: while (true) {
        for (marks) |mark| {
            if (!std.mem.startsWith(u8, named, mark.prefix)) continue;
            if (action == null) action = mark.action;
            named = named[mark.prefix.len..];
            continue :outer;
        }
        break;
    }
    return .{ .action = action orelse return null, .named = named };
}

// ---- the keys on the list ------------------------------------------------------------------------

/// The row the page's cursor is on, unless an answer earlier in the run changed what is there
/// (told); null off a row.
fn rowAtCursor(work: status.Work) !?document.AtRow {
    if (try vcs_page.changedUnderCursor(work.pass, page)) return null;
    return switch (try vcs_page.atCursor(work.pass, page)) {
        .row => |row| row,
        .heading, .group, .text, .none => null,
    };
}

/// `p`, `r`, `e`, `s`, `f`, `k`: the row under the cursor marked `action`; a line of git's own
/// is kept as it is, and told.
fn setAction(work: status.Work, action: git.RebaseAction) !void {
    const row = try rowAtCursor(work) orelse return;
    const rows = try work.writeCells(list_table);
    const line = rows.getRow(row.row, RebaseRow) orelse return;
    if (line.line.len != 0) return work.tell("A line of git's own: it is kept as it is");
    try rows.setString(row.row, "action", action.word());
}

/// Which way `M-p` and `M-n` move a row.
const Direction = enum { up, down };

/// `M-p` and `M-n`: the row under the cursor and its neighbour swapped, every cell, the cursor
/// following the commit; at the list's end nothing moves.
fn moveRow(work: status.Work, direction: Direction) !void {
    const row = try rowAtCursor(work) orelse return;
    const rows = try work.writeCells(list_table);
    const position = document.positionOf(rows, row.row) orelse return;
    const neighbour_position = switch (direction) {
        .up => if (position == 0) return else position - 1,
        .down => position + 1,
    };
    const neighbour = document.rowAt(rows, neighbour_position) orelse return;
    const allocator = try work.scratch();
    // Copied first: each cell written may move the table's text.
    const here = try copyRow(allocator, rows.getRow(row.row, RebaseRow) orelse return);
    const there = try copyRow(allocator, rows.getRow(neighbour, RebaseRow) orelse return);
    try writeRow(rows, row.row, there);
    try writeRow(rows, neighbour, here);
    try vcs_page.putCursorOnRow(work.pass, page, row.key, neighbour);
}

/// `row`'s cells copied into `allocator`.
fn copyRow(allocator: std.mem.Allocator, row: RebaseRow) !RebaseRow {
    return .{
        .action = try allocator.dupe(u8, row.action),
        .hash = try allocator.dupe(u8, row.hash),
        .subject = try allocator.dupe(u8, row.subject),
        .full_hash = try allocator.dupe(u8, row.full_hash),
        .line = try allocator.dupe(u8, row.line),
    };
}

/// Writes `cells` into the row `handle` of `rows`.
fn writeRow(rows: *Table, handle: Table.RowHandle, cells: RebaseRow) !void {
    try rows.setString(handle, "action", cells.action);
    try rows.setString(handle, "hash", cells.hash);
    try rows.setString(handle, "subject", cells.subject);
    try rows.setString(handle, "full_hash", cells.full_hash);
    try rows.setString(handle, "line", cells.line);
}

/// RET in the rebase view: the commit of the row under the cursor shown in the diff panel.
pub fn visit(work: status.Work) !void {
    const row = try rowAtCursor(work) orelse return;
    try showRow(work, row);
}

/// A row chosen (RET, or a click on the row the cursor is on): its commit in the diff panel; a
/// line of git's own shows nothing.
pub fn chooseAt(work: status.Work, at: document.At) !void {
    switch (at) {
        .row => |row| {
            if (try vcs_page.changedUnderCursor(work.pass, page)) return;
            try showRow(work, row);
        },
        .heading, .group, .text, .none => {},
    }
}

fn showRow(work: status.Work, row: document.AtRow) !void {
    const line = row.table.getRow(row.row, RebaseRow) orelse return;
    if (line.line.len != 0) return;
    const allocator = try work.scratch();
    const hash = try allocator.dupe(u8, line.full_hash);
    try git_diff.show(work, .{ .commit = .{ .hash = hash } });
}

/// `C-c C-c`: the list begins a new rebase (`rebase -i`) or is written back over the rest of
/// the one in progress (`rebase --edit-todo`). What can be refused now is, before anything
/// runs: a list made where the status already says `HEAD` no longer is, and a first commit kept
/// that is folded into the one before it, there being none. Then the status is read again, and
/// the list given to git only as that refresh ends with `HEAD` still where it was listed at
/// (`refreshEnded`, `giveList`): a commit made or a branch switched to since would be lost or
/// replayed elsewhere. git's own `rebase.missingCommitsCheck` guards what is left.
fn begin(work: status.Work) !void {
    if (work.rootUnknown()) return;
    const read = try work.pass.readSingleton(view_table, ListRead);
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    switch (phase) {
        .editing, .editing_rest => {},
        .verifying, .verifying_rest => return work.tell("The status is being read before the list is given to git"),
        else => return work.tell("No rebase list is being edited"),
    }
    if (try movedSince(work, phase)) return;
    const allocator = try work.scratch();
    const entries = try entriesOf(allocator, try work.pass.table(list_table));
    if (phase == .editing) {
        for (entries) |entry| {
            switch (entry.action) {
                .drop, .kept => continue,
                .squash, .fixup => return work.tell("The first commit kept cannot be squashed or fixed up: there is none before it to fold it into"),
                .pick, .reword, .edit => break,
            }
        }
    }
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    listed.phase.* = @intFromEnum(if (phase == .editing) Phase.verifying else Phase.verifying_rest);
    try work.refresh(.ask);
}

/// Whether `HEAD`, or the commit a rebase stopped on, moved since the list of `phase` was made
/// or read, as the status says now: told, the list kept.
fn movedSince(work: status.Work, phase: Phase) !bool {
    const read = try work.pass.readSingleton(view_table, ListRead);
    const head_now = work.cells.textOf(work.state.oid.*);
    const stopped_now = work.cells.textOf(work.state.operation_commit.*);
    switch (phase) {
        .editing, .verifying => {
            if (std.mem.eql(u8, head_now, read.head)) return false;
            work.tell("HEAD moved since the list was made; r i lists again");
        },
        else => {
            const same = std.mem.eql(u8, head_now, read.head) and std.mem.eql(u8, stopped_now, read.stopped);
            if (same) return false;
            work.tell("The rebase moved on since its list was read; r e reads it again");
        },
    }
    return true;
}

/// The refresh `begin` asked ended with nothing moved: the list, as its rows are now, given to
/// git, one program, the list on its input; the view goes back to the status and the rows stay
/// until git took them (`commandEnded`, `refreshEnded`).
fn giveList(work: status.Work, phase: Phase) !void {
    const read = try work.pass.readSingleton(view_table, ListRead);
    const allocator = try work.scratch();
    const entries = try entriesOf(allocator, try work.pass.table(list_table));
    var list: std.Io.Writer.Allocating = .init(allocator);
    git.rebaseList(&list.writer, entries) catch |err| switch (err) {
        error.UnpassableArgument => return work.tell("A line of the list git cannot be given: nothing ran"),
        error.WriteFailed => return error.OutOfMemory,
    };
    const base = try allocator.dupe(u8, read.base);
    const arguments = try allocator.dupe(u8, read.arguments);
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    switch (phase) {
        .verifying => {
            try work.runCommand(.{ .rebase = .{ .arguments = arguments, .base = base } }, list.written());
            listed.phase.* = @intFromEnum(Phase.begun);
        },
        .verifying_rest => {
            try work.runCommand(.rebase_edit_todo, list.written());
            listed.phase.* = @intFromEnum(Phase.rest_given);
        },
        else => unreachable,
    }
    if (status.viewOf(work.state.view.*) == .rebase) work.state.view.* = @intFromEnum(status.View.status);
}

/// What a command of the rebase's ending tells: a list given git, a new one or the rest of one,
/// or going on (`--continue`, `--skip`).
pub const Given = enum { new_rebase, rest, go_on };

/// The command that gave git a list (`given`) ended, `outcome` as git exited. The rest of a
/// rebase in progress is taken or not by the exit code: taken, the rows go and that is told; not,
/// the list is shown again as it was left. A new rebase waits for the refresh after it
/// (`refreshEnded`), as one that stopped on a conflict exits failing yet has begun.
pub fn commandEnded(work: status.Work, given: Given, outcome: Outcome) !void {
    const listed = try work.pass.writeSingleton(view_table, ListRow);
    const phase = std.enums.fromInt(Phase, listed.phase.*) orelse .none;
    switch (given) {
        .go_on => listed.go_on_failed.* = @intFromBool(outcome == .failed),
        .new_rebase => {
            if (phase != .begun) return;
            listed.phase.* = @intFromEnum(Phase.begun_answered);
            listed.outcome.* = @intFromEnum(outcome);
        },
        .rest => {
            if (phase != .rest_given) return;
            switch (outcome) {
                .succeeded => {
                    try clearList(work);
                    work.tell("The rest of the rebase's list is set: r r goes on");
                },
                .failed => {
                    listed.phase.* = @intFromEnum(Phase.editing_rest);
                    work.enterView(.rebase);
                    work.tell("git did not take the list; $ shows why; the list is as you left it");
                },
            }
        },
    }
}

/// The words a list git refused as missing commits is told in, as the status's line keeps
/// saying while that rebase lasts.
const refused_sentence = "git did not run the list; $ shows why: r a aborts and leaves the branch as it was, then r i lists again";

/// Whether the status a refresh ended with is its own.
pub const StatusRead = enum { read, unread };

/// Whether git did not run a list of the panel's, as the status holds it: then only `r a` is
/// offered, and that is told in place of running `r r`, `r s` or `r e`.
fn listNotRun(work: status.Work) bool {
    const rebasing_now = work.state.operation.* == @intFromEnum(git.Operation.rebasing);
    if (!rebasing_now or work.state.rebase_refused.* == 0) return false;
    work.tell(refused_sentence);
    return true;
}

/// The rebase in progress stopped before its first line at the commit it is onto, between
/// commits and with no conflict, as the status holds it: where git leaves a list it did not run.
fn atOntoUnrun(work: status.Work) bool {
    const state = work.state;
    const rebasing_now = state.operation.* == @intFromEnum(git.Operation.rebasing);
    const between = state.operation_stop.* == @intFromEnum(git.RebaseStop.between_commits);
    const at_onto = std.mem.eql(u8, work.cells.textOf(state.oid.*), work.cells.textOf(state.operation_commit.*));
    return rebasing_now and between and at_onto and state.unmerged_count.* == 0;
}

/// The refresh that ended, its operation read, for what waits on it:
/// - `C-c C-c` asked it (`verifying`): the list is given to git when nothing moved, else told and
///   kept;
/// - a new rebase given to git and answered began when a rebase is in progress now, or when git
///   ended well, and its rows go; one stopped before its first line with `HEAD` at the base and
///   no conflict, git having exited failing, is a list that left out a commit `HEAD` has
///   (`rebase.missingCommitsCheck`): told, and the status keeps saying so (`rebase_refused`);
///   one that did not begin shows the list again as it was left;
/// - a `--continue` or `--skip` that failed, the rebase stopped between commits at the commit it
///   is onto with no conflict, is git refusing the list again (after a restart of the editor,
///   which forgets the refusal): told the same, and kept.
pub fn refreshEnded(work: status.Work, status_read: StatusRead) !void {
    const read = try work.pass.readSingleton(view_table, ListRead);
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    const state = work.state;
    const in_progress = state.operation.* == @intFromEnum(git.Operation.rebasing);
    const between = state.operation_stop.* == @intFromEnum(git.RebaseStop.between_commits);
    const no_conflict = state.unmerged_count.* == 0;
    if (read.go_on_failed.* != 0) {
        const listed = try work.pass.writeSingleton(view_table, ListRow);
        listed.go_on_failed.* = 0;
        if (atOntoUnrun(work)) {
            state.rebase_refused.* = 1;
            work.tell(refused_sentence);
            try work.publish();
        }
    }
    switch (phase) {
        .verifying, .verifying_rest => {
            // A status not read leaves HEAD as it was held: nothing verified, nothing given.
            const unread = status_read == .unread;
            if (unread) work.tell("The status could not be read ($ shows why); the list was not given to git");
            if (unread or try movedSince(work, phase)) {
                const listed = try work.pass.writeSingleton(view_table, ListRow);
                listed.phase.* = @intFromEnum(if (phase == .verifying) Phase.editing else Phase.editing_rest);
                return;
            }
            return giveList(work, phase);
        },
        .begun_answered => {},
        else => return,
    }
    const outcome = std.enums.fromInt(Outcome, read.outcome.*) orelse .failed;
    if (in_progress) {
        const at_base = std.mem.eql(u8, work.cells.textOf(state.oid.*), read.base);
        const refused_list = outcome == .failed and at_base and between and no_conflict;
        if (refused_list) {
            state.rebase_refused.* = 1;
            work.tell(refused_sentence);
            try work.publish();
        }
        return clearList(work);
    }
    switch (outcome) {
        .succeeded => try clearList(work),
        .failed => {
            const listed = try work.pass.writeSingleton(view_table, ListRow);
            listed.phase.* = @intFromEnum(Phase.editing);
            work.enterView(.rebase);
            work.tell("git did not begin the rebase; $ shows why; the list is as you left it");
        },
    }
}

/// `C-c C-k` and `q`: the list is left and nothing runs; the view goes back to the status.
pub fn leave(work: status.Work) !void {
    try clearList(work);
    work.state.view.* = @intFromEnum(status.View.status);
    work.tell("Left the rebase list; nothing ran");
}

/// The list's rows as `git.rebaseList` takes them, in the table's order, their text the table's.
fn entriesOf(allocator: std.mem.Allocator, rows: *Table) ![]git.RebaseEntry {
    const entries = try allocator.alloc(git.RebaseEntry, rows.count());
    var position: u32 = 0;
    while (position < entries.len) : (position += 1) {
        const handle = document.rowAt(rows, position) orelse return error.RowGone;
        const row = rows.getRow(handle, RebaseRow) orelse return error.RowGone;
        if (row.line.len != 0) {
            entries[position] = .{ .action = .kept, .hash = "", .subject = row.line };
            continue;
        }
        const action = git.RebaseAction.ofWord(row.action) orelse .pick;
        entries[position] = .{ .action = action, .hash = row.full_hash, .subject = row.subject };
    }
    return entries;
}

// ---- helpers -------------------------------------------------------------------------------------

/// A revision as a person reads it: a full hash cut to its first seven, anything else as it is,
/// in `allocator`.
fn shortOf(allocator: std.mem.Allocator, revision: []const u8) ![]const u8 {
    const full_hash = revision.len == 40 or revision.len == 64;
    const hex = for (revision) |byte| {
        if (!std.ascii.isHex(byte)) break false;
    } else true;
    if (full_hash and hex) return allocator.dupe(u8, revision[0..7]);
    return ui.displayText(allocator, revision);
}
