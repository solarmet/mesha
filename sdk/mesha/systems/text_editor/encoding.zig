//! What a file's bytes are: which encoding, whether a byte order mark leads them, and how
//! their lines end. A buffer holds UTF-8 only; anything else is converted on the way in
//! and back on the way out, by the host (`runtime/text_editor/iconv.zig`). A plugin asks it
//! which encodings it converts with the text editor's `supported_encodings` request.

const std = @import("std");

/// UTF-8's name as iconv has it: the encoding of every buffer's text, and of a file no mark or
/// bytes say otherwise of.
pub const utf8_name = "UTF-8";

/// The longest encoding name a buffer remembers.
pub const max_encoding_name = 40;

/// The byte order mark a file starts with. It is not part of a buffer's text: it is
/// remembered and written back.
pub const Bom = enum(u8) {
    /// No mark.
    none,
    /// UTF-8's, three bytes.
    utf8,
    /// UTF-16's, little endian.
    utf16le,
    /// UTF-16's, big endian.
    utf16be,
    /// UTF-32's, little endian.
    utf32le,
    /// UTF-32's, big endian.
    utf32be,

    /// The mark's bytes as a file starts with them; empty for `none`. Static memory.
    pub fn bytes(bom: Bom) []const u8 {
        return switch (bom) {
            .none => "",
            .utf8 => "\xEF\xBB\xBF",
            .utf16le => "\xFF\xFE",
            .utf16be => "\xFE\xFF",
            .utf32le => "\xFF\xFE\x00\x00",
            .utf32be => "\x00\x00\xFE\xFF",
        };
    }

    /// The encoding a mark declares, by its iconv name; null for `none`. Static memory.
    pub fn encoding(bom: Bom) ?[]const u8 {
        return switch (bom) {
            .none => null,
            .utf8 => utf8_name,
            .utf16le => "UTF-16LE",
            .utf16be => "UTF-16BE",
            .utf32le => "UTF-32LE",
            .utf32be => "UTF-32BE",
        };
    }
};

/// The mark `bytes` starts with. UTF-32LE is tested before UTF-16LE, whose mark begins it.
pub fn sniffBom(bytes: []const u8) Bom {
    const order = [_]Bom{ .utf8, .utf32le, .utf32be, .utf16le, .utf16be };
    for (order) |bom| {
        if (std.mem.startsWith(u8, bytes, bom.bytes())) return bom;
    }
    return .none;
}

/// Whether `name` could be an encoding's: no longer than a buffer remembers, and with no byte
/// below a space.
pub fn isEncodingName(name: []const u8) bool {
    if (name.len > max_encoding_name) return false;
    for (name) |byte| {
        if (byte < ' ') return false;
    }
    return true;
}

/// Whether `name` names UTF-8: `UTF-8` or `UTF8`, in either case.
pub fn isUtf8(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, utf8_name) or std.ascii.eqlIgnoreCase(name, "UTF8");
}

/// How a text's lines end.
pub const LineEndings = enum(u8) {
    /// Every line ends with `\n`, or the text has no line ending.
    lf,
    /// Every line ends with `\r\n`.
    crlf,
    /// Every line ends with a `\r` alone.
    cr,
    /// More than one kind. New lines take the commonest.
    mixed,
};

/// How many line endings of each kind a text has; `countLineEndings` makes one.
pub const LineEndingCounts = struct {
    /// Endings that are a `\n` with no `\r` before it.
    lf: usize = 0,
    /// Endings that are `\r\n`.
    crlf: usize = 0,
    /// Endings that are a `\r` with no `\n` after it.
    cr: usize = 0,

    /// How the counted text's lines end: `mixed` when more than one kind was counted, `lf` when
    /// none was.
    pub fn kind(counts: LineEndingCounts) LineEndings {
        const kinds_present = @as(u8, @intFromBool(counts.lf > 0)) + @intFromBool(counts.crlf > 0) + @intFromBool(counts.cr > 0);
        if (kinds_present > 1) return .mixed;
        if (counts.crlf > 0) return .crlf;
        if (counts.cr > 0) return .cr;
        return .lf;
    }

    /// The ending most lines have; a text with none ends its lines with `\n`.
    pub fn commonest(counts: LineEndingCounts) LineEndings {
        if (counts.crlf > counts.lf and counts.crlf >= counts.cr) return .crlf;
        if (counts.cr > counts.lf) return .cr;
        return .lf;
    }
};

/// Counts the line endings in `sample`, the start of a text: enough to know a file's convention
/// without reading all of a large one. A `\r` that is the sample's last byte counts as a `cr`,
/// though a `\n` may follow it in the text.
pub fn countLineEndings(sample: []const u8) LineEndingCounts {
    var counts: LineEndingCounts = .{};
    var position: usize = 0;
    while (std.mem.indexOfAnyPos(u8, sample, position, "\r\n")) |found| {
        position = found + 1;
        if (sample[found] == '\n') {
            counts.lf += 1;
        } else if (position < sample.len and sample[position] == '\n') {
            counts.crlf += 1;
            position += 1;
        } else {
            counts.cr += 1;
        }
    }
    return counts;
}

/// The encodings iconv names, one name each, the commonest first: glibc's converters and GNU
/// libiconv's. Which of them convert depends on the platform (its iconv, or on Windows its code
/// pages), and it may convert
/// others, and these under other names: the host tells which (`supported_encodings`).
pub const known_names = [_][]const u8{
    "UTF-8",            "UTF-16LE",          "UTF-16BE",          "UTF-32LE",         "UTF-32BE",      "UTF-16",           "UTF-32",            "UTF-7",            "UCS-2LE",
    "UCS-2BE",          "UCS-4LE",           "UCS-4BE",           "US-ASCII",         "ISO-8859-1",    "ISO-8859-2",       "ISO-8859-3",        "ISO-8859-4",       "ISO-8859-5",
    "ISO-8859-6",       "ISO-8859-7",        "ISO-8859-8",        "ISO-8859-9",       "ISO-8859-10",   "ISO-8859-11",      "ISO-8859-13",       "ISO-8859-14",      "ISO-8859-15",
    "ISO-8859-16",      "WINDOWS-1250",      "WINDOWS-1251",      "WINDOWS-1252",     "WINDOWS-1253",  "WINDOWS-1254",     "WINDOWS-1255",      "WINDOWS-1256",     "WINDOWS-1257",
    "WINDOWS-1258",     "WINDOWS-874",       "WINDOWS-31J",       "KOI8-R",           "KOI8-U",        "KOI8-RU",          "KOI8-T",            "SHIFT_JIS",        "EUC-JP",
    "ISO-2022-JP",      "ISO-2022-JP-2",     "ISO-2022-JP-3",     "EUC-KR",           "ISO-2022-KR",   "JOHAB",            "UHC",               "GBK",              "GB18030",
    "GB2312",           "HZ",                "ISO-2022-CN",       "ISO-2022-CN-EXT",  "BIG5",          "BIG5-HKSCS",       "EUC-TW",            "TIS-620",          "VISCII",
    "TCVN",             "MACINTOSH",         "MACCENTRALEUROPE",  "MACCROATIAN",      "MACROMANIA",    "MACCYRILLIC",      "MACUKRAINE",        "MACGREEK",         "MACTURKISH",
    "MACICELAND",       "MACHEBREW",         "MACARABIC",         "MACTHAI",          "CP437",         "CP737",            "CP775",             "CP850",            "CP852",
    "CP853",            "CP855",             "CP856",             "CP857",            "CP858",         "CP860",            "CP861",             "CP862",            "CP863",
    "CP864",            "CP865",             "CP866",             "CP869",            "CP922",         "CP932",            "CP936",             "CP943",            "CP949",
    "CP950",            "CP1046",            "CP1124",            "CP1125",           "CP1129",        "CP1131",           "CP1133",            "CP1161",           "CP1162",
    "CP1163",           "CP1361",            "ARMSCII-8",         "GEORGIAN-ACADEMY", "GEORGIAN-PS",   "PT154",            "RK1048",            "MULELAO-1",        "NEXTSTEP",
    "HP-ROMAN8",        "ATARIST",           "RISCOS-LATIN1",     "TDS565",           "DEC-KANJI",     "DEC-HANYU",        "EUC-JISX0213",      "SHIFT_JISX0213",   "BIG5-2003",
    "BIG5-HKSCS:1999",  "BIG5-HKSCS:2001",   "BIG5-HKSCS:2004",   "BIG5-HKSCS:2008",  "ISO-2022-JP-1", "ISO-2022-JP-2004", "UTF-7-IMAP",        "C99",              "JAVA",
    "ANSI_X3.110",      "ASMO_449",          "BRF",               "BS_4730",          "CP10007",       "CP770",            "CP771",             "CP772",            "CP773",
    "CP774",            "CSA_Z243.4-1985-1", "CSA_Z243.4-1985-2", "CSN_369103",       "CWI",           "DEC-MCS",          "DIN_66003",         "DS_2089",          "EBCDIC-AT-DE",
    "EBCDIC-AT-DE-A",   "EBCDIC-CA-FR",      "EBCDIC-DK-NO",      "EBCDIC-DK-NO-A",   "EBCDIC-ES",     "EBCDIC-ES-A",      "EBCDIC-ES-S",       "EBCDIC-FI-SE",     "EBCDIC-FI-SE-A",
    "EBCDIC-FR",        "EBCDIC-IS-FRISS",   "EBCDIC-IT",         "EBCDIC-PT",        "EBCDIC-UK",     "EBCDIC-US",        "ECMA-CYRILLIC",     "ES",               "ES2",
    "EUC-CN",           "EUC-JP-MS",         "GB_1988-80",        "GOST_19768-74",    "GREEK-CCITT",   "GREEK7",           "GREEK7-OLD",        "HP-GREEK8",        "HP-ROMAN9",
    "HP-THAI8",         "HP-TURKISH8",       "IBM037",            "IBM038",           "IBM1004",       "IBM1008",          "IBM1025",           "IBM1026",          "IBM1047",
    "IBM1097",          "IBM1112",           "IBM1122",           "IBM1123",          "IBM1130",       "IBM1132",          "IBM1137",           "IBM1140",          "IBM1141",
    "IBM1142",          "IBM1143",           "IBM1144",           "IBM1145",          "IBM1146",       "IBM1147",          "IBM1148",           "IBM1149",          "IBM1153",
    "IBM1154",          "IBM1155",           "IBM1156",           "IBM1157",          "IBM1158",       "IBM1160",          "IBM1164",           "IBM1166",          "IBM1167",
    "IBM12712",         "IBM1364",           "IBM1371",           "IBM1388",          "IBM1390",       "IBM1399",          "IBM16804",          "IBM256",           "IBM273",
    "IBM274",           "IBM275",            "IBM277",            "IBM278",           "IBM280",        "IBM281",           "IBM284",            "IBM285",           "IBM290",
    "IBM297",           "IBM420",            "IBM423",            "IBM424",           "IBM4517",       "IBM4899",          "IBM4909",           "IBM4971",          "IBM500",
    "IBM5347",          "IBM803",            "IBM851",            "IBM866NAV",        "IBM868",        "IBM870",           "IBM871",            "IBM875",           "IBM880",
    "IBM891",           "IBM901",            "IBM902",            "IBM903",           "IBM9030",       "IBM904",           "IBM905",            "IBM9066",          "IBM918",
    "IBM921",           "IBM930",            "IBM932",            "IBM933",           "IBM935",        "IBM937",           "IBM939",            "IBM943",           "IBM9448",
    "IEC_P27-1",        "INIS",              "INIS-8",            "INIS-CYRILLIC",    "ISIRI-3342",    "ISO-8859-9E",      "ISO-IR-197",        "ISO-IR-209",       "ISO_10367-BOX",
    "ISO_11548-1",      "ISO_2033",          "ISO_5427",          "ISO_5427-EXT",     "ISO_5428",      "ISO_6937",         "ISO_6937-2",        "IT",               "JIS_C6220-1969-RO",
    "JIS_C6229-1984-B", "JUS_I.B1.002",      "KOI-8",             "KSC5636",          "LATIN-GREEK",   "LATIN-GREEK-1",    "MAC-CENTRALEUROPE", "MAC-IS",           "MAC-SAMI",
    "MAC-UK",           "MIK",               "MSZ_7795.3",        "NATS-DANO",        "NATS-SEFI",     "NC_NC00-10",       "NF_Z_62-010",       "NF_Z_62-010_1973", "NS_4551-1",
    "NS_4551-2",        "PT",                "PT2",               "SEN_850200_B",     "SEN_850200_C",  "SJIS",             "T.61-8BIT",         "TCVN5712-1",       "TSCII",
    "UNICODE",          "WIN-SAMI-2",
};

/// The encodings a file with no mark and invalid UTF-8 is read as, in order of preference.
/// The last maps every byte, so one of them always reads the file where SDL has it.
pub const fallback_encodings = [_][]const u8{ "WINDOWS-1252", "ISO-8859-1" };

const testing = std.testing;

// The tests that convert are the runtime's, in `text_editor/iconv.zig`.

test "marks are told apart, the longer first" {
    try testing.expectEqual(Bom.utf8, sniffBom("\xEF\xBB\xBFa"));
    try testing.expectEqual(Bom.utf16le, sniffBom("\xFF\xFEa\x00"));
    try testing.expectEqual(Bom.utf32le, sniffBom("\xFF\xFE\x00\x00a\x00\x00\x00"));
    try testing.expectEqual(Bom.utf16be, sniffBom("\xFE\xFF\x00a"));
    try testing.expectEqual(Bom.none, sniffBom("plain"));
}

test "line endings are counted by kind" {
    const counts = countLineEndings("a\r\nb\r\nc\nd\r");
    try testing.expectEqual(@as(usize, 2), counts.crlf);
    try testing.expectEqual(@as(usize, 1), counts.lf);
    try testing.expectEqual(@as(usize, 1), counts.cr);
    try testing.expectEqual(LineEndings.mixed, counts.kind());
    try testing.expectEqual(LineEndings.crlf, counts.commonest());
    try testing.expectEqual(LineEndings.lf, countLineEndings("none").kind());
}
