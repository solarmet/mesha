//! The text editor's text as its readers see it: the `View` over a buffer's bytes and
//! line starts, and the commands, enums and history nodes the system's contract and its
//! users name. The buffer itself, which writes the view, is the runtime's.

const std = @import("std");

/// What an editor can be told to do. The editor binds no keys of its own: its user maps its
/// keys to these.
pub const EditCommand = enum(u8) {
    /// Move left a character.
    char_left,
    /// Extend the selection left a character.
    char_left_extend,
    /// Move right a character.
    char_right,
    /// Extend the selection right a character.
    char_right_extend,
    /// Move to the previous word.
    word_left,
    /// Extend the selection to the previous word.
    word_left_extend,
    /// Move to the next word.
    word_right,
    /// Extend the selection to the next word.
    word_right_extend,
    /// Move up a line.
    line_up,
    /// Extend the selection up a line.
    line_up_extend,
    /// Move down a line.
    line_down,
    /// Extend the selection down a line.
    line_down_extend,
    /// Move to the line's indentation, then its start.
    line_start,
    /// Extend the selection to the line's indentation, then its start.
    line_start_extend,
    /// Move to the end of the line.
    line_end,
    /// Extend the selection to the end of the line.
    line_end_extend,
    /// Move up a page.
    page_up,
    /// Extend the selection up a page.
    page_up_extend,
    /// Move down a page.
    page_down,
    /// Extend the selection down a page.
    page_down_extend,
    /// Move to the start of the text.
    document_start,
    /// Extend the selection to the start of the text.
    document_start_extend,
    /// Move to the end of the text.
    document_end,
    /// Extend the selection to the end of the text.
    document_end_extend,
    /// Scroll up a line.
    scroll_up,
    /// Scroll down a line.
    scroll_down,
    /// Delete the character before the caret, or the selection.
    delete_back,
    /// Delete the character after the caret, or the selection.
    delete_forward,
    /// Delete to the start of the word.
    delete_word_back,
    /// Delete to the start of the next word.
    delete_word_forward,
    /// Delete to the start of the line.
    delete_line_back,
    /// Delete to the end of the line.
    delete_line_forward,
    /// Delete the line.
    delete_line,
    /// Duplicate the line.
    duplicate_line,
    /// Move the selected lines up.
    move_lines_up,
    /// Move the selected lines down.
    move_lines_down,
    /// Break the line, keeping its indentation.
    new_line,
    /// Indent, or insert spaces to the next tab stop.
    indent,
    /// Unindent.
    unindent,
    /// Undo.
    undo,
    /// Redo.
    redo,
    /// Cut the selection.
    cut,
    /// Copy the selection.
    copy,
    /// Paste.
    paste,
    /// Select all the text.
    select_all,
    /// Drop the selection and the mark.
    cancel,
    /// Switch between inserting and overtyping.
    toggle_overtype,
    /// Set the mark at the caret: moving then selects from it.
    set_mark,
    /// Swap the caret and the mark.
    exchange_point_and_mark,
    /// Kill to the end of the line, or the line break when already there.
    kill_line,
    /// Kill the selection.
    kill_region,
    /// Copy the selection to the kill ring.
    copy_region,
    /// Kill to the start of the next word.
    kill_word_forward,
    /// Kill to the start of the word.
    kill_word_back,
    /// Insert the last text killed or copied.
    yank,
    /// Replace the text just yanked with the one killed before it.
    yank_pop,
    /// Join the next line to this one.
    join_line,
    /// Scroll the caret's line to the middle.
    recenter,
    /// Move past the end of the next word, as Emacs's `forward-word`.
    forward_word,
    /// Extend the selection past the end of the next word.
    forward_word_extend,
    /// Move to the start of the word before the caret, as Emacs's `backward-word`.
    backward_word,
    /// Extend the selection to the start of the word before the caret.
    backward_word_extend,
    /// Move to the line's first cell.
    line_begin,
    /// Extend the selection to the line's first cell.
    line_begin_extend,
    /// Move to the line's indentation.
    back_to_indentation,
    /// Move to the blank line before the paragraph.
    paragraph_back,
    /// Move to the blank line after the paragraph.
    paragraph_forward,
    /// Kill the line with its line break.
    kill_whole_line,
    /// Break the line after the caret, which stays.
    open_line,
    /// Swap the characters either side of the caret.
    transpose_chars,
    /// Make the next word upper case.
    upcase_word,
    /// Make the next word lower case.
    downcase_word,
    /// Give the next word a capital and lower case after it.
    capitalize_word,
    /// Delete the spaces and tabs around the caret.
    delete_horizontal_space,
    /// Leave one space where the spaces and tabs around the caret were.
    just_one_space,
    /// Join this line to the one before it.
    join_previous_line,
    /// Keep the caret's place as the mark, without selecting from it.
    push_mark,
    /// Scroll down a page; the caret moves only to stay in sight.
    scroll_page_down,
    /// Scroll up a page; the caret moves only to stay in sight.
    scroll_page_up,
    /// Go to the mark, and make the mark before it the mark: Emacs's `C-u C-SPC`.
    pop_mark,
    /// Kill the rectangle whose corners are the selection's ends: the same cells of each line.
    kill_rectangle,
    /// Delete the rectangle, keeping nothing of it.
    delete_rectangle,
    /// Insert the rectangle last killed, its corner at the caret, a line of it on each line.
    yank_rectangle,
    /// Push the rectangle's lines right with blanks, to open room where it was.
    open_rectangle,
    /// Go to the state made beside this one from the same state before: the next branch of
    /// the history.
    undo_branch_next,
    /// Go to the branch of the history made before this one.
    undo_branch_previous,
    /// Comment the selection's lines, or uncomment them when every one is commented; with
    /// no selection, begin a comment at the line's end, or go to the one it has.
    comment_dwim,
    /// Comment the line, or uncomment it, and go to the next.
    comment_line,
    /// Fill the paragraph: break its lines again so none passes the fill column.
    fill_paragraph,
    /// On a blank line, delete all but one of the blank lines around it, or the one alone;
    /// on any other, the blank lines after it.
    delete_blank_lines,
    /// Swap the word before the caret with the word after, and step past them.
    transpose_words,
    /// Swap the line with the one before it, and go to the next.
    transpose_lines,
    /// Move past the expression after the caret: a bracketed group, a string or a name.
    forward_sexp,
    /// Move to the start of the expression before the caret.
    backward_sexp,
    /// Kill the expression after the caret.
    kill_sexp,
    /// Select the expression after the caret.
    mark_sexp,

    /// Whether the command may change the text: what a buffer that is only read drops.
    pub fn changesText(command: EditCommand) bool {
        return switch (command) {
            .delete_back,
            .delete_forward,
            .delete_word_back,
            .delete_word_forward,
            .delete_line_back,
            .delete_line_forward,
            .delete_line,
            .duplicate_line,
            .move_lines_up,
            .move_lines_down,
            .new_line,
            .indent,
            .unindent,
            .undo,
            .redo,
            .undo_branch_next,
            .undo_branch_previous,
            .kill_rectangle,
            .delete_rectangle,
            .yank_rectangle,
            .open_rectangle,
            .cut,
            .paste,
            .toggle_overtype,
            .kill_line,
            .kill_region,
            .kill_word_forward,
            .kill_word_back,
            .yank,
            .yank_pop,
            .join_line,
            .kill_whole_line,
            .open_line,
            .transpose_chars,
            .upcase_word,
            .downcase_word,
            .capitalize_word,
            .delete_horizontal_space,
            .just_one_space,
            .join_previous_line,
            .comment_dwim,
            .comment_line,
            .fill_paragraph,
            .delete_blank_lines,
            .transpose_words,
            .transpose_lines,
            .kill_sexp,
            => true,
            else => false,
        };
    }

    /// What the command does, as a sentence without its full stop, for an action's description.
    /// Static memory.
    pub fn doc(command: EditCommand) []const u8 {
        return switch (command) {
            .char_left => "Move left a character",
            .char_left_extend => "Extend the selection left a character",
            .char_right => "Move right a character",
            .char_right_extend => "Extend the selection right a character",
            .word_left => "Move to the previous word",
            .word_left_extend => "Extend the selection to the previous word",
            .word_right => "Move to the next word",
            .word_right_extend => "Extend the selection to the next word",
            .line_up => "Move up a line",
            .line_up_extend => "Extend the selection up a line",
            .line_down => "Move down a line",
            .line_down_extend => "Extend the selection down a line",
            .line_start => "Move to the line's indentation, then its start",
            .line_start_extend => "Extend the selection to the line's indentation, then its start",
            .line_end => "Move to the end of the line",
            .line_end_extend => "Extend the selection to the end of the line",
            .page_up => "Move up a page",
            .page_up_extend => "Extend the selection up a page",
            .page_down => "Move down a page",
            .page_down_extend => "Extend the selection down a page",
            .document_start => "Move to the start of the text",
            .document_start_extend => "Extend the selection to the start of the text",
            .document_end => "Move to the end of the text",
            .document_end_extend => "Extend the selection to the end of the text",
            .scroll_up => "Scroll up a line",
            .scroll_down => "Scroll down a line",
            .delete_back => "Delete the character before the caret, or the selection",
            .delete_forward => "Delete the character after the caret, or the selection",
            .delete_word_back => "Delete to the start of the word",
            .delete_word_forward => "Delete to the start of the next word",
            .delete_line_back => "Delete to the start of the line",
            .delete_line_forward => "Delete to the end of the line",
            .delete_line => "Delete the line",
            .duplicate_line => "Duplicate the line",
            .move_lines_up => "Move the selected lines up",
            .move_lines_down => "Move the selected lines down",
            .new_line => "Break the line, keeping its indentation",
            .indent => "Indent, or insert spaces to the next tab stop",
            .unindent => "Unindent",
            .undo => "Undo",
            .redo => "Redo",
            .cut => "Cut the selection",
            .copy => "Copy the selection",
            .paste => "Paste",
            .select_all => "Select all the text",
            .cancel => "Drop the selection and the mark",
            .toggle_overtype => "Switch between inserting and overtyping",
            .set_mark => "Set the mark at the caret",
            .exchange_point_and_mark => "Swap the caret and the mark",
            .kill_line => "Kill to the end of the line",
            .kill_region => "Kill the selection",
            .copy_region => "Copy the selection to the kill ring",
            .kill_word_forward => "Kill to the end of the next word",
            .kill_word_back => "Kill to the start of the word before the caret",
            .yank => "Insert the last text killed or copied",
            .yank_pop => "Replace the text just yanked with the one killed before it",
            .join_line => "Join the next line to this one",
            .recenter => "Scroll the caret's line to the middle, then the top, then the bottom",
            .forward_word => "Move past the end of the next word",
            .forward_word_extend => "Extend the selection past the end of the next word",
            .backward_word => "Move to the start of the word before the caret",
            .backward_word_extend => "Extend the selection to the start of the word before the caret",
            .line_begin => "Move to the start of the line",
            .line_begin_extend => "Extend the selection to the start of the line",
            .back_to_indentation => "Move to the line's indentation",
            .paragraph_back => "Move to the blank line before the paragraph",
            .paragraph_forward => "Move to the blank line after the paragraph",
            .kill_whole_line => "Kill the line with its line break",
            .open_line => "Break the line after the caret",
            .transpose_chars => "Swap the characters either side of the caret",
            .upcase_word => "Make the next word upper case",
            .downcase_word => "Make the next word lower case",
            .capitalize_word => "Capitalize the next word",
            .delete_horizontal_space => "Delete the spaces and tabs around the caret",
            .just_one_space => "Leave one space around the caret",
            .join_previous_line => "Join this line to the one before it",
            .push_mark => "Keep the caret's place as the mark",
            .scroll_page_down => "Scroll down a page",
            .scroll_page_up => "Scroll up a page",
            .pop_mark => "Go back to the mark, and on to the marks before it",
            .kill_rectangle => "Kill the rectangle between the selection's ends",
            .delete_rectangle => "Delete the rectangle between the selection's ends",
            .yank_rectangle => "Insert the rectangle last killed at the caret",
            .open_rectangle => "Open blank room where the rectangle between the selection's ends is",
            .undo_branch_next => "Go to the next branch of the undo history",
            .undo_branch_previous => "Go to the branch of the undo history before this one",
            .comment_dwim => "Comment or uncomment the selection's lines, or begin a comment on the line",
            .comment_line => "Comment or uncomment the line and go to the next",
            .fill_paragraph => "Break the paragraph's lines again within the fill column",
            .delete_blank_lines => "Delete the blank lines around the caret but one, or those after its line",
            .transpose_words => "Swap the words either side of the caret",
            .transpose_lines => "Swap the line with the one before it",
            .forward_sexp => "Move past the expression after the caret",
            .backward_sexp => "Move to the start of the expression before the caret",
            .kill_sexp => "Kill the expression after the caret",
            .mark_sexp => "Select the expression after the caret",
        };
    }
};

/// Whether a text may hold line breaks its user types: `multi` may; `single`, a one-line field's,
/// turns typed and pasted breaks into spaces. Text set whole is kept as given.
pub const LineMode = enum(u8) { single, multi };

/// The ending a new line gets.
pub const LineEnding = enum(u8) {
    /// `\n`.
    lf,
    /// `\r\n`.
    crlf,
    /// `\r`.
    cr,

    /// The ending's bytes. Static memory.
    pub fn bytes(ending: LineEnding) []const u8 {
        return switch (ending) {
            .lf => "\n",
            .crlf => "\r\n",
            .cr => "\r",
        };
    }
};

/// Whether moving the caret takes the anchor with it or leaves a selection behind.
pub const Select = enum(u8) {
    /// As a click: the selection and the mark are let go.
    move,
    /// The selection's other end stays where it is.
    extend,
    /// As a key's move: it selects from the mark while the mark is set.
    motion,
};

/// How far a zap kills: `up_to` the character typed, which stays, or `through` it.
pub const Zap = enum(u8) { up_to, through };
/// Whether an edit asked for by itself is an undo step of its own (`new`) or goes on with the one
/// before it (`joined`), as each replacement of a query replace joins the first.
pub const UndoStep = enum(u8) { new, joined };

/// A unit a click can select: the `word` or the `line` under it.
pub const Unit = enum(u8) { word, line };

/// The text as its readers see it: the bytes and the line starts, each in the two pieces either
/// side of its gap. A view is rewritten by every edit and is otherwise stable, so a reader between
/// edits may hold its slices. Offsets are bytes from the start of the text, and lines count from 0.
/// An offset or a line past the end is the caller's error.
pub const View = struct {
    /// The text's bytes before the gap, UTF-8.
    before: []const u8 = &.{},
    /// The text's bytes after the gap: the text is `before` then `after`.
    after: []const u8 = &.{},
    /// Starts of the lines before the index's gap, as offsets.
    starts_before: []const u32 = &.{},
    /// Starts of the lines after it, as distances back from the end of the text, so an
    /// edit at the caret changes none of them.
    starts_after_from_end: []const u32 = &.{},
    /// The buffer's markers: places in the text that move with it, as a second window's
    /// point does while the caret is another's. One that was never set is at the start.
    markers: []const u32 = &.{},
    /// The states the text has been in, as a tree, and the one it is in: what a view of its
    /// history draws. Node 0 is the root.
    history: []const HistoryNode = &.{},
    /// The node of `history` the text is in.
    history_current: u32 = 0,

    /// The text's length in bytes.
    pub fn byteCount(view: *const View) u32 {
        return @intCast(view.before.len + view.after.len);
    }

    /// How many lines the text has.
    pub fn lineCount(view: *const View) u32 {
        return @intCast(view.starts_before.len + view.starts_after_from_end.len);
    }

    /// The byte at `offset`, which must be less than `byteCount()`.
    pub fn byteAt(view: *const View, offset: u32) u8 {
        if (offset < view.before.len) return view.before[offset];
        return view.after[offset - view.before.len];
    }

    /// The offset of the first byte of `line`, which must be less than `lineCount()`.
    pub fn lineStart(view: *const View, line: u32) u32 {
        if (line < view.starts_before.len) return view.starts_before[line];
        const from_end = view.starts_after_from_end[line - view.starts_before.len];
        return view.byteCount() - from_end;
    }

    /// Where the line's text ends, before its line ending; the text's end for the last line.
    pub fn lineEnd(view: *const View, line: u32) u32 {
        const next_line = line + 1;
        if (next_line >= view.lineCount()) return view.byteCount();
        const next_start = view.lineStart(next_line);
        const start = view.lineStart(line);
        const last = next_start - 1;
        const ends_with_crlf = view.byteAt(last) == '\n' and last > start and view.byteAt(last - 1) == '\r';
        return if (ends_with_crlf) last - 1 else last;
    }

    /// The line holding `offset`: the last one starting at or before it.
    pub fn lineOf(view: *const View, offset: u32) u32 {
        var low: u32 = 0;
        var high: u32 = view.lineCount();
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (view.lineStart(middle) <= offset) {
                low = middle;
            } else {
                high = middle;
            }
        }
        return low;
    }

    /// The bytes from `start` to `end`, `start` at most `end` and `end` at most `byteCount()`: two
    /// pieces when the range spans the gap, the second empty otherwise. Slices of the view.
    pub fn range(view: *const View, start: u32, end: u32) [2][]const u8 {
        const split: u32 = @intCast(view.before.len);
        if (end <= split) return .{ view.before[start..end], &.{} };
        if (start >= split) return .{ view.after[start - split .. end - split], &.{} };
        return .{ view.before[start..], view.after[0 .. end - split] };
    }

    /// The text of line `index`, without its ending, in two pieces as `range` gives them.
    pub fn lineText(view: *const View, index: u32) [2][]const u8 {
        const start = view.lineStart(index);
        const end = view.lineEnd(index);
        return view.range(start, end);
    }

    /// Copies from `start`, at most `byteCount()`, as much as `out` holds or the text has, and
    /// returns the part of `out` written.
    pub fn copyRange(view: *const View, start: u32, out: []u8) []u8 {
        const available = view.byteCount() - start;
        const count: u32 = @intCast(@min(out.len, available));
        const pieces = view.range(start, start + count);
        @memcpy(out[0..pieces[0].len], pieces[0]);
        @memcpy(out[pieces[0].len..][0..pieces[1].len], pieces[1]);
        return out[0..count];
    }

    /// The first place at or after `from` where `needle` is; null when there is none. A
    /// needle with no capital letter finds text in either case.
    pub fn find(view: *const View, needle: []const u8, from: u32) ?u32 {
        if (needle.len == 0) return null;
        const text_len = view.byteCount();
        if (from >= text_len) return null;
        var any_capital = false;
        for (needle) |byte| any_capital = any_capital or std.ascii.isUpper(byte);
        const fold = !any_capital;

        const split: u32 = @intCast(view.before.len);
        if (from < split) {
            if (indexOfFolded(view.before, needle, from, fold)) |found| return @intCast(found);
            // Where the needle would lie across the gap: at most its length less one on each side.
            const reach: u32 = @intCast(@min(needle.len - 1, max_needle_across_gap));
            const window_start = @max(from, split -| reach);
            const window_end = @min(text_len, split + reach);
            var window: [2 * max_needle_across_gap]u8 = undefined;
            const joined = view.copyRange(window_start, window[0 .. window_end - window_start]);
            if (indexOfFolded(joined, needle, 0, fold)) |found| return window_start + @as(u32, @intCast(found));
        }
        const after_from = if (from > split) from - split else 0;
        const found = indexOfFolded(view.after, needle, after_from, fold) orelse return null;
        return split + @as(u32, @intCast(found));
    }

    /// The last place `needle` is that ends at or before `end_limit`; null when there is
    /// none. Folds case as `find` does.
    pub fn findBackward(view: *const View, needle: []const u8, end_limit: u32) ?u32 {
        const needle_len: u32 = @intCast(needle.len);
        const limit = @min(end_limit, view.byteCount());
        if (needle_len == 0 or limit < needle_len) return null;
        var any_capital = false;
        for (needle) |byte| any_capital = any_capital or std.ascii.isUpper(byte);
        var start = limit - needle_len;
        while (true) {
            if (view.hasTextAt(start, needle, !any_capital)) return start;
            if (start == 0) return null;
            start -= 1;
        }
    }

    /// Whether the bytes at `offset` are `text`, in either case when `fold` says so. The
    /// caller knows that many bytes are there.
    fn hasTextAt(view: *const View, offset: u32, text: []const u8, fold: bool) bool {
        for (text, 0..) |wanted, index| {
            const byte = view.byteAt(offset + @as(u32, @intCast(index)));
            const same = if (fold) std.ascii.toLower(byte) == std.ascii.toLower(wanted) else byte == wanted;
            if (!same) return false;
        }
        return true;
    }

    /// The cell `offset` is in on its line, from 0: one cell for each codepoint before it, a tab
    /// running to the next multiple of `tab_width`, which must not be 0.
    pub fn columnOf(view: *const View, offset: u32, tab_width: u32) u32 {
        const line_index = view.lineOf(offset);
        var position = view.lineStart(line_index);
        var column: u32 = 0;
        while (position < offset) {
            const byte = view.byteAt(position);
            column = columnAfter(column, byte, tab_width);
            position += codepointLength(byte);
        }
        return column;
    }

    /// The offset of the cell at `column` on the line, or the line's end when it is shorter. A
    /// column inside a tab's run gives the tab's offset. Cells are counted as `columnOf` counts
    /// them.
    pub fn offsetAtColumn(view: *const View, line_index: u32, column: u32, tab_width: u32) u32 {
        const end = view.lineEnd(line_index);
        var position = view.lineStart(line_index);
        var reached: u32 = 0;
        while (position < end) {
            const byte = view.byteAt(position);
            const next = columnAfter(reached, byte, tab_width);
            if (next > column) break;
            reached = next;
            position += codepointLength(byte);
        }
        return @min(position, end);
    }
};

/// A needle longer than this is not found where it lies across the gap.
const max_needle_across_gap = 256;

fn indexOfFolded(haystack: []const u8, needle: []const u8, from: usize, fold: bool) ?usize {
    if (!fold) return std.mem.indexOfPos(u8, haystack, from, needle);
    if (haystack.len < needle.len) return null;
    const first = needle[0];
    const first_other = std.ascii.toUpper(first);
    var position = from;
    const last_start = haystack.len - needle.len;
    while (position <= last_start) {
        // Skip to the next byte that could start a match.
        const candidate = std.mem.indexOfAnyPos(u8, haystack, position, &.{ first, first_other }) orelse return null;
        if (candidate > last_start) return null;
        if (std.ascii.eqlIgnoreCase(haystack[candidate..][0..needle.len], needle)) return candidate;
        position = candidate + 1;
    }
    return null;
}

fn columnAfter(column: u32, byte: u8, tab_width: u32) u32 {
    if (byte != '\t') return column + 1;
    return column + tab_width - column % tab_width;
}

/// The length a codepoint's first byte gives it. A stray continuation byte counts as one,
/// so a walk over damaged text still advances.
fn codepointLength(first_byte: u8) u32 {
    if (first_byte < 0x80) return 1;
    if (first_byte >= 0xF0) return 4;
    if (first_byte >= 0xE0) return 3;
    if (first_byte >= 0xC0) return 2;
    return 1;
}

/// How many markers a buffer keeps: one for each window that can show it.
pub const marker_count = 16;

/// A state the text has been in, a node of its history's tree. The edits that made it from
/// its parent's are its records; node 0, the root, is the text before any edit kept.
pub const HistoryNode = struct {
    /// What a link holds when there is no such node.
    pub const none: u32 = std.math.maxInt(u32);

    /// The state it was made from; `none` for the root.
    parent: u32 = none,
    /// Its children in the order they were made, each naming the next.
    first_child: u32 = none,
    /// The next child of its parent; `none` for the last.
    next_sibling: u32 = none,
    /// The child a redo goes to: the one last undone from, or the one last made.
    redo_child: u32 = none,
    /// Its records, one after another in the history's.
    first_record: u32 = 0,
    /// How many records it has.
    record_count: u32 = 0,
    /// The undo group that made it: edits of one command share it.
    group: u32 = 0,
};
