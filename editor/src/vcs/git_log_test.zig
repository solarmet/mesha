//! Tests of vcs-git's log (`git_log.zig`), its query and its table, run on the panel's bench
//! (`git_status_test.zig`): the log menu's answer is given as the menu gives it, the query's
//! prompt answered as the palette answers, keys as their actions deliver them, and each job's
//! answer as the runner gives it. One test runs typed queries and shows a commit through the
//! panel's own path in a real git repository (skipped on Windows and where `git` is not on
//! `PATH`).

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const transient = @import("../transient.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const git_status = @import("git_status.zig");
const git_commit = @import("git_commit.zig");
const git_log = @import("git_log.zig");
const git_diff = @import("git_diff.zig");
const view = @import("git_status_view.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");
const status_test = @import("git_status_test.zig");
const diff_test = @import("git_diff_test.zig");
const Bench = status_test.Bench;
const testing = std.testing;

/// A value given to an option of a menu before its keys are typed.
pub const Value = struct { id: u32, text: []const u8 };

/// The message `tag` delivered to the panel's inbox with nothing more, as an action delivers
/// it, and the panel's run.
pub fn deliver(bench: *Bench, tag: Atom) !void {
    const inbox = sequencer.inboxOf(git_status.system());
    try sequencer.deliverMessage(&bench.tables, inbox, tag, &.{}, &.{});
    bench.run();
}

/// The menu `shown` presents opened by `opener`, `values` given to its options, then `keys`
/// typed in it, the last choosing a command, answered as the menu answers.
pub fn chooseIn(bench: *Bench, opener: Atom, shown: *const ui.transient.Menu, values: []const Value, keys: []const u8) !void {
    try deliver(bench, opener);
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    var sent: [4]transient.Request = undefined;
    const presented = requests.peek(&sent);
    try testing.expectEqual(@as(usize, 1), presented.len);
    const presenting = presented[0].present;
    try testing.expect(presenting.menu == shown);
    var state = presenting.state;
    for (values) |value| try testing.expect(ui.transient.setValue(shown, &state, value.id, value.text));
    var chosen_id: ?u32 = null;
    for (0..keys.len) |index| {
        switch (ui.transient.press(shown, &state, keys[index .. index + 1])) {
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

/// `l`, `values` given, then `keys`.
fn openLog(bench: *Bench, values: []const Value, keys: []const u8) !void {
    try chooseIn(bench, Atom.from(git_log.Msg.vcs_git_log_menu), &git_log.menu, values, keys);
}

fn option(item: git_log.MenuItem, text: []const u8) Value {
    return .{ .id = @intFromEnum(item), .text = text };
}

/// `e`: the query's prompt, which must open holding `holding`, answered with `typed` and Enter.
fn editQuery(bench: *Bench, holding: []const u8, typed: []const u8) !void {
    bench.dialogs().reset();
    try deliver(bench, Atom.from(git_log.Msg.vcs_git_log_edit));
    const prompt = bench.dialog().?;
    try testing.expectEqualStrings(holding, prompt.completions.initial_query);
    try testing.expect(prompt.completions.accepts_text);
    bench.dialogs().reset();
    try submit(bench, prompt, typed);
}

/// `presented`, a prompt that takes text, ended with Enter on `typed`, as the palette ends it.
pub fn submit(bench: *Bench, presented: Bench.Presented, typed: []const u8) !void {
    const payload = try plugin.editor_api.eventPayload(bench.arena.allocator(), .{ .kind = .completed, .completion = .{ .label = "" }, .query = typed });
    const reply = presented.reply;
    try sequencer.deliverMessage(&bench.tables, reply.inbox, reply.tag, reply.user_data.bytes, payload);
    bench.run();
}

/// The one job queued since the requests were last forgotten, which must be for `purpose`.
pub fn onlyJob(bench: *Bench, purpose: git_status.Purpose) !runner.Job {
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    try testing.expectEqual(purpose, Bench.purposeOf(jobs[0]));
    return jobs[0];
}

/// Expects no job queued since the requests were last forgotten.
pub fn expectNoJob(bench: *Bench) !void {
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
}

/// `job`'s answer, ended with `code` having said `said`, and the panel's run; the requests
/// forgotten.
pub fn answer(bench: *Bench, job: runner.Job, code: i32, said: []const u8) !void {
    _ = try bench.finish(job, code, said, if (code == 0) "" else "fatal: bad revision\n");
    bench.run();
    bench.forgetRequests();
}

pub fn viewShown(bench: *Bench) git_status.View {
    const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
    var rows = state.readQuery(struct { view: *u8 });
    return git_status.viewOf(rows.next().?.view.view.*);
}

fn logTable(bench: *Bench) *Table {
    return bench.tables.findByName(Atom.from(git_log.log_table_name)).?;
}

/// The log's row: its query and what came of it.
fn asked(bench: *Bench) git_log.AskedRead {
    const cells = bench.tables.findByName(Atom.from(git_log.view_table_name)).?;
    return cells.getRow(.{ .row = 0, .generation = cells.rowGeneration(0) }, git_log.AskedRead).?;
}

/// The log's page as its draw lays it out.
fn logPage(bench: *Bench) !document.Layout {
    return vcs_page.laidOutIn(bench.arena.allocator(), &bench.tables, &bench.atoms, git_log.page);
}

/// The log page's cursor, scroll and view.
fn logState(bench: *Bench) document.StateRow {
    const cells = bench.tables.findByName(Atom.from(git_log.view_table_name)).?;
    return cells.getRow(.{ .row = 0, .generation = cells.rowGeneration(0) }, document.StateRow).?;
}

/// What the log page's cursor is on.
fn logAt(bench: *Bench) !document.At {
    return document.at(try logPage(bench), document.cursorOf(logState(bench)));
}

/// The full hash of the commit on the log page's cursor row; null off a row.
fn cursorHash(bench: *Bench) !?[]const u8 {
    const row = switch (try logAt(bench)) {
        .row => |row| row,
        .heading, .group, .text, .none => return null,
    };
    return row.table.getRow(row.row, git_log.LogRow).?.full_hash;
}

/// Whether `vcs-git.log` is published, and as read or unread.
fn sourceState(bench: *Bench) ?document_sources.SourceState {
    const sources = bench.tables.findByName(Atom.from(document_sources.sources_table_name)).?;
    const found = document_sources.sourceOf(sources.readQuery(document_sources.SourceRow), git_log.source_name) orelse return null;
    return found.state;
}

fn note(bench: *Bench) []const u8 {
    return bench.value("vcs-git.log-note").?;
}

/// What the page's query line says, as it is drawn.
fn queryLine(bench: *Bench) ![]const u8 {
    const page = try logPage(bench);
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .term and std.mem.eql(u8, block.text, "Query")) return block.detail;
    }
    return error.NoQueryLine;
}

/// The cursor put on the log row whose short hash is `short_hash`, outside any run.
fn placeOn(bench: *Bench, short_hash: []const u8) !void {
    const page = try logPage(bench);
    for (page.shown) |index| {
        const block = page.blocks[index];
        const table = block.table orelse continue;
        var rows = table.table.readQuery(git_log.LogRow);
        while (rows.next()) |row| {
            if (!std.mem.eql(u8, row.view.hash, short_hash)) continue;
            document.setCursor(logState(bench), document.cursorOnRow(page, block.key, row.handle));
            return;
        }
    }
    return error.NoSuchRow;
}

fn expectLogArgv(job: runner.Job, query: []const u8) !void {
    try status_test.expectArgv(job, .{ .log = query });
}

const first_hash = "1111111111111111111111111111111111111111";
const second_hash = "2222222222222222222222222222222222222222";
const third_hash = "3333333333333333333333333333333333333333";

const first_commit = first_hash ++ "\x1f1111111\x1fAna\x1f2026-11-22\x1fHEAD -> main\x1fTeach the log its grid\x00";
const second_commit = second_hash ++ "\x1f2222222\x1fBo\x1f2026-11-21\x1f\x1fFix the spinner\x00";
const third_commit = third_hash ++ "\x1f3333333\x1fAna\x1f2026-11-20\x1f\x1fStart\x00";
/// Three commits by two authors, newest first, as `log` lists them.
const three_commits = first_commit ++ second_commit ++ third_commit;
/// What git prints for the same three with `--oneline` among the query's arguments.
const three_oneline = "1111111 Teach the log its grid\x002222222 Fix the spinner\x003333333 Start\x00";

/// What `show` says of the second commit: its message, the summary, and one file's change.
const second_shown = second_hash ++ "\x1fBo\x1f2026-11-21\x1fFix the spinner\n\nIt turned twice.\n\x1e\n---\n" ++
    " a.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n\n" ++
    "diff --git a/a.txt b/a.txt\nindex 8c77464..ab4d2b1 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n";

/// The panel opened on a repository, `l l` run and answered with `three_commits`.
fn openAnsweredLog(bench: *Bench) !void {
    try status_test.openAnswered(bench);
    try openLog(bench, &.{}, "l");
    const job = try onlyJob(bench, .log);
    try answer(bench, job, 0, three_commits);
}

test "vcs git log: l l writes -n 256 HEAD and asks for it" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{}, "l");
    // One process, a query run with the panel's others, in the repository's root.
    const job = try onlyJob(&bench, .log);
    try expectLogArgv(job, "-n 256 HEAD");
    try testing.expectEqual(runner.Order.shared, job.order);
    try testing.expectEqualStrings("/work/repo", job.directory);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expectEqualStrings("-n 256 HEAD", asked(&bench).query);
    try testing.expectEqualStrings("git log -n 256 HEAD", try queryLine(&bench));
    try testing.expectEqualStrings("Loading...", note(&bench));
}

test "vcs git log: the menu's author option writes --author=kiran into the query" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{ option(.author, "kiran"), option(.limit, "20") }, "-ml");
    const job = try onlyJob(&bench, .log);
    try expectLogArgv(job, "-n 20 --author=kiran --no-merges HEAD");
    try testing.expect(std.mem.endsWith(u8, job.argv, "\x1f-n\x1f20\x1f--author=kiran\x1f--no-merges\x1fHEAD"));
    try testing.expectEqualStrings("git log -n 20 --author=kiran --no-merges HEAD", try queryLine(&bench));
    // `l` shows the menu again as it was set.
    try deliver(&bench, Atom.from(git_log.Msg.vcs_git_log_menu));
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    var sent: [4]transient.Request = undefined;
    const kept = requests.peek(&sent)[0].present.state;
    try testing.expectEqualStrings("kiran", ui.transient.valueOf(&git_log.menu, &kept, @intFromEnum(git_log.MenuItem.author)));
    try testing.expect(ui.transient.isOn(&git_log.menu, &kept, @intFromEnum(git_log.MenuItem.no_merges)));
    // An author of two words is one argument, quoted in the query.
    requests.reset();
    bench.forgetRequests();
    try openLog(&bench, &.{option(.author, "Kiran P")}, "l");
    const quoted = try onlyJob(&bench, .log);
    try expectLogArgv(quoted, "-n 20 '--author=Kiran P' --no-merges HEAD");
    try testing.expect(std.mem.endsWith(u8, quoted.argv, "\x1f--author=Kiran P\x1f--no-merges\x1fHEAD"));
}

test "vcs git log: the menu keeps what it was set to when it closes with nothing chosen" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try deliver(&bench, Atom.from(git_log.Msg.vcs_git_log_menu));
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    var sent: [4]transient.Request = undefined;
    const presenting = requests.peek(&sent)[0].present;
    var state = presenting.state;
    try testing.expect(ui.transient.setValue(&git_log.menu, &state, @intFromEnum(git_log.MenuItem.author), "kiran"));
    requests.reset();
    const cancelled: transient.Chosen = .{ .id = 0, .cancelled = 1, .state = state };
    try sequencer.deliverMessage(&bench.tables, presenting.reply.inbox, presenting.reply.tag, presenting.reply.user_data.bytes, std.mem.asBytes(&cancelled));
    bench.run();
    try deliver(&bench, Atom.from(git_log.Msg.vcs_git_log_menu));
    const kept = requests.peek(&sent)[0].present.state;
    try testing.expectEqualStrings("kiran", ui.transient.valueOf(&git_log.menu, &kept, @intFromEnum(git_log.MenuItem.author)));
    try expectNoJob(&bench);
    // Nothing was run, so no query was written.
    try testing.expectEqualStrings("", asked(&bench).query);
}

test "vcs git log: the menu's path is written after -- in the query" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{ option(.path, "src/"), option(.grep, "grid") }, "a");
    const job = try onlyJob(&bench, .log);
    // The path is no option: it follows `--`, and `--all` names the commits.
    try expectLogArgv(job, "-n 256 --grep=grid --all -- src/");
    try testing.expect(std.mem.endsWith(u8, job.argv, "\x1f--all\x1f--\x1fsrc/"));
}

test "vcs git log: e with the answer -n 5 main -- src/ asks git for those arguments with the format added before the --" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "-n 5 main -- src/");
    const job = try onlyJob(&bench, .log);
    try expectLogArgv(job, "-n 5 main -- src/");
    // vcs-git's own options come before the person's, and so before their `--`.
    const format = std.mem.indexOf(u8, job.argv, "\x1f--format=").?;
    const separator = std.mem.indexOf(u8, job.argv, "\x1f--\x1f").?;
    try testing.expect(format < separator);
    try testing.expect(std.mem.endsWith(u8, job.argv, "\x1f--date=short\x1f--max-count=4097\x1f-n\x1f5\x1fmain\x1f--\x1fsrc/"));
    try testing.expectEqualStrings("git log -n 5 main -- src/", try queryLine(&bench));
    // RET on the query's line opens the prompt too, holding the query as it runs.
    bench.forgetRequests();
    try bench.act(.vcs_git_first);
    try bench.act(.vcs_git_visit);
    try testing.expectEqualStrings("-n 5 main -- src/", bench.dialog().?.completions.initial_query);
    try expectNoJob(&bench);
}

test "vcs git log: a quoted argument --grep=\"two words\" is one argument" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "--grep=\"two words\" -n 3 HEAD");
    const job = try onlyJob(&bench, .log);
    try testing.expect(std.mem.endsWith(u8, job.argv, "\x1f--grep=two words\x1f-n\x1f3\x1fHEAD"));
    try testing.expectEqualStrings("--grep=\"two words\" -n 3 HEAD", asked(&bench).query);
}

test "vcs git log: a query with an unterminated quote is told and nothing runs; an empty one runs the default" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "--author='Ana");
    try expectNoJob(&bench);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The query has an unterminated quote", bench.told(&waiting)[0]);
    try testing.expectEqualStrings("-n 256 HEAD", asked(&bench).query);
    // The prompt opens again holding what was typed, to be put right.
    try testing.expectEqualStrings("--author='Ana", bench.dialog().?.completions.initial_query);
    try testing.expectEqual(@as(u32, 3), logTable(&bench).count());
    bench.forgetRequests();
    try editQuery(&bench, "-n 256 HEAD", "  ");
    try expectLogArgv(try onlyJob(&bench, .log), git_log.default_query);
}

test "vcs git log: a query that would write a file is refused, the prompt open again holding it" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "-n 5 --output=log.txt HEAD");
    try expectNoJob(&bench);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("--output is not passed to git log here", bench.told(&waiting)[0]);
    try testing.expectEqualStrings("-n 5 --output=log.txt HEAD", bench.dialog().?.completions.initial_query);
    try testing.expectEqualStrings("-n 256 HEAD", asked(&bench).query);
    // As a path, after `--`, it is no option.
    bench.forgetRequests();
    try editQuery(&bench, "-n 256 HEAD", "-n 5 HEAD -- --output");
    try expectLogArgv(try onlyJob(&bench, .log), "-n 5 HEAD -- --output");
}

test "vcs git log: the menu refuses a revision that would read as an option, and a value holding the separator" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{}, "o");
    _ = try bench.finish(try onlyJob(&bench, .refs), 0, "", "");
    bench.run();
    const prompt = bench.dialog().?;
    bench.forgetRequests();
    try submit(&bench, prompt, "-x");
    try expectNoJob(&bench);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("git cannot be given that revision", bench.told(&waiting)[0]);
    bench.forgetRequests();
    try openLog(&bench, &.{option(.author, "Ana\x1fBo")}, "l");
    try expectNoJob(&bench);
    try testing.expectEqualStrings("git cannot be given that value: it holds a control character", bench.told(&waiting)[0]);
}

test "vcs git log: an answer of two commits fills the source" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{}, "l");
    try answer(&bench, try onlyJob(&bench, .log), 0, first_commit ++ second_commit);
    const rows = logTable(&bench);
    try testing.expectEqual(@as(u32, 2), rows.count());
    var read = rows.readQuery(git_log.LogRow);
    const first = read.next().?.view;
    try testing.expectEqualStrings("1111111", first.hash);
    try testing.expectEqualStrings("HEAD -> main", first.refs);
    try testing.expectEqualStrings("Teach the log its grid", first.subject);
    try testing.expectEqualStrings("Ana", first.author);
    try testing.expectEqualStrings("2026-11-22", first.date);
    try testing.expectEqualStrings(first_hash, first.full_hash);
    try testing.expectEqualStrings("2222222", read.next().?.view.hash);
    try testing.expectEqual(document_sources.SourceState.ok, sourceState(&bench).?);
    // Nothing to note, so its line is left out; the cursor on the first row.
    try testing.expectEqualStrings("", note(&bench));
    try testing.expectEqualStrings(first_hash, (try cursorHash(&bench)).?);
    const page = try logPage(&bench);
    var tables: usize = 0;
    var paragraphs: usize = 0;
    for (page.shown) |index| {
        switch (page.blocks[index].kind) {
            .table => tables += 1,
            .paragraph => paragraphs += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), tables);
    try testing.expectEqual(@as(usize, 0), paragraphs);
    // The table shows the page's columns, its full hash data only.
    for (page.blocks) |block| {
        const table = block.table orelse continue;
        try testing.expectEqual(@as(usize, 5), table.columns.len);
        try testing.expectEqual(rows.getSchema().fieldIndex("subject").?, table.fill);
    }
}

test "vcs git log: an answer in another shape leaves the table with what parsed, marks it unread, tells *Messages* once and faults nothing; the next good answer clears the mark" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "--oneline -n 3 HEAD");
    // A commit read, then what `--oneline` printed.
    try answer(&bench, try onlyJob(&bench, .log), 0, first_commit ++ "2222222 Fix the spinner\x003333333 Start\x00");
    try testing.expectEqual(@as(u32, 1), logTable(&bench).count());
    try testing.expectEqual(document_sources.SourceState.unread, sourceState(&bench).?);
    try testing.expectEqualStrings("The log's output could not be read as commits", note(&bench));
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expectEqual(@as(u32, 2), asked(&bench).unread.*);
    // The page draws the table as unread, in the error colour.
    const page = try logPage(&bench);
    for (page.blocks) |block| {
        const table = block.table orelse continue;
        try testing.expectEqual(document_sources.SourceState.unread, table.state);
    }
    // Told once, as it answered.
    try bench.act(.vcs_git_next);
    try testing.expectEqual(document_sources.SourceState.unread, sourceState(&bench).?);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), bench.told(&waiting).len);

    // Nothing read at all: the table is empty, still unread, the first record named.
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    _ = try bench.finish(try onlyJob(&bench, .log), 0, three_oneline, "");
    bench.run();
    const told = bench.told(&waiting);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("git log --oneline -n 3 HEAD: the output could not be read as commits (1111111 Teach the log its grid)", told[0]);
    try testing.expectEqual(@as(u32, 0), logTable(&bench).count());
    try testing.expectEqual(document_sources.SourceState.unread, sourceState(&bench).?);
    bench.forgetRequests();

    // A stat after a commit (`--stat`): the line told is one line.
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    _ = try bench.finish(try onlyJob(&bench, .log), 0, first_commit ++ "\n a.txt | 2 +-\n" ++ second_commit, "");
    bench.run();
    try testing.expectEqualStrings("git log --oneline -n 3 HEAD: the output could not be read as commits (a.txt | 2 +- 2222222222222222222222222222222222222222 222222)", bench.told(&waiting)[0]);
    bench.forgetRequests();

    // A query whose answer reads: the mark cleared, nothing told.
    try editQuery(&bench, "--oneline -n 3 HEAD", "-n 3 HEAD");
    try answer(&bench, try onlyJob(&bench, .log), 0, three_commits);
    try testing.expectEqual(document_sources.SourceState.ok, sourceState(&bench).?);
    try testing.expectEqualStrings("", note(&bench));
    try testing.expectEqual(@as(u32, 3), logTable(&bench).count());
}

test "vcs git log: a failed query tells and keeps the rows" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try editQuery(&bench, "-n 256 HEAD", "-n 3 no-such-branch");
    const job = try onlyJob(&bench, .log);
    _ = try bench.finish(job, 128, "", "fatal: bad revision\n");
    bench.run();
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("git log failed; $ shows why", bench.told(&waiting)[0]);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expectEqual(@as(u32, 3), logTable(&bench).count());
    try testing.expectEqualStrings("git log failed; $ shows why", note(&bench));
    // The query line says what was run.
    try testing.expectEqualStrings("git log -n 3 no-such-branch", try queryLine(&bench));
}

test "vcs git log: an answer with no commits says none match, and one past the table says how many it holds" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try answer(&bench, try onlyJob(&bench, .log), 0, "");
    try testing.expectEqualStrings("No commits match", note(&bench));
    try testing.expectEqual(@as(u32, 0), logTable(&bench).count());
    // One commit more than the table holds, as the default `--max-count` lets git list.
    const allocator = bench.arena.allocator();
    var said: std.ArrayList(u8) = .empty;
    for (0..git_log.max_commits + 1) |index| {
        // The short hash begins the full one, as git's does.
        try said.print(allocator, "{x:0>7}" ++ "0" ** 33 ++ "\x1f{x:0>7}\x1fAna\x1f2026-11-20\x1f\x1fCommit {d}\x00", .{ index, index, index });
    }
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try answer(&bench, try onlyJob(&bench, .log), 0, said.items);
    try testing.expectEqual(@as(u32, git_log.max_commits), logTable(&bench).count());
    try testing.expectEqualStrings("More than 4096 commits match; the panel lists the first 4096", note(&bench));
}

test "vcs git log: RET on a row shows the commit in the diff panel" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    // `n`, the panel's move, from the first row to the second.
    try bench.act(.vcs_git_next);
    try testing.expectEqualStrings(second_hash, (try cursorHash(&bench)).?);
    try bench.act(.vcs_git_visit);
    const job = try onlyJob(&bench, .show);
    try status_test.expectArgv(job, .{ .show = second_hash });
    try testing.expect(diff_test.panelShown(&bench));
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try answer(&bench, job, 0, second_shown);
    const built = try diff_test.diffLines(&bench);
    try testing.expect(diff_test.diffLine(built, "Commit:  " ++ second_hash) != null);
    try testing.expect(diff_test.diffLine(built, "Author:  Bo") != null);
    try testing.expect(diff_test.diffLine(built, "It turned twice.") != null);
    try testing.expect(diff_test.diffLine(built, " 1 file changed, 1 insertion(+), 1 deletion(-)") != null);
    _ = try diff_test.diffKey(built, "a.txt");
    _ = try diff_test.diffKey(built, "@@ -1,2 +1,2 @@");
    _ = try diff_test.diffKey(built, "+TWO");
    try testing.expectEqualStrings("2222222 Fix the spinner", diff_test.panelTitle(&bench));
    // Its hunks change nothing.
    try diff_test.diffActOn(&bench, "+TWO", .vcs_git_diff_stage);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Not in a commit", bench.told(&waiting)[0]);
}

test "vcs git log: the status's keys that change files tell they are not in the log, and run nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_stage);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("Not in the log", bench.told(&waiting)[0]);
    try expectNoJob(&bench);
}

test "vcs git log: a rerun keeps the cursor on its commit while it is listed, else on the first row" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try placeOn(&bench, "2222222");
    // Listed again, in another place: the cursor goes with it.
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try answer(&bench, try onlyJob(&bench, .log), 0, third_commit ++ second_commit ++ first_commit);
    try testing.expectEqualStrings(second_hash, (try cursorHash(&bench)).?);
    // Not listed: the first row.
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try answer(&bench, try onlyJob(&bench, .log), 0, first_commit ++ third_commit);
    try testing.expectEqualStrings(first_hash, (try cursorHash(&bench)).?);
}

test "vcs git log: a commit shown from the log leaves the log as it was, its cursor where it was" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_last);
    try testing.expectEqualStrings(third_hash, (try cursorHash(&bench)).?);
    try bench.act(.vcs_git_visit);
    try answer(&bench, try onlyJob(&bench, .show), 0, second_shown);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    // The diff panel closed, the log is as it was; `$` and `q` back to it, then `q` to the
    // status, and the log's page kept its cursor.
    try diff_test.diffAct(&bench, .vcs_git_diff_close);
    try testing.expect(!diff_test.panelShown(&bench));
    try bench.act(.vcs_git_process_log);
    try testing.expectEqual(git_status.View.process_log, viewShown(&bench));
    try bench.act(.vcs_git_quit);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expectEqualStrings(third_hash, (try cursorHash(&bench)).?);
    try bench.act(.vcs_git_quit);
    try testing.expectEqual(git_status.View.status, viewShown(&bench));
    try testing.expectEqualStrings(third_hash, (try cursorHash(&bench)).?);
}

test "vcs git log: RET on a Recent commits line shows that commit in the diff panel, and the status stays" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try status_test.visitCommit(&bench, "5fa486e");
    const job = try onlyJob(&bench, .show);
    try status_test.expectArgv(job, .{ .show = "5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f" });
    try testing.expect(diff_test.panelShown(&bench));
    try testing.expectEqual(git_status.View.status, viewShown(&bench));
    try diff_test.diffAct(&bench, .vcs_git_diff_close);
    try testing.expectEqual(git_status.View.status, viewShown(&bench));
}

test "vcs git log: o asks for the refs once and writes the choice into the query" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try status_test.openAnswered(&bench);
    try openLog(&bench, &.{}, "o");
    const refs = try onlyJob(&bench, .refs);
    try status_test.expectArgv(refs, .refs);
    const listed = "refs/heads/main\x1fmain\x1forigin/main\x1f*\nrefs/heads/feature\x1ffeature\x1f\x1f \nrefs/remotes/origin/main\x1forigin/main\x1f\x1f \n";
    _ = try bench.finish(refs, 0, listed, "");
    bench.run();
    const prompt = bench.dialog().?;
    try testing.expectEqual(@as(usize, 3), prompt.completions.entries.len);
    bench.requests().reset();
    try bench.choose(prompt, "feature");
    // The refs are asked once, the log once: two processes.
    try expectLogArgv(try onlyJob(&bench, .log), "-n 256 feature");
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
}

test "vcs git log: c f on a log row makes a fixup of that row's commit" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_next);
    try chooseIn(&bench, Atom.from(git_commit.Msg.vcs_git_commit_menu), &git_commit.menu, &.{}, "f");
    const fixup = try status_test.expectCommand(&bench, .{ .commit = .{ .kind = .fixup, .target = second_hash } }, "");
    // Made, the fixup is in the log: its query is run again, the log still shown.
    _ = try bench.finish(fixup, 0, "", "");
    bench.run();
    var storage: [8]runner.Job = undefined;
    const log = try Bench.jobFor(bench.queued(&storage), .log);
    try expectLogArgv(log, "-n 256 HEAD");
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
}

test "vcs git log: a show that fails tells, the diff panel says so, and g asks again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_visit);
    const job = try onlyJob(&bench, .show);
    _ = try bench.finish(job, 128, "", "fatal: bad object\n");
    bench.run();
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("git show failed; $ shows why", bench.told(&waiting)[0]);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "Not shown; g asks again") != null);
    bench.forgetRequests();
    try diff_test.diffAct(&bench, .vcs_git_diff_refresh);
    const again = try onlyJob(&bench, .show);
    try status_test.expectArgv(again, .{ .show = first_hash });
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "Loading...") != null);
}

test "vcs git log: C-g while a query runs gives it up, and the note says so" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    // With commits listed before: they stay.
    try openAnsweredLog(&bench);
    try openLog(&bench, &.{ option(.author, "kiran"), option(.limit, "3") }, "l");
    try testing.expectEqualStrings("git log -n 3 --author=kiran HEAD", try queryLine(&bench));
    const again = try onlyJob(&bench, .log);
    try bench.markRunning(again);
    try bench.act(.vcs_git_give_up);
    try testing.expectEqualStrings("Gave up; g asks again", note(&bench));
    // Its answer, come late, is dropped.
    _ = try bench.finish(again, 0, "", "");
    bench.run();
    try testing.expectEqual(@as(u32, 3), logTable(&bench).count());
    bench.forgetRequests();
    // `g` asks the query given up, the one the line shows.
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try expectLogArgv(try onlyJob(&bench, .log), "-n 3 --author=kiran HEAD");
}

test "vcs git log: C-g while a show runs leaves the diff panel saying it was not shown" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_visit);
    try bench.markRunning(try onlyJob(&bench, .show));
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "Loading...") != null);
    try bench.act(.vcs_git_give_up);
    try testing.expectEqual(git_status.View.log, viewShown(&bench));
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "Not shown; g asks again") != null);
}

test "vcs git log: a file folded in one commit shown starts open in the next" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_visit);
    try answer(&bench, try onlyJob(&bench, .show), 0, second_shown);
    try diff_test.diffActOn(&bench, "a.txt", .vcs_git_diff_toggle);
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "+TWO") == null);
    // Another commit that changes `a.txt` too: its file is open.
    try bench.act(.vcs_git_next);
    try bench.act(.vcs_git_visit);
    try answer(&bench, try onlyJob(&bench, .show), 0, second_shown);
    try testing.expect(diff_test.diffLine(try diff_test.diffLines(&bench), "+TWO") != null);
}

test "vcs git log: a large commit shows its files folded, and builds a file's hunks once it is opened" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_visit);
    const job = try onlyJob(&bench, .show);
    // Seventeen files, one past what is shown open.
    var said: std.ArrayList(u8) = .empty;
    const allocator = bench.arena.allocator();
    try said.appendSlice(allocator, first_hash ++ "\x1fAna\x1f2026-11-22\x1fMany files\n\x1e\n");
    for (0..git_diff.small_commit_files + 1) |index| {
        try said.print(allocator, "diff --git a/f{d}.txt b/f{d}.txt\nindex 1111111..2222222 100644\n--- a/f{d}.txt\n+++ b/f{d}.txt\n@@ -1 +1 @@\n-old\n+new\n", .{ index, index, index, index });
    }
    try answer(&bench, job, 0, said.items);
    const folded = try diff_test.diffLines(&bench);
    try testing.expect(diff_test.diffLine(folded, "17 files; tab opens one") != null);
    try testing.expect(diff_test.diffLine(folded, "@@ -1 +1 @@") == null);
    // Folded, a file's part is not parsed.
    for (folded.files) |part| try testing.expect(part.diff == null);
    try diff_test.diffActOn(&bench, "f3.txt", .vcs_git_diff_toggle);
    const opened = try diff_test.diffLines(&bench);
    var hunks: usize = 0;
    for (opened.lines) |line| {
        if (std.mem.eql(u8, line.text, "@@ -1 +1 @@")) hunks += 1;
    }
    try testing.expectEqual(@as(usize, 1), hunks);
}

test "vcs git log: q returns to the status" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_quit);
    try testing.expectEqual(git_status.View.status, viewShown(&bench));
}

test "vcs git log: each new answer lists the newest commit first" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    // Each answer writes the table again: its order stays the log's.
    for (0..3) |_| {
        try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
        try answer(&bench, try onlyJob(&bench, .log), 0, three_commits);
        var read = logTable(&bench).readQuery(git_log.LogRow);
        try testing.expectEqualStrings(first_hash, read.next().?.view.full_hash);
        try testing.expectEqualStrings(second_hash, read.next().?.view.full_hash);
        try testing.expectEqualStrings(third_hash, read.next().?.view.full_hash);
        try testing.expectEqualStrings(first_hash, (try cursorHash(&bench)).?);
    }
}

// ---- against a real git ------------------------------------------------------------------------

/// Runs frames of the runner and the panel until `done` says the panel has what the test waits
/// for and nothing of its runs; fails after a few seconds.
fn settleUntil(bench: *Bench, done: *const fn (bench: *Bench) bool) !void {
    for (0..1000) |_| {
        status_test.stepReal(bench);
        const busy = runner.busy(&bench.tables, sequencer.inboxOf(git_status.system()));
        if (!busy and done(bench)) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

fn statusRead(bench: *Bench) bool {
    const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
    var rows = state.readQuery(struct { answered: *u8, refresh_jobs: *u8 });
    const row = rows.next().?.view;
    return row.answered.* == 1 and row.refresh_jobs.* == 0;
}

fn logAnswered(bench: *Bench) bool {
    const cells = bench.tables.findByName(Atom.from(git_log.view_table_name)).?;
    var rows = cells.readQuery(struct { phase: *u8 });
    const phase = rows.next().?.view.phase.*;
    return phase == @intFromEnum(git_log.Phase.answered) or phase == @intFromEnum(git_log.Phase.failed);
}

fn commitShown(bench: *Bench) bool {
    const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
    var rows = state.readQuery(struct { diffs_loaded: *u8 });
    return rows.next().?.view.diffs_loaded.* & git_status.DiffSource.shown.bit() != 0;
}

/// Commits what is staged in `repository` as `author`, saying `message`.
fn commitAs(allocator: std.mem.Allocator, environment: *std.process.Environ.Map, repository: []const u8, author: []const u8, message: []const u8) !void {
    try environment.put("GIT_AUTHOR_NAME", author);
    defer _ = environment.swapRemove("GIT_AUTHOR_NAME");
    _ = try status_test.runGit(allocator, environment, repository, &.{ "commit", "-q", "-m", message });
}

test "vcs git log: queries typed as text, one that git prints in another shape, and a commit shown, in a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var folder = try status_test.repositoryFolder();
    defer folder.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try folder.dir.realPath(testing.io, &path_buffer);
    const top = path_buffer[0..path_length];
    // The person's own git configuration is kept out: an empty global file, and no system file.
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
    // Three commits by two authors: Ana's first and last, Bo's between.
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });
    try commitAs(allocator, &environment, repository, "Ana", "Start");
    try repository_dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "bee\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "b.txt" });
    try commitAs(allocator, &environment, repository, "Bo", "Add bees");
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\nTWO\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });
    try commitAs(allocator, &environment, repository, "Ana", "Shout two");

    var bench: Bench = .{ .working_directory = repository };
    try bench.init();
    defer bench.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&bench, &processes, &environment);
    defer processes.deinit(&bench.tables);
    try bench.act(.vcs_git_status);
    try settleUntil(&bench, statusRead);

    // The query typed: Ana's two commits, newest first, and Bo's not.
    try editQuery(&bench, git_log.default_query, "-n 256 --author=Ana HEAD");
    try settleUntil(&bench, logAnswered);
    const rows = logTable(&bench);
    try testing.expectEqual(@as(u32, 2), rows.count());
    var read = rows.readQuery(git_log.LogRow);
    const newest = read.next().?.view;
    try testing.expectEqualStrings("Shout two", newest.subject);
    try testing.expectEqualStrings("Ana", newest.author);
    const oldest = read.next().?.view;
    try testing.expectEqualStrings("Start", oldest.subject);
    try testing.expectEqualStrings("Ana", oldest.author);
    try testing.expectEqual(document_sources.SourceState.ok, sourceState(&bench).?);

    // RET on the newest: its file and its hunk, in the diff panel.
    try bench.act(.vcs_git_visit);
    try settleUntil(&bench, commitShown);
    const built = try diff_test.diffLines(&bench);
    try testing.expect(diff_test.diffLine(built, "Shout two") != null);
    _ = try diff_test.diffKey(built, "a.txt");
    _ = try diff_test.diffKey(built, "@@ -1,2 +1,2 @@");
    _ = try diff_test.diffKey(built, "-two");
    _ = try diff_test.diffKey(built, "+TWO");

    // `--oneline` typed by hand: git prints its own shape, which the table cannot read; marked,
    // told in `*Messages*`, and nothing faults.
    bench.forgetRequests();
    try editQuery(&bench, "-n 256 --author=Ana HEAD", "--oneline -n 256 HEAD");
    try settleUntil(&bench, logAnswered);
    try testing.expectEqual(document_sources.SourceState.unread, sourceState(&bench).?);
    try testing.expectEqualStrings("The log's output could not be read as commits", note(&bench));
    try testing.expectEqual(@as(u32, 3), asked(&bench).unread.*);
    var waiting: [16][]const u8 = undefined;
    var unread_lines: usize = 0;
    for (bench.told(&waiting)) |line| {
        if (std.mem.startsWith(u8, line, "git log --oneline -n 256 HEAD: the output could not be read as commits (")) unread_lines += 1;
    }
    try testing.expectEqual(@as(usize, 1), unread_lines);

    // A good query clears it.
    bench.forgetRequests();
    try editQuery(&bench, "--oneline -n 256 HEAD", "-n 2 HEAD");
    try settleUntil(&bench, logAnswered);
    try testing.expectEqual(document_sources.SourceState.ok, sourceState(&bench).?);
    try testing.expectEqualStrings("", note(&bench));
    try testing.expectEqual(@as(u32, 2), rows.count());
}

test "vcs git log: c f in the run whose answer took the cursor's commit away makes no fixup; the next run does" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try placeOn(&bench, "2222222");
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    const rerun = try onlyJob(&bench, .log);
    const menu_shown = try status_test.presentCommitMenu(&bench);
    bench.forgetRequests();
    // The answer, without the second commit, and `c f` land in one run, the answer first.
    _ = try bench.finish(rerun, 0, first_commit ++ third_commit, "");
    try status_test.deliverFixupChoice(&bench, menu_shown);
    bench.run();
    try status_test.expectNoCommand(&bench);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The log changed under the cursor", bench.told(&waiting)[0]);
    bench.forgetRequests();
    // The next run acts on the row the page now shows there.
    try testing.expectEqualStrings(first_hash, (try cursorHash(&bench)).?);
    try status_test.deliverFixupChoice(&bench, try status_test.presentCommitMenu(&bench));
    bench.run();
    _ = try status_test.expectCommand(&bench, .{ .commit = .{ .kind = .fixup, .target = first_hash } }, "");
}

test "vcs git log: an answer leaves a cursor on the query's line where it is" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try bench.act(.vcs_git_first);
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    try answer(&bench, try onlyJob(&bench, .log), 0, three_commits);
    try testing.expect(try cursorHash(&bench) == null);
    // RET there edits the query.
    try bench.act(.vcs_git_visit);
    try testing.expectEqualStrings("-n 256 HEAD", bench.dialog().?.completions.initial_query);
    try expectNoJob(&bench);
}

test "vcs git log: an answer that took the log's commit away refuses no key of the status's in the same run" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredLog(&bench);
    try placeOn(&bench, "2222222");
    try deliver(&bench, Atom.from(git_status.Msg.vcs_git_refresh));
    const rerun = try onlyJob(&bench, .log);
    // Back to the status, its cursor on a file.
    try bench.act(.vcs_git_quit);
    try testing.expectEqual(git_status.View.status, viewShown(&bench));
    try bench.placeCursor(try bench.spotOf(.untracked, "notes.txt"));
    bench.forgetRequests();
    // The log's answer, without the commit under the log's cursor, and `s` in the status, in one
    // run: the status did not change, and `s` stages.
    _ = try bench.finish(rerun, 0, first_commit ++ third_commit, "");
    try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), Atom.from(git_status.Msg.vcs_git_stage), &.{}, &.{});
    bench.run();
    _ = try status_test.expectCommand(&bench, .stage, "notes.txt\x00");
    var said: [8][]const u8 = undefined;
    for (bench.told(&said)) |line| try testing.expect(std.mem.indexOf(u8, line, "changed under the cursor") == null);
}

test "vcs git log: a query typed while the repository's root is not known is told, and its prompt does not open again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, status_test.changed_status, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, status_test.recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(jobs, .root), 1, "", "fatal: something\n");
    bench.run();
    bench.forgetRequests();
    try editQuery(&bench, git_log.default_query, "-n 5 HEAD");
    try expectNoJob(&bench);
    try testing.expect(bench.dialog() == null);
    var said: [8][]const u8 = undefined;
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings(git_status.root_unknown, told[0]);
}
