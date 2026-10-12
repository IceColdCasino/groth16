const mod = @import("mod.zig");
const cpu = @import("cpu");

pub const VulkanProver = struct {
    pub fn init(allocator: @import("std").mem.Allocator) error{VulkanNotFound}!*VulkanProver {
        _ = allocator;
        return error.VulkanNotFound;
    }

    pub fn deinit(self: *VulkanProver) void {
        _ = self;
    }
};

pub fn accumulateG1(windows: []const mod.G1Point) cpu.curve.G1Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g1_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g1_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G1Point{
            .x = mod_pt.x,
            .y = mod_pt.y,
            .zz = mod_pt.zz,
            .zzz = mod_pt.zzz,
        };
        result = cpu.curve.g1_add(result, win_point);
    }
    return result;
}

pub fn accumulateG2(windows: []const mod.G2Point) cpu.curve.G2Point {
    const num_windows = windows.len;
    const window_size: usize = 8;
    var result = cpu.curve.g2_zero();
    for (0..num_windows) |i| {
        const win_idx = num_windows - 1 - i;
        for (0..window_size) |_| {
            result = cpu.curve.g2_dbl(result);
        }
        const mod_pt = windows[win_idx];
        const win_point = cpu.curve.G2Point{
            .x = .{ .a = mod_pt.x[0..4].*, .b = mod_pt.x[4..8].* },
            .y = .{ .a = mod_pt.y[0..4].*, .b = mod_pt.y[4..8].* },
            .zz = .{ .a = mod_pt.zz[0..4].*, .b = mod_pt.zz[4..8].* },
            .zzz = .{ .a = mod_pt.zzz[0..4].*, .b = mod_pt.zzz[4..8].* },
        };
        result = cpu.curve.g2_add(result, win_point);
    }
    return result;
}
