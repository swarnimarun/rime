const std = @import("std");
const root = @import("root.zig");
const digest_mod = @import("digest.zig");
const layout = @import("layout.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

pub const lease_ttl_ms: i64 = 2 * 60 * 60 * 1000; // 2 h, spec §9.3

pub const Pin = struct { name: []const u8, digest_hex: []const u8, created_ms: i64 };
pub const Lease = struct { build_id: []const u8, digest_hexes: []const []const u8, expires_ms: i64 };
pub const ProjectRetain = struct { project_id: []const u8, manifest_hexes: []const []const u8, updated_ms: i64 };

pub const StateError = error{ Unexpected, OutOfMemory, NoSuchPin } || Io.Cancelable ||
    Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Dir.ReadFileAllocError ||
    Io.Dir.WriteFileError || Io.Dir.RenameError || Io.Dir.DeleteFileError;

const LeaseJson = struct { build_id: []const u8, digest_hexes: []const []const u8, expires_ms: i64 };
const PinJson = struct { name: []const u8, digest_hex: []const u8, created_ms: i64 };
const RetainJson = struct { project_id: []const u8, manifest_hexes: []const []const u8, updated_ms: i64 };

pub fn isLive(lease: Lease, now_ms: i64) bool {
    return now_ms < lease.expires_ms;
}

/// Atomic JSON file write: tmp in state/ + rename (spec §8.3).
fn writeJsonAtomic(io: Io, store_dir: Io.Dir, sub_path: []const u8, json_bytes: []const u8) StateError!void {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const rand_hex = std.fmt.bytesToHex(rnd, .lower);
    var tmp_buf: [128]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/w-{s}", .{ layout.state_dir, rand_hex[0..] }) catch return error.Unexpected;
    store_dir.writeFile(io, .{ .sub_path = tmp, .data = json_bytes }) catch return error.Unexpected;
    store_dir.rename(tmp, store_dir, sub_path, io) catch return error.Unexpected;
}

fn subPathAlloc(comptime dir_suffix: []const u8, name: []const u8, suffix: []const u8) StateError![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}/{s}{s}", .{ layout.state_dir, dir_suffix, name, suffix }) catch return error.OutOfMemory;
}

pub fn putPin(io: Io, store_dir: Io.Dir, name: []const u8, digest: digest_mod.Digest, now_ms: i64) StateError!void {
    const hex = digest.toHex();
    const bytes = std.json.Stringify.valueAlloc(std.heap.page_allocator, PinJson{
        .name = name,
        .digest_hex = hex[0..],
        .created_ms = now_ms,
    }, .{}) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(bytes);
    const sub = try subPathAlloc("pins", name, "");
    defer std.heap.page_allocator.free(sub);
    try writeJsonAtomic(io, store_dir, sub, bytes);
}

pub fn removePin(io: Io, store_dir: Io.Dir, name: []const u8) StateError!void {
    const sub = try subPathAlloc("pins", name, "");
    defer std.heap.page_allocator.free(sub);
    store_dir.deleteFile(io, sub) catch |err| switch (err) {
        error.FileNotFound => return error.NoSuchPin,
        else => return error.Unexpected,
    };
}

pub fn listPins(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir) StateError![]Pin {
    var list: std.ArrayList(Pin) = .empty;
    errdefer {
        for (list.items) |p| {
            gpa.free(p.name);
            gpa.free(p.digest_hex);
        }
        list.deinit(gpa);
    }
    const pins_dir = store_dir.openDir(io, layout.state_dir ++ "/pins", .{ .iterate = true }) catch return error.Unexpected;
    defer pins_dir.close(io);
    var it = pins_dir.iterate();
    while (try it.next(io)) |entry| {
        const bytes = pins_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const parsed = std.json.parseFromSlice(PinJson, gpa, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => {
                gpa.free(bytes);
                return error.OutOfMemory;
            },
            else => {
                gpa.free(bytes);
                continue;
            },
        };
        gpa.free(bytes);
        defer parsed.deinit();
        const name = gpa.dupe(u8, parsed.value.name) catch return error.OutOfMemory;
        const hex = gpa.dupe(u8, parsed.value.digest_hex) catch {
            gpa.free(name);
            return error.OutOfMemory;
        };
        list.append(gpa, .{ .name = name, .digest_hex = hex, .created_ms = parsed.value.created_ms }) catch {
            gpa.free(name);
            gpa.free(hex);
            return error.OutOfMemory;
        };
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freePins(gpa: std.mem.Allocator, pins: []Pin) void {
    for (pins) |p| {
        gpa.free(p.name);
        gpa.free(p.digest_hex);
    }
    gpa.free(pins);
}

pub fn putLease(io: Io, store_dir: Io.Dir, build_id: []const u8, digests: []const digest_mod.Digest, now_ms: i64) StateError!void {
    const page = std.heap.page_allocator;
    const hexes = page.alloc([]const u8, digests.len) catch return error.OutOfMemory;
    var done: usize = 0;
    defer {
        for (hexes[0..done]) |h| page.free(h);
        page.free(hexes);
    }
    for (digests, hexes) |d, *slot| {
        const hex = d.toHex();
        slot.* = page.dupe(u8, hex[0..]) catch return error.OutOfMemory;
        done += 1;
    }
    const bytes = std.json.Stringify.valueAlloc(page, LeaseJson{
        .build_id = build_id,
        .digest_hexes = hexes,
        .expires_ms = now_ms + lease_ttl_ms,
    }, .{}) catch return error.OutOfMemory;
    defer page.free(bytes);
    const sub = try subPathAlloc("leases", build_id, "");
    defer page.free(sub);
    try writeJsonAtomic(io, store_dir, sub, bytes);
}

pub fn renewLease(io: Io, store_dir: Io.Dir, build_id: []const u8, now_ms: i64) StateError!void {
    const page = std.heap.page_allocator;
    const sub = try subPathAlloc("leases", build_id, "");
    defer page.free(sub);
    const bytes = store_dir.readFileAlloc(io, sub, page, .unlimited) catch |err| switch (err) {
        // No lease yet: write a fresh one carrying only the build id.
        error.FileNotFound => return putLease(io, store_dir, build_id, &.{}, now_ms),
        else => return error.Unexpected,
    };
    defer page.free(bytes);
    const parsed = std.json.parseFromSlice(LeaseJson, page, bytes, .{ .allocate = .alloc_always }) catch return error.Unexpected;
    defer parsed.deinit();
    const out = std.json.Stringify.valueAlloc(page, LeaseJson{
        .build_id = parsed.value.build_id,
        .digest_hexes = parsed.value.digest_hexes,
        .expires_ms = now_ms + lease_ttl_ms,
    }, .{}) catch return error.OutOfMemory;
    defer page.free(out);
    try writeJsonAtomic(io, store_dir, sub, out);
}

pub fn dropLease(io: Io, store_dir: Io.Dir, build_id: []const u8) StateError!void {
    const sub = try subPathAlloc("leases", build_id, "");
    defer std.heap.page_allocator.free(sub);
    // Idempotent: dropping an absent lease is a no-op.
    store_dir.deleteFile(io, sub) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    };
}

/// Returns live leases, deleting expired lease files as a side effect.
pub fn liveLeases(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir, now_ms: i64) StateError![]Lease {
    var list: std.ArrayList(Lease) = .empty;
    errdefer {
        for (list.items) |l| {
            gpa.free(l.build_id);
            for (l.digest_hexes) |h| gpa.free(h);
            gpa.free(l.digest_hexes);
        }
        list.deinit(gpa);
    }
    const leases_dir = store_dir.openDir(io, layout.state_dir ++ "/leases", .{ .iterate = true }) catch return error.Unexpected;
    defer leases_dir.close(io);
    var it = leases_dir.iterate();
    while (try it.next(io)) |entry| {
        const bytes = leases_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const parsed = std.json.parseFromSlice(LeaseJson, gpa, bytes, .{ .allocate = .alloc_always }) catch {
            gpa.free(bytes);
            continue;
        };
        gpa.free(bytes);
        defer parsed.deinit();
        if (now_ms >= parsed.value.expires_ms) {
            leases_dir.deleteFile(io, entry.name) catch {};
            continue;
        }
        const id = gpa.dupe(u8, parsed.value.build_id) catch return error.OutOfMemory;
        const hexes = gpa.alloc([]const u8, parsed.value.digest_hexes.len) catch {
            gpa.free(id);
            return error.OutOfMemory;
        };
        for (parsed.value.digest_hexes, 0..) |h, i| {
            hexes[i] = gpa.dupe(u8, h) catch {
                for (hexes[0..i]) |prev| gpa.free(prev);
                gpa.free(hexes);
                gpa.free(id);
                return error.OutOfMemory;
            };
        }
        list.append(gpa, .{ .build_id = id, .digest_hexes = hexes, .expires_ms = parsed.value.expires_ms }) catch {
            for (hexes) |h| gpa.free(h);
            gpa.free(hexes);
            gpa.free(id);
            return error.OutOfMemory;
        };
    }
    return try list.toOwnedSlice(gpa);
}

/// Counts expired leases without deleting them. Powers GcReport
/// accounting and dry-run expiry estimates (liveLeases deletes).
/// Skips unreadable/corrupt files like liveLeases does.
pub fn countExpiredLeases(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir, now_ms: i64) StateError!u64 {
    var expired: u64 = 0;
    const leases_dir = store_dir.openDir(io, layout.state_dir ++ "/leases", .{ .iterate = true }) catch return error.Unexpected;
    defer leases_dir.close(io);
    var it = leases_dir.iterate();
    while (try it.next(io)) |entry| {
        const bytes = leases_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(bytes);
        const parsed = std.json.parseFromSlice(LeaseJson, gpa, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (now_ms >= parsed.value.expires_ms) expired += 1;
    }
    return expired;
}

pub fn freeLeases(gpa: std.mem.Allocator, leases: []Lease) void {
    for (leases) |l| {
        gpa.free(l.build_id);
        for (l.digest_hexes) |h| gpa.free(h);
        gpa.free(l.digest_hexes);
    }
    gpa.free(leases);
}

pub fn putRetain(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir, project_id: []const u8, manifests: []const digest_mod.Digest, now_ms: i64) StateError!void {
    const page = std.heap.page_allocator;
    const hexes = gpa.alloc([]const u8, manifests.len) catch return error.OutOfMemory;
    var done: usize = 0;
    defer {
        for (hexes[0..done]) |h| gpa.free(h);
        gpa.free(hexes);
    }
    for (manifests, hexes) |m, *slot| {
        const hex = m.toHex();
        slot.* = gpa.dupe(u8, hex[0..]) catch return error.OutOfMemory;
        done += 1;
    }
    const bytes = std.json.Stringify.valueAlloc(page, RetainJson{
        .project_id = project_id,
        .manifest_hexes = hexes,
        .updated_ms = now_ms,
    }, .{}) catch return error.OutOfMemory;
    defer page.free(bytes);
    const sub = try subPathAlloc("projects", project_id, ".json");
    defer page.free(sub);
    try writeJsonAtomic(io, store_dir, sub, bytes);
}

pub fn listRetains(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir) StateError![]ProjectRetain {
    var list: std.ArrayList(ProjectRetain) = .empty;
    errdefer {
        for (list.items) |r| {
            gpa.free(r.project_id);
            for (r.manifest_hexes) |h| gpa.free(h);
            gpa.free(r.manifest_hexes);
        }
        list.deinit(gpa);
    }
    const projs_dir = store_dir.openDir(io, layout.state_dir ++ "/projects", .{ .iterate = true }) catch return error.Unexpected;
    defer projs_dir.close(io);
    var it = projs_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = projs_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const parsed = std.json.parseFromSlice(RetainJson, gpa, bytes, .{ .allocate = .alloc_always }) catch {
            gpa.free(bytes);
            continue;
        };
        gpa.free(bytes);
        defer parsed.deinit();
        const id = gpa.dupe(u8, parsed.value.project_id) catch return error.OutOfMemory;
        const hexes = gpa.alloc([]const u8, parsed.value.manifest_hexes.len) catch {
            gpa.free(id);
            return error.OutOfMemory;
        };
        for (parsed.value.manifest_hexes, 0..) |h, i| {
            hexes[i] = gpa.dupe(u8, h) catch {
                for (hexes[0..i]) |prev| gpa.free(prev);
                gpa.free(hexes);
                gpa.free(id);
                return error.OutOfMemory;
            };
        }
        list.append(gpa, .{ .project_id = id, .manifest_hexes = hexes, .updated_ms = parsed.value.updated_ms }) catch {
            for (hexes) |h| gpa.free(h);
            gpa.free(hexes);
            gpa.free(id);
            return error.OutOfMemory;
        };
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeRetains(gpa: std.mem.Allocator, retains: []ProjectRetain) void {
    for (retains) |r| {
        gpa.free(r.project_id);
        for (r.manifest_hexes) |h| gpa.free(h);
        gpa.free(r.manifest_hexes);
    }
    gpa.free(retains);
}

test "pins round trip and remove" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = root.hashBytes("pinned");
    try putPin(io, ts.store.dir, "corpus", d, 1000);
    const pins = try listPins(io, gpa, ts.store.dir);
    defer freePins(gpa, pins);
    try std.testing.expectEqual(@as(usize, 1), pins.len);
    try std.testing.expectEqualStrings("corpus", pins[0].name);

    try removePin(io, ts.store.dir, "corpus");
    const none = try listPins(io, gpa, ts.store.dir);
    defer freePins(gpa, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "leases expire by wall clock" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = root.hashBytes("leased");
    try putLease(io, ts.store.dir, "build-1", &.{d}, 1000);

    // Still live one minute after creation (lease TTL is 2 h).
    const live = try liveLeases(io, gpa, ts.store.dir, 1000 + 60 * 1000);
    defer freeLeases(gpa, live);
    try std.testing.expectEqual(@as(usize, 1), live.len);
    try std.testing.expect(isLive(live[0], 1000));

    const expired = try liveLeases(io, gpa, ts.store.dir, 1000 + 3 * lease_ttl_ms);
    defer freeLeases(gpa, expired);
    try std.testing.expectEqual(@as(usize, 0), expired.len);
}

test "retains record project manifests" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const m = root.hashBytes("manifest");
    try putRetain(io, gpa, ts.store.dir, "proj1", &.{m}, 42);
    const rs = try listRetains(io, gpa, ts.store.dir);
    defer freeRetains(gpa, rs);
    try std.testing.expectEqual(@as(usize, 1), rs.len);
    try std.testing.expectEqualStrings("proj1", rs[0].project_id);
}
