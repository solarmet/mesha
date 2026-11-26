//! Tests of Perforce's words (`p4.zig`): its command lines, what goes on their input, and its
//! parsers over literal outputs. Every fixture says where it comes from: the documentation's own
//! example (a page of the P4 command reference or user's guide), or constructed from the field
//! names and message formats Perforce publishes, where the documentation shows no example. No
//! fixture was captured from a running Perforce server: none was available.

const std = @import("std");
const mesha = @import("mesha");
const p4 = @import("p4.zig");

const testing = std.testing;
const diff_widget = mesha.ui.diff;

fn expectArgv(context: p4.Context, command: p4.Command, expected: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try p4.writeArgv(&writer, context, command);
    try testing.expectEqualStrings(expected, writer.buffered());
}

/// One command of each kind, for the test that iterates them all.
const every_command = [_]p4.Command{
    .info,
    .login_status,
    .{ .changes = .{ .client = "bruno_ws" } },
    .{ .history = .{ .max = 50, .user = "bruno", .path = "//depot/main/..." } },
    .{ .opened = "bruno_ws" },
    .{ .changes_query = "\x1f-m\x1f100\x1f//bruno_ws/..." },
    .shelved,
    .diff,
    .{ .describe = 4321 },
    .{ .change_form = .default },
    .save_change,
    .{ .delete_change = 77 },
    .{ .submit = .{ .numbered = 77 } },
    .{ .reopen = .{ .numbered = 410 } },
    .revert,
    .revert_unchanged,
    .{ .shelve = .{ .change = 77 } },
    .{ .unshelve = .{ .from = 65, .into = .{ .numbered = 77 } } },
    .{ .sync = .preview },
    .resolve,
    .{ .open = .{ .action = .edit, .into = .{ .numbered = 140 } } },
    .{ .reconcile = .{ .mode = .preview, .path = "//bruno_ws/..." } },
};

test "vcs p4: every command line has its global options first, and -x - only where files come on input" {
    // Every kind of command is in the list.
    for (std.meta.tags(std.meta.Tag(p4.Command))) |tag| {
        const listed = for (every_command) |command| {
            if (std.meta.activeTag(command) == tag) break true;
        } else false;
        try testing.expect(listed);
    }
    const context: p4.Context = .{ .client = "anotherclient" };
    for (every_command) |command| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try p4.writeArgv(&writer, context, command);
        var arguments = std.mem.splitScalar(u8, writer.buffered(), mesha.process.argument_separator);
        try testing.expectEqualStrings("p4", arguments.next().?);
        const output = p4.outputOf(command);
        if (output == .tagged) try testing.expectEqualStrings("-ztag", arguments.next().?);
        // The client is the global -c, before the command.
        try testing.expectEqualStrings("-c", arguments.next().?);
        try testing.expectEqualStrings("anotherclient", arguments.next().?);
        const input = p4.inputOf(command);
        const arguments_on_input = switch (input) {
            .depot_paths, .local_paths, .literal_paths, .change_numbers => true,
            .none, .form => false,
        };
        const next = arguments.next().?;
        if (arguments_on_input) {
            try testing.expectEqualStrings("-x", next);
            try testing.expectEqualStrings("-", arguments.next().?);
        } else {
            try testing.expect(!std.mem.eql(u8, next, "-x"));
        }
        // No global option after the command's name.
        while (arguments.next()) |argument| {
            try testing.expect(!std.mem.eql(u8, argument, "-ztag"));
            try testing.expect(!std.mem.eql(u8, argument, "anotherclient"));
            try testing.expect(!std.mem.eql(u8, argument, "-x"));
        }
    }
}

test "vcs p4: command lines are p4's arguments, the client's -c never the changelist's" {
    const none: p4.Context = .{};
    const ws: p4.Context = .{ .client = "bruno_ws" };
    try expectArgv(none, .info, "p4\x1f-ztag\x1finfo");
    try expectArgv(ws, .info, "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1finfo");
    try expectArgv(none, .login_status, "p4\x1f-ztag\x1flogin\x1f-s");
    try expectArgv(none, .{ .changes = .{ .client = "bruno_ws" } }, "p4\x1f-ztag\x1fchanges\x1f-s\x1fpending\x1f-l\x1f-c\x1fbruno_ws");
    try expectArgv(none, .{ .changes = .{ .status = .shelved, .client = "bruno_ws" } }, "p4\x1f-ztag\x1fchanges\x1f-s\x1fshelved\x1f-l\x1f-c\x1fbruno_ws");
    try expectArgv(none, .{ .history = .{ .max = 50 } }, "p4\x1f-ztag\x1fchanges\x1f-s\x1fsubmitted\x1f-l\x1f-m\x1f50");
    // A person's query after `-l`, as the splitter wrote it; none at all is `changes -l`.
    try expectArgv(ws, .{ .changes_query = "\x1f-u\x1fedk\x1f-m\x1f5" }, "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-l\x1f-u\x1fedk\x1f-m\x1f5");
    try expectArgv(none, .{ .changes_query = "" }, "p4\x1f-ztag\x1fchanges\x1f-l");
    try testing.expect(!p4.passes(none, .{ .changes_query = "\x1fa\nb" }));
    try testing.expect(!p4.passes(none, .{ .changes_query = "-m\x1f5" }));
    try expectArgv(none, .{ .history = .{ .max = 5, .user = "edk", .path = "//depot/project/..." } }, "p4\x1f-ztag\x1fchanges\x1f-s\x1fsubmitted\x1f-l\x1f-m\x1f5\x1f-u\x1fedk\x1f//depot/project/...");
    try expectArgv(ws, .{ .opened = "bruno_ws" }, "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1ffstat\x1f-Ro\x1f//bruno_ws/...");
    try expectArgv(ws, .shelved, "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fdescribe\x1f-S\x1f-s");
    try expectArgv(ws, .diff, "p4\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fdiff\x1f-du");
    try expectArgv(none, .{ .describe = 4321 }, "p4\x1fdescribe\x1f-du\x1f4321");
    try expectArgv(none, .{ .change_form = .default }, "p4\x1fchange\x1f-o");
    try expectArgv(none, .{ .change_form = .{ .numbered = 77 } }, "p4\x1fchange\x1f-o\x1f77");
    try expectArgv(none, .save_change, "p4\x1fchange\x1f-i");
    try expectArgv(none, .{ .delete_change = 77 }, "p4\x1f-ztag\x1fchange\x1f-d\x1f77");
    // The documentation's own example: `p4 -c new_client submit -c 100`.
    try expectArgv(.{ .client = "new_client" }, .{ .submit = .{ .numbered = 100 } }, "p4\x1f-ztag\x1f-c\x1fnew_client\x1fsubmit\x1f-c\x1f100");
    // The default changelist's description goes in its form, on the input.
    try expectArgv(none, .{ .submit = .default }, "p4\x1f-ztag\x1fsubmit\x1f-i");
    try testing.expectEqual(p4.Input.form, p4.inputOf(.{ .submit = .default }));
    try testing.expectEqual(p4.Input.none, p4.inputOf(.{ .submit = .{ .numbered = 1 } }));
    // `p4 -c anotherclient edit -c 140 file.c`, the global options page's example, with the file
    // on the input.
    try expectArgv(.{ .client = "anotherclient" }, .{ .open = .{ .action = .edit, .into = .{ .numbered = 140 } } }, "p4\x1f-ztag\x1f-c\x1fanotherclient\x1f-x\x1f-\x1fedit\x1f-c\x1f140");
    try expectArgv(none, .{ .open = .{ .action = .add } }, "p4\x1f-ztag\x1f-x\x1f-\x1fadd\x1f-f");
    try expectArgv(none, .{ .open = .{ .action = .delete, .into = .{ .numbered = 9 } } }, "p4\x1f-ztag\x1f-x\x1f-\x1fdelete\x1f-c\x1f9");
    try expectArgv(none, .{ .reopen = .default }, "p4\x1f-ztag\x1f-x\x1f-\x1freopen\x1f-c\x1fdefault");
    try expectArgv(none, .{ .reopen = .{ .numbered = 410 } }, "p4\x1f-ztag\x1f-x\x1f-\x1freopen\x1f-c\x1f410");
    try expectArgv(none, .revert, "p4\x1f-ztag\x1f-x\x1f-\x1frevert");
    try expectArgv(none, .revert_unchanged, "p4\x1f-ztag\x1f-x\x1f-\x1frevert\x1f-a");
    try expectArgv(none, .{ .shelve = .{ .change = 77 } }, "p4\x1f-ztag\x1fshelve\x1f-c\x1f77");
    try expectArgv(none, .{ .shelve = .{ .change = 77, .action = .replace } }, "p4\x1f-ztag\x1fshelve\x1f-r\x1f-c\x1f77");
    try expectArgv(none, .{ .shelve = .{ .change = 77, .action = .overwrite } }, "p4\x1f-ztag\x1fshelve\x1f-f\x1f-c\x1f77");
    try expectArgv(none, .{ .shelve = .{ .change = 77, .action = .discard } }, "p4\x1f-ztag\x1fshelve\x1f-d\x1f-c\x1f77");
    try expectArgv(none, .{ .unshelve = .{ .from = 65, .into = .{ .numbered = 77 } } }, "p4\x1f-ztag\x1funshelve\x1f-s\x1f65\x1f-c\x1f77");
    try expectArgv(none, .{ .unshelve = .{ .from = 65 } }, "p4\x1f-ztag\x1funshelve\x1f-s\x1f65");
    try expectArgv(none, .{ .sync = .sync }, "p4\x1f-ztag\x1fsync");
    try expectArgv(none, .{ .sync = .preview }, "p4\x1f-ztag\x1fsync\x1f-n");
    try expectArgv(none, .resolve, "p4\x1f-ztag\x1fresolve\x1f-am");
    try expectArgv(none, .{ .reconcile = .{ .mode = .preview, .path = "//bruno_ws/..." } }, "p4\x1f-ztag\x1freconcile\x1f-n\x1f//bruno_ws/...");
    try expectArgv(none, .{ .reconcile = .{ .mode = .open, .into = .{ .numbered = 12 }, .path = "//bruno_ws/..." } }, "p4\x1f-ztag\x1freconcile\x1f-c\x1f12\x1f//bruno_ws/...");
    // Without `-c` edit, add, delete and reconcile open files in the default changelist; only
    // reopen's page documents `-c default`.
    try expectArgv(none, .{ .reconcile = .{ .mode = .open, .path = "//bruno_ws/..." } }, "p4\x1f-ztag\x1freconcile\x1f//bruno_ws/...");
    try expectArgv(none, .{ .open = .{ .action = .edit } }, "p4\x1f-ztag\x1f-x\x1f-\x1fedit");

    // Names that would be read as options, or are no client's, are refused before anything is
    // written.
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, .{ .client = "-x" }, .info));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, .{ .client = "ws\x1fother" }, .info));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, none, .{ .changes = .{ .client = "-zackary" } }));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, none, .{ .changes = .{ .client = "zac*" } }));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, none, .{ .opened = "1234" }));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, none, .{ .history = .{ .max = 5, .user = "-a" } }));
    try testing.expectError(error.UnpassableArgument, p4.writeArgv(&writer, none, .{ .history = .{ .max = 5, .path = "-m" } }));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try testing.expect(!p4.passes(.{ .client = "a@b" }, .info));
    try testing.expect(p4.passes(.{ .client = "bruno_ws" }, .info));
    // `/` is allowed in a user's name, not in a client's.
    try testing.expect(p4.passes(none, .{ .history = .{ .max = 5, .user = "dept/bob" } }));
    try testing.expect(!p4.isClientName("dept/bob"));
    try testing.expect(p4.isUserName("dept/bob"));
}

test "vcs p4: files on the input are a line each, local names encoded, depot names as printed" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    // Depot paths as fstat printed them, already encoded: written as they are.
    try p4.writePaths(&writer, &.{ "//depot/path/status%40june.txt", "//depot/a b/c.txt" }, .depot_paths, .posix);
    try testing.expectEqualStrings("//depot/path/status%40june.txt\n//depot/a b/c.txt\n", writer.buffered());

    // A local name: `@`, `#`, `*` and `%` as the file specifications page encodes them.
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writePaths(&writer, &.{ "/home/bruno/ws/status@june.txt", "C:/ws/100% #1 *.txt" }, .local_paths, .posix);
    try testing.expectEqualStrings("/home/bruno/ws/status%40june.txt\nC:/ws/100%25 %231 %2A.txt\n", writer.buffered());

    // `add -f` takes the name as it is: encoding it would add `status%2540june.txt`.
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writePaths(&writer, &.{"/home/bruno/ws/status@june.txt"}, .literal_paths, .posix);
    try testing.expectEqualStrings("/home/bruno/ws/status@june.txt\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.UnpassableArgument, p4.writePaths(&writer, &.{ "/ws/a", "/ws/two\nlines" }, .local_paths, .posix));
    try testing.expectError(error.UnpassableArgument, p4.writePaths(&writer, &.{"-n"}, .literal_paths, .posix));
    try testing.expectError(error.UnpassableArgument, p4.writePaths(&writer, &.{"/ws/a...b"}, .local_paths, .posix));
    try testing.expectError(error.UnpassableArgument, p4.writePaths(&writer, &.{"/ws/not-depot"}, .depot_paths, .posix));
    try testing.expectError(error.UnpassableArgument, p4.writePaths(&writer, &.{""}, .depot_paths, .posix));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    // A Windows client's local paths in its own syntax, backslashes, special characters still
    // encoded; depot paths stay `/`-separated.
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writePaths(&writer, &.{"C:/Users/bruno/my ws/status@june.txt"}, .local_paths, .windows);
    try testing.expectEqualStrings("C:\\Users\\bruno\\my ws\\status%40june.txt\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writePaths(&writer, &.{"C:/ws/a@b.txt"}, .literal_paths, .windows);
    try testing.expectEqualStrings("C:\\ws\\a@b.txt\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writePaths(&writer, &.{"//depot/a/b.c"}, .depot_paths, .windows);
    try testing.expectEqualStrings("//depot/a/b.c\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try p4.writeChangeNumbers(&writer, &.{ 765, 987 });
    try testing.expectEqualStrings("765\n987\n", writer.buffered());
}

// Constructed from the field names `p4 -ztag describe` prints in the describe page's own example
// (https://help.perforce.com/helix-core/server-apps/cmdref/current/Content/CmdRef/p4_describe.html:
// `change`, `user`, `client`, `time`, `desc`, `status`, `changeType`), which `changes` is taken
// to share; the description of the first is three lines, ended as `-l` ends it with a line
// break, and the record separated by a blank line as `fstat`'s are.
const changes_fixture =
    "... change 412\n" ++
    "... time 1546621943\n" ++
    "... user bruno\n" ++
    "... client brn123\n" ++
    "... status pending\n" ++
    "... changeType public\n" ++
    "... desc Fix the loader.\n" ++
    "\n" ++
    "It read past the end of a short file.\n" ++
    "\n" ++
    "\n" ++
    "... change 2\n" ++
    "... time 1546620000\n" ++
    "... user bruno\n" ++
    "... client brn123\n" ++
    "... status pending\n" ++
    "... changeType restricted\n" ++
    "... desc x\n" ++
    "\n";

test "vcs p4: tagged records split at their key, a description's later lines kept with it" {
    var records = p4.parseTagged(changes_fixture, "change");
    const first = records.next().?;
    try testing.expectEqualStrings("412", first.get("change").?);
    try testing.expectEqualStrings("Fix the loader.\n\nIt read past the end of a short file.", first.get("desc").?);
    try testing.expectEqualStrings("public", first.get("changeType").?);
    try testing.expect(first.get("shelved") == null);
    const second = records.next().?;
    try testing.expectEqualStrings("x", second.get("desc").?);
    try testing.expect(records.next() == null);

    var changes: [1]p4.Change = undefined;
    const parsed = p4.parseChanges(changes_fixture, &changes);
    try testing.expectEqual(@as(u32, 2), parsed.records.seen);
    try testing.expectEqual(@as(u32, 1), parsed.records.kept);
    try testing.expectEqual(@as(u32, 412), changes[0].number);
    try testing.expectEqual(@as(i64, 1546621943), changes[0].time);
    try testing.expectEqualStrings("bruno", changes[0].user);
    try testing.expectEqual(p4.ChangeStatus.pending, changes[0].status);
    try testing.expectEqualStrings("Fix the loader.", changes[0].summary);
}

test "vcs p4: tagged input that is malformed is passed over, never read past" {
    // Lines before any field, a record cut short, a field with no value, a line of dots alone,
    // and bytes after the last record with no line break.
    const malformed = "Perforce client error:\n\tConnect to server failed\n... change\n... change 9\n... time 1\n... user an\n... client ws\n... \n...\n... desc cut sh";
    var records = p4.parseTagged(malformed, "change");
    var count: usize = 0;
    while (records.next()) |record| : (count += 1) {
        try testing.expect(count < 4);
        _ = record.get("desc");
    }
    try testing.expectEqual(@as(usize, 2), count);

    var changes: [4]p4.Change = undefined;
    const parsed = p4.parseChanges(malformed, &changes);
    // The record whose `change` has no number is unread; the other is kept, cut short as it is.
    try testing.expectEqual(@as(u32, 1), parsed.records.kept);
    try testing.expectEqual(@as(u32, 1), parsed.unread);
    try testing.expectEqual(@as(u32, 9), changes[0].number);
    try testing.expectEqualStrings("cut sh", changes[0].description);

    // Nothing at all, and a lone line break.
    var empty = p4.parseTagged("", "change");
    try testing.expect(empty.next() == null);
    var newline = p4.parseTagged("\n", "change");
    try testing.expect(newline.next() == null);
    var fields = p4.Fields.init("... ... otherOpen0 user1@ws1\r\n...... otherAction0 edit\n... isMapped\r\n");
    const nested = fields.next().?;
    try testing.expectEqual(@as(u8, 2), nested.level);
    try testing.expectEqualStrings("otherOpen0", nested.name);
    try testing.expectEqualStrings("user1@ws1", nested.value);
    // Nested as the fstat page prints it.
    const page_nested = fields.next().?;
    try testing.expectEqual(@as(u8, 2), page_nested.level);
    try testing.expectEqualStrings("otherAction0", page_nested.name);
    try testing.expectEqualStrings("edit", page_nested.value);
    const flag = fields.next().?;
    try testing.expectEqualStrings("isMapped", flag.name);
    try testing.expectEqualStrings("", flag.value);
    try testing.expect(fields.next() == null);
}

// Constructed: the fstat page's example record
// (https://help.perforce.com/helix-core/server-apps/cmdref/current/Content/CmdRef/p4_fstat.html,
// `p4 fstat -Oa //depot/main/release1/perl_proj/kitten.gif`) with a space put in its path, and
// the fields the page documents for an opened file (`action`, `change`, `type`, `unresolved`)
// added; a second file named as the file specifications page names `status@june.txt`
// (https://help.perforce.com/helix-core/server-apps/cmdref/current/Content/CmdRef/filespecs.html),
// its depot path encoded and its local one not, as the fstat page says of `depotFile` and
// `clientFile`; `change` `default` as `p4 opened` names the default changelist.
const opened_posix_fixture =
    "... depotFile //depot/main/release1/perl proj/kitten.gif\n" ++
    "... clientFile /home/bruno/main/release1/perl proj/kitten.gif\n" ++
    "... isMapped \n" ++
    "... headAction edit\n" ++
    "... headType binary\n" ++
    "... headTime 1422908282\n" ++
    "... headRev 4\n" ++
    "... headChange 25424\n" ++
    "... headModTime 1422908084\n" ++
    "... action edit\n" ++
    "... change 77\n" ++
    "... type binary\n" ++
    "... actionOwner bruno\n" ++
    "... workRev 4\n" ++
    "... haveRev 4\n" ++
    "... unresolved 1\n" ++
    "... otherOpen 1\n" ++
    "... ... otherOpen0 maria@maria_ws\n" ++
    "... ... otherAction0 edit\n" ++
    "\n" ++
    "... depotFile //depot/path/status%40june.txt\n" ++
    "... clientFile /home/bruno/path/status@june.txt\n" ++
    "... isMapped \n" ++
    "... action add\n" ++
    "... change default\n" ++
    "... type text\n" ++
    "... actionOwner bruno\n" ++
    "\n";

// Constructed: a Windows workspace's record, its `clientFile` in local syntax as the file
// specifications page writes one (`c:\staff\bruno\myworkspace\file.c`), the lines ended as a
// Windows console program's are.
const opened_windows_fixture =
    "... depotFile //depot/source/module/file.c\r\n" ++
    "... clientFile c:\\staff\\bruno\\myworkspace\\file.c\r\n" ++
    "... isMapped \r\n" ++
    "... action move/add\r\n" ++
    "... change 140\r\n" ++
    "... type text\r\n" ++
    "... movedFile //depot/source/module/old.c\r\n" ++
    "\r\n";

test "vcs p4: opened files keep their depot path, a local path /-separated, their changelist and state" {
    var scratch_bytes: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    var files: [4]p4.Opened = undefined;
    const parsed = try p4.parseOpened(opened_posix_fixture, .posix, scratch.allocator(), &files);
    try testing.expectEqual(@as(u32, 2), parsed.records.kept);
    try testing.expectEqual(@as(u32, 0), parsed.unread);
    try testing.expectEqualStrings("//depot/main/release1/perl proj/kitten.gif", files[0].depot_path);
    try testing.expectEqualStrings("/home/bruno/main/release1/perl proj/kitten.gif", files[0].local_path);
    try testing.expectEqual(p4.Changelist{ .numbered = 77 }, files[0].change);
    try testing.expectEqual(p4.FileAction.edit, files[0].action);
    try testing.expectEqualStrings("binary", files[0].file_type);
    try testing.expectEqual(p4.Resolve.unresolved, files[0].resolve);
    try testing.expectEqualStrings("//depot/path/status%40june.txt", files[1].depot_path);
    try testing.expectEqualStrings("/home/bruno/path/status@june.txt", files[1].local_path);
    try testing.expectEqual(p4.Changelist.default, files[1].change);
    try testing.expectEqual(p4.FileAction.add, files[1].action);
    try testing.expectEqual(p4.Resolve.resolved, files[1].resolve);
    // A posix path's backslash is a character of its name, never copied.
    try testing.expectEqual(@as(usize, 0), scratch.end_index);

    const windows = try p4.parseOpened(opened_windows_fixture, .windows, scratch.allocator(), &files);
    try testing.expectEqual(@as(u32, 1), windows.records.kept);
    try testing.expectEqualStrings("c:/staff/bruno/myworkspace/file.c", files[0].local_path);
    try testing.expectEqual(p4.FileAction.move_add, files[0].action);
    try testing.expectEqualStrings("//depot/source/module/old.c", files[0].moved_path);
    try testing.expectEqual(p4.Changelist{ .numbered = 140 }, files[0].change);
}

// Constructed: `describe -S -s` of two changelists, tagged, each file's fields numbered from 0 as
// the fstat page numbers `otherOpen0`; the record's own fields are those of the describe page's
// example. The numbered names (`depotFile0`, `action0`, `type0`, `rev0`) are not on any page.
const shelved_fixture =
    "... change 65\n" ++
    "... user bruno\n" ++
    "... client brn123\n" ++
    "... time 1546621943\n" ++
    "... desc Shelved for review\n" ++
    "\n" ++
    "... status pending\n" ++
    "... changeType public\n" ++
    "... shelved \n" ++
    "... depotFile0 //depot/a.c\n" ++
    "... action0 edit\n" ++
    "... type0 text\n" ++
    "... rev0 3\n" ++
    "... depotFile1 //depot/new file.c\n" ++
    "... action1 add\n" ++
    "... type1 text\n" ++
    "... rev1 none\n" ++
    "\n" ++
    "... change 66\n" ++
    "... user bruno\n" ++
    "... client brn123\n" ++
    "... time 1546621950\n" ++
    "... desc Another\n" ++
    "\n" ++
    "... status pending\n" ++
    "... changeType public\n" ++
    "... shelved \n" ++
    "... depotFile0 //depot/b.c\n" ++
    "... action0 delete\n" ++
    "... type0 text\n" ++
    "... rev0 7\n" ++
    "\n";

test "vcs p4: shelved files of several changelists, by changelist" {
    var changes: [2]p4.Change = undefined;
    var files: [2]p4.ShelvedFile = undefined;
    const described = p4.parseDescribe(shelved_fixture, &changes, &files);
    try testing.expectEqual(@as(u32, 2), described.changes.kept);
    try testing.expectEqual(@as(u32, 3), described.files.seen);
    try testing.expectEqual(@as(u32, 2), described.files.kept);
    try testing.expectEqualStrings("Shelved for review", changes[0].description);
    try testing.expectEqual(@as(u32, 65), files[0].change);
    try testing.expectEqualStrings("//depot/a.c", files[0].depot_path);
    try testing.expectEqual(p4.FileAction.edit, files[0].action);
    try testing.expectEqualStrings("3", files[0].revision);
    try testing.expectEqualStrings("//depot/new file.c", files[1].depot_path);
    try testing.expectEqual(p4.FileAction.add, files[1].action);
}

// Constructed from the fields the brief names (`userName`, `clientName`, `clientRoot`,
// `serverAddress`): the info page documents `p4 -ztag info` only by its `unloadSupport`,
// `tenantID` and `datasetID` fields.
const info_fixture =
    "... userName bruno\n" ++
    "... clientName bruno_ws\n" ++
    "... clientRoot c:\\staff\\bruno\\myworkspace\n" ++
    "... clientHost bruno-pc\n" ++
    "... serverAddress someaddress.perforce.com:1999\n" ++
    "... unloadSupport disabled\n" ++
    "\n";

test "vcs p4: info names the user, the workspace and its root, /-separated" {
    var scratch_bytes: [128]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    const info = try p4.parseInfo(info_fixture, .windows, scratch.allocator());
    try testing.expectEqualStrings("bruno", info.user);
    try testing.expectEqualStrings("bruno_ws", info.client);
    try testing.expectEqualStrings("c:/staff/bruno/myworkspace", info.client_root);
    try testing.expectEqualStrings("someaddress.perforce.com:1999", info.server_address);
    try testing.expect(info.hasClient());
    const unknown = try p4.parseInfo("... userName bruno\n... clientName *unknown*\n\n", .posix, scratch.allocator());
    try testing.expect(!unknown.hasClient());
    // `p4_info.html`'s own case of no workspace: the client name is the host's, and there is
    // no root.
    const host_named = try p4.parseInfo("... userName bruno\n... clientName myserver-24-n102\n... clientHost myserver-24-n102.dhcp.perforce.com\n... serverAddress someaddress.perforce.com:1999\n\n", .posix, scratch.allocator());
    try testing.expectEqualStrings("myserver-24-n102", host_named.client);
    try testing.expect(!host_named.hasClient());
}

// From the P4 User's Guide's submit form
// (https://www.perforce.com/manuals/v14.2/p4guide/chapter.files.html, served from
// legacy-docs.perforce.com), with a comment line and the form's indentation written as a tab, as
// the change page asks that a line under a field be indented.
const form_fixture =
    "# A changelist form.\n" ++
    "\n" ++
    "Change:\tnew\n" ++
    "\n" ++
    "Client:\tbruno_ws\n" ++
    "\n" ++
    "User:\tbruno\n" ++
    "\n" ++
    "Status:\tnew\n" ++
    "\n" ++
    "Description:\n" ++
    "\t<enter description here>\n" ++
    "\n" ++
    "Type:\tpublic\n" ++
    "\n" ++
    "Files:\n" ++
    "\t//depot/dev/main/docs/manuals/installnotes.txt\t# add\n" ++
    "\t//depot/dev/main/docs/manuals/requirements.txt\t# add\n";

test "vcs p4: a change form is written with a description of three lines, and read back" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try p4.writeChangeForm(&writer, form_fixture, "Fix the loader.\n\nIt read past the end.", .keep);
    const written = writer.buffered();
    try testing.expectEqualStrings(
        "# A changelist form.\n\nChange:\tnew\n\nClient:\tbruno_ws\n\nUser:\tbruno\n\nStatus:\tnew\n\n" ++
            "Description:\n\tFix the loader.\n\t\n\tIt read past the end.\n\n" ++
            "Type:\tpublic\n\nFiles:\n" ++
            "\t//depot/dev/main/docs/manuals/installnotes.txt\t# add\n" ++
            "\t//depot/dev/main/docs/manuals/requirements.txt\t# add\n",
        written,
    );
    const form = p4.parseChangeForm(written);
    try testing.expectEqualStrings("new", form.change);
    try testing.expectEqualStrings("bruno_ws", form.client);
    try testing.expectEqualStrings("public", form.type);
    try testing.expectEqual(@as(u32, 2), form.file_count);
    var description_buffer: [128]u8 = undefined;
    var description = std.Io.Writer.fixed(&description_buffer);
    try p4.writeDescription(&description, form.description);
    try testing.expectEqualStrings("Fix the loader.\n\nIt read past the end.", description.buffered());

    // A new, empty changelist: the default changelist's files are left where they are.
    writer = std.Io.Writer.fixed(&buffer);
    try p4.writeChangeForm(&writer, form_fixture, "Empty", .drop);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Files:") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "installnotes") == null);
    try testing.expectEqual(@as(u32, 0), p4.parseChangeForm(writer.buffered()).file_count);
    // An existing changelist's form keeps its files: leaving them out would move them all to
    // the default changelist.
    const existing = "Change:\t77\n\nDescription:\n\tOld\n\nFiles:\n\t//depot/a.c\t# edit\n";
    writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(error.UnpassableArgument, p4.writeChangeForm(&writer, existing, "New", .drop));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    // What `change -i` says, as Perforce's message catalog writes it (`MsgDm::ChangeCreated`,
    // `ChangeUpdated`).
    try testing.expectEqual(@as(?u32, 1234), p4.parseChangeSaved("Change 1234 created.\n"));
    try testing.expectEqual(@as(?u32, 77), p4.parseChangeSaved("Change 77 updated, adding 1 file(s).\r\n"));
    try testing.expectEqual(@as(?u32, null), p4.parseChangeSaved("Change spec error\n"));
}

// Constructed from the header Perforce's published message catalog gives `p4 diff`
// (`MsgDm::DiffData`: `==== %depotFile%%depotRev% - %localPath% ====[ (%type%)]`) and the hunks its
// client's unified diff writes (`@@ -a,b +c,d @@` and no `---`/`+++` lines); the second file has
// a space in its name and a type after its header, and a third differs as a binary file does.
const diff_fixture =
    "==== //depot/main/a.c#3 - /home/bruno/ws/main/a.c ====\n" ++
    "@@ -1,3 +1,3 @@\n" ++
    " one\n" ++
    "-two\n" ++
    "+TWO\n" ++
    " three\n" ++
    "@@ -10,2 +10,3 @@\n" ++
    " ten\n" ++
    "+ten and a half\n" ++
    " eleven\n" ++
    "==== //depot/main/b file.txt#1 - /home/bruno/ws/main/b file.txt ==== (text+k)\n" ++
    "@@ -1 +1 @@\n" ++
    "-old\n" ++
    "+new\n" ++
    "==== //depot/main/logo.png#2 - /home/bruno/ws/main/logo.png ==== (binary)\n" ++
    "(... files differ ...)\n";

// Constructed from `MsgDm::DescribeDiff` (`\n==== %depotFile%%depotRev% (%type%[/%type2%]) ====\n`)
// after the lines `describe` writes before its differences.
const describe_fixture =
    "Change 4321 by bruno@brn123 on 2019/02/04 09:12:23\n" ++
    "\n" ++
    "\tFix the loader.\n" ++
    "\n" ++
    "Affected files ...\n" ++
    "\n" ++
    "... //depot/main/a.c#4 edit\n" ++
    "\n" ++
    "Differences ...\n" ++
    "\n" ++
    "==== //depot/main/a.c#4 (text) ====\n" ++
    "\n" ++
    "@@ -1,2 +1,2 @@\n" ++
    "-two\n" ++
    "+TWO\n" ++
    " three\n" ++
    "\n" ++
    "==== //depot/main/c.h#2 (text/ktext) ====\n" ++
    "\n" ++
    "@@ -5 +5 @@\n" ++
    "-five\n" ++
    "+FIVE\n";

test "vcs p4: the default changelist is submitted from its form, a description beginning with - and of three lines" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try p4.writeChangeForm(&writer, form_fixture, "-v flag removed\nfrom the loader\n-- and its test", .keep);
    const written = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "Description:\n\t-v flag removed\n\tfrom the loader\n\t-- and its test\n") != null);
    // `Change: new` and the default changelist's files, as `change -o` printed them: what is
    // submitted.
    const form = p4.parseChangeForm(written);
    try testing.expectEqualStrings("new", form.change);
    try testing.expectEqual(@as(u32, 2), form.file_count);
    var description_buffer: [128]u8 = undefined;
    var description = std.Io.Writer.fixed(&description_buffer);
    try p4.writeDescription(&description, form.description);
    try testing.expectEqualStrings("-v flag removed\nfrom the loader\n-- and its test", description.buffered());
}

test "vcs p4: a diff is split by Perforce's headers into its files, each with its hunks" {
    var files: [4]p4.FileDiff = undefined;
    var hunks: [8]diff_widget.Hunk = undefined;
    const counts = p4.parseDiff(diff_fixture, &files, &hunks);
    try testing.expectEqual(@as(u32, 3), counts.files.kept);
    try testing.expectEqual(@as(u32, 3), counts.hunks.kept);
    try testing.expectEqualStrings("//depot/main/a.c", files[0].depot_path);
    try testing.expectEqualStrings("3", files[0].revision);
    try testing.expectEqualStrings("/home/bruno/ws/main/a.c", files[0].local_path);
    try testing.expectEqual(@as(u32, 2), files[0].hunk_count);
    try testing.expectEqual(@as(u32, 0), files[0].first_hunk);
    try testing.expectEqual(@as(u32, 10), hunks[1].old_start);
    try testing.expectEqualStrings(" ten\n+ten and a half\n eleven\n", hunks[1].body);
    try testing.expectEqualStrings("//depot/main/b file.txt", files[1].depot_path);
    try testing.expectEqualStrings("/home/bruno/ws/main/b file.txt", files[1].local_path);
    try testing.expectEqualStrings("text+k", files[1].file_type);
    try testing.expectEqual(@as(u32, 2), files[1].first_hunk);
    try testing.expectEqualStrings("-old\n+new\n", hunks[2].body);
    try testing.expect(files[2].binary);
    try testing.expectEqual(@as(u32, 0), files[2].hunk_count);
    try testing.expectEqual(p4.DiffBody.hunks, p4.diffBodyOf(files[0]));
    try testing.expectEqual(p4.DiffBody.binary, p4.diffBodyOf(files[2]));

    // `describe -du`: the change's own lines passed over, the blank line before each header no
    // line of the hunk before it.
    const described = p4.parseDiff(describe_fixture, &files, &hunks);
    try testing.expectEqual(@as(u32, 2), described.files.kept);
    try testing.expectEqualStrings("//depot/main/a.c", files[0].depot_path);
    try testing.expectEqualStrings("4", files[0].revision);
    try testing.expectEqualStrings("text", files[0].file_type);
    try testing.expectEqualStrings("", files[0].local_path);
    try testing.expectEqualStrings("-two\n+TWO\n three\n", hunks[0].body);
    try testing.expectEqualStrings("text/ktext", files[1].file_type);
    try testing.expectEqual(@as(u32, 5), hunks[1].old_start);

    // Room for one file: the second's hunks are counted, not kept.
    var one_file: [1]p4.FileDiff = undefined;
    const short = p4.parseDiff(diff_fixture, &one_file, &hunks);
    try testing.expectEqual(@as(u32, 3), short.files.seen);
    try testing.expectEqual(@as(u32, 1), short.files.kept);
    try testing.expectEqual(@as(u32, 3), short.hunks.seen);
    try testing.expectEqual(@as(u32, 2), short.hunks.kept);
}

// Constructed: what a person's `P4DIFF` (a plain `diff`, its normal format) writes after
// `p4`'s headers, and a file with nothing after its header.
const external_diff_fixture =
    "==== //depot/main/a.c#3 - /home/bruno/ws/main/a.c ====\n" ++
    "2c2\n" ++
    "< two\n" ++
    "---\n" ++
    "> TWO\n" ++
    "==== //depot/main/same.c#1 - /home/bruno/ws/main/same.c ====\n";

test "vcs p4: a file's part that is no unified diff is told apart, its text kept" {
    var files: [2]p4.FileDiff = undefined;
    var hunks: [2]diff_widget.Hunk = undefined;
    const counts = p4.parseDiff(external_diff_fixture, &files, &hunks);
    try testing.expectEqual(@as(u32, 2), counts.files.kept);
    try testing.expectEqual(@as(u32, 0), counts.hunks.seen);
    try testing.expectEqual(p4.DiffBody.other, p4.diffBodyOf(files[0]));
    try testing.expectEqualStrings("2c2\n< two\n---\n> TWO\n", files[0].body);
    try testing.expectEqual(p4.DiffBody.empty, p4.diffBodyOf(files[1]));
    try testing.expectEqualStrings("P4DIFF=\x1fDIFF=\x1fP4DIFFUNICODE=", p4.internal_diff_environment);
}

test "vcs p4: a description's line beginning ... change is no changelist" {
    const phantom =
        "... change 412\n" ++
        "... time 1546621943\n" ++
        "... user bruno\n" ++
        "... client brn123\n" ++
        "... desc Quote a log:\n" ++
        "and more\n" ++
        "... change 99\n" ++
        "... status pending\n" ++
        "\n";
    var changes: [4]p4.Change = undefined;
    const parsed = p4.parseChanges(phantom, &changes);
    try testing.expectEqual(@as(u32, 1), parsed.records.kept);
    try testing.expectEqual(@as(u32, 1), parsed.unread);
    try testing.expectEqual(@as(u32, 412), changes[0].number);
    // The description ends where the phantom record began.
    try testing.expectEqualStrings("Quote a log:\nand more", changes[0].description);
    // Every field after the line is lost to the phantom record: the status too.
    try testing.expectEqual(@as(?p4.ChangeStatus, null), changes[0].status);
}

test "vcs p4: pending and shelved changelists are joined by number, the shelved list marking them" {
    var into: [3]p4.Change = .{
        .{ .number = 412, .status = .pending },
        .{ .number = 413, .status = .pending },
        undefined,
    };
    const shelved = [_]p4.Change{
        .{ .number = 413, .status = .shelved, .description = "from the shelved list" },
        .{ .number = 65, .status = .shelved },
        .{ .number = 66, .status = .shelved },
    };
    const merged = p4.mergeShelved(&into, .{ .seen = 2, .kept = 2 }, &shelved);
    try testing.expectEqual(@as(u32, 4), merged.seen);
    try testing.expectEqual(@as(u32, 3), merged.kept);
    try testing.expectEqual(p4.ChangeStatus.pending, into[0].status.?);
    try testing.expectEqual(p4.ChangeStatus.shelved, into[1].status.?);
    try testing.expectEqualStrings("", into[1].description);
    try testing.expectEqual(@as(u32, 65), into[2].number);

    // A pending list that did not fit: a shelved changelist not among those kept may be one of
    // those left out, so it is neither added nor counted again.
    var full: [2]p4.Change = .{
        .{ .number = 412, .status = .pending },
        .{ .number = 413, .status = .pending },
    };
    const overflowed = p4.mergeShelved(&full, .{ .seen = 3, .kept = 2 }, &shelved);
    try testing.expectEqual(@as(u32, 3), overflowed.seen);
    try testing.expectEqual(@as(u32, 2), overflowed.kept);
    try testing.expectEqual(p4.ChangeStatus.shelved, full[1].status.?);
}

test "vcs p4: a session is told by the exit codes of info and login -s, never by a sentence" {
    try testing.expectEqual(p4.Session.signed_in, p4.sessionOf(0, 0));
    // `info` needs no ticket; `login -s` fails without one.
    try testing.expectEqual(p4.Session.not_signed_in, p4.sessionOf(0, 1));
    // No server answered `info`: nothing is known of the ticket.
    try testing.expectEqual(p4.Session.unknown, p4.sessionOf(1, 1));
    try testing.expectEqual(p4.Session.unknown, p4.sessionOf(1, 0));
}
