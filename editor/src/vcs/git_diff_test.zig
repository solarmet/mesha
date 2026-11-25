//! Tests of vcs-git's diff panel (`git_diff.zig`), run on the panel's bench
//! (`git_status_test.zig`): the panel's system alone, the programs its jobs ran stood in for
//! with what git says, and one test against a real git.

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const outline = mesha.ui.outline;
const Atom = mesha.Atom;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const action_palette = @import("../action_palette.zig");
const transient = @import("../transient.zig");
const git_commit = @import("git_commit.zig");
const workspaces = @import("../workspaces.zig");
const style = @import("../ui/style.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");
const git_status = @import("git_status.zig");
const git_diff = @import("git_diff.zig");
const status_test = @import("git_status_test.zig");
const commit_test = @import("git_commit_test.zig");
const Bench = status_test.Bench;
const testing = std.testing;

/// The lines the diff panel shows now, as its draw builds them.
pub fn diffLines(bench: *Bench) !git_diff.Built {
    const sources = git_diff.sourcesOf(&bench.tables) orelse return error.NoTables;
    return git_diff.build(bench.arena.allocator(), sources);
}

/// The diff panel's line that says `text`; null when none does.
pub fn diffLine(built: git_diff.Built, text: []const u8) ?outline.Line {
    for (built.lines) |line| {
        if (std.mem.eql(u8, line.text, text)) return line;
    }
    return null;
}

/// The key of the diff panel's line that says `text`.
pub fn diffKey(built: git_diff.Built, text: []const u8) !u64 {
    const line = diffLine(built, text) orelse {
        std.debug.print("no line \"{s}\" in the diff panel among:\n", .{text});
        for (built.lines) |shown| std.debug.print("  \"{s}\"\n", .{shown.text});
        return error.NoSuchLine;
    };
    return line.key;
}

/// The diff panel's message `tag`, with `user_data`, and the system's run.
fn deliver(bench: *Bench, tag: git_diff.Msg, user_data: []const u8) !void {
    const inbox = sequencer.inboxOf(git_status.system());
    try sequencer.deliverMessage(&bench.tables, inbox, Atom.from(tag), user_data, &.{});
    bench.run();
}

/// The diff panel's action `tag` invoked, and the system's run.
pub fn diffAct(bench: *Bench, tag: git_diff.Msg) !void {
    try deliver(bench, tag, &.{});
}

/// The diff panel's cursor put on the line that says `text`, as a click puts it, and `tag`
/// invoked there.
pub fn diffActOn(bench: *Bench, text: []const u8, tag: git_diff.Msg) !void {
    const key = try diffKey(try diffLines(bench), text);
    try deliver(bench, .vcs_git_diff_click, std.mem.asBytes(&key));
    try diffAct(bench, tag);
}

/// Whether the diff panel is shown.
pub fn panelShown(bench: *Bench) bool {
    return workspaces.panelShown(&bench.tables, git_diff.panel);
}

/// The diff panel's title, as its row of `editor_shown_panels` holds it.
pub fn panelTitle(bench: *Bench) []const u8 {
    const shown = bench.tables.findByName(Atom.from(workspaces.shown_panels_table_name)).?;
    var rows = shown.readQuery(struct { id: *Atom, title: []const u8 });
    while (rows.next()) |row| {
        if (row.view.id.* == git_diff.panel) return row.view.title;
    }
    return "";
}

/// The text of the diff panel's line under its cursor.
fn cursorText(bench: *Bench) ![]const u8 {
    const built = try diffLines(bench);
    const sources = git_diff.sourcesOf(&bench.tables).?;
    var out: [256]u32 = undefined;
    const shown = outline.visible(built.lines, built.folded, &out);
    const cursor = outline.settle(built.lines, shown, sources.row.cursor());
    return built.lines[shown[cursor.index]].text;
}

fn panelRequests(bench: *Bench, into: []plugin.panels.CmdPayload) []plugin.panels.CmdPayload {
    const requests = plugin.panels.Requests.of(&bench.memory, &bench.tables, plugin.panels.commands_table_name);
    return requests.peek(into);
}

fn forgetPanelRequests(bench: *Bench) void {
    plugin.panels.Requests.of(&bench.memory, &bench.tables, plugin.panels.commands_table_name).reset();
}

/// RET on the file at `text` under `section` of the status, and the side's diff it asks for
/// answered with `diff`.
fn showWithDiff(bench: *Bench, section: git_status.SectionKind, text: []const u8, side: git.Side, diff: []const u8) !void {
    try bench.actOn(section, text, .vcs_git_visit);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try status_test.diffJob(jobs, side), 0, diff, "");
    bench.run();
    bench.forgetRequests();
}

test "vcs git diff: RET on an unstaged file asks for the unstaged diff once and shows that file's hunks in the panel" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnsweredWith(&bench, status_test.unstaged_status);
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    try testing.expect(!panelShown(&bench));

    try bench.actOn(.unstaged, "a.txt", .vcs_git_visit);
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    const diff_job = jobs[0];
    try status_test.expectArgv(diff_job, .{ .diff = .unstaged });
    try testing.expectEqual(runner.Order.shared, diff_job.order);
    try testing.expect(panelShown(&bench));
    try testing.expectEqualStrings("a.txt (unstaged)", panelTitle(&bench));
    // While it is asked for, the panel says so.
    try testing.expect(diffLine(try diffLines(&bench), "Loading...") != null);
    // RET again asks nothing more.
    bench.forgetRequests();
    try bench.act(.vcs_git_visit);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);

    // Answered: a.txt's hunks, open, in the code font, their lines coloured; b.txt's not built.
    _ = try bench.finish(diff_job, 0, status_test.a_diff ++ status_test.b_diff, "");
    bench.run();
    const built = try diffLines(&bench);
    try testing.expect(diffLine(built, "Loading...") == null);
    try testing.expectEqualStrings("modified", diffLine(built, "a.txt").?.detail);
    const first_hunk = diffLine(built, "@@ -1,4 +1,4 @@").?;
    try testing.expectEqual(outline.Font.code, first_hunk.font);
    try testing.expect(first_hunk.expandable);
    try testing.expect(std.mem.indexOfScalar(u64, built.folded, first_hunk.key) == null);
    try testing.expect(diffLine(built, "@@ -10,3 +10,4 @@ ten") != null);
    const colours = [_]struct { text: []const u8, colour: mesha.ui.Color }{
        .{ .text = "+TWO", .colour = style.col.success },
        .{ .text = "-two", .colour = style.col.danger },
        .{ .text = " one", .colour = style.col.text },
        .{ .text = "\\ No newline at end of file", .colour = style.col.text_dim },
    };
    for (colours) |expected| {
        const line = diffLine(built, expected.text) orelse return error.NoSuchLine;
        try testing.expectEqual(expected.colour, line.colour);
        try testing.expectEqual(outline.Font.code, line.font);
        try testing.expectEqual(@as(u8, 2), line.depth);
    }
    try testing.expect(diffLine(built, "@@ -3 +3 @@") == null);
    try testing.expect(diffLine(built, "+BEE") == null);
    // The panel parsed a.txt's part alone, its own bytes as the status recorded them.
    try testing.expectEqual(@as(usize, 1), built.files.len);
    try testing.expectEqualStrings(status_test.a_diff, built.files[0].bytes);
    try testing.expectEqual(@as(usize, 2), built.files[0].hunks.len);

    // `M-n` by hunk from the file's line, `M-p` back; a hunk folds, its key kept.
    try diffAct(&bench, .vcs_git_diff_first);
    try diffAct(&bench, .vcs_git_diff_next_hunk);
    try testing.expectEqualStrings("@@ -1,4 +1,4 @@", try cursorText(&bench));
    try diffAct(&bench, .vcs_git_diff_next_hunk);
    try testing.expectEqualStrings("@@ -10,3 +10,4 @@ ten", try cursorText(&bench));
    try diffAct(&bench, .vcs_git_diff_next);
    try diffAct(&bench, .vcs_git_diff_previous_hunk);
    try testing.expectEqualStrings("@@ -10,3 +10,4 @@ ten", try cursorText(&bench));
    try diffActOn(&bench, "@@ -1,4 +1,4 @@", .vcs_git_diff_toggle);
    try testing.expect(std.mem.indexOfScalar(u64, (try diffLines(&bench)).folded, first_hunk.key) != null);

    // The deleted c.txt is not in the diff given: the panel says it has no changes.
    try bench.actOn(.unstaged, "c.txt", .vcs_git_visit);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    try testing.expect(diffLine(try diffLines(&bench), "No changes") != null);
}

test "vcs git diff: moving the status cursor to another file while the panel is open follows without a new program" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnsweredWith(&bench, status_test.unstaged_status);
    // Before the panel opens, moving shows nothing and runs nothing.
    try bench.act(.vcs_git_next);
    try testing.expect(!panelShown(&bench));
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff ++ status_test.b_diff);
    forgetPanelRequests(&bench);

    // Onto b.txt: its hunk, from the diff held; no program, and the focus stays.
    try status_test.moveOnto(&bench, .unstaged, "b.txt");
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    try testing.expectEqualStrings("b.txt (unstaged)", panelTitle(&bench));
    const built = try diffLines(&bench);
    try testing.expect(diffLine(built, "+BEE") != null);
    try testing.expect(diffLine(built, "+TWO") == null);
    try testing.expectEqualStrings(status_test.b_diff, built.files[0].bytes);
    var sent: [8]plugin.panels.CmdPayload = undefined;
    try testing.expectEqual(@as(usize, 0), panelRequests(&bench, &sent).len);

    // Onto the heading: the panel keeps b.txt.
    try status_test.moveOnto(&bench, .unstaged, "Unstaged changes (3)");
    try testing.expectEqualStrings("b.txt (unstaged)", panelTitle(&bench));

    // Closed, the panel follows no more.
    try diffAct(&bench, .vcs_git_diff_close);
    try status_test.moveOnto(&bench, .unstaged, "a.txt");
    const row = git_diff.sourcesOf(&bench.tables).?.row;
    try testing.expectEqualStrings("b.txt", row.path);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
}

test "vcs git diff: s on a hunk applies it to the index by the bytes of the diff" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);

    try diffActOn(&bench, "@@ -10,3 +10,4 @@ ten", .vcs_git_diff_stage);
    const patch = status_test.a_header ++ status_test.a_second_hunk_header ++ status_test.a_second_hunk_body;
    const job = try status_test.expectCommand(&bench, .{ .apply = .stage }, patch);
    try testing.expectEqualStrings("git apply --cached", job.shown);

    // Its end refreshes, the diff is asked again, and the cursor is on the hunk that took the
    // staged one's place: the last left.
    try status_test.endCommand(&bench, job, status_test.changed_status);
    var storage: [8]runner.Job = undefined;
    const again = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), again.len);
    const first_only = status_test.a_header ++ status_test.a_first_hunk;
    _ = try bench.finish(try status_test.diffJob(again, .unstaged), 0, first_only, "");
    bench.run();
    bench.forgetRequests();
    try testing.expectEqualStrings("@@ -1,4 +1,4 @@", try cursorText(&bench));

    // A hunk's line stands for its hunk; a file's line for the file.
    try diffActOn(&bench, "+TWO", .vcs_git_diff_stage);
    const line_job = try status_test.expectCommand(&bench, .{ .apply = .stage }, first_only);
    try status_test.endCommand(&bench, line_job, status_test.changed_status);
    _ = try bench.finish(try status_test.diffJob(bench.queued(&storage), .unstaged), 0, first_only, "");
    bench.run();
    bench.forgetRequests();
    try diffActOn(&bench, "a.txt", .vcs_git_diff_stage);
    const whole = try status_test.expectCommand(&bench, .stage, "a.txt\x00");
    // Nothing left on the side: the panel says so, and stays open on it, though the status's
    // cursor settles on another line as a.txt leaves the unstaged section.
    // The staged a.txt takes the unstaged one's place in the status's lines.
    const staged_only = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +1 -0\x00" ++
        "1 M. N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b ab4d2b1079bf560e64cdb7242e2cdcceca23cf4c a.txt\x00" ++
        "? notes.txt\x00";
    try testing.expectEqualStrings("vcs-git.unstaged", (try bench.at()).row.source);
    try status_test.endCommand(&bench, whole, staged_only);
    const settled = try bench.at();
    try testing.expect(settled != .row or !std.mem.eql(u8, settled.row.source, "vcs-git.unstaged"));
    const emptied = bench.queued(&storage);
    _ = try bench.finish(try status_test.diffJob(emptied, .unstaged), 0, "", "");
    bench.run();
    bench.forgetRequests();
    try testing.expect(diffLine(try diffLines(&bench), "No changes") != null);
    try testing.expectEqualStrings("a.txt (unstaged)", panelTitle(&bench));
    try testing.expect(panelShown(&bench));

    // `s` on an unstaged hunk where it is staged tells as the status does; `u` on a staged hunk
    // applies it reversed, `s` on it tells.
    try showWithDiff(&bench, .staged, "a.txt", .staged, status_test.staged_diff);
    try testing.expectEqualStrings("a.txt (staged)", panelTitle(&bench));
    try diffActOn(&bench, "@@ -1,2 +1,2 @@", .vcs_git_diff_unstage);
    _ = try status_test.expectCommand(&bench, .{ .apply = .unstage }, status_test.a_header ++ status_test.staged_a_hunk);
    bench.forgetRequests();
    try diffActOn(&bench, "@@ -1,2 +1,2 @@", .vcs_git_diff_stage);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Already staged", bench.told(&said)[0]);
}

test "vcs git diff: s on a hunk in the run whose diff took it from under the cursor acts on nothing; the next run does" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);
    const key = try diffKey(try diffLines(&bench), "@@ -10,3 +10,4 @@ ten");
    try deliver(&bench, .vcs_git_diff_click, std.mem.asBytes(&key));
    // `g`: the refresh ends and asks the diff again.
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    try commit_test.answerRefresh(&bench, status_test.changed_status);
    var storage: [8]runner.Job = undefined;
    const asked = try status_test.diffJob(bench.queued(&storage), .unstaged);
    // In one run, the diff answers with the second hunk gone, another in its place, and `s`.
    bench.forgetRequests();
    const other_second = "@@ -20,3 +20,4 @@ twenty\n twenty-one\n twenty-two\n+twenty-three\n twenty-four\n";
    _ = try bench.finish(asked, 0, status_test.a_header ++ status_test.a_first_hunk ++ other_second, "");
    const inbox = sequencer.inboxOf(git_status.system());
    try sequencer.deliverMessage(&bench.tables, inbox, Atom.from(git_diff.Msg.vcs_git_diff_stage), &.{}, &.{});
    bench.run();
    try status_test.expectNoCommand(&bench);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The diff changed under the cursor", bench.told(&said)[0]);
    // Seen now: the next `s` stages what is under the cursor.
    bench.forgetRequests();
    try diffAct(&bench, .vcs_git_diff_stage);
    _ = try status_test.expectCommand(&bench, .{ .apply = .stage }, status_test.a_header ++ other_second);
}

test "vcs git diff: u on an unstaged hunk tells, and a staged rename shows its hunks under both its paths" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);
    try diffActOn(&bench, "+TWO", .vcs_git_diff_unstage);
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Not staged", bench.told(&said)[0]);

    bench.forgetRequests();
    try showWithDiff(&bench, .staged, "old.txt -> new.txt", .staged, status_test.staged_diff);
    const built = try diffLines(&bench);
    try testing.expectEqualStrings("new.txt (staged)", panelTitle(&bench));
    try testing.expect(diffLine(built, "+moved") != null);
    try testing.expect(diffLine(built, "-moved") != null);
    try testing.expectEqualStrings("new file", diffLine(built, "new.txt").?.detail);
    try testing.expectEqualStrings("deleted", diffLine(built, "old.txt").?.detail);
    // On a file's line, `u` unstages the rename whole, both its paths, as the status does.
    try diffActOn(&bench, "old.txt", .vcs_git_diff_unstage);
    _ = try status_test.expectCommand(&bench, .unstage, "new.txt\x00old.txt\x00");
}

test "vcs git diff: k asks first and a changed hunk is not discarded" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnsweredWith(&bench, status_test.unstaged_status);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);
    var storage: [8]runner.Job = undefined;

    try diffActOn(&bench, "@@ -1,4 +1,4 @@", .vcs_git_diff_discard);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    const hunk = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqual(action_palette.Completions.Presentation.dialog, hunk.completions.presentation);
    try testing.expectEqualStrings("Discard hunk?", hunk.completions.title);
    try testing.expectEqualStrings("a.txt", hunk.completions.body);
    // Cancel runs nothing; Discard throws the hunk away with `apply --reverse`.
    try bench.choose(hunk, "Cancel");
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    try bench.choose(hunk, "Discard");
    const discard = try status_test.expectCommand(&bench, .{ .apply = .discard }, status_test.a_header ++ status_test.a_first_hunk);
    try status_test.endCommand(&bench, discard, status_test.unstaged_status);
    _ = try bench.finish(try status_test.diffJob(bench.queued(&storage), .unstaged), 0, status_test.a_diff, "");
    bench.run();
    bench.forgetRequests();

    // Asked, then the hunk's bytes change under the same key before the answer: nothing runs.
    try diffActOn(&bench, "@@ -1,4 +1,4 @@", .vcs_git_diff_discard);
    const changed = bench.dialog() orelse return error.NoDialog;
    try diffAct(&bench, .vcs_git_diff_refresh);
    var refresh_jobs: [2]runner.Job = undefined;
    @memcpy(&refresh_jobs, bench.queued(&storage));
    bench.forgetRequests();
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .status), 0, status_test.unstaged_status, "");
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .recent), 0, status_test.recent_commits, "");
    bench.run();
    const reasked = bench.queued(&storage);
    const other_lines = status_test.a_header ++ "@@ -1,4 +1,4 @@\n one\n-two\n+Two, written again\n three\n four\n";
    _ = try bench.finish(try status_test.diffJob(reasked, .unstaged), 0, other_lines, "");
    bench.run();
    bench.forgetRequests();
    try bench.choose(changed, "Discard");
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    var said: [8][]const u8 = undefined;
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("It changed meanwhile; k asks again", told[0]);
}

test "vcs git diff: a conflict says how it is resolved, and k on its hunk tells" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const conflicted = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "u UU N... 100644 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b both.txt\x00";
    try status_test.openAnsweredWith(&bench, conflicted);
    // git gives a conflict as a combined diff, which is not read.
    const combined = "diff --cc both.txt\nindex 1111111,2222222..0000000\n--- a/both.txt\n+++ b/both.txt\n@@@ -1,1 -1,1 +1,5 @@@\n";
    try showWithDiff(&bench, .unmerged, "both.txt", .unstaged, combined);
    try testing.expect(diffLine(try diffLines(&bench), "Conflicted: RET opens the file to resolve it") != null);
    try diffAct(&bench, .vcs_git_diff_discard);
    var said: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Resolve it, or abort the merge", bench.told(&said)[0]);
    try testing.expect(bench.dialog() == null);
}

test "vcs git diff: a diff asked before a refresh's status is dropped, and asked again once it ends" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try bench.actOn(.unstaged, "a.txt", .vcs_git_visit);
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 1), bench.queued(&storage).len);
    // The requests are kept until the jobs that name them have answered: a job's user data is
    // read from them.
    try bench.act(.vcs_git_refresh);
    const with_refresh = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 3), with_refresh.len);
    const early = try status_test.diffJob(with_refresh, .unstaged);
    _ = try bench.finish(try Bench.jobFor(with_refresh, .status), 0, status_test.changed_status, "");
    bench.run();
    // The diff asked before the status answers after it: it is of what the status replaced.
    const dropped = try bench.finish(early, 0, status_test.a_diff, "");
    bench.run();
    try testing.expect(bench.released(dropped));
    try testing.expect(diffLine(try diffLines(&bench), "Loading...") != null);
    const recent = try Bench.jobFor(with_refresh, .recent);
    bench.forgetRequests();
    _ = try bench.finish(recent, 0, status_test.recent_commits, "");
    bench.run();
    // Asked again for the side the panel shows, and for no other.
    const again = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), again.len);
    _ = try status_test.diffJob(again, .unstaged);
}

/// What `show` says of a commit: its message, the summary, and one file's change.
pub const second_shown = "2222222222222222222222222222222222222222" ++ "\x1fBo\x1f2026-11-21\x1fFix the spinner\n\nIt turned twice.\n\x1e\n---\n" ++
    " a.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n\n" ++
    "diff --git a/a.txt b/a.txt\nindex 8c77464..ab4d2b1 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n";

test "vcs git diff: RET on a commit row asks for one show" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try status_test.visitCommit(&bench, "72f25b6");
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    try testing.expectEqual(git_status.Purpose.show, Bench.purposeOf(jobs[0]));
    try status_test.expectArgv(jobs[0], .{ .show = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0" });
    try testing.expect(panelShown(&bench));
    try testing.expectEqualStrings("72f25b6", panelTitle(&bench));
    // The status shows what it showed.
    try testing.expectEqual(git_status.View.status, git_status.viewOf(git_diff.sourcesOf(&bench.tables).?.state.view.*));
    try testing.expect(diffLine(try diffLines(&bench), "Loading...") != null);
    // Asked again before it answers, the same commit is not asked twice.
    bench.forgetRequests();
    try bench.act(.vcs_git_visit);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);

    // Its answer: the commit's lines, its file open to its hunk, and its subject in the title.
    _ = try bench.finish(jobs[0], 0, second_shown, "");
    bench.run();
    try testing.expectEqualStrings("72f25b6 Fix the spinner", panelTitle(&bench));
    const built = try diffLines(&bench);
    try testing.expect(diffLine(built, "Commit:  72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0") != null);
    try testing.expect(diffLine(built, "Author:  Bo") != null);
    try testing.expect(diffLine(built, "It turned twice.") != null);
    try testing.expect(diffLine(built, " 1 file changed, 1 insertion(+), 1 deletion(-)") != null);
    try testing.expect(diffLine(built, "Files (1)") != null);
    try testing.expectEqualStrings("modified", diffLine(built, "a.txt").?.detail);
    try testing.expect(diffLine(built, "@@ -1,2 +1,2 @@") != null);
    try testing.expect(diffLine(built, "+TWO") != null);
}

test "vcs git diff: s on a commit's hunk tells and runs nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try status_test.visitCommit(&bench, "72f25b6");
    var storage: [8]runner.Job = undefined;
    const job = bench.queued(&storage)[0];
    _ = try bench.finish(job, 0, second_shown, "");
    bench.run();
    bench.forgetRequests();
    const keys = [_]git_diff.Msg{ .vcs_git_diff_stage, .vcs_git_diff_unstage, .vcs_git_diff_discard };
    var said: [8][]const u8 = undefined;
    for (keys) |tag| {
        bench.forgetRequests();
        try diffActOn(&bench, "+TWO", tag);
        try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
        try testing.expect(bench.dialog() == null);
        try testing.expectEqualStrings("Not in a commit", bench.told(&said)[0]);
    }
}

test "vcs git diff: closing the panel asks for no focus by name" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnsweredWith(&bench, status_test.unstaged_status);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);
    try testing.expect(panelShown(&bench));
    forgetPanelRequests(&bench);
    try diffAct(&bench, .vcs_git_diff_close);
    try testing.expect(!panelShown(&bench));
    // The panels system gives the focus back by its history: nothing is asked for here.
    var sent: [8]plugin.panels.CmdPayload = undefined;
    for (panelRequests(&bench, &sent)) |request| switch (request) {
        .focus, .focus_previous => return error.FocusAskedByName,
        else => {},
    };
    // `q` and `C-x 0` both close it.
    var closing: usize = 0;
    for (git_diff.keys) |key| {
        if (!std.mem.eql(u8, key.action[1], "close")) continue;
        try testing.expect(std.mem.eql(u8, key.chord, "q") or std.mem.eql(u8, key.chord, "C-x 0"));
        closing += 1;
    }
    try testing.expectEqual(@as(usize, 2), closing);
    // Opened again on a file, it takes the focus as it opens.
    try bench.actOn(.unstaged, "b.txt", .vcs_git_visit);
    try testing.expect(panelShown(&bench));
}

test "vcs git diff: showing the open panel again asks for its focus" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnsweredWith(&bench, status_test.unstaged_status);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff ++ status_test.b_diff);
    forgetPanelRequests(&bench);
    // RET on another file while the panel is open: it shows it and takes the focus back.
    try bench.actOn(.unstaged, "b.txt", .vcs_git_visit);
    var sent: [8]plugin.panels.CmdPayload = undefined;
    const focused = for (panelRequests(&bench, &sent)) |request| switch (request) {
        .focus => |asked| if (asked.id == git_diff.panel) break true,
        else => {},
    } else false;
    try testing.expect(focused);
    try testing.expectEqualStrings("b.txt (unstaged)", panelTitle(&bench));
}

test "vcs git diff: following onto a side whose diff is not held asks exactly one program" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try showWithDiff(&bench, .unstaged, "a.txt", .unstaged, status_test.a_diff);
    // Onto the staged a.txt: the staged diff, not held, asked once, and nothing else.
    try status_test.moveOnto(&bench, .staged, "a.txt");
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    try status_test.expectArgv(jobs[0], .{ .diff = .staged });
    try testing.expectEqualStrings("a.txt (staged)", panelTitle(&bench));
}

test "vcs git diff: a commit shown is let go as the panel closes, and as a file takes its place" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    var storage: [8]runner.Job = undefined;
    try status_test.visitCommit(&bench, "72f25b6");
    _ = try bench.finish(bench.queued(&storage)[0], 0, second_shown, "");
    bench.run();
    bench.forgetRequests();
    try testing.expect(git_diff.sourcesOf(&bench.tables).?.state.shown_commit.len != 0);

    // Closed: its bytes go, and showing it again asks for it.
    try diffAct(&bench, .vcs_git_diff_close);
    try testing.expectEqual(@as(usize, 0), git_diff.sourcesOf(&bench.tables).?.state.shown_commit.len);
    try testing.expectEqual(@as(usize, 0), git_diff.sourcesOf(&bench.tables).?.state.shown_hash.len);
    try status_test.visitCommit(&bench, "72f25b6");
    const again = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqual(git_status.Purpose.show, Bench.purposeOf(again[0]));
    _ = try bench.finish(again[0], 0, second_shown, "");
    bench.run();
    bench.forgetRequests();

    // A file in its place: the commit's bytes go too.
    try bench.actOn(.unstaged, "a.txt", .vcs_git_visit);
    try testing.expectEqual(@as(usize, 0), git_diff.sourcesOf(&bench.tables).?.state.shown_commit.len);
}

// ---- against a real git ------------------------------------------------------------------------

/// The commit menu shown (`c`) and the keys `keys` pressed in it, its answer delivered.
fn chooseCommit(bench: *Bench, keys: []const u8) !void {
    try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), Atom.from(git_commit.Msg.vcs_git_commit_menu), &.{}, &.{});
    bench.run();
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    var sent: [4]transient.Request = undefined;
    const presenting = requests.peek(&sent)[0].present;
    var state = presenting.state;
    var chosen_id: ?u32 = null;
    for (0..keys.len) |index| {
        switch (mesha.ui.transient.press(&git_commit.menu, &state, keys[index .. index + 1])) {
            .chosen => |id| chosen_id = id,
            .pending, .toggled, .unbound, .wants_value, .menu => {},
        }
    }
    const reply = presenting.reply;
    requests.reset();
    const chosen: transient.Chosen = .{ .id = chosen_id.?, .cancelled = 0, .state = state };
    try sequencer.deliverMessage(&bench.tables, reply.inbox, reply.tag, reply.user_data.bytes, std.mem.asBytes(&chosen));
    bench.run();
}

test "vcs git diff: a file staged from its row, the second hunk of two from the diff panel, and HEAD extended with them in a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var folder = try status_test.repositoryFolder();
    defer folder.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try folder.dir.realPath(testing.io, &path_buffer);
    const top = path_buffer[0..path_length];
    // The person's own git configuration (signing, hooks, line endings) is kept out: an empty
    // global file beside the repository, and no system file, for the test's git and the panel's.
    try folder.dir.writeFile(testing.io, .{ .sub_path = "gitconfig", .data = "" });
    try folder.dir.createDirPath(testing.io, "repo");
    const repository = try std.fs.path.join(allocator, &.{ top, "repo" });
    const global_config = try std.fs.path.join(allocator, &.{ top, "gitconfig" });
    var environment = try status_test.gitEnvironment();
    defer environment.deinit();
    try environment.put("GIT_CONFIG_GLOBAL", global_config);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    var repository_dir = try folder.dir.openDir(testing.io, "repo", .{});
    defer repository_dir.close(testing.io);
    _ = status_test.runGit(allocator, &environment, repository, &.{ "init", "-q", "-b", "main" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    // Twenty lines, committed; then the second and the nineteenth changed, two hunks apart.
    var committed: std.ArrayList(u8) = .empty;
    var changed: std.ArrayList(u8) = .empty;
    for (1..21) |number| {
        try committed.print(allocator, "line {d}\n", .{number});
        const line_changed = number == 2 or number == 19;
        if (line_changed) try changed.print(allocator, "line {d} changed\n", .{number}) else try changed.print(allocator, "line {d}\n", .{number});
    }
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = committed.items });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "First" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = changed.items });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "new\n" });
    try environment.put("GIT_AUTHOR_NAME", "Test");
    try environment.put("GIT_AUTHOR_EMAIL", "test@example.com");
    try environment.put("GIT_COMMITTER_NAME", "Test");
    try environment.put("GIT_COMMITTER_EMAIL", "test@example.com");

    var bench: Bench = .{ .working_directory = repository };
    try bench.init();
    defer bench.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&bench, &processes, &environment);
    defer processes.deinit(&bench.tables);
    try bench.act(.vcs_git_status);
    try status_test.settleReal(&bench, null);
    // `s` on the untracked file's row of the page stages it.
    try bench.actOn(.untracked, "b.txt", .vcs_git_stage);
    try status_test.settleReal(&bench, null);
    try testing.expectEqualStrings("added", bench.file(.staged, "b.txt").?.change);
    // RET on the file shows it in the diff panel, which asks for the unstaged diff; its second
    // hunk staged, through the panel's own command, and the refresh after it ends.
    try bench.actOn(.unstaged, "a.txt", .vcs_git_visit);
    try status_test.settleReal(&bench, .unstaged);
    const hunks = try diffLines(&bench);
    try testing.expect(diffLine(hunks, "@@ -1,5 +1,5 @@") != null);
    try diffActOn(&bench, "@@ -16,5 +16,5 @@ line 15", .vcs_git_diff_stage);
    try status_test.settleReal(&bench, .unstaged);

    const staged = try status_test.runGit(allocator, &environment, repository, &.{ "diff", "--cached", "--no-color", "--no-ext-diff" });
    try testing.expect(std.mem.indexOf(u8, staged, "+line 19 changed\n") != null);
    try testing.expect(std.mem.indexOf(u8, staged, "line 2 changed") == null);
    // b.txt's one hunk, and a.txt's second.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, staged, "\n@@ "));
    const unstaged = try status_test.runGit(allocator, &environment, repository, &.{ "diff", "--no-color", "--no-ext-diff" });
    try testing.expect(std.mem.indexOf(u8, unstaged, "+line 2 changed\n") != null);
    try testing.expect(std.mem.indexOf(u8, unstaged, "line 19 changed") == null);
    // The panel shows it so: a.txt under both sections of the status, the panel's unstaged lines
    // the first hunk's, the cursor on it, the one that took the staged one's place.
    _ = try bench.spotOf(.staged, "a.txt");
    const shown_after = try diffLines(&bench);
    try testing.expect(diffLine(shown_after, "@@ -1,5 +1,5 @@") != null);
    try testing.expect(diffLine(shown_after, "@@ -16,5 +16,5 @@ line 15") == null);
    try testing.expectEqualStrings("@@ -1,5 +1,5 @@", try cursorText(&bench));

    // `c e`: HEAD extended with what is staged, at once; nothing is staged after, and the page
    // has no Staged heading.
    try chooseCommit(&bench, "e");
    try status_test.settleReal(&bench, null);
    const head = try status_test.runGit(allocator, &environment, repository, &.{ "show", "--no-color", "--format=%s", "HEAD" });
    try testing.expect(std.mem.indexOf(u8, head, "First\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "+new\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "+line 19 changed\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "line 2 changed") == null);
    const left_staged = try status_test.runGit(allocator, &environment, repository, &.{ "diff", "--cached", "--name-only" });
    try testing.expectEqualStrings("", left_staged);
    try testing.expect(!status_test.headingBeginning(try bench.laidOutPage(), "Staged"));
    try status_test.expectHeading(try bench.laidOutPage(), "Unstaged changes (1)");
}
