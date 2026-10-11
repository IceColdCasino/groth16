const std = @import("std");
const parser = @import("parser.zig");
const qap = @import("gpu/qap.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub const CachedZkey = struct {
    data: []const u8, // Reference to cache-owned data (DO NOT FREE)
    zkey: parser.Zkey, // Cloned sections - caller must deinit
    qap_info: qap.ZkeyInfo,

    pub fn deinit(self: *CachedZkey, allocator: std.mem.Allocator) void {
        self.zkey.deinit(allocator);
        // NOTE: do NOT free self.data - it is owned by the cache
    }
};

fn readFileToBuffer(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const file = c.fopen(path_z.ptr, "rb");
    if (file == null) return error.FileNotFound;
    defer _ = c.fclose(file);

    _ = c.fseek(file, 0, c.SEEK_END);
    const size = c.ftell(file);
    _ = c.fseek(file, 0, c.SEEK_SET);

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const read_size = c.fread(buf.ptr, 1, @intCast(size), file);
    if (read_size != @as(usize, @intCast(size))) {
        allocator.free(buf);
        return error.ReadFailed;
    }
    return buf;
}

fn zkeyToQapInfo(zkey: parser.Zkey) !qap.ZkeyInfo {
    const sec4 = zkey.getSection(4) orelse return error.MissingSection;
    const sec9 = zkey.getSection(9) orelse return error.MissingSection;

    const sec4_offset = @intFromPtr(sec4.ptr) - @intFromPtr(zkey.raw.ptr);
    const sec9_offset = @intFromPtr(sec9.ptr) - @intFromPtr(zkey.raw.ptr);

    return qap.ZkeyInfo{
        .n_vars = zkey.header.nVars,
        .n_public = zkey.header.nPublic,
        .domain_size = zkey.header.domainSize,
        .n8r = zkey.header.n8r,
        .sec4_offset = sec4_offset,
        .sec4_size = sec4.len,
        .sec9_offset = sec9_offset,
        .sec9_size = sec9.len,
    };
}

pub const ZkeyCache = struct {
    mutex: std.atomic.Mutex,
    map: std.StringHashMap(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        data: []u8,
        zkey: parser.Zkey,
        qap_info: qap.ZkeyInfo,
    };

    pub fn init(allocator: std.mem.Allocator) ZkeyCache {
        return .{
            .mutex = .unlocked,
            .map = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZkeyCache) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
            entry.value_ptr.zkey.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    pub fn getOrLoad(self: *ZkeyCache, path: []const u8) !CachedZkey {
        // Use path as-is for cache key (caller should pass consistent paths)
        const key = try self.allocator.dupe(u8, path);
        // NOTE: key is either freed on cache hit or transferred to the map on cache miss

        mutexLock(&self.mutex);

        if (self.map.getPtr(key)) |entry| {
            self.mutex.unlock();
            self.allocator.free(key);
            const sections = try self.allocator.dupe(parser.Section, entry.zkey.sections);
            errdefer self.allocator.free(sections);
            return CachedZkey{
                .data = entry.data,
                .zkey = .{
                    .raw = entry.data,
                    .header = entry.zkey.header,
                    .sections = sections,
                },
                .qap_info = entry.qap_info,
            };
        }

        self.mutex.unlock();

        const data = try readFileToBuffer(path, self.allocator);
        errdefer self.allocator.free(data);

        var zkey = try parser.parseZkey(self.allocator, data);
        errdefer zkey.deinit(self.allocator);
        zkey.raw = data;

        const qap_info = try zkeyToQapInfo(zkey);

        mutexLock(&self.mutex);
        defer self.mutex.unlock();

        if (self.map.getPtr(key)) |entry| {
            self.allocator.free(key);
            zkey.deinit(self.allocator);
            const sections = try self.allocator.dupe(parser.Section, entry.zkey.sections);
            errdefer self.allocator.free(sections);
            return CachedZkey{
                .data = entry.data,
                .zkey = .{
                    .raw = entry.data,
                    .header = entry.zkey.header,
                    .sections = sections,
                },
                .qap_info = entry.qap_info,
            };
        }

        try self.map.put(key, .{
            .data = data,
            .zkey = zkey,
            .qap_info = qap_info,
        });

        const sections = try self.allocator.dupe(parser.Section, zkey.sections);
        errdefer self.allocator.free(sections);

        return CachedZkey{
            .data = data,
            .zkey = .{
                .raw = data,
                .header = zkey.header,
                .sections = sections,
            },
            .qap_info = qap_info,
        };
    }
};

var g_cache: ZkeyCache = undefined;
var g_cache_initialized: bool = false;
var g_cache_init_mutex: std.atomic.Mutex = .unlocked;

pub fn getGlobalCache() *ZkeyCache {
    if (!g_cache_initialized) {
        mutexLock(&g_cache_init_mutex);
        defer g_cache_init_mutex.unlock();
        if (!g_cache_initialized) {
            g_cache = ZkeyCache.init(std.heap.c_allocator);
            g_cache_initialized = true;
        }
    }
    return &g_cache;
}
