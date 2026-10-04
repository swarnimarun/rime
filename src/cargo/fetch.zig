const std = @import("std");
// NOTE (Tasks 1-4): no store/lock imports yet. Nothing in this chunk touches
// Store/Digest/Tag (Task 5 unpackCrate) or Lockfile (Task 8 ensureSources),
// and a `../store/root.zig` import would break bare
// `zig test src/cargo/fetch.zig` (single-file mode rejects parent-dir
// imports). The plan's `store_mod`/`lock_mod` import block lands with Task 5.

pub const FetchError = error{
    Network, Auth, NotFound, ChecksumMismatch, InvalidIndex, InvalidCrate,
    GitFailed, OfflineMissing, FrozenViolation, LockedViolation,
    StoreRead, StoreFull, TagError, OutOfMemory, Usage,
};

pub const IndexResponse = union(enum) { fresh: []u8, not_modified: void, not_found: void };

pub const RegistryClient = struct {
    ptr: *anyopaque,
    fetchConfigFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) FetchError![]u8,
    fetchIndexFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse,
    fetchCrateFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8,
    pub fn fetchConfig(self: RegistryClient, gpa: std.mem.Allocator) FetchError![]u8 {
        return self.fetchConfigFn(self.ptr, gpa);
    }
    pub fn fetchIndex(self: RegistryClient, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse {
        return self.fetchIndexFn(self.ptr, gpa, crate_name, cached_version);
    }
    pub fn fetchCrate(self: RegistryClient, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8 {
        return self.fetchCrateFn(self.ptr, gpa, dl_url);
    }
};

pub const GitRunner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8,
    pub fn run(self: GitRunner, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 {
        return self.runFn(self.ptr, gpa, io, argv, cwd);
    }
};

/// Entry-point options (FINAL form per the plan's Public Surface; Task 8 owns
/// the remaining entry points, but fetchCrateBytes in Task 4 already takes this).
pub const FetchOptions = struct {
    offline: bool = false,
    frozen: bool = false,
    locked: bool = false,
    cache_dir: []const u8, // registry cache root (index cache + .crate cache live here, NOT in the store)
};

pub const StubFile = struct { path: []const u8, contents: []const u8 };

/// Test harness: serves a stub registry directory through the RegistryClient seam. No sockets.
pub const FileRegistry = struct {
    root: []const u8,
    pub fn client(self: *FileRegistry) RegistryClient {
        return .{
            .ptr = self,
            .fetchConfigFn = fileFetchConfig,
            .fetchIndexFn = fileFetchIndex,
            .fetchCrateFn = fileFetchCrate,
        };
    }
    fn fileFetchConfig(ptr: *anyopaque, gpa: std.mem.Allocator) FetchError![]u8 {
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        const p = std.fs.path.join(gpa, &.{ self.root, "config.json" }) catch return FetchError.OutOfMemory;
        defer gpa.free(p);
        return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch return FetchError.NotFound;
    }
    fn fileFetchIndex(ptr: *anyopaque, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse {
        _ = cached_version; // file stub has no versions: always fresh (Task 2 adds cache semantics to the real client)
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
        defer gpa.free(rel);
        const p = std.fs.path.join(gpa, &.{ self.root, "index", rel }) catch return FetchError.OutOfMemory;
        defer gpa.free(p);
        const body = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 20)) catch return FetchError.NotFound;
        return IndexResponse{ .fresh = body };
    }
    fn fileFetchCrate(ptr: *anyopaque, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8 {
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        // Stub dl URLs are file paths: strip the "file://" scheme and read directly.
        const path = if (std.mem.startsWith(u8, dl_url, "file://")) dl_url["file://".len..] else return FetchError.Network;
        const abs = if (std.mem.startsWith(u8, path, "STUB/"))
            std.fs.path.join(gpa, &.{ self.root, path["STUB/".len..] }) catch return FetchError.OutOfMemory
        else
            gpa.dupe(u8, path) catch return FetchError.OutOfMemory;
        defer gpa.free(abs);
        return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(512 << 20)) catch return FetchError.NotFound;
    }
};

/// Test harness: pre-canned git outputs, no subprocess. `tree_files` is the checked-out tree.
pub const StubGit = struct {
    oid: [40]u8,
    tree_files: []const StubFile,
    pub fn runner(self: *StubGit) GitRunner {
        return .{ .ptr = self, .runFn = stubRun };
    }
    fn stubRun(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 {
        _ = io;
        _ = cwd;
        const self: *StubGit = @ptrCast(@alignCast(ptr));
        // Only rev-parse is emulated: `git rev-parse <ref>^{commit}` -> canned OID. Anything else is a test bug.
        if (argv.len >= 2 and std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[1], "rev-parse")) {
            return gpa.dupe(u8, self.oid[0..]) catch return FetchError.OutOfMemory;
        }
        return FetchError.GitFailed;
    }
};

pub fn indexRelPath(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8 {
    // cargo_util::registry::make_dep_path: exact shard rules (registry/mod.rs module docs).
    const lower = try gpa.dupe(u8, crate_name);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    defer gpa.free(lower);
    return switch (lower.len) {
        1 => std.fmt.allocPrint(gpa, "1/{s}", .{lower}),
        2 => std.fmt.allocPrint(gpa, "2/{s}", .{lower}),
        3 => std.fmt.allocPrint(gpa, "3/{c}/{s}", .{ lower[0], lower }),
        else => std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ lower[0..2], lower[2..4], lower }),
    };
}

pub const RegistryConfig = struct {
    dl: []const u8,
    api: ?[]const u8,
    auth_required: bool,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *RegistryConfig) void {
        self.arena.deinit();
    }
};

pub fn parseRegistryConfig(gpa: std.mem.Allocator, text: []const u8) FetchError!RegistryConfig {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return FetchError.InvalidIndex;
    defer parsed.deinit();
    if (parsed.value != .object) return FetchError.InvalidIndex;
    const dl_v = parsed.value.object.get("dl") orelse return FetchError.InvalidIndex;
    if (dl_v != .string) return FetchError.InvalidIndex;
    const api_v = parsed.value.object.get("api");
    const auth_v = parsed.value.object.get("auth-required");
    return .{
        .dl = try alloc.dupe(u8, dl_v.string),
        .api = if (api_v) |a| (if (a == .string) try alloc.dupe(u8, a.string) else null) else null,
        .auth_required = if (auth_v) |a| switch (a) {
            .bool => |b| b,
            else => false,
        } else false,
        .arena = arena,
    };
}

pub fn dlUrlFor(gpa: std.mem.Allocator, cfg: *const RegistryConfig, name: []const u8, version: []const u8, checksum: []const u8) FetchError![]u8 {
    // cargo_util::registry::crate_url (references/cargo/crates/cargo-util/src/registry.rs): exact port.
    // No placeholder present -> fallback "{dl}/{crate}/{version}/download". Otherwise substitute
    // {crate}/{version}/{sha256-checksum}/{prefix}/{lowerprefix}, where prefix = make_dep_path(name,
    // prefix_only=true) WITHOUT lowercasing (registry.rs prefix_only test: ("AbCd",true)->"Ab/Cd")
    // and lowerprefix = prefix.to_lowercase(). Index sharding (indexRelPath) always lowercases; dl
    // {prefix} preserves the crate-name case.
    const has_placeholder = std.mem.indexOf(u8, cfg.dl, "{crate}") != null or
        std.mem.indexOf(u8, cfg.dl, "{version}") != null or
        std.mem.indexOf(u8, cfg.dl, "{prefix}") != null or
        std.mem.indexOf(u8, cfg.dl, "{lowerprefix}") != null or
        std.mem.indexOf(u8, cfg.dl, "{sha256-checksum}") != null;
    if (!has_placeholder) {
        return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/download", .{ cfg.dl, name, version }) catch return FetchError.OutOfMemory;
    }
    const prefix = makeDepPrefix(gpa, name) catch return FetchError.OutOfMemory;
    defer gpa.free(prefix);
    const lowerprefix = gpa.dupe(u8, prefix) catch return FetchError.OutOfMemory;
    defer gpa.free(lowerprefix);
    for (lowerprefix) |*c| c.* = std.ascii.toLower(c.*);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = cfg.dl;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "{crate}")) {
            try out.appendSlice(gpa, name);
            rest = rest["{crate}".len..];
        } else if (std.mem.startsWith(u8, rest, "{version}")) {
            try out.appendSlice(gpa, version);
            rest = rest["{version}".len..];
        } else if (std.mem.startsWith(u8, rest, "{lowerprefix}")) {
            try out.appendSlice(gpa, lowerprefix);
            rest = rest["{lowerprefix}".len..];
        } else if (std.mem.startsWith(u8, rest, "{prefix}")) {
            try out.appendSlice(gpa, prefix);
            rest = rest["{prefix}".len..];
        } else if (std.mem.startsWith(u8, rest, "{sha256-checksum}")) {
            try out.appendSlice(gpa, checksum);
            rest = rest["{sha256-checksum}".len..];
        } else {
            try out.append(gpa, rest[0]);
            rest = rest[1..];
        }
    }
    return out.toOwnedSlice(gpa) catch return FetchError.OutOfMemory;
}

/// make_dep_path(name, prefix_only=true) exact port (cargo_util::registry::make_dep_path).
/// NOTE: unlike indexRelPath this does NOT lowercase: ("AbCd",true)->"Ab/Cd", ("abc",true)->"3/a".
fn makeDepPrefix(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8 {
    return switch (crate_name.len) {
        1 => std.fmt.allocPrint(gpa, "1", .{}),
        2 => std.fmt.allocPrint(gpa, "2", .{}),
        3 => std.fmt.allocPrint(gpa, "3/{c}", .{crate_name[0]}),
        else => std.fmt.allocPrint(gpa, "{s}/{s}", .{ crate_name[0..2], crate_name[2..4] }),
    };
}

/// On-disk index cache subset: <cache_dir>/<sharded-path> holds the body,
/// <cache_dir>/<sharded-path>.version holds the index_version (ETag). Mirrors
/// http_remote.rs revalidation inputs: callers pass the stored version as
/// If-None-Match and treat .not_modified as cache-valid (reuse the cached body).
/// FS pattern (verified precedent: src/main.zig openStoreDir uses
/// std.Io.Dir.cwd().createDirPathOpen(io, abs_path, .{}) for absolute paths; then all
/// I/O is handle-relative createDirPath/writeFile/readFileAlloc like src/store/cold.zig
/// store.dir.createDirPath/store.dir.writeFile/store.dir.readFileAlloc). No Dir.openPath.
pub fn writeIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8, body: []const u8, version: []const u8) FetchError!void {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    const dir_rel = std.fs.path.dirname(rel) orelse "";
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    if (dir_rel.len > 0) cache.createDirPath(io, dir_rel) catch return FetchError.StoreRead;
    const ver_rel = std.fmt.allocPrint(gpa, "{s}.version", .{rel}) catch return FetchError.OutOfMemory;
    defer gpa.free(ver_rel);
    cache.writeFile(io, .{ .sub_path = rel, .data = body }) catch return FetchError.StoreRead;
    cache.writeFile(io, .{ .sub_path = ver_rel, .data = version }) catch return FetchError.StoreRead;
}

pub fn readIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!IndexResponse {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    const body = cache.readFileAlloc(io, rel, gpa, .limited(4 << 20)) catch return IndexResponse{ .not_found = {} };
    return IndexResponse{ .fresh = body };
}

/// Stored index_version (ETag) for If-None-Match revalidation. Returns null when no cached
/// version file exists (caller passes null as cached_version = unconditional fetch).
pub fn readIndexVersion(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!?[]u8 {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    const ver_rel = std.fmt.allocPrint(gpa, "{s}.version", .{rel}) catch return FetchError.OutOfMemory;
    defer gpa.free(ver_rel);
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    return cache.readFileAlloc(io, ver_rel, gpa, .limited(1 << 16)) catch null;
}

pub const IndexEntry = struct { version: []const u8, checksum: []const u8, yanked: bool };

pub fn selectIndexEntry(gpa: std.mem.Allocator, index_body: []const u8, want_version: []const u8) FetchError!IndexEntry {
    var lines = std.mem.splitScalar(u8, index_body, '\n');
    while (lines.next()) |line| {
        const trim = std.mem.trim(u8, line, " \t\r");
        if (trim.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, trim, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const vers = parsed.value.object.get("vers") orelse continue;
        if (vers != .string) continue;
        if (!std.mem.eql(u8, vers.string, want_version)) continue;
        const cksum = parsed.value.object.get("cksum") orelse return FetchError.InvalidIndex;
        if (cksum != .string or cksum.string.len != 64) return FetchError.InvalidIndex;
        const yanked_v = parsed.value.object.get("yanked");
        const yanked = if (yanked_v) |y| switch (y) {
            .bool => |b| b,
            else => false,
        } else false;
        const version = gpa.dupe(u8, vers.string) catch return FetchError.OutOfMemory;
        errdefer gpa.free(version);
        const checksum = gpa.dupe(u8, cksum.string) catch return FetchError.OutOfMemory;
        return .{ .version = version, .checksum = checksum, .yanked = yanked };
    }
    return FetchError.NotFound;
}

pub fn verifySha256Hex(data: []const u8, want_hex: []const u8) FetchError!void {
    if (want_hex.len != 64) return FetchError.ChecksumMismatch;
    var want: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, want_hex) catch return FetchError.ChecksumMismatch;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    // NOTE: plan text spells `std.crypto.timing.safeEqual`; Zig 0.16 renamed
    // the namespace to `timing_safe` and the fn to `eql` (same semantics).
    if (!std.crypto.timing_safe.eql([32]u8, want, actual)) return FetchError.ChecksumMismatch;
}

pub fn fetchCrateBytes(gpa: std.mem.Allocator, io: std.Io, client: RegistryClient, cfg: *const RegistryConfig, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError![]u8 {
    // Cache path mirrors cargo's cache/<name>-<version>.crate flat layout (download.rs docs).
    // FS pattern (verified): cwd().createDirPathOpen for the absolute cache dir (src/main.zig),
    // then handle-relative readFileAlloc/createDirPath/writeFile (src/store/cold.zig). No Dir.openPath.
    const fname = std.fmt.allocPrint(gpa, "{s}-{s}.crate", .{ name, version }) catch return FetchError.OutOfMemory;
    defer gpa.free(fname);
    const rel = std.fmt.allocPrint(gpa, "crates/{s}", .{fname}) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    var cdir = std.Io.Dir.cwd().createDirPathOpen(io, opts.cache_dir, .{}) catch return FetchError.StoreRead;
    defer cdir.close(io);
    if (cdir.readFileAlloc(io, rel, gpa, .limited(512 << 20))) |cached| {
        if (cached.len > 0) return cached; // cargo download(): nonzero cache hit = Ready, no re-verify
        gpa.free(cached);
    } else |_| {}
    if (opts.offline) return FetchError.OfflineMissing;
    const url = try dlUrlFor(gpa, cfg, name, version, want_checksum);
    defer gpa.free(url);
    const data = try client.fetchCrate(gpa, url);
    errdefer gpa.free(data);
    try verifySha256Hex(data, want_checksum); // cargo finish_download(): bail BEFORE persisting
    cdir.createDirPath(io, "crates") catch {
        return FetchError.StoreRead;
    };
    cdir.writeFile(io, .{ .sub_path = rel, .data = data }) catch {
        return FetchError.StoreRead;
    };
    return data;
}

/// Test helper (same file): a RegistryClient whose every fn returns Network. Proves cache-hit and
/// store-reuse paths perform zero network I/O.
fn failingClient() RegistryClient {
    const S = struct {
        fn cfg(_: *anyopaque, _: std.mem.Allocator) FetchError![]u8 {
            return FetchError.Network;
        }
        fn idx(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) FetchError!IndexResponse {
            return FetchError.Network;
        }
        fn crt(_: *anyopaque, _: std.mem.Allocator, _: []const u8) FetchError![]u8 {
            return FetchError.Network;
        }
    };
    return .{ .ptr = undefined, .fetchConfigFn = S.cfg, .fetchIndexFn = S.idx, .fetchCrateFn = S.crt };
}

test "file registry stub serves config and index lines" {
    const gpa = std.testing.allocator;
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    const client = stub.client();
    const cfg_text = try client.fetchConfig(gpa);
    defer gpa.free(cfg_text);
    try std.testing.expect(std.mem.indexOf(u8, cfg_text, "\"dl\"") != null);
    const resp = try client.fetchIndex(gpa, "serde", null);
    const body = switch (resp) {
        .fresh => |b| b,
        else => return error.TestUnexpectedResult,
    };
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"yanked\":true") != null);
}

test "index paths shard like cargo" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "u", .want = "1/u" },
        .{ .name = "ab", .want = "2/ab" },
        .{ .name = "url", .want = "3/u/url" },
        .{ .name = "serde", .want = "se/rd/serde" },
        .{ .name = "bzip2", .want = "bz/ip/bzip2" },
    };
    for (cases) |c| {
        const got = try indexRelPath(gpa, c.name);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "config parses dl template and auth default" {
    var cfg = try parseRegistryConfig(std.testing.allocator,
        \\{"dl":"https://static.crates.io/crates/{crate}/{version}/download","api":"https://crates.io/api/v1/crates"}
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("https://static.crates.io/crates/{crate}/{version}/download", cfg.dl);
    try std.testing.expect(!cfg.auth_required);
    const url = try dlUrlFor(std.testing.allocator, &cfg, "serde", "1.0.0", "aa");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://static.crates.io/crates/serde/1.0.0/download", url);
}

test "dl template substitutes prefix/lowerprefix and falls back without placeholders" {
    const gpa = std.testing.allocator;
    // {prefix} is make_dep_path(name, prefix_only=true) WITHOUT lowercasing (cargo registry.rs
    // prefix_only test: make_dep_path("AbCd", true) == "Ab/Cd"); {lowerprefix} is prefix.to_lowercase().
    // Index sharding (indexRelPath) always lowercases; dl {prefix} preserves case.
    var cfg_p = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/{prefix}/{crate}/{version}/{sha256-checksum}\"}");
    defer cfg_p.deinit();
    const url1 = try dlUrlFor(gpa, &cfg_p, "serde", "1.0.0", "aa");
    defer gpa.free(url1);
    try std.testing.expectEqualStrings("https://dl.example/se/rd/serde/1.0.0/aa", url1);
    var cfg_l = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/{lowerprefix}/{crate}/{version}\"}");
    defer cfg_l.deinit();
    const url2 = try dlUrlFor(gpa, &cfg_l, "AbCd", "0.1.0", "aa");
    defer gpa.free(url2);
    try std.testing.expectEqualStrings("https://dl.example/ab/cd/AbCd/0.1.0", url2);
    // No placeholder at all -> fallback "{dl}/{crate}/{version}/download" (cargo crate_url branch).
    var cfg_f = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/base\"}");
    defer cfg_f.deinit();
    const url3 = try dlUrlFor(gpa, &cfg_f, "serde", "1.0.0", "aa");
    defer gpa.free(url3);
    try std.testing.expectEqualStrings("https://dl.example/base/serde/1.0.0/download", url3);
}

test "index cache round-trips and stub resolves sharded paths" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Verified precedent: dir.realPathFile with a stack buffer (src/store/disk_usage.zig:30). No realPathFileAlloc in src/store.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const root = path_buf[0..path_len];
    try writeIndexCache(gpa, io, root, "serde", "line1\n", "etag-1");
    const hit = try readIndexCache(gpa, io, root, "serde");
    const body = switch (hit) {
        .fresh => |b| b,
        else => return error.TestUnexpectedResult,
    };
    defer gpa.free(body);
    try std.testing.expectEqualStrings("line1\n", body);
    // Sharded stub file now resolves through the real layout:
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    const resp = try stub.client().fetchIndex(gpa, "serde", null);
    const sb = switch (resp) {
        .fresh => |b| b,
        else => return error.TestUnexpectedResult,
    };
    defer gpa.free(sb);
    try std.testing.expect(std.mem.indexOf(u8, sb, "\"1.0.0\"") != null);
}

test "index selection pins locked version and tolerates yanked" {
    const gpa = std.testing.allocator;
    const body =
        \\{"name":"serde","vers":"1.0.0","cksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","yanked":false}
        \\{"name":"serde","vers":"1.0.1","cksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","yanked":true}
        \\not json at all
        \\
    ;
    const pinned = try selectIndexEntry(gpa, body, "1.0.0");
    defer {
        gpa.free(pinned.version);
        gpa.free(pinned.checksum);
    }
    try std.testing.expectEqualStrings("1.0.0", pinned.version);
    try std.testing.expect(!pinned.yanked);
    // Locked yanked versions still fetch (cargo query() Yanked handling for locked deps):
    const yanked = try selectIndexEntry(gpa, body, "1.0.1");
    defer {
        gpa.free(yanked.version);
        gpa.free(yanked.checksum);
    }
    try std.testing.expect(yanked.yanked);
    try std.testing.expectError(FetchError.NotFound, selectIndexEntry(gpa, body, "9.9.9"));
}

test "sha256 verification accepts exact hex and rejects mismatch" {
    try verifySha256Hex("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex("abc", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex("abc", "not-hex-at-all"));
}

test "crate bytes come from cache when present, else download and verify" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stack-buffer realPathFile (disk_usage.zig:30 precedent).
    var cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_len = try tmp.dir.realPathFile(io, ".", &cache_buf);
    const cache = cache_buf[0..cache_len];
    // Fixture bytes + their real sha256 (the stub index cksum carries this hash).
    const fixture = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/fetch/stub/crates/serde-1.0.0.crate", gpa, .limited(512 << 20));
    defer gpa.free(fixture);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(fixture);
    var sum: [32]u8 = undefined;
    hasher.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    const want = try gpa.dupe(u8, &hex);
    defer gpa.free(want);
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    // NOTE (deviation from plan text, same intent): the plan's closed-over
    // literal dl path has no placeholders, so dlUrlFor would take the
    // no-placeholder fallback (".../serde/1.0.0/download") and the stub would
    // 404. A {crate}-{version} template resolves to the same literal fixture
    // path while exercising the substitution branch.
    var cfg = try parseRegistryConfig(gpa, "{\"dl\":\"file://STUB/crates/{crate}-{version}.crate\"}");
    defer cfg.deinit();
    const opts = FetchOptions{ .cache_dir = cache };
    // 1. Miss: downloads through the stub and verifies against the real hash (byte-identical).
    const got = try fetchCrateBytes(gpa, io, stub.client(), &cfg, opts, "serde", "1.0.0", want);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, fixture, got);
    // 2. Corrupt one byte in a copy -> ChecksumMismatch (proves verify-before-persist).
    const bad = try gpa.dupe(u8, fixture);
    defer gpa.free(bad);
    bad[bad.len / 2] ^= 0xff;
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex(bad, want));
    // 3. Cache hit: pre-place bytes at <cache>/crates/serde-1.0.0.crate, then call with a FAILING
    //    client (every fn returns Network) -> still byte-identical, proving no network on nonzero hit
    //    (cargo download() Ready path: no re-download, no re-verify).
    var cdir = try std.Io.Dir.cwd().createDirPathOpen(io, cache, .{});
    defer cdir.close(io);
    try cdir.createDirPath(io, "crates");
    try cdir.writeFile(io, .{ .sub_path = "crates/serde-1.0.0.crate", .data = fixture });
    const failing = failingClient();
    const hit = try fetchCrateBytes(gpa, io, failing, &cfg, opts, "serde", "1.0.0", want);
    defer gpa.free(hit);
    try std.testing.expectEqualSlices(u8, fixture, hit);
}
