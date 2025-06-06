// Copyright 2021 Antoine Vugliano

const std = @import("std");
const Type = std.builtin.Type;
const assert = std.debug.assert;
const time = std.time;
const print = std.debug.print;

const Timer = time.Timer;

const BenchFn = fn (*Context) void;

pub const Context = struct {
    timer: Timer,
    iter: u32,
    count: u32,
    state: State,
    nanoseconds: u64,

    const HeatingTime = time.ns_per_s / 2;
    const RunTime = time.ns_per_s / 2;

    const State = enum {
        None,
        Heating,
        Running,
        Finished,
    };

    pub fn init() Context {
        return Context{ .timer = Timer.start() catch unreachable, .iter = 0, .count = 0, .state = .None, .nanoseconds = 0 };
    }

    pub fn run(self: *Context) bool {
        switch (self.state) {
            .None => {
                self.state = .Heating;
                self.timer.reset();
                return true;
            },
            .Heating => {
                self.count += 1;
                const elapsed = self.timer.read();
                if (elapsed >= HeatingTime) {
                    // Caches should be hot
                    self.count = @intCast(RunTime / (HeatingTime / self.count));
                    self.state = .Running;
                    self.timer.reset();
                }

                return true;
            },
            .Running => {
                if (self.iter < self.count) {
                    self.iter += 1;
                    return true;
                } else {
                    self.nanoseconds = self.timer.read();
                    self.state = .Finished;
                    return false;
                }
            },
            .Finished => unreachable,
        }
    }

    pub fn startTimer(self: *Context) void {
        self.timer.reset();
    }

    pub fn stopTimer(self: *Context) void {
        const elapsed = self.timer.read();
        self.nanoseconds += elapsed;
    }

    pub fn runExplicitTiming(self: *Context) bool {
        switch (self.state) {
            .None => {
                self.state = .Heating;
                return true;
            },
            .Heating => {
                self.count += 1;
                if (self.nanoseconds >= HeatingTime) {
                    // Caches should be hot
                    self.count = @intCast(RunTime / (HeatingTime / self.count));
                    self.nanoseconds = 0;
                    self.state = .Running;
                }

                return true;
            },
            .Running => {
                if (self.iter < self.count) {
                    self.iter += 1;
                    return true;
                } else {
                    self.state = .Finished;
                    return false;
                }
            },
            .Finished => unreachable,
        }
    }

    pub fn averageTime(self: *Context, unit: u64) f32 {
        assert(self.state == .Finished);
        return @as(f32, @floatFromInt(self.nanoseconds / unit)) / @as(f32, @floatFromInt(self.iter));
    }
};

pub fn benchmark(name: []const u8, comptime f: BenchFn) void {
    var ctx = Context.init();
    @call(.never_inline, f, .{&ctx});
    // @noInlineCall(f, &ctx);

    var unit: u64 = undefined;
    var unit_name: []const u8 = undefined;
    const avg_time = ctx.averageTime(1);
    assert(avg_time >= 0);

    if (avg_time <= time.us_per_s) {
        unit = 1;
        unit_name = "ns";
    } else if (avg_time <= time.ms_per_s) {
        unit = time.us_per_s;
        unit_name = "us";
    } else {
        unit = time.ms_per_s;
        unit_name = "ms";
    }

    print("{s}: avg {d:.3}{s} ({d} iterations)\n", .{ name, ctx.averageTime(unit), unit_name, ctx.iter });
}

fn benchArgFn(comptime argType: type) type {
    return fn (*Context, argType) void;
}

fn argTypeFromFn(comptime f: anytype) type {
    const F = @TypeOf(f);
    if (@typeInfo(F) != .@"fn") {
        @compileError("Argument must be a function.");
    }

    const fnInfo = @typeInfo(F).@"fn";
    if (fnInfo.params.len != 2) {
        @compileError("Only functions taking 1 argument are accepted.");
    }

    return fnInfo.params[1].type.?;
}

fn benchmarkArg(comptime name: []const u8, comptime f: anytype, arg: argTypeFromFn(f)) void {
    var ctx = Context.init();
    @call(.never_inline, f, .{ &ctx, arg });

    var unit: u64 = undefined;
    var unit_name: []const u8 = undefined;
    const avg_time = ctx.averageTime(1);
    assert(avg_time >= 0);

    if (avg_time <= time.ns_per_us) {
        unit = 1;
        unit_name = "ns";
    } else if (avg_time <= time.ns_per_ms) {
        unit = time.ns_per_us;
        unit_name = "us";
    } else {
        unit = time.ns_per_ms;
        unit_name = "ms";
    }

    const typeOfArg = @TypeOf(arg);
    // TODO: improve text report, this is workaround to avoid printing entire slices to bench log
    if (typeOfArg == type or @typeInfo(typeOfArg) == .pointer) {
        print("{s} <{s}>: avg {d:.3}{s} ({d} iterations)\n", .{
            name,
            @typeName(typeOfArg),
            ctx.averageTime(unit),
            unit_name,
            ctx.iter,
        });
    } else {
        print("{s} <{any}>: avg {d:.3}{s} ({d} iterations)\n", .{
            name,
            arg,
            ctx.averageTime(unit),
            unit_name,
            ctx.iter,
        });
    }
}

pub fn benchmarkArgs(comptime name: []const u8, comptime f: anytype, args: []const argTypeFromFn(f)) void {
    // This check is needed so that args can also accept runtime-known values.
    if (argTypeFromFn(f) == type) {
        inline for (args) |arg| {
            benchmarkArg(name, f, arg);
        }
        return;
    }
    for (args) |arg| {
        benchmarkArg(name, f, arg);
    }
}
pub fn doNotOptimize(value: anytype) void {
    // LLVM triggers an assert if we pass non-trivial types as inputs for the
    // asm volatile expression.
    // Workaround until asm support is better on Zig's end.
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool, .int, .float => {
            asm volatile (""
                :
                : [_] "r,m" (value),
                : "memory"
            );
        },
        .optional => {
            if (value) |v| doNotOptimize(v);
        },
        .@"struct" => {
            inline for (comptime std.meta.fields(T)) |field| {
                doNotOptimize(@field(value, field.name));
            }
        },
        .type,
        .void,
        .noreturn,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .@"fn",
        => @compileError("doNotOptimize makes no sense for " ++ @tagName(T)),
        else => @compileError("doNotOptimize is not implemented for " ++ @tagName(T)),
    }
}

pub fn clobberMemory() void {
    asm volatile ("" ::: "memory");
}

test "benchmark" {
    const benchSleep57 = struct {
        fn benchSleep57(ctx: *Context) void {
            while (ctx.run()) {
                time.sleep(57 * time.ms_per_s);
            }
        }
    }.benchSleep57;

    benchmark("Sleep57", benchSleep57);
}

test "benchmarkArgs" {
    const benchSleep = struct {
        fn benchSleep(ctx: *Context, ms: u32) void {
            while (ctx.run()) {
                time.sleep(ms * time.ms_per_s);
            }
        }
    }.benchSleep;

    benchmarkArgs("Sleep", benchSleep, &[_]u32{ 20, 30, 57 });
}
test "benchmarkArgs runtime args" {
    const allocator = std.testing.allocator;
    var timestamps = try allocator.alloc(i64, 100);
    defer allocator.free(timestamps);
    @memset(timestamps, std.time.milliTimestamp());

    const benchRuntimeArgs = struct {
        fn benchRuntimeArgs(ctx: *Context, stamps: []i64) void {
            while (ctx.run()) {
                var sum: i64 = 0;
                for (stamps) |val| {
                    sum += val;
                }
                doNotOptimize(sum);
            }
        }
    }.benchRuntimeArgs;

    benchmarkArgs("runtime args", benchRuntimeArgs, &[_][]i64{ timestamps[0..20], timestamps[20..100] });
}

test "benchmarkArgs types" {
    const benchMin = struct {
        fn benchMin(ctx: *Context, comptime intType: type) void {
            _ = intType;
            while (ctx.run()) {
                time.sleep(@min(37, 48) * time.ms_per_s);
            }
        }
    }.benchMin;
    benchmarkArgs("Min", benchMin, &[_]type{ u32, u64 });
}

test "benchmark custom timing" {
    const sleep = struct {
        fn sleep(ctx: *Context) void {
            while (ctx.runExplicitTiming()) {
                time.sleep(30 * time.ms_per_s);
                ctx.startTimer();
                defer ctx.stopTimer();
                time.sleep(10 * time.ms_per_s);
            }
        }
    }.sleep;

    benchmark("sleep", sleep);
}
