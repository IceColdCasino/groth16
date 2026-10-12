//! Groth16 phase-2 zkey (`snarkjs groth16 setup` / `zkey_new`).
//!
//! The prepared powers-of-tau file already stores `[L_i(τ)]` in Lagrange form.
//! Each R1CS coefficient `c` at constraint `i` contributes `c · L_i` to that
//! signal's proving-key point. ±1 coefficients are grouped by signal so the
//! accumulator stays in registers, and threads own disjoint signal ranges.
const std = @import("std");
const batch = @import("batch.zig");
const ff = @import("ff.zig");
const curve = @import("curve.zig");

const Fq = ff.Fq;
const Fr = ff.Fr;
const G1 = curve.G1;
const G2 = curve.G2;
const Blake = std.crypto.hash.blake2.Blake2b512;

const Sparse = struct {
    signal: u32,
    coef: [4]u64,
};

const Con = struct {
    a_off: u32,
    a_len: u32,
    b_off: u32,
    b_len: u32,
    c_off: u32,
    c_len: u32,
};

const CoefRec = struct {
    mat: u32,
    ci: u32,
    signal: u32,
    coef: [4]u64,
};

const Sec = struct {
    off: u64,
    size: u64,
};

pub fn run(alloc: std.mem.Allocator, io: std.Io, r1cs_path: []const u8, ptau_path: []const u8, out_path: []const u8) !void {
    const bytes = try build(alloc, io, r1cs_path, ptau_path);
    defer alloc.free(bytes);
    try writeAll(io, out_path, bytes);
    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, bytes.len });
}

pub fn build(alloc: std.mem.Allocator, io: std.Io, r1cs_path: []const u8, ptau_path: []const u8) ![]u8 {
    var timer = std.Io.Clock.Timestamp.now(io, .awake);
    const r1cs_bytes = try readFile(alloc, io, r1cs_path);
    defer alloc.free(r1cs_bytes);
    const parsed = try parseR1cs(alloc, r1cs_bytes);
    defer {
        alloc.free(parsed.cons);
        alloc.free(parsed.terms);
        alloc.free(parsed.coefs);
    }

    const sum: u64 = @as(u64, parsed.n_constraints) + parsed.n_public;
    if (sum == 0 or sum >= (@as(u64, 1) << 31)) return error.CircuitTooBig;
    const cir_power: u8 = (63 - @as(u8, @clz(sum))) + 1;
    if (cir_power > 28) return error.CircuitTooBig;
    const domain: u32 = @as(u32, 1) << @intCast(cir_power);
    if (@as(u64, parsed.n_constraints) + parsed.n_public + 1 > domain) return error.DomainTooSmall;

    var ptau_file = try openFile(io, ptau_path);
    defer ptau_file.close(io);
    const ptau_secs = try scan(io, ptau_file, "ptau");
    const power = try readPtauPower(io, ptau_file, ptau_secs);
    if (cir_power > power) {
        std.debug.print("circuit power {d} exceeds ptau power {d}\n", .{ cir_power, power });
        return error.CircuitTooBig;
    }
    const sec12 = ptau_secs[12] orelse return error.PtauNotPrepared;
    const sec13 = ptau_secs[13] orelse return error.PtauNotPrepared;
    const sec14 = ptau_secs[14] orelse return error.PtauNotPrepared;
    const sec15 = ptau_secs[15] orelse return error.PtauNotPrepared;
    const sec4 = ptau_secs[4] orelse return error.PtauNotPrepared;
    const sec5 = ptau_secs[5] orelse return error.PtauNotPrepared;
    const sec6 = ptau_secs[6] orelse return error.PtauNotPrepared;
    const sec2 = ptau_secs[2] orelse return error.PtauNotPrepared;

    var alpha: [64]u8 = undefined;
    var beta1: [64]u8 = undefined;
    var beta2: [128]u8 = undefined;
    try readExact(io, ptau_file, sec4.off, &alpha);
    try readExact(io, ptau_file, sec5.off, &beta1);
    try readExact(io, ptau_file, sec6.off, &beta2);

    const tau_g1 = try readDomain(alloc, io, ptau_file, sec12, domain, 64);
    defer alloc.free(tau_g1);
    const tau_g2 = try readDomain(alloc, io, ptau_file, sec13, domain, 128);
    defer alloc.free(tau_g2);
    const alpha_tau = try readDomain(alloc, io, ptau_file, sec14, domain, 64);
    defer alloc.free(alpha_tau);
    const beta_tau = try readDomain(alloc, io, ptau_file, sec15, domain, 64);
    defer alloc.free(beta_tau);
    const h_bytes = try readH(alloc, io, ptau_file, sec12, domain, cir_power);
    defer alloc.free(h_bytes);

    std.debug.print("r1cs vars {d} public {d} constraints {d} domain 2^{d}\n", .{
        parsed.n_vars, parsed.n_public, parsed.n_constraints, cir_power,
    });
    std.debug.print("read ceremony in {d} ms\n", .{elapsedMs(io, &timer)});

    const nthreads = threadCount(parsed.n_constraints);
    std.debug.print("accumulating on {d} threads\n", .{nthreads});
    const merged = try accumulate(alloc, io, parsed, tau_g1, tau_g2, alpha_tau, beta_tau, nthreads);
    defer freeAcc(alloc, merged);

    std.debug.print("accumulated in {d} ms\n", .{elapsedMs(io, &timer)});

    const points = try serialize(alloc, merged);
    defer points.deinit(alloc);
    std.debug.print("serialized in {d} ms\n", .{elapsedMs(io, &timer)});

    var hasher = Blake.init(.{});
    var out = Out.init(alloc);
    errdefer out.deinit();
    try out.bytes("zkey");
    try out.u32le(1);
    try out.u32le(10);

    {
        const at = try out.begin(1);
        try out.u32le(1);
        try out.end(at);
    }
    {
        const at = try out.begin(2);
        try out.u32le(32);
        var prime: [32]u8 = undefined;
        storeLimbs(Fq.mod_limbs, &prime);
        try out.bytes(&prime);
        try out.u32le(32);
        storeLimbs(Fr.mod_limbs, &prime);
        try out.bytes(&prime);
        try out.u32le(parsed.n_vars);
        try out.u32le(parsed.n_public);
        try out.u32le(domain);
        try out.bytes(&alpha);
        try out.bytes(&beta1);
        try out.bytes(&beta2);
        const g1 = g1Gen();
        const g2 = g2Gen();
        try out.bytes(&g2);
        try out.bytes(&g1);
        try out.bytes(&g2);
        try out.end(at);
        hashPoints(&hasher, &alpha, 64);
        hashPoints(&hasher, &beta1, 64);
        hashPoints(&hasher, &beta2, 128);
        hashPoints(&hasher, &g2, 128);
        hashPoints(&hasher, &g1, 64);
        hashPoints(&hasher, &g2, 128);
    }
    {
        const at = try out.begin(4);
        try writeCoefs(&out, parsed.coefs);
        try out.end(at);
    }
    try writePointSection(&out, &hasher, 3, points.ic, 64);
    {
        const at = try out.begin(9);
        try out.bytes(h_bytes);
        try out.end(at);
    }
    try hashH(&hasher, alloc, io, ptau_file, sec2, domain);
    try writePointSection(&out, &hasher, 8, points.c, 64);
    try writePointSection(&out, &hasher, 5, points.a, 64);
    try writePointSection(&out, &hasher, 6, points.b1, 64);
    try writePointSection(&out, &hasher, 7, points.b2, 128);

    var digest: [64]u8 = undefined;
    hasher.final(&digest);
    {
        const at = try out.begin(10);
        try out.bytes(&digest);
        try out.u32le(0);
        try out.end(at);
    }
    printHash(&digest);
    return out.toOwned();
}

const Parsed = struct {
    n_vars: u32,
    n_public: u32,
    n_constraints: u32,
    cons: []Con,
    terms: []Sparse,
    coefs: []CoefRec,
};

fn parseR1cs(alloc: std.mem.Allocator, file: []const u8) !Parsed {
    const secs = try scanBytes(file, "r1cs");
    const s1 = secs[1] orelse return error.NotR1cs;
    const s2 = secs[2] orelse return error.NotR1cs;
    if (s1.off + s1.size > file.len or s2.off + s2.size > file.len) return error.UnexpectedEof;
    const h = file[s1.off .. s1.off + s1.size];
    if (h.len < 4) return error.NotR1cs;
    const n8 = std.mem.readInt(u32, h[0..4], .little);
    if (n8 != 32) return error.NotBn254;
    if (h.len < 4 + 32 + 28) return error.NotR1cs;
    const prime = ff.loadLimbs(h[4..36]);
    if (!std.mem.eql(u64, &prime, &Fr.mod_limbs)) return error.NotBn254;
    const base: usize = 36;
    const n_vars = std.mem.readInt(u32, h[base..][0..4], .little);
    const n_out = std.mem.readInt(u32, h[base + 4 ..][0..4], .little);
    const n_pub = std.mem.readInt(u32, h[base + 8 ..][0..4], .little);
    // nPrvInputs u32, nLabels u64, then nConstraints.
    const n_constraints = std.mem.readInt(u32, h[base + 24 ..][0..4], .little);
    const n_public = n_out + n_pub;
    if (n_vars < n_public + 1) return error.BadConstraint;

    var terms: std.ArrayList(Sparse) = .empty;
    errdefer terms.deinit(alloc);
    var cons: std.ArrayList(Con) = .empty;
    errdefer cons.deinit(alloc);
    var coefs: std.ArrayList(CoefRec) = .empty;
    errdefer coefs.deinit(alloc);

    var cur = Cursor{ .data = file[s2.off .. s2.off + s2.size] };
    var ci: u32 = 0;
    while (ci < n_constraints) : (ci += 1) {
        const a_off: u32 = @intCast(terms.items.len);
            const nA = try cur.takeU32();
        var i: u32 = 0;
        while (i < nA) : (i += 1) {
            const s = try cur.takeU32();
            const coef = try cur.fq();
            if (s >= n_vars) return error.BadConstraint;
            try terms.append(alloc, .{ .signal = s, .coef = coef });
            try coefs.append(alloc, .{ .mat = 0, .ci = ci, .signal = s, .coef = coef });
        }
        const a_len: u32 = @as(u32, @intCast(terms.items.len)) - a_off;
        const b_off: u32 = @intCast(terms.items.len);
        const nB = try cur.takeU32();
        i = 0;
        while (i < nB) : (i += 1) {
            const s = try cur.takeU32();
            const coef = try cur.fq();
            if (s >= n_vars) return error.BadConstraint;
            try terms.append(alloc, .{ .signal = s, .coef = coef });
            try coefs.append(alloc, .{ .mat = 1, .ci = ci, .signal = s, .coef = coef });
        }
        const b_len: u32 = @as(u32, @intCast(terms.items.len)) - b_off;
        const c_off: u32 = @intCast(terms.items.len);
        const nC = try cur.takeU32();
        i = 0;
        while (i < nC) : (i += 1) {
            const s = try cur.takeU32();
            const coef = try cur.fq();
            if (s >= n_vars) return error.BadConstraint;
            try terms.append(alloc, .{ .signal = s, .coef = coef });
        }
        const c_len: u32 = @as(u32, @intCast(terms.items.len)) - c_off;
        try cons.append(alloc, .{
            .a_off = a_off,
            .a_len = a_len,
            .b_off = b_off,
            .b_len = b_len,
            .c_off = c_off,
            .c_len = c_len,
        });
    }
    var s: u32 = 0;
    while (s <= n_public) : (s += 1) {
        try coefs.append(alloc, .{
            .mat = 0,
            .ci = n_constraints + s,
            .signal = s,
            .coef = .{ 1, 0, 0, 0 },
        });
    }

    return .{
        .n_vars = n_vars,
        .n_public = n_public,
        .n_constraints = n_constraints,
        .cons = try cons.toOwnedSlice(alloc),
        .terms = try terms.toOwnedSlice(alloc),
        .coefs = try coefs.toOwnedSlice(alloc),
    };
}

const Cursor = struct {
    data: []const u8,
    i: usize = 0,

    fn takeU32(self: *Cursor) !u32 {
        if (self.i + 4 > self.data.len) return error.BadConstraint;
        const v = std.mem.readInt(u32, self.data[self.i..][0..4], .little);
        self.i += 4;
        return v;
    }

    fn fq(self: *Cursor) ![4]u64 {
        if (self.i + 32 > self.data.len) return error.BadConstraint;
        const v = ff.loadLimbs(self.data[self.i..][0..32]);
        self.i += 32;
        return v;
    }
};

const Acc = struct {
    a: []G1.Jac,
    b1: []G1.Jac,
    b2: []G2.Jac,
    c: []G1.Jac,
    ic: []G1.Jac,
};

fn allocAcc(alloc: std.mem.Allocator, n_vars: u32, n_public: u32) !Acc {
    const c_len = n_vars - n_public - 1;
    const acc = Acc{
        .a = try alloc.alloc(G1.Jac, n_vars),
        .b1 = try alloc.alloc(G1.Jac, n_vars),
        .b2 = try alloc.alloc(G2.Jac, n_vars),
        .c = try alloc.alloc(G1.Jac, c_len),
        .ic = try alloc.alloc(G1.Jac, n_public + 1),
    };
    @memset(acc.a, .{});
    @memset(acc.b1, .{});
    @memset(acc.b2, .{});
    @memset(acc.c, .{});
    @memset(acc.ic, .{});
    return acc;
}

fn freeAcc(alloc: std.mem.Allocator, acc: Acc) void {
    alloc.free(acc.a);
    alloc.free(acc.b1);
    alloc.free(acc.b2);
    alloc.free(acc.c);
    alloc.free(acc.ic);
}

const CoefKind = enum { zero, one, neg, hard };

fn coefKind(k: [4]u64) CoefKind {
    if ((k[0] | k[1] | k[2] | k[3]) == 0) return .zero;
    if (k[0] == 1 and k[1] == 0 and k[2] == 0 and k[3] == 0) return .one;
    if (std.mem.eql(u64, &k, &curve.FrMinusOne)) return .neg;
    return .hard;
}

const Hard = struct {
    dest: u8,
    signal: u32,
    ci: u32,
    src: u8,
    coef: [4]u64,
};

const G1Touch = struct { ci: u32, src: u8, neg: u8 };
const G2Touch = struct { ci: u32, neg: u8 };
const G2Hard = struct { ci: u32, coef: [4]u64 };

const Work = struct {
    hards: []Hard,
    a_off: []u32,
    a: []G1Touch,
    b1_off: []u32,
    b1: []G1Touch,
    c_off: []u32,
    c: []G1Touch,
    ic_off: []u32,
    ic: []G1Touch,
    g2_off: []u32,
    g2: []G2Touch,
    g2h_off: []u32,
    g2h: []G2Hard,
    ha_off: []u32,
    ha_idx: []u32,
    hb_off: []u32,
    hb_idx: []u32,
    hc_off: []u32,
    hc_idx: []u32,
    hi_off: []u32,
    hi_idx: []u32,

    fn deinit(self: *Work, alloc: std.mem.Allocator) void {
        alloc.free(self.hards);
        alloc.free(self.a_off);
        alloc.free(self.a);
        alloc.free(self.b1_off);
        alloc.free(self.b1);
        alloc.free(self.c_off);
        alloc.free(self.c);
        alloc.free(self.ic_off);
        alloc.free(self.ic);
        alloc.free(self.g2_off);
        alloc.free(self.g2);
        alloc.free(self.g2h_off);
        alloc.free(self.g2h);
        alloc.free(self.ha_off);
        alloc.free(self.ha_idx);
        alloc.free(self.hb_off);
        alloc.free(self.hb_idx);
        alloc.free(self.hc_off);
        alloc.free(self.hc_idx);
        alloc.free(self.hi_off);
        alloc.free(self.hi_idx);
    }
};

fn exclusiveScan(count: []const u32, offs: []u32) void {
    var sum: u32 = 0;
    for (count, 0..) |c, i| {
        offs[i] = sum;
        sum += c;
    }
    offs[count.len] = sum;
}

fn countBuf(alloc: std.mem.Allocator, n: u32) ![]u32 {
    const c = try alloc.alloc(u32, n);
    @memset(c, 0);
    return c;
}

fn buildWork(alloc: std.mem.Allocator, parsed: Parsed) !Work {
    const n_vars = parsed.n_vars;
    const n_pub = parsed.n_public;
    const c_len: u32 = n_vars - n_pub - 1;
    const a_count = try countBuf(alloc, n_vars);
    defer alloc.free(a_count);
    const b1_count = try countBuf(alloc, n_vars);
    defer alloc.free(b1_count);
    const c_count = try countBuf(alloc, c_len);
    defer alloc.free(c_count);
    const ic_count = try countBuf(alloc, n_pub + 1);
    defer alloc.free(ic_count);
    const g2_count = try countBuf(alloc, n_vars);
    defer alloc.free(g2_count);
    const g2h_count = try countBuf(alloc, n_vars);
    defer alloc.free(g2h_count);
    var n_hard: u32 = 0;

    for (parsed.cons) |con| {
        for (parsed.terms[con.a_off..][0..con.a_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => n_hard += 2,
                .one, .neg => {
                    a_count[t.signal] += 1;
                    if (t.signal <= n_pub) ic_count[t.signal] += 1 else c_count[t.signal - n_pub - 1] += 1;
                },
            }
        }
        for (parsed.terms[con.b_off..][0..con.b_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => {
                    g2h_count[t.signal] += 1;
                    n_hard += 2;
                },
                .one, .neg => {
                    g2_count[t.signal] += 1;
                    b1_count[t.signal] += 1;
                    if (t.signal <= n_pub) ic_count[t.signal] += 1 else c_count[t.signal - n_pub - 1] += 1;
                },
            }
        }
        for (parsed.terms[con.c_off..][0..con.c_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => n_hard += 1,
                .one, .neg => {
                    if (t.signal <= n_pub) ic_count[t.signal] += 1 else c_count[t.signal - n_pub - 1] += 1;
                },
            }
        }
    }
    var s: u32 = 0;
    while (s <= n_pub) : (s += 1) {
        a_count[s] += 1;
        ic_count[s] += 1;
    }

    const a_off = try alloc.alloc(u32, n_vars + 1);
    const b1_off = try alloc.alloc(u32, n_vars + 1);
    const c_off = try alloc.alloc(u32, c_len + 1);
    const ic_off = try alloc.alloc(u32, n_pub + 2);
    const g2_off = try alloc.alloc(u32, n_vars + 1);
    const g2h_off = try alloc.alloc(u32, n_vars + 1);
    exclusiveScan(a_count, a_off);
    exclusiveScan(b1_count, b1_off);
    exclusiveScan(c_count, c_off);
    exclusiveScan(ic_count, ic_off);
    exclusiveScan(g2_count, g2_off);
    exclusiveScan(g2h_count, g2h_off);
    const a = try alloc.alloc(G1Touch, a_off[n_vars]);
    const b1 = try alloc.alloc(G1Touch, b1_off[n_vars]);
    const c = try alloc.alloc(G1Touch, c_off[c_len]);
    const ic = try alloc.alloc(G1Touch, ic_off[n_pub + 1]);
    const g2 = try alloc.alloc(G2Touch, g2_off[n_vars]);
    const g2h = try alloc.alloc(G2Hard, g2h_off[n_vars]);
    const hards = try alloc.alloc(Hard, n_hard);

    @memcpy(a_count, a_off[0..n_vars]);
    @memcpy(b1_count, b1_off[0..n_vars]);
    @memcpy(c_count, c_off[0..c_len]);
    @memcpy(ic_count, ic_off[0 .. n_pub + 1]);
    @memcpy(g2_count, g2_off[0..n_vars]);
    @memcpy(g2h_count, g2h_off[0..n_vars]);

    var hard_i: u32 = 0;
    for (parsed.cons, 0..) |con, ci_usize| {
        const ci: u32 = @intCast(ci_usize);
        for (parsed.terms[con.a_off..][0..con.a_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => {
                    hards[hard_i] = .{ .dest = 0, .signal = t.signal, .ci = ci, .src = 0, .coef = t.coef };
                    hard_i += 1;
                    const dest: u8 = if (t.signal <= n_pub) 3 else 2;
                    hards[hard_i] = .{ .dest = dest, .signal = t.signal, .ci = ci, .src = 1, .coef = t.coef };
                    hard_i += 1;
                },
                .one, .neg => {
                    const neg: u8 = if (coefKind(t.coef) == .neg) 1 else 0;
                    pushG1(a, a_count, t.signal, .{ .ci = ci, .src = 0, .neg = neg });
                    if (t.signal <= n_pub) {
                        pushG1(ic, ic_count, t.signal, .{ .ci = ci, .src = 1, .neg = neg });
                    } else {
                        pushG1(c, c_count, t.signal - n_pub - 1, .{ .ci = ci, .src = 1, .neg = neg });
                    }
                },
            }
        }
        for (parsed.terms[con.b_off..][0..con.b_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => {
                    pushG2H(g2h, g2h_count, t.signal, .{ .ci = ci, .coef = t.coef });
                    hards[hard_i] = .{ .dest = 1, .signal = t.signal, .ci = ci, .src = 0, .coef = t.coef };
                    hard_i += 1;
                    const dest: u8 = if (t.signal <= n_pub) 3 else 2;
                    hards[hard_i] = .{ .dest = dest, .signal = t.signal, .ci = ci, .src = 2, .coef = t.coef };
                    hard_i += 1;
                },
                .one, .neg => {
                    const neg: u8 = if (coefKind(t.coef) == .neg) 1 else 0;
                    pushG2(g2, g2_count, t.signal, .{ .ci = ci, .neg = neg });
                    pushG1(b1, b1_count, t.signal, .{ .ci = ci, .src = 0, .neg = neg });
                    if (t.signal <= n_pub) {
                        pushG1(ic, ic_count, t.signal, .{ .ci = ci, .src = 2, .neg = neg });
                    } else {
                        pushG1(c, c_count, t.signal - n_pub - 1, .{ .ci = ci, .src = 2, .neg = neg });
                    }
                },
            }
        }
        for (parsed.terms[con.c_off..][0..con.c_len]) |t| {
            switch (coefKind(t.coef)) {
                .zero => {},
                .hard => {
                    const dest: u8 = if (t.signal <= n_pub) 3 else 2;
                    hards[hard_i] = .{ .dest = dest, .signal = t.signal, .ci = ci, .src = 0, .coef = t.coef };
                    hard_i += 1;
                },
                .one, .neg => {
                    const neg: u8 = if (coefKind(t.coef) == .neg) 1 else 0;
                    if (t.signal <= n_pub) {
                        pushG1(ic, ic_count, t.signal, .{ .ci = ci, .src = 0, .neg = neg });
                    } else {
                        pushG1(c, c_count, t.signal - n_pub - 1, .{ .ci = ci, .src = 0, .neg = neg });
                    }
                },
            }
        }
    }
    s = 0;
    while (s <= n_pub) : (s += 1) {
        const ci = parsed.n_constraints + s;
        pushG1(a, a_count, s, .{ .ci = ci, .src = 0, .neg = 0 });
        pushG1(ic, ic_count, s, .{ .ci = ci, .src = 1, .neg = 0 });
    }

    const ha = try groupHard(alloc, hards, 0, n_vars);
    const hb = try groupHard(alloc, hards, 1, n_vars);
    const hc = try groupHard(alloc, hards, 2, n_vars);
    const hi = try groupHard(alloc, hards, 3, n_vars);
    return .{
        .hards = hards,
        .a_off = a_off,
        .a = a,
        .b1_off = b1_off,
        .b1 = b1,
        .c_off = c_off,
        .c = c,
        .ic_off = ic_off,
        .ic = ic,
        .g2_off = g2_off,
        .g2 = g2,
        .g2h_off = g2h_off,
        .g2h = g2h,
        .ha_off = ha.off,
        .ha_idx = ha.idx,
        .hb_off = hb.off,
        .hb_idx = hb.idx,
        .hc_off = hc.off,
        .hc_idx = hc.idx,
        .hi_off = hi.off,
        .hi_idx = hi.idx,
    };
}

fn pushG1(items: []G1Touch, cursor: []u32, signal: u32, touch: G1Touch) void {
    const i = cursor[signal];
    items[i] = touch;
    cursor[signal] = i + 1;
}

fn pushG2(items: []G2Touch, cursor: []u32, signal: u32, touch: G2Touch) void {
    const i = cursor[signal];
    items[i] = touch;
    cursor[signal] = i + 1;
}

fn pushG2H(items: []G2Hard, cursor: []u32, signal: u32, touch: G2Hard) void {
    const i = cursor[signal];
    items[i] = touch;
    cursor[signal] = i + 1;
}

const HardGroup = struct { off: []u32, idx: []u32 };

fn groupHard(alloc: std.mem.Allocator, hards: []const Hard, dest: u8, n_vars: u32) !HardGroup {
    const count = try countBuf(alloc, n_vars);
    defer alloc.free(count);
    var n: usize = 0;
    for (hards) |h| {
        if (h.dest != dest) continue;
        count[h.signal] += 1;
        n += 1;
    }
    const off = try alloc.alloc(u32, n_vars + 1);
    exclusiveScan(count, off);
    const idx = try alloc.alloc(u32, n);
    @memcpy(count, off[0..n_vars]);
    for (hards, 0..) |h, i| {
        if (h.dest != dest) continue;
        const at = count[h.signal];
        idx[at] = @intCast(i);
        count[h.signal] = at + 1;
    }
    return .{ .off = off, .idx = idx };
}

fn packHards(alloc: std.mem.Allocator, hards: []const Hard, tau_g1: []const u8, alpha_tau: []const u8, beta_tau: []const u8) !struct { points: []u8, scalars: []u8 } {
    const points = try alloc.alloc(u8, hards.len * 64);
    errdefer alloc.free(points);
    const scalars = try alloc.alloc(u8, hards.len * 32);
    errdefer alloc.free(scalars);
    for (hards, 0..) |h, i| {
        const src = switch (h.src) {
            1 => beta_tau,
            2 => alpha_tau,
            else => tau_g1,
        };
        @memcpy(points[i * 64 ..][0..64], src[h.ci * 64 ..][0..64]);
        inline for (0..4) |limb| {
            std.mem.writeInt(u64, scalars[i * 32 + limb * 8 ..][0..8], h.coef[limb], .little);
        }
    }
    return .{ .points = points, .scalars = scalars };
}

const Fold = struct {
    s0: u32,
    s1: u32,
    n_public: u32,
    work: *const Work,
    acc: *Acc,
    tau_g1: []const u8,
    tau_g2: []const u8,
    alpha: []const u8,
    beta: []const u8,
    results: []const u8,
    g2_results: []const u8,
    apply_hard: bool,

    fn run(self: *Fold) void {
        var s = self.s0;
        while (s < self.s1) : (s += 1) {
            if (self.apply_hard) {
                addHardG1(&self.acc.a[s], self.work.ha_off, self.work.ha_idx, self.results, s);
                addHardG1(&self.acc.b1[s], self.work.hb_off, self.work.hb_idx, self.results, s);
                if (s <= self.n_public) {
                    addHardG1(&self.acc.ic[s], self.work.hi_off, self.work.hi_idx, self.results, s);
                } else {
                    addHardG1(&self.acc.c[s - self.n_public - 1], self.work.hc_off, self.work.hc_idx, self.results, s);
                }
                addHardG2(&self.acc.b2[s], self.work.g2h_off, self.g2_results, s);
            } else {
                self.foldG1(self.work.a_off, self.work.a, &self.acc.a[s], s);
                self.foldG1(self.work.b1_off, self.work.b1, &self.acc.b1[s], s);
                self.foldG2(s);
                if (s <= self.n_public) {
                    self.foldG1(self.work.ic_off, self.work.ic, &self.acc.ic[s], s);
                } else {
                    const ci = s - self.n_public - 1;
                    self.foldG1(self.work.c_off, self.work.c, &self.acc.c[ci], ci);
                }
            }
        }
    }

    fn foldG1(self: *Fold, off: []const u32, touches: []G1Touch, dst: *G1.Jac, signal: u32) void {
        const slice = touches[off[signal]..off[signal + 1]];
        if (slice.len == 0) return;
        if (slice.len > 1) std.mem.sortUnstable(G1Touch, slice, {}, lessG1);
        var jac: G1.Jac = .{};
        for (slice) |t| {
            const src = switch (t.src) {
                1 => self.beta,
                2 => self.alpha,
                else => self.tau_g1,
            };
            var p = curve.loadG1(src, t.ci);
            if (t.neg != 0) p = p.neg();
            jac.addAffine(p);
        }
        dst.* = jac;
    }

    fn foldG2(self: *Fold, signal: u32) void {
        const units = self.work.g2[self.work.g2_off[signal]..self.work.g2_off[signal + 1]];
        const hards = self.work.g2h[self.work.g2h_off[signal]..self.work.g2h_off[signal + 1]];
        if (units.len == 0 and hards.len == 0) return;
        if (units.len > 1) std.mem.sortUnstable(G2Touch, units, {}, lessG2);
        var jac: G2.Jac = .{};
        for (units) |t| {
            var p = curve.loadG2(self.tau_g2, t.ci);
            if (t.neg != 0) p = p.neg();
            jac.addAffine(p);
        }
        self.acc.b2[signal] = jac;
    }
};

fn addHardG1(dst: *G1.Jac, off: []const u32, idx: []const u32, results: []const u8, signal: u32) void {
    const hard = idx[off[signal]..off[signal + 1]];
    if (hard.len == 0) return;
    var jac = dst.*;
    for (hard) |i| jac.addAffine(curve.loadG1(results, i));
    dst.* = jac;
}

fn addHardG2(dst: *G2.Jac, off: []const u32, results: []const u8, signal: u32) void {
    const start = off[signal];
    const end = off[signal + 1];
    if (start == end or results.len == 0) return;
    var jac = dst.*;
    var i = start;
    while (i < end) : (i += 1) jac.addAffine(curve.loadG2(results, i));
    dst.* = jac;
}

fn lessG1(_: void, a: G1Touch, b: G1Touch) bool {
    return a.ci < b.ci;
}

fn lessG2(_: void, a: G2Touch, b: G2Touch) bool {
    return a.ci < b.ci;
}

fn accumulate(
    alloc: std.mem.Allocator,
    io: std.Io,
    parsed: Parsed,
    tau_g1: []const u8,
    tau_g2: []const u8,
    alpha_tau: []const u8,
    beta_tau: []const u8,
    nthreads: usize,
) !Acc {
    var phase = std.Io.Clock.Timestamp.now(io, .awake);
    var work = try buildWork(alloc, parsed);
    defer work.deinit(alloc);
    const index_ms = elapsedMs(io, &phase);
    const hards = work.hards;
    const hard_pack = try packHards(alloc, hards, tau_g1, alpha_tau, beta_tau);
    defer alloc.free(hard_pack.points);
    defer alloc.free(hard_pack.scalars);
    const pack_ms = elapsedMs(io, &phase);
    const results = try alloc.alloc(u8, hards.len * 64);
    defer alloc.free(results);
    // One G2 multiplication is about seven G1 multiplications. Counting them that
    // way keeps G1 on the GPU while the CPUs work through G2.
    const cpu_extra: usize = work.g2h.len * 7;
    const gpu_n: usize = if (hards.len == 0) 0 else try batch.choose(alloc, io, hard_pack.points, hard_pack.scalars, cpu_extra);
    const g2_pack = try packG2(alloc, work.g2h, tau_g2);
    defer alloc.free(g2_pack.points);
    defer alloc.free(g2_pack.scalars);
    const g2_n = work.g2h.len;
    var g2_gpu_n: usize = if (g2_n == 0) 0 else try batch.planG2(alloc, io, g2_pack.points, g2_pack.scalars, batch.g1GpuNs(gpu_n));
    const g2_results = try alloc.alloc(u8, g2_n * 128);
    defer alloc.free(g2_results);
    const g2_in = if (g2_gpu_n == 0) null else try batch.prepareG2(alloc, g2_pack.points[0 .. g2_gpu_n * 128], g2_pack.scalars[0 .. g2_gpu_n * 32]);
    if (g2_gpu_n > 0 and g2_in == null) g2_gpu_n = 0;
    defer if (g2_in) |in| in.deinit(alloc);
    const GpuArgs = struct {
        g1_points: []u8,
        g1_scalars: []u8,
        g1_out: []u8,
        g2_p1: []const u8,
        g2_p2: []const u8,
        g2_ks: []const u8,
        g2_out: []u8,
        g1_ok: bool = true,
        g2_ok: bool = true,
        fn run(self: *@This()) void {
            if (self.g1_points.len > 0) self.g1_ok = batch.gpuPart(self.g1_points, self.g1_scalars, self.g1_out);
            if (self.g2_p1.len > 0) self.g2_ok = batch.g2Part(self.g2_p1, self.g2_p2, self.g2_ks, self.g2_out);
        }
    };
    var gpu_args = GpuArgs{
        .g1_points = hard_pack.points[0 .. gpu_n * 64],
        .g1_scalars = hard_pack.scalars[0 .. gpu_n * 32],
        .g1_out = results[0 .. gpu_n * 64],
        .g2_p1 = if (g2_in) |in| in.p1 else &.{},
        .g2_p2 = if (g2_in) |in| in.p2 else &.{},
        .g2_ks = if (g2_in) |in| in.ks else &.{},
        .g2_out = g2_results[0 .. g2_gpu_n * 128],
    };
    const gpu_thread = if (gpu_n > 0 or g2_gpu_n > 0)
        try std.Thread.spawn(.{}, GpuArgs.run, .{&gpu_args})
    else
        null;

    var acc = try allocAcc(alloc, parsed.n_vars, parsed.n_public);
    const nt: usize = if (parsed.n_vars == 0) 1 else @min(@max(nthreads, 1), parsed.n_vars);
    const ranges = try signalRanges(alloc, &work, parsed.n_vars, parsed.n_public, nt);
    defer alloc.free(ranges);
    try runFolds(alloc, &work, &acc, ranges, tau_g1, tau_g2, alpha_tau, beta_tau, results, g2_results, false);
    const fold_ms = elapsedMs(io, &phase);
    if (g2_gpu_n < g2_n) {
        batch.g2Cpu(g2_pack.points[g2_gpu_n * 128 ..], g2_pack.scalars[g2_gpu_n * 32 ..], g2_results[g2_gpu_n * 128 ..]);
    }
    if (gpu_n < hards.len) {
        batch.cpuPart(hard_pack.points[gpu_n * 64 ..], hard_pack.scalars[gpu_n * 32 ..], results[gpu_n * 64 ..]);
    }
    const cpu_ms = elapsedMs(io, &phase);
    if (gpu_thread) |t| t.join();
    if (gpu_n > 0 and !gpu_args.g1_ok) {
        batch.cpuPart(hard_pack.points[0 .. gpu_n * 64], hard_pack.scalars[0 .. gpu_n * 32], results[0 .. gpu_n * 64]);
    }
    if (g2_gpu_n > 0 and !gpu_args.g2_ok) {
        batch.g2Cpu(g2_pack.points[0 .. g2_gpu_n * 128], g2_pack.scalars[0 .. g2_gpu_n * 32], g2_results[0 .. g2_gpu_n * 128]);
    }
    if (hards.len > 0 or g2_n > 0) {
        try runFolds(alloc, &work, &acc, ranges, tau_g1, tau_g2, alpha_tau, beta_tau, results, g2_results, true);
    }
    const apply_ms = elapsedMs(io, &phase);
    std.debug.print("index {d} ms, pack {d} ms, fold {d} ms, cpu scalars {d} ms, apply {d} ms\n", .{ index_ms, pack_ms, fold_ms, cpu_ms, apply_ms });
    return acc;
}

fn packG2(alloc: std.mem.Allocator, hards: []const G2Hard, tau_g2: []const u8) !struct { points: []u8, scalars: []u8 } {
    const points = try alloc.alloc(u8, hards.len * 128);
    errdefer alloc.free(points);
    const scalars = try alloc.alloc(u8, hards.len * 32);
    errdefer alloc.free(scalars);
    for (hards, 0..) |h, i| {
        @memcpy(points[i * 128 ..][0..128], tau_g2[h.ci * 128 ..][0..128]);
        inline for (0..4) |limb| {
            std.mem.writeInt(u64, scalars[i * 32 + limb * 8 ..][0..8], h.coef[limb], .little);
        }
    }
    return .{ .points = points, .scalars = scalars };
}

fn signalRanges(alloc: std.mem.Allocator, work: *const Work, n_vars: u32, n_public: u32, nt: usize) ![][2]u32 {
    const cost = try alloc.alloc(u64, n_vars + 1);
    defer alloc.free(cost);
    cost[0] = 0;
    var s: u32 = 0;
    while (s < n_vars) : (s += 1) {
        var c: u64 = span(work.a_off, s) + span(work.b1_off, s) + span(work.g2_off, s) * 3;
        c += span(work.ha_off, s) + span(work.hb_off, s);
        if (s <= n_public) {
            c += span(work.ic_off, s) + span(work.hi_off, s);
        } else {
            c += span(work.c_off, s - n_public - 1) + span(work.hc_off, s);
        }
        cost[s + 1] = cost[s] + c;
    }
    const ranges = try alloc.alloc([2]u32, nt);
    const total = cost[n_vars];
    var prev: u32 = 0;
    for (ranges, 0..) |*r, i| {
        const target = total * @as(u64, @intCast(i + 1)) / @as(u64, @intCast(nt));
        const cut: u32 = if (i + 1 == nt) n_vars else findCut(cost, target);
        r.* = .{ prev, cut };
        prev = cut;
    }
    return ranges;
}

fn span(off: []const u32, s: u32) u64 {
    return off[s + 1] - off[s];
}

fn findCut(cost: []const u64, target: u64) u32 {
    var lo: u32 = 0;
    var hi: u32 = @intCast(cost.len - 1);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cost[mid] < target) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn runFolds(
    alloc: std.mem.Allocator,
    work: *const Work,
    acc: *Acc,
    ranges: []const [2]u32,
    tau_g1: []const u8,
    tau_g2: []const u8,
    alpha: []const u8,
    beta: []const u8,
    results: []const u8,
    g2_results: []const u8,
    apply_hard: bool,
) !void {
    const jobs = try alloc.alloc(Fold, ranges.len);
    defer alloc.free(jobs);
    const threads = try alloc.alloc(std.Thread, ranges.len);
    defer alloc.free(threads);
    var nspawn: usize = 0;
    for (ranges, jobs) |range, *job| {
        if (range[0] == range[1]) continue;
        job.* = .{
            .s0 = range[0],
            .s1 = range[1],
            .n_public = @intCast(acc.ic.len - 1),
            .work = work,
            .acc = acc,
            .tau_g1 = tau_g1,
            .tau_g2 = tau_g2,
            .alpha = alpha,
            .beta = beta,
            .results = results,
            .g2_results = g2_results,
            .apply_hard = apply_hard,
        };
        if (std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, Fold.run, .{job})) |t| {
            threads[nspawn] = t;
            nspawn += 1;
        } else |_| job.run();
    }
    for (threads[0..nspawn]) |t| t.join();
}

const Points = struct {
    a: []u8,
    b1: []u8,
    b2: []u8,
    c: []u8,
    ic: []u8,

    fn deinit(self: Points, alloc: std.mem.Allocator) void {
        alloc.free(self.a);
        alloc.free(self.b1);
        alloc.free(self.b2);
        alloc.free(self.c);
        alloc.free(self.ic);
    }
};

fn serialize(alloc: std.mem.Allocator, acc: Acc) !Points {
    const ic = try alloc.alloc(u8, acc.ic.len * 64);
    errdefer alloc.free(ic);
    const a = try alloc.alloc(u8, acc.a.len * 64);
    errdefer alloc.free(a);
    const b1 = try alloc.alloc(u8, acc.b1.len * 64);
    errdefer alloc.free(b1);
    const b2 = try alloc.alloc(u8, acc.b2.len * 128);
    errdefer alloc.free(b2);
    const c = try alloc.alloc(u8, acc.c.len * 64);
    errdefer alloc.free(c);

    const nt = threadCount(0);
    try storeParallel(G1, alloc, acc.ic, ic, nt);
    try storeParallel(G1, alloc, acc.a, a, nt);
    try storeParallel(G1, alloc, acc.b1, b1, nt);
    try storeParallel(G2, alloc, acc.b2, b2, nt);
    try storeParallel(G1, alloc, acc.c, c, nt);
    return .{ .a = a, .b1 = b1, .b2 = b2, .c = c, .ic = ic };
}

fn storeParallel(comptime G: type, alloc: std.mem.Allocator, pts: []const G.Jac, dst: []u8, nthreads: usize) !void {
    const nt = @min(@max(nthreads, 1), @max(pts.len, 1));
    if (nt <= 1 or pts.len < 2048) {
        G.storeJacMany(pts, dst);
        return;
    }
    const StoreJob = struct {
        pts: []const G.Jac,
        dst: []u8,
        fn run(self: *@This()) void {
            G.storeJacMany(self.pts, self.dst);
        }
    };
    const jobs = try alloc.alloc(StoreJob, nt);
    defer alloc.free(jobs);
    const threads = try alloc.alloc(std.Thread, nt);
    defer alloc.free(threads);
    const chunk = (pts.len + nt - 1) / nt;
    for (jobs, 0..) |*job, i| {
        const start = @min(i * chunk, pts.len);
        const end = @min(start + chunk, pts.len);
        const plen = G.point_len;
        job.* = .{
            .pts = pts[start..end],
            .dst = dst[start * plen .. end * plen],
        };
        threads[i] = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, StoreJob.run, .{job});
    }
    for (threads) |t| t.join();
}

fn writePointSection(out: *Out, hasher: *Blake, id: u32, lem: []u8, point_len: usize) !void {
    hashU32(hasher, @intCast(lem.len / point_len));
    const at = try out.begin(id);
    try out.bytes(lem);
    try out.end(at);
    hashPoints(hasher, lem, point_len);
}

fn writeCoefs(out: *Out, coefs: []const CoefRec) !void {
    try out.u32le(@intCast(coefs.len));
    const r2m = Fr.fromStd(Fr.r2_std);
    var buf: [44]u8 = undefined;
    for (coefs) |c| {
        std.mem.writeInt(u32, buf[0..4], c.mat, .little);
        std.mem.writeInt(u32, buf[4..8], c.ci, .little);
        std.mem.writeInt(u32, buf[8..12], c.signal, .little);
        const w = Fr.fromStd(c.coef).mul(r2m);
        w.storeStd(buf[12..44]);
        try out.bytes(&buf);
    }
}

fn hashH(hasher: *Blake, alloc: std.mem.Allocator, io: std.Io, file: std.Io.File, sec2: Sec, domain: usize) !void {
    hashU32(hasher, @intCast(domain - 1));
    const chunk: usize = 1 << 14;
    const limit = domain - 1;
    var i: usize = 0;
    while (i < limit) : (i += chunk) {
        // Same chunking as snarkjs `hashHPoints`: the count does not shrink on the last chunk.
        const n: usize = @min(limit, chunk);
        const nbytes: usize = n * 64;
        // snarkjs reads this chunk even when it runs past section 2 into the next
        // section header. A power-20 domain against a power-20 ceremony does that
        // on the last chunk.
        const b1_at = sec2.off + (@as(u64, domain) + i) * 64;
        const file_len = try file.length(io);
        if (b1_at + nbytes > file_len) return error.PtauTooSmall;
        const b1 = try readAlloc(alloc, io, file, b1_at, nbytes);
        defer alloc.free(b1);
        const b2 = try readAlloc(alloc, io, file, sec2.off + @as(u64, i) * 64, nbytes);
        defer alloc.free(b2);
        const jacs = try alloc.alloc(G1.Jac, n);
        defer alloc.free(jacs);
        for (0..n) |j| {
            jacs[j] = G1.Jac.fromAffine(curve.loadG1(b1, j));
            jacs[j].addAffine(curve.loadG1(b2, j).neg());
        }
        const lem = try alloc.alloc(u8, n * 64);
        defer alloc.free(lem);
        G1.storeJacMany(jacs, lem);
        hashPoints(hasher, lem, 64);
    }
}

fn hashU32(hasher: *Blake, n: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .big);
    hasher.update(&b);
}

fn hashPoints(hasher: *Blake, lem: []const u8, point_len: usize) void {
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < lem.len) : (i += point_len) {
        var o: usize = 0;
        while (o < point_len) : (o += 32) {
            const f = Fq{ .limbs = ff.loadLimbs(lem[i + o ..][0..32]) };
            // snarkjs hashes uncompressed coordinates as big-endian integers.
            storeStdBe(f.toStd(), buf[o..][0..32]);
        }
        // G2's base field is 64 bytes. snarkjs reverses each Fq2 element, which swaps c0 and c1.
        if (point_len == 128) {
            var k: usize = 0;
            while (k < point_len) : (k += 64) {
                var tmp: [32]u8 = undefined;
                @memcpy(&tmp, buf[k..][0..32]);
                @memcpy(buf[k..][0..32], buf[k + 32 ..][0..32]);
                @memcpy(buf[k + 32 ..][0..32], &tmp);
            }
        }
        hasher.update(buf[0..point_len]);
    }
}

fn storeStdBe(limbs: [4]u64, dst: []u8) void {
    inline for (0..4) |i| {
        std.mem.writeInt(u64, dst[(3 - i) * 8 ..][0..8], limbs[i], .big);
    }
}

fn printHash(digest: *const [64]u8) void {
    std.debug.print("Circuit hash:\n", .{});
    var i: usize = 0;
    while (i < 64) : (i += 4) {
        if (i % 16 == 0) std.debug.print("\t\t", .{});
        std.debug.print("{x:0>2}{x:0>2}{x:0>2}{x:0>2} ", .{ digest[i], digest[i + 1], digest[i + 2], digest[i + 3] });
        if (i % 16 == 12) std.debug.print("\n", .{});
    }
}

fn g1Gen() [64]u8 {
    var o: [64]u8 = undefined;
    curve.g1Generator().store(&o);
    return o;
}

fn g2Gen() [128]u8 {
    var o: [128]u8 = undefined;
    curve.g2Generator().store(&o);
    return o;
}

fn storeLimbs(limbs: [4]u64, dst: []u8) void {
    inline for (0..4) |i| {
        std.mem.writeInt(u64, dst[i * 8 ..][0..8], limbs[i], .little);
    }
}

fn readH(alloc: std.mem.Allocator, io: std.Io, file: std.Io.File, sec12: Sec, domain: u32, cir_power: u8) ![]u8 {
    if (cir_power == 28) {
        const point_off = (@as(u64, 1) << 29) - 1 + @as(u64, domain);
        if (point_off * 64 + @as(u64, domain) * 64 > sec12.size) return error.PtauTooSmall;
        return readAlloc(alloc, io, file, sec12.off + point_off * 64, @as(usize, domain) * 64);
    }
    const doubled: usize = @as(usize, domain) * 2;
    const bytes = try readDomain(alloc, io, file, sec12, @intCast(doubled), 64);
    defer alloc.free(bytes);
    const h = try alloc.alloc(u8, @as(usize, domain) * 64);
    var i: usize = 0;
    while (i < domain) : (i += 1) {
        @memcpy(h[i * 64 ..][0..64], bytes[(2 * i + 1) * 64 ..][0..64]);
    }
    return h;
}

fn readDomain(alloc: std.mem.Allocator, io: std.Io, file: std.Io.File, sec: Sec, domain: u32, point: usize) ![]u8 {
    const off = (@as(u64, domain) - 1) * point;
    const len = @as(u64, domain) * point;
    if (off + len > sec.size) return error.PtauTooSmall;
    return readAlloc(alloc, io, file, sec.off + off, @intCast(len));
}

fn readPtauPower(io: std.Io, file: std.Io.File, secs: [32]?Sec) !u32 {
    const s1 = secs[1] orelse return error.NotPtau;
    var hdr: [40]u8 = undefined;
    if (s1.size < 40) return error.NotPtau;
    try readExact(io, file, s1.off, &hdr);
    const n8 = std.mem.readInt(u32, hdr[0..4], .little);
    if (n8 != 32) return error.NotBn254;
    const q = ff.loadLimbs(hdr[4..36]);
    if (!std.mem.eql(u64, &q, &Fq.mod_limbs)) return error.NotBn254;
    return std.mem.readInt(u32, hdr[36..40], .little);
}

fn elapsedMs(io: std.Io, start: *std.Io.Clock.Timestamp) u64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const ns = start.durationTo(now).raw.nanoseconds;
    start.* = now;
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn threadCount(n_constraints: u32) usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    var n = cpu;
    if (std.c.getenv("ZKEY_THREADS")) |raw| {
        n = std.fmt.parseInt(usize, std.mem.span(raw), 10) catch cpu;
    }
    if (n == 0) n = 1;
    if (n_constraints > 0) n = @min(n, n_constraints);
    return n;
}

fn scan(io: std.Io, file: std.Io.File, magic: *const [4]u8) ![32]?Sec {
    var hdr: [12]u8 = undefined;
    try readExact(io, file, 0, &hdr);
    if (!std.mem.eql(u8, hdr[0..4], magic)) return error.BadMagic;
    const nsec = std.mem.readInt(u32, hdr[8..12], .little);
    var secs: [32]?Sec = @splat(null);
    var pos: u64 = 12;
    var i: u32 = 0;
    while (i < nsec) : (i += 1) {
        var sh: [12]u8 = undefined;
        try readExact(io, file, pos, &sh);
        const id = std.mem.readInt(u32, sh[0..4], .little);
        const size = std.mem.readInt(u64, sh[4..12], .little);
        const off = pos + 12;
        if (id < secs.len and secs[id] == null) secs[id] = .{ .off = off, .size = size };
        pos = off + size;
    }
    return secs;
}

fn scanBytes(file: []const u8, magic: *const [4]u8) ![32]?Sec {
    if (file.len < 12 or !std.mem.eql(u8, file[0..4], magic)) return error.BadMagic;
    const nsec = std.mem.readInt(u32, file[8..12], .little);
    var secs: [32]?Sec = @splat(null);
    var pos: usize = 12;
    var i: u32 = 0;
    while (i < nsec) : (i += 1) {
        if (pos + 12 > file.len) return error.UnexpectedEof;
        const id = std.mem.readInt(u32, file[pos..][0..4], .little);
        const size = std.mem.readInt(u64, file[pos + 4 ..][0..8], .little);
        const off = pos + 12;
        if (off + size > file.len) return error.UnexpectedEof;
        if (id < secs.len and secs[id] == null) secs[id] = .{ .off = off, .size = size };
        pos = off + @as(usize, @intCast(size));
    }
    return secs;
}

fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try openFile(io, path);
    defer f.close(io);
    const size = try f.length(io);
    const buf = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(buf);
    try readExact(io, f, 0, buf);
    return buf;
}

fn readAlloc(alloc: std.mem.Allocator, io: std.Io, file: std.Io.File, off: u64, len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);
    try readExact(io, file, off, buf);
    return buf;
}

fn readExact(io: std.Io, file: std.Io.File, off: u64, buf: []u8) !void {
    const n = try file.readPositionalAll(io, buf, off);
    if (n != buf.len) return error.UnexpectedEof;
}

fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
}

const Out = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn init(alloc: std.mem.Allocator) Out {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *Out) void {
        self.list.deinit(self.alloc);
    }

    fn toOwned(self: *Out) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }

    fn bytes(self: *Out, data: []const u8) !void {
        try self.list.appendSlice(self.alloc, data);
    }

    fn u32le(self: *Out, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.bytes(&b);
    }

    fn u64le(self: *Out, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try self.bytes(&b);
    }

    fn begin(self: *Out, id: u32) !u64 {
        try self.u32le(id);
        const at: u64 = @intCast(self.list.items.len);
        try self.u64le(0);
        return at;
    }

    fn end(self: *Out, at: u64) !void {
        const pos: usize = @intCast(at);
        const size = self.list.items.len - pos - 8;
        std.mem.writeInt(u64, self.list.items[pos..][0..8], @intCast(size), .little);
    }
};
