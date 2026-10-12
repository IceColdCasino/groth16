const std = @import("std");

pub const Section = struct {
    id: u32,
    size: u64,
    pos: u64,
};

pub const ZkeyHeader = struct {
    n8: u32,
    n8r: u32,
    q: [32]u8,
    r: [32]u8,
    nVars: u32,
    nPublic: u32,
    domainSize: u32,
    power: u32,
    nCoefs: u64,
};

pub const Zkey = struct {
    raw: []const u8,
    header: ZkeyHeader,
    sections: []Section,

    pub fn getSection(self: Zkey, id: u32) ?[]const u8 {
        for (self.sections) |section| {
            if (section.id == id) {
                const start = @as(usize, @intCast(section.pos));
                const end = start + @as(usize, @intCast(section.size));
                if (end > self.raw.len) return null;
                return self.raw[start..end];
            }
        }
        return null;
    }

    pub fn deinit(self: Zkey, allocator: std.mem.Allocator) void {
        allocator.free(self.sections);
    }
};

pub const WitnessHeader = struct {
    n8: u32,
    q: [32]u8,
    nVars: u32,
};

pub const Witness = struct {
    raw: []const u8,
    header: WitnessHeader,
    data: []const u8,

    pub fn deinit(self: Witness, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn parseZkey(allocator: std.mem.Allocator, data: []const u8) !Zkey {
    if (data.len < 12) return error.FileTooShort;

    if (!std.mem.eql(u8, data[0..4], "zkey")) return error.InvalidMagic;

    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version != 1) return error.InvalidVersion;

    const nSections = std.mem.readInt(u32, data[8..12], .little);
    const minFileSize = 12 + nSections * 12;
    if (data.len < minFileSize) return error.FileTooShort;

    var sections = try allocator.alloc(Section, nSections);
    errdefer allocator.free(sections);

    var pos: u64 = 12;
    for (0..nSections) |i| {
        if (pos + 12 > data.len) return error.FileTooShort;
        const id = std.mem.readInt(u32, data[pos..][0..4], .little);
        const size = std.mem.readInt(u64, data[pos + 4 ..][0..8], .little);
        pos += 12;

        if (pos + size > data.len) return error.InvalidSectionSize;

        sections[i] = .{
            .id = id,
            .size = size,
            .pos = pos,
        };
        pos += size;
    }

    // Parse header from section 2
    const section2 = blk: {
        for (sections) |section| {
            if (section.id == 2) break :blk section;
        }
        return error.MissingHeaderSection;
    };

    const headerData = data[section2.pos..];
    if (section2.size < 4) return error.HeaderTooShort;

    var hpos: u64 = 0;
    const n8q = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;
    if (n8q > 32) return error.FieldTooLarge;
    if (section2.size < hpos + n8q + 4) return error.HeaderTooShort;

    var q: [32]u8 = undefined;
    @memcpy(q[0..n8q], headerData[hpos..][0..n8q]);
    hpos += n8q;

    const n8r = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;
    if (n8r > 32) return error.FieldTooLarge;

    const remaining_after_r = section2.size - hpos;
    if (remaining_after_r < n8r + 4 + 4 + 4) return error.HeaderTooShort;

    var r: [32]u8 = undefined;
    @memcpy(r[0..n8r], headerData[hpos..][0..n8r]);
    hpos += n8r;

    const nVars = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;
    const nPublic = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;
    const domainSize = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;

    // Skip verification key points
    const vk_total_size = n8q * 2 + n8q * 2 + n8q * 4 + n8q * 4 + n8q * 2 + n8q * 4;
    if (section2.size < hpos + vk_total_size) return error.HeaderTooShort;
    hpos += vk_total_size;

    // Calculate power = log2(domainSize)
    const power = std.math.log2_int(u32, domainSize);

    // Calculate nCoefs from section 4
    const section4 = blk: {
        for (sections) |section| {
            if (section.id == 4) break :blk section;
        }
        return error.MissingCoefficientsSection;
    };

    const coefRecordSize = 12 + n8r;
    const nCoefs = section4.size / coefRecordSize;

    const header = ZkeyHeader{
        .n8 = n8q,
        .n8r = n8r,
        .q = q,
        .r = r,
        .nVars = nVars,
        .nPublic = nPublic,
        .domainSize = domainSize,
        .power = power,
        .nCoefs = nCoefs,
    };

    return Zkey{
        .raw = data,
        .header = header,
        .sections = sections,
    };
}

pub fn parseWitness(allocator: std.mem.Allocator, data: []const u8) !Witness {
    _ = allocator;

    if (data.len < 12) return error.FileTooShort;

    if (!std.mem.eql(u8, data[0..4], "wtns")) return error.InvalidMagic;

    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version != 2) return error.InvalidVersion;

    const nSections = std.mem.readInt(u32, data[8..12], .little);
    const minFileSize = 12 + nSections * 12;
    if (data.len < minFileSize) return error.FileTooShort;

    var pos: u64 = 12;
    var section1: ?Section = null;
    var section2: ?Section = null;

    for (0..nSections) |_| {
        if (pos + 12 > data.len) return error.FileTooShort;
        const id = std.mem.readInt(u32, data[pos..][0..4], .little);
        const size = std.mem.readInt(u64, data[pos + 4 ..][0..8], .little);
        pos += 12;

        if (pos + size > data.len) return error.InvalidSectionSize;

        const section = Section{
            .id = id,
            .size = size,
            .pos = pos,
        };

        if (id == 1) section1 = section;
        if (id == 2) section2 = section;

        pos += size;
    }

    const s1 = section1 orelse return error.MissingHeaderSection;
    const s2 = section2 orelse return error.MissingDataSection;

    const headerData = data[s1.pos..][0..s1.size];
    if (s1.size < 4) return error.HeaderTooShort;

    var hpos: u64 = 0;
    const n8 = std.mem.readInt(u32, headerData[hpos..][0..4], .little);
    hpos += 4;
    if (n8 > 32) return error.FieldTooLarge;
    if (s1.size < hpos + n8 + 4) return error.HeaderTooShort;

    var q: [32]u8 = undefined;
    @memcpy(q[0..n8], headerData[hpos..][0..n8]);
    hpos += n8;

    const nVars = std.mem.readInt(u32, headerData[hpos..][0..4], .little);

    const header = WitnessHeader{
        .n8 = n8,
        .q = q,
        .nVars = nVars,
    };

    const witnessData = data[s2.pos..][0..s2.size];

    return Witness{
        .raw = data,
        .header = header,
        .data = witnessData,
    };
}

test "parse zkey" {
    const testdata = @import("testdata");
    var zkey = try parseZkey(std.testing.allocator, testdata.ZKEY);
    defer zkey.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1003), zkey.header.nVars);
    try std.testing.expectEqual(@as(u32, 1), zkey.header.nPublic);
    try std.testing.expectEqual(@as(u32, 1024), zkey.header.domainSize);
    // Verify section 5 exists (pointsA)
    const section5 = zkey.getSection(5);
    try std.testing.expect(section5 != null);
}

test "parse witness" {
    const testdata = @import("testdata");
    var wtns = try parseWitness(std.testing.allocator, testdata.WTNS);
    defer wtns.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1003), wtns.header.nVars);
    try std.testing.expectEqual(@as(usize, 1003 * 32), wtns.data.len);
}
