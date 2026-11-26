//! The source of a document: org-mode text read into blocks. A document is an `.org` file and
//! nothing else; this reads its text, in one pass, into the blocks a document lays out and
//! draws, allocating nothing: every slice a block or a span holds is of the text, which the
//! caller keeps alive as long as it keeps them.
//!
//!     var blocks: [64]org.Block = undefined;
//!     var spans: [256]org.Span = undefined;
//!     const parsed = org.parse(text, &blocks, &spans);
//!     for (blocks[0..parsed.blocks_kept]) |block| switch (block.content) { ... }
//!
//! It reads the subset of org that documents use, and shows the rest as it is: what it does
//! not understand is a `text` block, a line of the source as written, and nothing after it is
//! lost. Lines end with LF or CRLF; no slice holds a line's end. The subset:
//!
//! - `#+TITLE: text`: the document's title (`title`). Keywords are read whatever their case.
//! - `#+REFRESH: 5s`: how often the document's sources are asked to refresh (`refresh`), a
//!   whole number of seconds (`5s`), minutes (`2m`) or hours (`1h`), more than none. Anything
//!   else (`5`, `1.5s`, `0s`) is text.
//! - `* Heading`, `** Sub`: a heading at the start of a line, its level the number of stars,
//!   a space after them (`heading`). What follows is its text, a TODO word or tags included.
//! - A paragraph: lines next to each other that are none of the rest, ended by a blank line or
//!   by any other element (`paragraph`). Org fills a paragraph: where one of its lines ended is
//!   a `line_end` span.
//! - `- term :: text`: an item of a description list (`term`), one line.
//! - `{{{name}}}`, `{{{name(argument)}}}`: a macro, inside the text of a title, a heading, a
//!   paragraph, a term or its description (`Span.macro`). A name is letters, digits, `-`,
//!   `_` and `.`; the argument is everything between the parentheses, as written. What is not
//!   such a macro (an unterminated `{{{`) is text. Which macros there are is not this file's:
//!   the document resolves them.
//! - `#+BEGIN: table :source name :columns "a b" :rows n :fill b` … `#+END:`: a dynamic block, a
//!   table a system publishes (`table`). Its parameters are in any order: `:source` is needed,
//!   `:columns` (one word, or several in double quotes), `:rows` (a whole number more than
//!   none, digits alone) and `:fill` (the one of `:columns` that takes the width the others
//!   leave; the last when not given) are not. Its body is what org would write when it brings
//!   the block up to date, which a document does as it draws: it is left empty, and a table
//!   whose body holds anything but blank lines is text, a body of `# comment` lines alone
//!   among them (a comment in a table's body is not dropped). A dynamic block of another name, or one whose parameters
//!   cannot be read (an unknown or repeated one, a quote not closed, no `:source`, `:rows` not
//!   such a number, `:fill` not one of `:columns`), is text, every line of it. A dynamic block ends at the first `#+END:`
//!   after it and may hold headings; one with no `#+END:` before the next `#+BEGIN:` or the end
//!   is its first line as text, and the lines after it are read as any other.
//! - `#+BEGIN: group :by name :key field :source name :columns "a b" :rows n :fill b`, one
//!   heading line, `#+END:`: a dynamic block of groups (`group`), a heading and a table for each
//!   row of the source `:by`, the table's rows those of `:source` whose `:key` field matches the
//!   row's. Its parameters are in any order: `:by`, `:key`, `:source` and `:columns` are needed,
//!   `:rows` (which caps each group's table) and `:fill` are as a table's. Its body is a
//!   template, not what org would write: one heading line (`** Change {{{change}}}`), its level
//!   the stars written, its text with macros the document fills from each group's row, and
//!   nothing else but blank lines. This departs from org, which holds no heading inside a
//!   block: org reads the template as a heading of the file, ending the block there, and has no
//!   writer named `group` to bring it up to date, so it leaves every line as written; here the
//!   lines from `#+BEGIN:` to `#+END:` are one block. No heading line, two, a line of anything else beside it, a
//!   parameter needed and not given, or one a group does not take, makes the block text, every
//!   line of it, as a table's mistakes do.
//! - `# comment`: a `#` and a space, or a `#` alone, after any indentation: dropped, as org does.
//!
//! Text, one line a block, as written:
//! - a `#+` keyword other than those above;
//! - a block (`#+BEGIN_SRC` … `#+END_SRC`, and every `#+BEGIN_name` … `#+END_name`) and a
//!   drawer (`:PROPERTIES:` … `:END:`), every line from its first to its last, nothing inside
//!   read; one not closed before the next heading or the end is its first line, as org holds
//!   no heading inside one;
//! - the items of plain lists (`- item`, `+ item`, `1. item`, an indented `* item`), the lines
//!   of org's own tables (`| a | b |`) and rules (`-----`), so they keep their lines.
//! Links (`[[target][name]]`), emphasis and the like are not read inside text: they are shown
//! as written.
//!
//! A dynamic block is read in two steps, so another kind is one more case: its first line,
//! body and last line are found whatever its name (`DynamicBlock`), and then its name says how
//! its parameters (`readParameters`) and body are read (`readDynamicBlock`).
const std = @import("std");

/// How often a document's sources are asked to refresh, in seconds; more than none.
pub const Seconds = u32;

/// A run of the `spans` given to `parse`: a block's text, its pieces in order. Holding a range
/// rather than a slice keeps a block small and lets `parse` allocate nothing.
pub const Spans = struct {
    /// The first span's index in the caller's `spans`.
    start: u32 = 0,
    /// How many spans there are.
    count: u32 = 0,

    /// The spans of `range`, of the `spans` that `parse` wrote: valid for a kept block.
    pub fn of(range: Spans, spans: []const Span) []const Span {
        return spans[range.start..][0..range.count];
    }
};

/// A macro in a document's text: a value the document asks for by name as it draws.
pub const Macro = struct {
    /// Its name, `vcs-git.branch` in `{{{vcs-git.branch}}}`.
    name: []const u8,
    /// What is between its parentheses as written, `vcs-git.untracked` in
    /// `{{{count(vcs-git.untracked)}}}`; empty for a macro with none.
    argument: []const u8,
    /// Whether it was written with parentheses, `{{{count()}}}`, an empty argument given, as
    /// against `{{{count}}}`, a name and nothing more.
    parenthesized: bool,
};

/// A piece of a block's text.
pub const Span = union(enum) {
    /// Text shown as written; never empty.
    text: []const u8,
    /// A macro, shown as its value.
    macro: Macro,
    /// Where a line of a paragraph ended and the next began; org joins them with a space as it
    /// fills the paragraph.
    line_end,
};

/// A heading: `* Heading`.
pub const Heading = struct {
    /// How deep it is: its number of stars, 1 for `*`.
    level: u8,
    /// Its text, after the stars and the space; trimmed.
    text: Spans,
};

/// An item of a description list: `- term :: text`.
pub const Term = struct {
    /// What is described, between `- ` and ` :: `; trimmed, never empty.
    term: Spans,
    /// What is said of it, after ` :: `; trimmed, may be empty.
    text: Spans,
};

/// A table a system publishes: `#+BEGIN: table :source name :columns "a b" :rows n :fill b`.
pub const Table = struct {
    /// The name of the source the rows are of, as a system publishes it (`vcs-git.unstaged`).
    source: []const u8,
    /// Which of the source's fields are shown, in order, separated by spaces (`columns` splits
    /// them); empty for every field the source shows.
    columns: []const u8,
    /// The most rows shown; null for all of them.
    rows: ?u32,
    /// The column, one of `columns`, that takes the width the others leave; empty for the last.
    fill: []const u8 = "",
};

/// A group of tables a system publishes: `#+BEGIN: group :by name :key field :source name
/// :columns "a b"`, its body one heading line. For each row of `by`, a heading made from
/// `heading`, and under it a table of the rows of `table.source` whose `key` matches the row's.
pub const Group = struct {
    /// The name of the source whose rows are the groups, one group a row (`vcs-p4.changelists`).
    by: []const u8,
    /// The field both sources hold whose cells say which group a row of `table.source` is in.
    key: []const u8,
    /// Each group's table: its source, columns, most rows and fill column, as a table block's.
    table: Table,
    /// The heading each group is shown under: its level as written, and its text, whose macros
    /// name the group row's fields.
    heading: Heading,
};

/// What a block is.
pub const Content = union(enum) {
    /// `#+TITLE:`: the document's title.
    title: Spans,
    /// `#+REFRESH:`: how often its sources are asked to refresh.
    refresh: Seconds,
    /// `* Heading`.
    heading: Heading,
    /// Lines of text, filled.
    paragraph: Spans,
    /// `- term :: text`.
    term: Term,
    /// A dynamic block of a table.
    table: Table,
    /// A dynamic block of a group of tables, one a row of another source.
    group: Group,
    /// A line not read, shown as it is, without its line end.
    text: []const u8,
};

/// A block of a document: a thing laid out on its own lines.
pub const Block = struct {
    /// The line of the source it begins on, from 1: for a message about the source.
    line: u32,
    /// What it is.
    content: Content,
};

/// How many blocks and spans `parse` found, and how many it wrote. What it wrote is a whole
/// prefix: the first `blocks_kept` blocks, whose spans are all among the first `spans_kept`.
/// Once a block or its spans did not fit, no later block is kept, so a first call with empty
/// slices says how large to make them.
pub const Parsed = struct {
    /// Blocks in the text.
    blocks_seen: u32 = 0,
    /// Blocks written: the first so many of those found.
    blocks_kept: u32 = 0,
    /// Spans the text's blocks hold.
    spans_seen: u32 = 0,
    /// Spans the kept blocks hold.
    spans_kept: u32 = 0,

    /// Whether every block and span found was written.
    pub fn complete(parsed: Parsed) bool {
        return parsed.blocks_kept == parsed.blocks_seen and parsed.spans_kept == parsed.spans_seen;
    }
};

/// The field names of a table's `columns`, in order: `columns("change path")` gives `change`,
/// then `path`.
pub fn columns(text: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, text, " \t");
}

/// Reads `text` into `blocks`, the spans of their text into `spans`, as many as fit, and says
/// how many there were. Allocates nothing; every slice written is of `text`.
pub fn parse(text: []const u8, blocks: []Block, spans: []Span) Parsed {
    var out: Output = .{ .blocks = blocks, .spans = spans };
    var lines: Lines = .{ .text = text };
    // The paragraph being read, until a line that is not one of its own ends it.
    var paragraph: ?OpenParagraph = null;
    while (lines.next()) |line| {
        const element = classify(line.text);
        if (element == .paragraph) {
            if (paragraph == null) {
                paragraph = .{ .line = line.number, .spans = out.openSpans() };
            } else {
                out.span(.line_end);
            }
            out.textSpans(element.paragraph);
            continue;
        }
        if (paragraph) |open| {
            const filled = out.closeSpans(open.spans);
            out.block(open.line, .{ .paragraph = filled });
            paragraph = null;
        }
        readElement(&out, &lines, line, element);
    }
    if (paragraph) |open| {
        const filled = out.closeSpans(open.spans);
        out.block(open.line, .{ .paragraph = filled });
    }
    return out.parsed;
}

/// A paragraph begun and not yet ended: its first line and its spans so far.
const OpenParagraph = struct { line: u32, spans: Spans };

/// Reads the element `line` begins, other than a paragraph's line, into `out`; one that spans
/// several lines takes them from `lines`.
fn readElement(out: *Output, lines: *Lines, line: Line, element: Element) void {
    switch (element) {
        .blank, .comment => {},
        .heading => |heading| {
            const opened = out.openSpans();
            out.textSpans(heading.text);
            const text = out.closeSpans(opened);
            out.block(line.number, .{ .heading = .{ .level = heading.level, .text = text } });
        },
        .term => |term| {
            const term_opened = out.openSpans();
            out.textSpans(term.term);
            const term_spans = out.closeSpans(term_opened);
            const text_opened = out.openSpans();
            out.textSpans(term.text);
            const text_spans = out.closeSpans(text_opened);
            out.block(line.number, .{ .term = .{ .term = term_spans, .text = text_spans } });
        },
        .keyword => |keyword| readKeyword(out, lines, line, keyword),
        .greater_block => |name| readEnclosed(out, lines, line, .{ .greater_block = name }),
        .drawer => readEnclosed(out, lines, line, .drawer),
        .verbatim => out.block(line.number, .{ .text = line.text }),
        .paragraph => unreachable,
    }
}

/// Reads a `#+KEY: value` line: the keywords a document knows, a dynamic block, and as text
/// any other.
fn readKeyword(out: *Output, lines: *Lines, line: Line, keyword: Keyword) void {
    if (std.ascii.eqlIgnoreCase(keyword.key, "TITLE")) {
        const opened = out.openSpans();
        out.textSpans(keyword.value);
        const title = out.closeSpans(opened);
        out.block(line.number, .{ .title = title });
        return;
    }
    if (std.ascii.eqlIgnoreCase(keyword.key, "REFRESH")) {
        if (readDuration(keyword.value)) |seconds| {
            out.block(line.number, .{ .refresh = seconds });
        } else {
            out.block(line.number, .{ .text = line.text });
        }
        return;
    }
    if (std.ascii.eqlIgnoreCase(keyword.key, "BEGIN")) return readDynamic(out, lines, line, keyword.value);
    out.block(line.number, .{ .text = line.text });
}

/// A dynamic block as found, before its name says what it is: `#+BEGIN: name parameters`, the
/// lines of its body, and `#+END:`. Its slices are of the text.
const DynamicBlock = struct {
    /// The word after `#+BEGIN:`: `table`. Compared as written, as org names a block's writer.
    name: []const u8,
    /// The rest of its first line, trimmed: `:source a :columns "b c"`.
    parameters: []const u8,
    /// The lines between its first and its last, with their line ends as written.
    body: []const u8,
};

/// What a dynamic block of a name this file knows is; null for one it does not, or whose
/// parameters or body cannot be read, which is shown as text. A kind of dynamic block is one
/// more case here.
/// A group's heading has spans, pushed to `out` only once the block is known to be read, so a
/// block shown as text leaves none behind.
fn readDynamicBlock(out: *Output, found: DynamicBlock) ?Content {
    if (std.mem.eql(u8, found.name, "table")) {
        // A table's body is what org writes as it brings the block up to date, which a document
        // does as it draws: only an empty one is passed over, so no text of an author's is lost.
        const body_blank = std.mem.indexOfNone(u8, found.body, " \t\r\n") == null;
        if (!body_blank) return null;
        const read = readParameters(found.parameters, .table) orelse return null;
        const table = tableOf(read) orelse return null;
        return .{ .table = table };
    }
    if (std.mem.eql(u8, found.name, "group")) {
        const read = readParameters(found.parameters, .group) orelse return null;
        const table = tableOf(read) orelse return null;
        const by = read.by orelse return null;
        const key = read.key orelse return null;
        if (table.columns.len == 0) return null;
        const template = onlyHeading(found.body) orelse return null;
        const opened = out.openSpans();
        out.textSpans(template.text);
        const text = out.closeSpans(opened);
        return .{ .group = .{ .by = by, .key = key, .table = table, .heading = .{ .level = template.level, .text = text } } };
    }
    return null;
}

/// The one heading line of a group's body, which holds nothing else but blank lines; null for a
/// body of no heading, of two, or of a line of anything else.
fn onlyHeading(body: []const u8) ?HeadingLine {
    var lines: Lines = .{ .text = body };
    var found: ?HeadingLine = null;
    while (lines.next()) |line| {
        if (trim(line.text).len == 0) continue;
        if (found != null) return null;
        const element = headingOf(line.text) orelse return null;
        found = .{ .level = element.heading.level, .text = element.heading.text };
    }
    return found;
}

/// A heading line as `headingOf` reads it: its level and its trimmed text.
const HeadingLine = struct { level: u8, text: []const u8 };

/// Reads the dynamic block `line` begins, `value` the rest of that line after `#+BEGIN:`.
fn readDynamic(out: *Output, lines: *Lines, line: Line, value: []const u8) void {
    const end = findEnd(lines.*, .dynamic_block) orelse {
        out.block(line.number, .{ .text = line.text });
        return;
    };
    const name_end = std.mem.indexOfAny(u8, value, " \t") orelse value.len;
    const found: DynamicBlock = .{
        .name = value[0..name_end],
        .parameters = trim(value[name_end..]),
        .body = lines.text[line.next..end.start],
    };
    if (readDynamicBlock(out, found)) |content| {
        out.block(line.number, content);
        lines.skipThrough(end);
        return;
    }
    emitVerbatim(out, lines, line, end);
}

/// Reads a block or a drawer that `first` begins: every line through its last as text, or
/// `first` alone as text when nothing closes it.
fn readEnclosed(out: *Output, lines: *Lines, first: Line, closer: Closer) void {
    const end = findEnd(lines.*, closer) orelse {
        out.block(first.number, .{ .text = first.text });
        return;
    };
    emitVerbatim(out, lines, first, end);
}

/// Writes `first`, then every line of `lines` through `last`, as text, one block a line.
fn emitVerbatim(out: *Output, lines: *Lines, first: Line, last: Line) void {
    out.block(first.number, .{ .text = first.text });
    while (lines.next()) |line| {
        out.block(line.number, .{ .text = line.text });
        if (line.number == last.number) return;
    }
}

/// What ends an element that spans lines.
const Closer = union(enum) {
    /// `#+END:`.
    dynamic_block,
    /// `#+END_name`, the name `#+BEGIN_name` gave, in any case.
    greater_block: []const u8,
    /// `:END:`.
    drawer,

    fn closes(closer: Closer, text: []const u8) bool {
        const trimmed = trim(text);
        return switch (closer) {
            .dynamic_block => std.ascii.eqlIgnoreCase(trimmed, "#+END:"),
            .greater_block => |name| trimmed.len == "#+END_".len + name.len and
                std.ascii.startsWithIgnoreCase(trimmed, "#+END_") and
                std.ascii.eqlIgnoreCase(trimmed["#+END_".len..], name),
            .drawer => std.ascii.eqlIgnoreCase(trimmed, ":END:"),
        };
    }
};

/// The line that ends the element begun on the line before `after`, the lines that follow it;
/// null when none does. A block or a drawer is not closed past the next heading, as org holds
/// no heading inside one. A dynamic block may hold a heading in its body (a kind that makes
/// headings from one, as a group would), so it is not closed past the next `#+BEGIN:`, which a
/// forgotten `#+END:` would otherwise take into its body with the block it begins.
fn findEnd(after: Lines, closer: Closer) ?Line {
    var lines = after;
    while (lines.next()) |line| {
        if (closer.closes(line.text)) return line;
        const stops = switch (closer) {
            .dynamic_block => isDynamicBegin(line.text),
            .greater_block, .drawer => headingOf(line.text) != null,
        };
        if (stops) return null;
    }
    return null;
}

/// Whether a line begins a dynamic block: `#+BEGIN:`, in any case, after any indentation.
fn isDynamicBegin(text: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(trim(text), "#+BEGIN:");
}

/// Reads a duration: a whole number more than none and a unit, `s`, `m` or `h`. Null for
/// anything else, or one past `Seconds`.
fn readDuration(value: []const u8) ?Seconds {
    if (value.len < 2) return null;
    const unit: Seconds = switch (value[value.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        else => return null,
    };
    const digits = value[0 .. value.len - 1];
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return null;
    const count = std.fmt.parseInt(Seconds, digits, 10) catch return null;
    const seconds = std.math.mul(Seconds, count, unit) catch return null;
    if (seconds == 0) return null;
    return seconds;
}

/// Which dynamic block's parameters are read: a group takes `:by` and `:key` besides a table's.
const BlockKind = enum { table, group };

/// A dynamic block's parameters as given, each null when not.
const ReadParameters = struct {
    source: ?[]const u8 = null,
    columns: ?[]const u8 = null,
    fill: ?[]const u8 = null,
    rows: ?u32 = null,
    by: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

/// Reads the parameters of a dynamic block of `kind`; null for one it does not take, one given
/// twice, a quote not closed, a name with no value (`:source`, `:fill`, `:by`, `:key`), or
/// `:rows` not a whole number more than none written with digits alone.
fn readParameters(parameters: []const u8, kind: BlockKind) ?ReadParameters {
    var read: ReadParameters = .{};
    var rows_given = false;
    var reader: Parameters = .{ .text = parameters };
    while (true) {
        const parameter = (reader.next() catch return null) orelse break;
        if (std.mem.eql(u8, parameter.key, ":source")) {
            if (read.source != null or parameter.value.len == 0) return null;
            read.source = parameter.value;
        } else if (std.mem.eql(u8, parameter.key, ":columns")) {
            if (read.columns != null) return null;
            read.columns = parameter.value;
        } else if (std.mem.eql(u8, parameter.key, ":rows")) {
            if (rows_given) return null;
            rows_given = true;
            if (parameter.value.len == 0) return null;
            for (parameter.value) |digit| if (!std.ascii.isDigit(digit)) return null;
            const count = std.fmt.parseInt(u32, parameter.value, 10) catch return null;
            if (count == 0) return null;
            read.rows = count;
        } else if (std.mem.eql(u8, parameter.key, ":fill")) {
            if (read.fill != null or parameter.value.len == 0) return null;
            read.fill = parameter.value;
        } else if (kind == .group and std.mem.eql(u8, parameter.key, ":by")) {
            if (read.by != null or parameter.value.len == 0) return null;
            read.by = parameter.value;
        } else if (kind == .group and std.mem.eql(u8, parameter.key, ":key")) {
            if (read.key != null or parameter.value.len == 0) return null;
            read.key = parameter.value;
        } else {
            return null;
        }
    }
    return read;
}

/// The table `read` gives; null with no `:source`, or a `:fill` not one of `:columns`.
fn tableOf(read: ReadParameters) ?Table {
    const source = read.source orelse return null;
    const named = read.columns orelse "";
    if (read.fill) |filling| {
        var each = columns(named);
        const among = while (each.next()) |column| {
            if (std.mem.eql(u8, column, filling)) break true;
        } else false;
        if (!among) return null;
    }
    return .{ .source = source, .columns = named, .rows = read.rows, .fill = read.fill orelse "" };
}

/// A dynamic block's parameter: `:key value`, `:key "a value"`, or `:key` with none.
const Parameter = struct {
    /// With its colon: `:source`.
    key: []const u8,
    /// A word, or what is between double quotes without them; empty when none is given.
    value: []const u8,
};

/// The parameters of a dynamic block's first line, in order.
const Parameters = struct {
    text: []const u8,
    position: usize = 0,

    /// The next parameter; null after the last; `error.Unreadable` at what is not a key, or
    /// a quote not closed.
    fn next(reader: *Parameters) error{Unreadable}!?Parameter {
        reader.skipBlanks();
        if (reader.position >= reader.text.len) return null;
        if (reader.text[reader.position] != ':') return error.Unreadable;
        const key = reader.word();
        if (key.len < 2) return error.Unreadable;
        reader.skipBlanks();
        if (reader.position >= reader.text.len or reader.text[reader.position] == ':') {
            return .{ .key = key, .value = "" };
        }
        if (reader.text[reader.position] != '"') return .{ .key = key, .value = reader.word() };
        const opened = reader.position + 1;
        const closed = std.mem.indexOfScalarPos(u8, reader.text, opened, '"') orelse return error.Unreadable;
        reader.position = closed + 1;
        return .{ .key = key, .value = reader.text[opened..closed] };
    }

    fn skipBlanks(reader: *Parameters) void {
        while (reader.position < reader.text.len and isBlank(reader.text[reader.position])) reader.position += 1;
    }

    fn word(reader: *Parameters) []const u8 {
        const start = reader.position;
        while (reader.position < reader.text.len and !isBlank(reader.text[reader.position])) reader.position += 1;
        return reader.text[start..reader.position];
    }
};

// ---- lines and what they begin ---------------------------------------------------------------

/// A line of the text.
const Line = struct {
    /// Its bytes, without its line end, LF or CRLF.
    text: []const u8,
    /// Its number, from 1.
    number: u32,
    /// Where it begins in the text.
    start: usize,
    /// Where the line after it begins: past its line end.
    next: usize,
};

/// The text's lines in order.
const Lines = struct {
    text: []const u8,
    position: usize = 0,
    number: u32 = 0,

    fn next(lines: *Lines) ?Line {
        if (lines.position >= lines.text.len) return null;
        const start = lines.position;
        const line_feed = std.mem.indexOfScalarPos(u8, lines.text, start, '\n');
        const end = line_feed orelse lines.text.len;
        const after = if (line_feed) |found| found + 1 else end;
        var text = lines.text[start..end];
        if (text.len != 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        lines.position = after;
        lines.number += 1;
        return .{ .text = text, .number = lines.number, .start = start, .next = after };
    }

    /// Goes on from the line after `line`, one `next` gave or will give.
    fn skipThrough(lines: *Lines, line: Line) void {
        lines.position = line.next;
        lines.number = line.number;
    }
};

/// `#+KEY: value`.
const Keyword = struct {
    /// Between `#+` and the colon, as written.
    key: []const u8,
    /// After the colon, trimmed.
    value: []const u8,
};

/// What a line begins.
const Element = union(enum) {
    /// Nothing but spaces and tabs.
    blank,
    /// `# comment`.
    comment,
    /// `* text`.
    heading: struct { level: u8, text: []const u8 },
    /// `- term :: text`, each trimmed.
    term: struct { term: []const u8, text: []const u8 },
    /// `#+KEY: value`.
    keyword: Keyword,
    /// `#+BEGIN_name`: the name.
    greater_block: []const u8,
    /// `:NAME:`.
    drawer,
    /// A line kept as written: a `#+` line that is no keyword, a plain list's item, a line of
    /// org's table, a rule.
    verbatim,
    /// A line of a paragraph: its text, trimmed.
    paragraph: []const u8,
};

fn classify(text: []const u8) Element {
    const trimmed = trim(text);
    if (trimmed.len == 0) return .blank;
    if (headingOf(text)) |heading| return heading;
    if (std.mem.eql(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "# ")) return .comment;
    if (std.mem.startsWith(u8, trimmed, "#+")) return classifyHash(trimmed);
    if (isDrawer(trimmed)) return .drawer;
    if (std.mem.startsWith(u8, trimmed, "- ")) {
        if (termOf(trimmed["- ".len..])) |term| return term;
        return .verbatim;
    }
    if (isVerbatim(trimmed)) return .verbatim;
    return .{ .paragraph = trimmed };
}

/// The heading `text` is, at the start of a line: stars, a space, its text; null for any other
/// line, and for more stars than a level holds.
fn headingOf(text: []const u8) ?Element {
    const stars = std.mem.indexOfNone(u8, text, "*") orelse text.len;
    if (stars == 0 or stars > std.math.maxInt(u8)) return null;
    if (stars >= text.len or text[stars] != ' ') return null;
    return .{ .heading = .{ .level = @intCast(stars), .text = trim(text[stars + 1 ..]) } };
}

/// A trimmed line beginning `#+`: a keyword, a greater block's beginning, or verbatim.
fn classifyHash(trimmed: []const u8) Element {
    const after = trimmed["#+".len..];
    const key_end = std.mem.indexOfAny(u8, after, ": \t") orelse after.len;
    const key = after[0..key_end];
    if (key_end < after.len and after[key_end] == ':') {
        return .{ .keyword = .{ .key = key, .value = trim(after[key_end + 1 ..]) } };
    }
    const begin = "BEGIN_";
    if (key.len > begin.len and std.ascii.startsWithIgnoreCase(key, begin)) return .{ .greater_block = key[begin.len..] };
    return .verbatim;
}

/// Whether a trimmed line opens a drawer: `:NAME:`, a name of letters, digits, `-` and `_`, other
/// than `END`.
fn isDrawer(trimmed: []const u8) bool {
    if (trimmed.len < 3 or trimmed[0] != ':' or trimmed[trimmed.len - 1] != ':') return false;
    const name = trimmed[1 .. trimmed.len - 1];
    for (name) |character| {
        const allowed = std.ascii.isAlphanumeric(character) or character == '-' or character == '_';
        if (!allowed) return false;
    }
    return !std.ascii.eqlIgnoreCase(name, "END");
}

/// A description list's item from what follows its `- `: a term, ` :: `, its text; null when it
/// has no ` :: ` after a term.
fn termOf(item: []const u8) ?Element {
    const separator = " :: ";
    if (std.mem.indexOf(u8, item, separator)) |found| {
        const term = trim(item[0..found]);
        if (term.len == 0) return null;
        return .{ .term = .{ .term = term, .text = trim(item[found + separator.len ..]) } };
    }
    const at_end = " ::";
    if (!std.mem.endsWith(u8, item, at_end)) return null;
    const term = trim(item[0 .. item.len - at_end.len]);
    if (term.len == 0) return null;
    return .{ .term = .{ .term = term, .text = "" } };
}

/// Whether a trimmed line is kept as written: an item of a plain list (`- `, `+ `, `1. `, `1) `,
/// or `* ` indented, which `headingOf` has not taken), a line of org's table, a rule.
fn isVerbatim(trimmed: []const u8) bool {
    if (std.mem.eql(u8, trimmed, "-") or std.mem.eql(u8, trimmed, "+")) return true;
    if (std.mem.startsWith(u8, trimmed, "+ ") or std.mem.startsWith(u8, trimmed, "* ")) return true;
    if (trimmed[0] == '|') return true;
    if (trimmed.len >= 5 and std.mem.indexOfNone(u8, trimmed, "-") == null) return true;
    const digits = std.mem.indexOfNone(u8, trimmed, "0123456789") orelse return false;
    if (digits == 0) return false;
    if (trimmed[digits] != '.' and trimmed[digits] != ')') return false;
    return digits + 1 == trimmed.len or trimmed[digits + 1] == ' ';
}

fn isBlank(character: u8) bool {
    return character == ' ' or character == '\t';
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

// ---- what is written ---------------------------------------------------------------------------

/// The caller's arrays and what `parse` has written to them.
const Output = struct {
    blocks: []Block,
    spans: []Span,
    parsed: Parsed = .{},
    /// Set once a block or its spans did not fit: no later block is kept, so those kept are a
    /// whole prefix.
    full: bool = false,

    /// The spans the next pushed begin, none yet.
    fn openSpans(out: *const Output) Spans {
        return .{ .start = out.parsed.spans_seen, .count = 0 };
    }

    /// The spans pushed since `opened`.
    fn closeSpans(out: *const Output, opened: Spans) Spans {
        return .{ .start = opened.start, .count = out.parsed.spans_seen - opened.start };
    }

    fn span(out: *Output, value: Span) void {
        const index = out.parsed.spans_seen;
        if (index < out.spans.len) out.spans[index] = value;
        out.parsed.spans_seen += 1;
    }

    /// Pushes `text`'s spans: its macros, and the text between them.
    fn textSpans(out: *Output, text: []const u8) void {
        var plain_start: usize = 0;
        var position: usize = 0;
        while (std.mem.indexOfPos(u8, text, position, "{{{")) |opened| {
            const macro = readMacro(text[opened..]) orelse {
                position = opened + 1;
                continue;
            };
            if (opened > plain_start) out.span(.{ .text = text[plain_start..opened] });
            out.span(.{ .macro = macro.macro });
            position = opened + macro.length;
            plain_start = position;
        }
        if (plain_start < text.len) out.span(.{ .text = text[plain_start..] });
    }

    /// Writes a block whose spans were all pushed before it, if it and they fit.
    fn block(out: *Output, line: u32, content: Content) void {
        const index = out.parsed.blocks_seen;
        out.parsed.blocks_seen += 1;
        if (out.full) return;
        const spans_end = out.parsed.spans_seen;
        if (index >= out.blocks.len or spans_end > out.spans.len) {
            out.full = true;
            return;
        }
        out.blocks[index] = .{ .line = line, .content = content };
        out.parsed.blocks_kept = index + 1;
        out.parsed.spans_kept = spans_end;
    }
};

/// A macro read at the start of some text, and how many bytes it takes.
const ReadMacro = struct { macro: Macro, length: usize };

/// The macro `text` begins with, `{{{name}}}` or `{{{name(argument)}}}`; null when it begins
/// with none.
fn readMacro(text: []const u8) ?ReadMacro {
    const name_start = "{{{".len;
    var position: usize = name_start;
    while (position < text.len and isNameCharacter(text[position])) position += 1;
    const name = text[name_start..position];
    if (name.len == 0) return null;
    const rest = text[position..];
    if (std.mem.startsWith(u8, rest, "}}}")) {
        return .{ .macro = .{ .name = name, .argument = "", .parenthesized = false }, .length = position + "}}}".len };
    }
    if (rest.len == 0 or rest[0] != '(') return null;
    const argument_start = position + 1;
    const closed = std.mem.indexOfPos(u8, text, argument_start, ")}}}") orelse return null;
    return .{ .macro = .{ .name = name, .argument = text[argument_start..closed], .parenthesized = true }, .length = closed + ")}}}".len };
}

fn isNameCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.';
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// A document read into arrays large enough for the tests'.
const TestParse = struct {
    blocks: [64]Block = undefined,
    spans: [256]Span = undefined,
    parsed: Parsed = .{},

    fn of(document: *TestParse, text: []const u8) []const Block {
        document.parsed = parse(text, &document.blocks, &document.spans);
        return document.blocks[0..document.parsed.blocks_kept];
    }

    fn spansOf(document: *const TestParse, range: Spans) []const Span {
        return range.of(document.spans[0..document.parsed.spans_kept]);
    }
};

fn expectText(expected: []const u8, span: Span) !void {
    try testing.expectEqualStrings(expected, span.text);
}

fn expectMacro(name: []const u8, argument: []const u8, span: Span) !void {
    try testing.expectEqualStrings(name, span.macro.name);
    try testing.expectEqualStrings(argument, span.macro.argument);
}

fn expectHeading(document: *const TestParse, level: u8, block: Block) ![]const Span {
    try testing.expectEqual(level, block.content.heading.level);
    return document.spansOf(block.content.heading.text);
}

fn expectTable(source: []const u8, table_columns: []const u8, rows: ?u32, block: Block) !void {
    try testing.expectEqualStrings(source, block.content.table.source);
    try testing.expectEqualStrings(table_columns, block.content.table.columns);
    try testing.expectEqual(rows, block.content.table.rows);
}

test "document: the vcs-git document reads to its title, refresh, terms, paragraphs, headings and tables" {
    var document: TestParse = .{};
    const blocks = document.of(@embedFile("vcs_git_document"));
    try testing.expect(document.parsed.complete());
    try testing.expectEqual(@as(usize, 18), blocks.len);

    const title = document.spansOf(blocks[0].content.title);
    try testing.expectEqual(@as(usize, 1), title.len);
    try expectText("vcs-git", title[0]);
    try testing.expectEqual(@as(u32, 1), blocks[0].line);
    try testing.expectEqual(@as(Seconds, 5), blocks[1].content.refresh);

    const head = blocks[2].content.term;
    try testing.expectEqual(@as(u32, 4), blocks[2].line);
    try expectText("Head", document.spansOf(head.term)[0]);
    const head_text = document.spansOf(head.text);
    try testing.expectEqual(@as(usize, 3), head_text.len);
    try expectMacro("vcs-git.branch", "", head_text[0]);
    try expectText("  ", head_text[1]);
    try expectMacro("vcs-git.head-subject", "", head_text[2]);
    const upstream = blocks[3].content.term;
    try expectText("Upstream", document.spansOf(upstream.term)[0]);
    const upstream_text = document.spansOf(upstream.text);
    try testing.expectEqual(@as(usize, 3), upstream_text.len);
    try expectMacro("vcs-git.upstream", "", upstream_text[0]);
    try expectMacro("vcs-git.ahead-behind", "", upstream_text[2]);

    const stashes = blocks[4].content.term;
    try expectText("Stashes", document.spansOf(stashes.term)[0]);
    try expectMacro("vcs-git.stashes", "", document.spansOf(stashes.text)[0]);

    const paragraphs = [_][]const u8{ "vcs-git.operation", "vcs-git.unlisted", "vcs-git.clean" };
    for (paragraphs, 5..) |name, index| {
        const said = document.spansOf(blocks[index].content.paragraph);
        try testing.expectEqual(@as(usize, 1), said.len);
        try expectMacro(name, "", said[0]);
    }

    const Expected = struct { heading: []const u8, count: []const u8, source: []const u8, columns: []const u8, rows: ?u32 };
    const expected = [_]Expected{
        .{ .heading = "Untracked files (", .count = "vcs-git.untracked-count", .source = "vcs-git.untracked", .columns = "path", .rows = null },
        .{ .heading = "Unmerged (", .count = "vcs-git.unmerged-count", .source = "vcs-git.unmerged", .columns = "change path", .rows = null },
        .{ .heading = "Unstaged changes (", .count = "vcs-git.unstaged-count", .source = "vcs-git.unstaged", .columns = "change path", .rows = null },
        .{ .heading = "Staged changes (", .count = "vcs-git.staged-count", .source = "vcs-git.staged", .columns = "change path", .rows = null },
        .{ .heading = "Recent commits", .count = "", .source = "vcs-git.commits", .columns = "hash subject author date", .rows = 10 },
    };
    for (expected, 0..) |section, index| {
        const heading = try expectHeading(&document, 1, blocks[8 + 2 * index]);
        try expectText(section.heading, heading[0]);
        if (section.count.len != 0) {
            try testing.expectEqual(@as(usize, 3), heading.len);
            try expectMacro(section.count, "", heading[1]);
            try expectText(")", heading[2]);
        } else {
            try testing.expectEqual(@as(usize, 1), heading.len);
        }
        try expectTable(section.source, section.columns, section.rows, blocks[9 + 2 * index]);
        const fill = if (section.rows != null) "subject" else "path";
        try testing.expectEqualStrings(fill, blocks[9 + 2 * index].content.table.fill);
    }
    var names = columns(blocks[17].content.table.columns);
    try testing.expectEqualStrings("hash", names.next().?);
    try testing.expectEqualStrings("subject", names.next().?);
    try testing.expectEqualStrings("author", names.next().?);
    try testing.expectEqualStrings("date", names.next().?);
    try testing.expect(names.next() == null);
}

test "document: ** Sub is a heading of level 2, and a paragraph's lines join" {
    var document: TestParse = .{};
    const blocks = document.of("* Top\n** Sub\n***not a heading\nfirst line\n  second line\n\nnext\n");
    try testing.expectEqual(@as(usize, 4), blocks.len);
    try expectText("Top", (try expectHeading(&document, 1, blocks[0]))[0]);
    try expectText("Sub", (try expectHeading(&document, 2, blocks[1]))[0]);
    const lines = document.spansOf(blocks[2].content.paragraph);
    try testing.expectEqual(@as(usize, 5), lines.len);
    try expectText("***not a heading", lines[0]);
    try testing.expect(lines[1] == .line_end);
    try expectText("first line", lines[2]);
    try expectText("second line", lines[4]);
    try testing.expectEqual(@as(u32, 3), blocks[2].line);
    try expectText("next", document.spansOf(blocks[3].content.paragraph)[0]);
    try testing.expectEqual(@as(u32, 7), blocks[3].line);
}

test "document: a source block, a drawer and a link come through as text" {
    var document: TestParse = .{};
    const source =
        \\#+BEGIN_SRC zig :results none
        \\#+TITLE: not read inside
        \\#+end_src
        \\:PROPERTIES:
        \\:ID: 42
        \\:END:
        \\See [[https://orgmode.org][org]] for {{{more}}}.
        \\# a comment, dropped
        \\#+AUTHOR: someone
        \\| a | b |
        \\- an item
    ;
    const blocks = document.of(source);
    const lines = [_][]const u8{ "#+BEGIN_SRC zig :results none", "#+TITLE: not read inside", "#+end_src", ":PROPERTIES:", ":ID: 42", ":END:" };
    try testing.expectEqual(@as(usize, lines.len + 4), blocks.len);
    for (lines, blocks[0..lines.len], 1..) |line, block, number| {
        try testing.expectEqualStrings(line, block.content.text);
        try testing.expectEqual(@as(u32, @intCast(number)), block.line);
    }
    const linked = document.spansOf(blocks[6].content.paragraph);
    try testing.expectEqual(@as(usize, 3), linked.len);
    try expectText("See [[https://orgmode.org][org]] for ", linked[0]);
    try expectMacro("more", "", linked[1]);
    try expectText(".", linked[2]);
    try testing.expectEqualStrings("#+AUTHOR: someone", blocks[7].content.text);
    try testing.expectEqualStrings("| a | b |", blocks[8].content.text);
    try testing.expectEqualStrings("- an item", blocks[9].content.text);
}

test "document: an unclosed or unknown #+BEGIN: is text and nothing after it is lost" {
    var document: TestParse = .{};
    const source =
        \\#+BEGIN: table :source left.open
        \\Still read.
        \\* After
        \\#+BEGIN: table :source second :columns "path"
        \\#+END:
        \\#+BEGIN: clocktable :scope file
        \\body
        \\#+END:
        \\#+BEGIN: table :source a :rows many
        \\#+END:
        \\#+BEGIN: table :source a :rows 0
        \\#+END:
        \\#+BEGIN: table :source a :rows +5
        \\#+END:
        \\#+BEGIN: table :source a :columns "path" :fill nowhere
        \\#+END:
        \\#+BEGIN: table :columns "path"
        \\#+END:
        \\#+BEGIN: table :source b
        \\stray author text
        \\#+END:
        \\#+BEGIN: table :source c
        \\
        \\#+END:
        \\#+BEGIN: table :source at.end
        \\Kept too.
    ;
    const blocks = document.of(source);
    try testing.expectEqual(@as(usize, 23), blocks.len);
    // The first has no #+END: before the second's #+BEGIN:, which is still a table.
    try testing.expectEqualStrings("#+BEGIN: table :source left.open", blocks[0].content.text);
    try expectText("Still read.", document.spansOf(blocks[1].content.paragraph)[0]);
    try expectText("After", (try expectHeading(&document, 1, blocks[2]))[0]);
    try expectTable("second", "path", null, blocks[3]);
    try testing.expectEqual(@as(u32, 4), blocks[3].line);
    const verbatim = [_][]const u8{
        "#+BEGIN: clocktable :scope file",                          "body",                              "#+END:",
        "#+BEGIN: table :source a :rows many",                      "#+END:",                            "#+BEGIN: table :source a :rows 0",
        "#+END:",                                                   "#+BEGIN: table :source a :rows +5", "#+END:",
        "#+BEGIN: table :source a :columns \"path\" :fill nowhere", "#+END:",                            "#+BEGIN: table :columns \"path\"",
        "#+END:",                                                   "#+BEGIN: table :source b",          "stray author text",
        "#+END:",
    };
    for (verbatim, blocks[4 .. 4 + verbatim.len], 6..) |line, block, number| {
        try testing.expectEqualStrings(line, block.content.text);
        try testing.expectEqual(@as(u32, @intCast(number)), block.line);
    }
    // A body of blank lines is passed over.
    try expectTable("c", "", null, blocks[20]);
    // Unclosed at the end of the text: its first line is text, and the rest is read.
    try testing.expectEqualStrings("#+BEGIN: table :source at.end", blocks[21].content.text);
    try expectText("Kept too.", document.spansOf(blocks[22].content.paragraph)[0]);
}

test "document: a dynamic block holding a heading is read whole, as text when its name is unknown" {
    var document: TestParse = .{};
    const source =
        \\#+BEGIN: other :by changes
        \\** Change {{{change}}}
        \\#+END:
        \\* Real
    ;
    const blocks = document.of(source);
    try testing.expectEqual(@as(usize, 4), blocks.len);
    const lines = [_][]const u8{ "#+BEGIN: other :by changes", "** Change {{{change}}}", "#+END:" };
    for (lines, blocks[0..lines.len], 1..) |line, block, number| {
        try testing.expectEqualStrings(line, block.content.text);
        try testing.expectEqual(@as(u32, @intCast(number)), block.line);
    }
    try expectText("Real", (try expectHeading(&document, 1, blocks[3]))[0]);
}

test "document: a group block reads its parameters in any order and its one heading line, macros and all" {
    var document: TestParse = .{};
    const source =
        \\* Pending
        \\#+BEGIN: group :by vcs-p4.changelists :key change :source vcs-p4.opened :columns "action path"
        \\
        \\** Change {{{change}}}  {{{description}}} ({{{count()}}})
        \\
        \\#+END:
        \\#+BEGIN: group :rows 5 :columns path :fill path :source s :key k :by b
        \\*** Other
        \\#+END:
        \\After.
    ;
    const blocks = document.of(source);
    try testing.expect(document.parsed.complete());
    try testing.expectEqual(@as(usize, 4), blocks.len);
    const group = blocks[1].content.group;
    try testing.expectEqual(@as(u32, 2), blocks[1].line);
    try testing.expectEqualStrings("vcs-p4.changelists", group.by);
    try testing.expectEqualStrings("change", group.key);
    try testing.expectEqualStrings("vcs-p4.opened", group.table.source);
    try testing.expectEqualStrings("action path", group.table.columns);
    try testing.expectEqual(@as(?u32, null), group.table.rows);
    try testing.expectEqualStrings("", group.table.fill);
    try testing.expectEqual(@as(u8, 2), group.heading.level);
    const heading = document.spansOf(group.heading.text);
    try testing.expectEqual(@as(usize, 7), heading.len);
    try expectText("Change ", heading[0]);
    try expectMacro("change", "", heading[1]);
    try expectText("  ", heading[2]);
    try expectMacro("description", "", heading[3]);
    try expectText(" (", heading[4]);
    try expectMacro("count", "", heading[5]);
    try expectText(")", heading[6]);

    const other = blocks[2].content.group;
    try testing.expectEqualStrings("b", other.by);
    try testing.expectEqualStrings("k", other.key);
    try testing.expectEqualStrings("s", other.table.source);
    try testing.expectEqual(@as(?u32, 5), other.table.rows);
    try testing.expectEqualStrings("path", other.table.fill);
    try testing.expectEqual(@as(u8, 3), other.heading.level);
    try expectText("Other", document.spansOf(other.heading.text)[0]);
    try expectText("After.", document.spansOf(blocks[3].content.paragraph)[0]);
}

test "document: a group block without exactly one heading line, or with a parameter wrong, is text and nothing after it is lost" {
    var document: TestParse = .{};
    const source =
        \\#+BEGIN: group :by b :key k :source s :columns "path"
        \\#+END:
        \\#+BEGIN: group :by b :key k :source s :columns "path"
        \\** One
        \\** Two
        \\#+END:
        \\#+BEGIN: group :by b :key k :source s :columns "path"
        \\** One
        \\a word beside it
        \\#+END:
        \\#+BEGIN: group :key k :source s :columns "path"
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :source s :columns "path"
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :key k :columns "path"
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :key k :source s
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :key k :source s :columns "path" :sort path
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :by c :key k :source s :columns "path"
        \\** One
        \\#+END:
        \\#+BEGIN: group :by b :key k :source s :columns "path" :rows 0
        \\** One
        \\#+END:
        \\#+BEGIN: table :by b :source s
        \\#+END:
        \\* Kept
    ;
    const blocks = document.of(source);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);
    var each = std.mem.splitScalar(u8, source, '\n');
    while (each.next()) |line| try lines.append(testing.allocator, line);
    const verbatim = lines.items[0 .. lines.items.len - 1];
    try testing.expectEqual(verbatim.len + 1, blocks.len);
    for (verbatim, blocks[0..verbatim.len], 1..) |line, block, number| {
        try testing.expectEqualStrings(line, block.content.text);
        try testing.expectEqual(@as(u32, @intCast(number)), block.line);
    }
    try expectText("Kept", (try expectHeading(&document, 1, blocks[verbatim.len]))[0]);
    // No spans were kept of the headings inside the blocks shown as text.
    try testing.expectEqual(@as(u32, 1), document.parsed.spans_kept);
}

test "document: {{{count()}}} is parenthesized with an empty argument, {{{count}}} a name alone" {
    var document: TestParse = .{};
    const blocks = document.of("{{{count()}}} {{{count}}}");
    const spans = document.spansOf(blocks[0].content.paragraph);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try expectMacro("count", "", spans[0]);
    try testing.expect(spans[0].macro.parenthesized);
    try expectMacro("count", "", spans[2]);
    try testing.expect(!spans[2].macro.parenthesized);
}

test "document: {{{count(x)}}} is the macro count with the argument x" {
    var document: TestParse = .{};
    const blocks = document.of("{{{count(x)}}} and {{{name}}}, not {{{open or {{{(x)}}}");
    const spans = document.spansOf(blocks[0].content.paragraph);
    try testing.expectEqual(@as(usize, 4), spans.len);
    try expectMacro("count", "x", spans[0]);
    try expectText(" and ", spans[1]);
    try expectMacro("name", "", spans[2]);
    try expectText(", not {{{open or {{{(x)}}}", spans[3]);
}

test "document: CRLF line ends read as LF" {
    const lf_source = @embedFile("vcs_git_document") ++ "#+BEGIN_SRC\nkept\n#+END_SRC\n#+AUTHOR: someone\nline one\nline two\n";
    var crlf_buffer: [2 * lf_source.len]u8 = undefined;
    _ = std.mem.replace(u8, lf_source, "\n", "\r\n", &crlf_buffer);
    const crlf_length = std.mem.replacementSize(u8, lf_source, "\n", "\r\n");
    const crlf_source = crlf_buffer[0..crlf_length];

    var lf: TestParse = .{};
    var crlf: TestParse = .{};
    const lf_blocks = lf.of(lf_source);
    const crlf_blocks = crlf.of(crlf_source);
    try testing.expect(lf.parsed.complete());
    try testing.expectEqual(lf.parsed, crlf.parsed);
    for (lf_blocks, crlf_blocks) |lf_block, crlf_block| {
        try testing.expectEqual(lf_block.line, crlf_block.line);
        try testing.expectEqual(std.meta.activeTag(lf_block.content), std.meta.activeTag(crlf_block.content));
        switch (lf_block.content) {
            .table => |table| try expectTable(table.source, table.columns, table.rows, crlf_block),
            .text => |text| try testing.expectEqualStrings(text, crlf_block.content.text),
            else => {},
        }
    }
    for (lf.spans[0..lf.parsed.spans_kept], crlf.spans[0..crlf.parsed.spans_kept]) |lf_span, crlf_span| {
        try testing.expectEqual(std.meta.activeTag(lf_span), std.meta.activeTag(crlf_span));
        switch (lf_span) {
            .text => |text| try testing.expectEqualStrings(text, crlf_span.text),
            .macro => |macro| try expectMacro(macro.name, macro.argument, crlf_span),
            .line_end => {},
        }
    }
    try testing.expectEqualStrings("kept", crlf_blocks[crlf_blocks.len - 4].content.text);
    try testing.expectEqualStrings("#+AUTHOR: someone", crlf_blocks[crlf_blocks.len - 2].content.text);
}

test "document: too small arrays keep a whole prefix and say how many there are" {
    const source = "* One {{{a}}}\ntext\n* Two\n";
    const counted = parse(source, &.{}, &.{});
    try testing.expectEqual(Parsed{ .blocks_seen = 3, .blocks_kept = 0, .spans_seen = 4, .spans_kept = 0 }, counted);
    var blocks: [3]Block = undefined;
    var spans: [2]Span = undefined;
    const parsed = parse(source, &blocks, &spans);
    try testing.expectEqual(Parsed{ .blocks_seen = 3, .blocks_kept = 1, .spans_seen = 4, .spans_kept = 2 }, parsed);
    try testing.expect(!parsed.complete());
}
