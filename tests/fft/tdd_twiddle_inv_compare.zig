const std = @import("std");
const cpu = @import("cpu");
const field = cpu.field;
const fft = cpu.fft;

pub fn main() !void {
    const n: u32 = 1024;
    const omega = fft.getOmegaN(n);
    const omega_inv = field.fr_inv(omega);
    
    // Compute via recurrence
    var rec = try std.heap.c_allocator.alloc(field.FrElement, n / 2);
    defer std.heap.c_allocator.free(rec);
    rec[0] = field.fr_one();
    for (1..n / 2) |i| {
        rec[i] = field.fr_mul(rec[i - 1], omega_inv);
    }
    
    // Compute via fr_inv(getTwiddle)
    var direct = try std.heap.c_allocator.alloc(field.FrElement, n / 2);
    defer std.heap.c_allocator.free(direct);
    for (0..n / 2) |i| {
        direct[i] = fft.getTwiddleInv(n, @intCast(i));
    }
    
    var mismatches: usize = 0;
    for (0..n / 2) |i| {
        if (!field.fr_eq(rec[i], direct[i])) {
            if (mismatches < 5) {
                std.debug.print("Mismatch at {d}: rec={x} direct={x}\n", .{i, rec[i][0], direct[i][0]});
            }
            mismatches += 1;
        }
    }
    std.debug.print("Total mismatches: {d}/{d}\n", .{mismatches, n / 2});
}
