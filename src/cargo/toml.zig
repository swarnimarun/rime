const std = @import("std");

pub const Span = struct { line: u32, col: u32 };
pub const TomlError = error{ ParseError, UnsupportedType, OutOfMemory };
pub const TomlValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    array: []TomlValue,
    table: TomlTable,
};
pub const TomlTable = struct {
    entries: std.StringHashMap(TomlEntry),
    // Pointer access: TomlValue holds a TomlTable holding a StringHashMap — returning by value would copy the map header.
    // get returns *const TomlValue; field access auto-derefs, so `t.get("k").?.table` still compiles.
    pub fn get(self: *const TomlTable, key: []const u8) ?*const TomlValue {
        const e = self.entries.getPtr(key) orelse return null;
        return &e.value;
    }
    pub fn require(self: *const TomlTable, key: []const u8) TomlError!*const TomlValue {
        const e = self.entries.getPtr(key) orelse return TomlError.ParseError;
        return &e.value;
    }
};
pub const TomlEntry = struct { value: TomlValue, span: Span };
pub const TomlDoc = struct {
    arena: std.heap.ArenaAllocator,
    root: TomlTable,
    pub fn deinit(self: *TomlDoc) void {
        self.arena.deinit();
    }
};

pub fn parseDocument(gpa: std.mem.Allocator, text: []const u8) TomlError!TomlDoc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser{
        .alloc = alloc,
        .text = text,
        .pos = 0,
        .line = 1,
        .col = 1,
        .root = TomlTable{ .entries = std.StringHashMap(TomlEntry).init(alloc) },
        .cur_path = .empty,
        .cur_array_idx = null,
    };
    try p.parseRoot();
    return .{ .arena = arena, .root = p.root };
}

const Parser = struct {
    alloc: std.mem.Allocator, // arena allocator: owns every string, array, and table map
    text: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    root: TomlTable,
    // Current-table context: path from the root plus, for `[[array-table]]`
    // headers, the index of the latest element. Resolved fresh from the root
    // on every statement so no entry pointer is ever held across a map growth.
    cur_path: std.ArrayList([]const u8),
    cur_array_idx: ?usize,

    fn eof(self: *Parser) bool {
        return self.pos >= self.text.len;
    }

    fn peek(self: *Parser) u8 {
        return self.text[self.pos];
    }

    fn advance(self: *Parser) u8 {
        const c = self.text[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn here(self: *Parser) Span {
        return .{ .line = self.line, .col = self.col };
    }

    fn skipSpaces(self: *Parser) void {
        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t')) _ = self.advance();
    }

    fn skipToNewline(self: *Parser) void {
        while (!self.eof() and self.peek() != '\n') _ = self.advance();
    }

    fn skipBlankLinesAndComments(self: *Parser) void {
        while (true) {
            while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r')) _ = self.advance();
            if (self.eof()) break;
            if (self.peek() == '\n') {
                _ = self.advance();
                continue;
            }
            if (self.peek() == '#') {
                self.skipToNewline();
                continue;
            }
            break;
        }
    }

    /// Whitespace, newlines, and comments: used inside arrays and between
    /// `=` and its value (a lenient superset of TOML there; manifests never
    /// rely on it, and strict single-line layout is enforced for keyvals).
    fn skipTrivia(self: *Parser) void {
        while (true) {
            while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\r' or self.peek() == '\n')) _ = self.advance();
            if (!self.eof() and self.peek() == '#') {
                self.skipToNewline();
                continue;
            }
            break;
        }
    }

    /// Consumes the rest of the line after a `[header]` or `key = value`
    /// statement: optional trailing comment, then exactly one newline or EOF.
    fn finishLine(self: *Parser) TomlError!void {
        self.skipSpaces();
        if (!self.eof() and self.peek() == '\r') _ = self.advance();
        if (!self.eof() and self.peek() == '#') self.skipToNewline();
        if (self.eof()) return;
        if (self.peek() != '\n') return TomlError.ParseError;
        _ = self.advance();
    }

    fn parseRoot(self: *Parser) TomlError!void {
        while (true) {
            self.skipBlankLinesAndComments();
            if (self.eof()) break;
            if (self.peek() == '[') {
                try self.parseHeader();
            } else {
                try self.parseKeyval();
            }
        }
    }

    fn parseHeader(self: *Parser) TomlError!void {
        _ = self.advance(); // '['
        if (!self.eof() and self.peek() == '[') {
            _ = self.advance();
            self.skipSpaces();
            const path = try self.parseKeyPath();
            self.skipSpaces();
            if (self.eof() or self.peek() != ']') return TomlError.ParseError;
            _ = self.advance();
            if (self.eof() or self.peek() != ']') return TomlError.ParseError;
            _ = self.advance();
            try self.finishLine();
            try self.enterArrayTable(path);
        } else {
            self.skipSpaces();
            const path = try self.parseKeyPath();
            self.skipSpaces();
            if (self.eof() or self.peek() != ']') return TomlError.ParseError;
            _ = self.advance();
            try self.finishLine();
            try self.enterTable(path);
        }
    }

    fn parseKeyPath(self: *Parser) TomlError![]const []const u8 {
        var segs: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpaces();
            const seg = try self.parseKeySegment();
            try segs.append(self.alloc, seg);
            self.skipSpaces();
            if (!self.eof() and self.peek() == '.') {
                _ = self.advance();
                continue;
            }
            break;
        }
        return try segs.toOwnedSlice(self.alloc);
    }

    fn parseKeySegment(self: *Parser) TomlError![]const u8 {
        if (self.eof()) return TomlError.ParseError;
        const c = self.peek();
        if (c == '"') return try self.parseBasicString();
        if (c == '\'') return try self.parseLiteralString();
        const start = self.pos;
        while (!self.eof() and isBareKeyChar(self.peek())) _ = self.advance();
        if (self.pos == start) return TomlError.ParseError;
        return try self.alloc.dupe(u8, self.text[start..self.pos]);
    }

    fn parseKeyval(self: *Parser) TomlError!void {
        const span = self.here();
        const path = try self.parseKeyPath();
        self.skipSpaces();
        if (self.eof() or self.peek() != '=') return TomlError.ParseError;
        _ = self.advance();
        self.skipTrivia();
        const val = try self.parseValue();
        try self.finishLine();
        const tbl = try self.currentTable();
        try insertDotted(self.alloc, tbl, path, val, span);
    }

    fn parseValue(self: *Parser) TomlError!TomlValue {
        self.skipSpaces();
        if (self.eof()) return TomlError.ParseError;
        const c = self.peek();
        switch (c) {
            '"' => return .{ .string = try self.parseBasicString() },
            '\'' => return .{ .string = try self.parseLiteralString() },
            't', 'f' => return try self.parseBool(),
            '[' => return try self.parseArray(),
            '{' => return try self.parseInlineTable(),
            '+', '-', '0'...'9' => return try self.parseNumber(),
            else => return TomlError.ParseError,
        }
    }

    fn parseBasicString(self: *Parser) TomlError![]const u8 {
        // Multiline `"""` strings are rejected (decision D2: manifest/lock subset only).
        if (self.pos + 3 <= self.text.len and std.mem.eql(u8, self.text[self.pos..][0..3], "\"\"\"")) return TomlError.ParseError;
        _ = self.advance(); // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.eof()) return TomlError.ParseError;
            const c = self.advance();
            if (c == '"') break;
            if (c == '\n') return TomlError.ParseError;
            if (c == '\\') {
                if (self.eof()) return TomlError.ParseError;
                const e = self.advance();
                switch (e) {
                    'b' => try out.append(self.alloc, 0x08),
                    't' => try out.append(self.alloc, 0x09),
                    'n' => try out.append(self.alloc, 0x0A),
                    'f' => try out.append(self.alloc, 0x0C),
                    'r' => try out.append(self.alloc, 0x0D),
                    '"' => try out.append(self.alloc, '"'),
                    '\\' => try out.append(self.alloc, '\\'),
                    'u' => try self.appendUtf8(&out, try self.parseHexDigits(4)),
                    'U' => try self.appendUtf8(&out, try self.parseHexDigits(8)),
                    else => return TomlError.ParseError,
                }
            } else {
                try out.append(self.alloc, c);
            }
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn parseLiteralString(self: *Parser) TomlError![]const u8 {
        if (self.pos + 3 <= self.text.len and std.mem.eql(u8, self.text[self.pos..][0..3], "'''")) return TomlError.ParseError;
        _ = self.advance(); // opening quote
        const start = self.pos;
        while (true) {
            if (self.eof()) return TomlError.ParseError;
            if (self.peek() == '\'') break;
            if (self.peek() == '\n') return TomlError.ParseError;
            _ = self.advance();
        }
        const s = self.text[start..self.pos];
        _ = self.advance(); // closing quote
        return try self.alloc.dupe(u8, s);
    }

    fn parseBool(self: *Parser) TomlError!TomlValue {
        if (matchLiteral(self, "true")) return .{ .boolean = true };
        if (matchLiteral(self, "false")) return .{ .boolean = false };
        return TomlError.ParseError;
    }

    fn parseNumber(self: *Parser) TomlError!TomlValue {
        var negative = false;
        if (self.peek() == '+' or self.peek() == '-') {
            negative = self.peek() == '-';
            _ = self.advance();
        }
        const start = self.pos;
        while (!self.eof() and (isDigit(self.peek()) or self.peek() == '_')) _ = self.advance();
        const raw = self.text[start..self.pos];
        if (!validIntRaw(raw)) return TomlError.ParseError;
        // A float (`1.5`, `1e6`), hex/oct/bin (`0x…`), or datetime fragment
        // after the integer run is rejected, never silently parsed.
        if (!self.eof()) {
            const f = self.peek();
            if (isDigit(f) or isAlpha(f) or f == '_' or f == '.' or f == '-' or f == ':' or f == '+') return TomlError.ParseError;
        }
        var clean: std.ArrayList(u8) = .empty;
        if (negative) try clean.append(self.alloc, '-');
        for (raw) |c| {
            if (c != '_') try clean.append(self.alloc, c);
        }
        const s = try clean.toOwnedSlice(self.alloc);
        const ival = std.fmt.parseInt(i64, s, 10) catch return TomlError.ParseError;
        return .{ .integer = ival };
    }

    fn parseHexDigits(self: *Parser, n: usize) TomlError!u32 {
        if (self.pos + n > self.text.len) return TomlError.ParseError;
        const s = self.text[self.pos..][0..n];
        for (s) |c| {
            if (!isHexDigit(c)) return TomlError.ParseError;
        }
        const v = std.fmt.parseInt(u32, s, 16) catch return TomlError.ParseError;
        for (s) |_| _ = self.advance();
        return v;
    }

    fn appendUtf8(self: *Parser, out: *std.ArrayList(u8), code: u32) TomlError!void {
        if (code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) return TomlError.ParseError;
        if (code < 0x80) {
            try out.append(self.alloc, @intCast(code));
        } else if (code < 0x800) {
            try out.append(self.alloc, @intCast(0xC0 | (code >> 6)));
            try out.append(self.alloc, @intCast(0x80 | (code & 0x3F)));
        } else if (code < 0x10000) {
            try out.append(self.alloc, @intCast(0xE0 | (code >> 12)));
            try out.append(self.alloc, @intCast(0x80 | ((code >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (code & 0x3F)));
        } else {
            try out.append(self.alloc, @intCast(0xF0 | (code >> 18)));
            try out.append(self.alloc, @intCast(0x80 | ((code >> 12) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | ((code >> 6) & 0x3F)));
            try out.append(self.alloc, @intCast(0x80 | (code & 0x3F)));
        }
    }

    fn parseArray(self: *Parser) TomlError!TomlValue {
        _ = self.advance(); // '['
        var vals: std.ArrayList(TomlValue) = .empty;
        self.skipTrivia();
        if (!self.eof() and self.peek() == ']') {
            _ = self.advance();
            return .{ .array = try vals.toOwnedSlice(self.alloc) };
        }
        while (true) {
            const v = try self.parseValue();
            try vals.append(self.alloc, v);
            self.skipTrivia();
            if (self.eof()) return TomlError.ParseError;
            if (self.peek() == ',') {
                _ = self.advance();
                self.skipTrivia();
                if (self.eof()) return TomlError.ParseError;
                if (self.peek() == ']') {
                    _ = self.advance();
                    break;
                }
                continue;
            }
            if (self.peek() == ']') {
                _ = self.advance();
                break;
            }
            return TomlError.ParseError;
        }
        return .{ .array = try vals.toOwnedSlice(self.alloc) };
    }

    fn parseInlineTable(self: *Parser) TomlError!TomlValue {
        _ = self.advance(); // '{'
        var tbl = TomlTable{ .entries = std.StringHashMap(TomlEntry).init(self.alloc) };
        self.skipSpaces();
        if (!self.eof() and self.peek() == '}') {
            _ = self.advance();
            return .{ .table = tbl };
        }
        while (true) {
            const kspan = self.here();
            const path = try self.parseKeyPath();
            self.skipSpaces();
            if (self.eof() or self.peek() != '=') return TomlError.ParseError;
            _ = self.advance();
            self.skipSpaces();
            const v = try self.parseValue();
            try insertDotted(self.alloc, &tbl, path, v, kspan);
            self.skipSpaces();
            if (self.eof()) return TomlError.ParseError;
            if (self.peek() == ',') {
                _ = self.advance();
                self.skipSpaces();
                continue;
            }
            if (self.peek() == '}') {
                _ = self.advance();
                break;
            }
            return TomlError.ParseError;
        }
        return .{ .table = tbl };
    }

    fn currentTable(self: *Parser) TomlError!*TomlTable {
        var tbl: *TomlTable = &self.root;
        const n = self.cur_path.items.len;
        if (n == 0) return tbl;
        for (self.cur_path.items[0 .. n - 1]) |seg| {
            const e = tbl.entries.getPtr(seg) orelse return TomlError.ParseError;
            if (e.value != .table) return TomlError.ParseError;
            tbl = &e.value.table;
        }
        const last = self.cur_path.items[n - 1];
        const e = tbl.entries.getPtr(last) orelse return TomlError.ParseError;
        if (self.cur_array_idx) |idx| {
            if (e.value != .array) return TomlError.ParseError;
            if (idx >= e.value.array.len) return TomlError.ParseError;
            if (e.value.array[idx] != .table) return TomlError.ParseError;
            return &e.value.array[idx].table;
        }
        if (e.value != .table) return TomlError.ParseError;
        return &e.value.table;
    }

    fn enterTable(self: *Parser, path: []const []const u8) TomlError!void {
        const span = self.here();
        var cur: *TomlTable = &self.root;
        for (path) |seg| {
            cur = try ensureTable(self.alloc, cur, seg, span);
        }
        // Re-entering an existing table merges (lenient: TOML forbids
        // `[a]` twice, but manifests never do this and merge keeps
        // out-of-order `[a.b]`-then-`[a]` working). Duplicate *keys*
        // still fail in insertDotted.
        self.cur_path.clearRetainingCapacity();
        for (path) |seg| try self.cur_path.append(self.alloc, seg);
        self.cur_array_idx = null;
    }

    fn enterArrayTable(self: *Parser, path: []const []const u8) TomlError!void {
        if (path.len == 0) return TomlError.ParseError;
        const span = self.here();
        var cur: *TomlTable = &self.root;
        for (path[0 .. path.len - 1]) |seg| {
            cur = try ensureTable(self.alloc, cur, seg, span);
        }
        const last = path[path.len - 1];
        const idx: usize = blk: {
            if (cur.entries.getPtr(last)) |e| {
                if (e.value != .array) return TomlError.ParseError;
                try appendArrayTable(self.alloc, e, span);
                break :blk e.value.array.len - 1;
            } else {
                const arr = try newArrayTable(self.alloc);
                try cur.entries.put(last, .{ .value = .{ .array = arr }, .span = span });
                break :blk 0;
            }
        };
        self.cur_path.clearRetainingCapacity();
        for (path) |seg| try self.cur_path.append(self.alloc, seg);
        self.cur_array_idx = idx;
    }
};

/// Descends into child table `seg`, creating it when absent. The child must
/// be a table when present (arrays and scalars reject dotted descent).
fn ensureTable(alloc: std.mem.Allocator, tbl: *TomlTable, seg: []const u8, span: Span) TomlError!*TomlTable {
    if (tbl.entries.getPtr(seg)) |e| {
        if (e.value != .table) return TomlError.ParseError;
        return &e.value.table;
    }
    const fresh = TomlTable{ .entries = std.StringHashMap(TomlEntry).init(alloc) };
    try tbl.entries.put(seg, .{ .value = .{ .table = fresh }, .span = span });
    const e2 = tbl.entries.getPtr(seg) orelse return TomlError.ParseError;
    return &e2.value.table;
}

/// Inserts `val` at dotted `path` inside `tbl`, creating intermediate tables.
/// Redefining an existing leaf is a ParseError (TOML duplicate-key rule).
fn insertDotted(alloc: std.mem.Allocator, tbl: *TomlTable, path: []const []const u8, val: TomlValue, span: Span) TomlError!void {
    var cur = tbl;
    for (path[0 .. path.len - 1]) |seg| {
        cur = try ensureTable(alloc, cur, seg, span);
    }
    const leaf = path[path.len - 1];
    if (cur.entries.contains(leaf)) return TomlError.ParseError;
    try cur.entries.put(leaf, .{ .value = val, .span = span });
}

fn newArrayTable(alloc: std.mem.Allocator) TomlError![]TomlValue {
    var list: std.ArrayList(TomlValue) = .empty;
    const fresh = TomlTable{ .entries = std.StringHashMap(TomlEntry).init(alloc) };
    try list.append(alloc, .{ .table = fresh });
    return try list.toOwnedSlice(alloc);
}

fn appendArrayTable(alloc: std.mem.Allocator, entry: *TomlEntry, span: Span) TomlError!void {
    var list: std.ArrayList(TomlValue) = .empty;
    try list.appendSlice(alloc, entry.value.array);
    const fresh = TomlTable{ .entries = std.StringHashMap(TomlEntry).init(alloc) };
    try list.append(alloc, .{ .table = fresh });
    entry.value.array = try list.toOwnedSlice(alloc);
    entry.span = span;
}

fn matchLiteral(self: *Parser, lit: []const u8) bool {
    if (self.pos + lit.len > self.text.len) return false;
    if (!std.mem.eql(u8, self.text[self.pos..][0..lit.len], lit)) return false;
    if (self.pos + lit.len < self.text.len and isBareKeyChar(self.text[self.pos + lit.len])) return false;
    for (lit) |_| _ = self.advance();
    return true;
}

fn isBareKeyChar(c: u8) bool {
    return isAlpha(c) or isDigit(c) or c == '-' or c == '_';
}

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Integer runs are digits with single interior underscores (`1_000`).
/// The sign is consumed by the caller and is not part of `raw`.
fn validIntRaw(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (raw[0] == '_' or raw[raw.len - 1] == '_') return false;
    var prev_underscore = false;
    for (raw) |c| {
        if (c == '_') {
            if (prev_underscore) return false;
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
    }
    return true;
}

test "toml parses package table with deps" {
    var doc = try parseDocument(std.testing.allocator,
        \\[package]
        \\name = "foo"
        \\version = "0.1.0"
        \\edition = "2021"
        \\
        \\[dependencies]
        \\serde = "1.0"
        \\
    );
    defer doc.deinit();
    const pkg = &doc.root.get("package").?.table; // *const TomlTable: no map-header copy
    const name = pkg.get("name").?.string;
    try std.testing.expectEqualStrings("foo", name);
    const deps = &doc.root.get("dependencies").?.table; // *const TomlTable: no map-header copy
    try std.testing.expectEqualStrings("1.0", deps.get("serde").?.string);
}

test "toml rejects floats and multiline strings" {
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 1.5\n"));
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = \"\"\"x\"\"\"\n"));
}

test "toml array tables collect members" {
    var doc = try parseDocument(std.testing.allocator, "[[bin]]\nname = \"a\"\n[[bin]]\nname = \"b\"\n");
    defer doc.deinit();
    const bins = doc.root.get("bin").?.array;
    try std.testing.expectEqual(@as(usize, 2), bins.len);
    try std.testing.expectEqualStrings("b", bins[1].table.get("name").?.string);
}

test "toml parses dotted keys and inline tables" {
    var doc = try parseDocument(std.testing.allocator,
        \\[dependencies.rime-dep]
        \\path = "../rime-dep"
        \\
        \\[dependencies]
        \\g = { git = "https://example.com/r.git", rev = "abc123" }
        \\w = { workspace = true }
        \\
    );
    defer doc.deinit();
    const deps = &doc.root.get("dependencies").?.table;
    const rp = &deps.get("rime-dep").?.table;
    try std.testing.expectEqualStrings("../rime-dep", rp.get("path").?.string);
    const g = &deps.get("g").?.table;
    try std.testing.expectEqualStrings("https://example.com/r.git", g.get("git").?.string);
    try std.testing.expectEqualStrings("abc123", g.get("rev").?.string);
    try std.testing.expect(deps.get("w").?.table.get("workspace").?.boolean);
}

test "toml parses arrays, integers, booleans, literal strings, and comments" {
    var doc = try parseDocument(std.testing.allocator,
        \\# leading comment
        \\version = 4 # trailing comment
        \\members = ["crates/*", 'plain'] # mixed quote styles
        \\offline = true
        \\frozen = false
        \\edition = '2021' # literal string
        \\
    );
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 4), doc.root.get("version").?.integer);
    const members = doc.root.get("members").?.array;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("crates/*", members[0].string);
    try std.testing.expectEqualStrings("plain", members[1].string);
    try std.testing.expect(doc.root.get("offline").?.boolean);
    try std.testing.expect(!doc.root.get("frozen").?.boolean);
    try std.testing.expectEqualStrings("2021", doc.root.get("edition").?.string);
}

test "toml rejects bad values and duplicate keys" {
    // hex/oct/bin integers, floats, datetimes, and exponents are rejected
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 0x12\n"));
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 1e6\n"));
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 1979-05-27\n"));
    // duplicate keys and unterminated values are rejected
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 1\nk = 2\n"));
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = \"abc\n"));
    // single-line strings cannot span lines
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = \"a\nb\"\n"));
}
