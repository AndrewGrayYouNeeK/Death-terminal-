//! Minimal Objective-C runtime bridge for the Cocoa backend.
//!
//! Everything is resolved at run time with dlopen/dlsym (libobjc plus the
//! AppKit, QuartzCore, CoreGraphics and CoreFoundation frameworks), so the
//! binary cross-compiles without a macOS SDK. Messages are sent through
//! `objc_msgSend` cast to the exact C prototype of each call.

const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Class = ?*anyopaque;

/// Objective-C BOOL: `bool` on arm64, `signed char` on x86_64.
pub const BOOL = if (builtin.cpu.arch == .aarch64) bool else i8;
pub const YES: BOOL = if (BOOL == bool) true else 1;
pub const NO: BOOL = if (BOOL == bool) false else 0;

pub fn isTrue(b: BOOL) bool {
    return if (BOOL == bool) b else b != 0;
}

pub const CGFloat = f64;
pub const NSPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const NSSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const NSRect = extern struct { origin: NSPoint = .{}, size: NSSize = .{} };

const Lib = struct {
    handle: ?*anyopaque = null,
    fn sym(self: Lib, comptime T: type, name: [:0]const u8) ?T {
        const h = self.handle orelse return null;
        const p = std.c.dlsym(h, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }
};

const RTLD_NOW = 2;
const RTLD_GLOBAL = if (builtin.os.tag == .macos) 8 else 0x100;

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;

pub const Runtime = struct {
    objc: Lib = .{},
    appkit: Lib = .{},
    quartz: Lib = .{},
    cg: Lib = .{},
    cf: Lib = .{},

    getClass: *const fn ([*:0]const u8) callconv(.C) Class = undefined,
    registerName: *const fn ([*:0]const u8) callconv(.C) Sel = undefined,
    msgSend: *const anyopaque = undefined,
    msgSend_stret: ?*const anyopaque = null,
    msgSend_fpret: ?*const anyopaque = null,
    poolPush: *const fn () callconv(.C) ?*anyopaque = undefined,
    poolPop: *const fn (?*anyopaque) callconv(.C) void = undefined,
};

pub var rt: Runtime = .{};
var loaded = false;

pub fn load() !void {
    if (loaded) return;
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    rt.objc.handle = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW | RTLD_GLOBAL) orelse return error.NoObjcRuntime;
    // Foundation comes in with AppKit.
    rt.appkit.handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW | RTLD_GLOBAL) orelse return error.NoAppKit;
    rt.quartz.handle = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW | RTLD_GLOBAL) orelse return error.NoQuartzCore;
    rt.cg.handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_GLOBAL);
    rt.cf.handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_GLOBAL);
    rt.getClass = rt.objc.sym(@TypeOf(rt.getClass), "objc_getClass") orelse return error.NoObjcRuntime;
    rt.registerName = rt.objc.sym(@TypeOf(rt.registerName), "sel_registerName") orelse return error.NoObjcRuntime;
    rt.msgSend = rt.objc.sym(*const anyopaque, "objc_msgSend") orelse return error.NoObjcRuntime;
    if (builtin.cpu.arch == .x86_64) {
        rt.msgSend_stret = rt.objc.sym(*const anyopaque, "objc_msgSend_stret");
        rt.msgSend_fpret = rt.objc.sym(*const anyopaque, "objc_msgSend_fpret");
    }
    rt.poolPush = rt.objc.sym(@TypeOf(rt.poolPush), "objc_autoreleasePoolPush") orelse return error.NoObjcRuntime;
    rt.poolPop = rt.objc.sym(@TypeOf(rt.poolPop), "objc_autoreleasePoolPop") orelse return error.NoObjcRuntime;
    loaded = true;
}

pub fn class(name: [:0]const u8) Id {
    return rt.getClass(name.ptr);
}

pub fn sel(name: [:0]const u8) Sel {
    return rt.registerName(name.ptr);
}

/// Global `NSString *const` exported by a framework (e.g.
/// NSDefaultRunLoopMode, NSPasteboardTypeString).
pub fn constant(name: [:0]const u8) Id {
    const p = rt.appkit.sym(*const Id, name) orelse return null;
    return p.*;
}

/// Look up a C function in one of the loaded frameworks.
pub fn cfn(comptime T: type, name: [:0]const u8) ?T {
    inline for (.{ rt.cg, rt.cf, rt.quartz, rt.appkit }) |lib| {
        if (lib.sym(T, name)) |f| return f;
    }
    return null;
}

/// True when the x86_64 ABI returns R in memory (objc_msgSend_stret).
fn usesStret(comptime R: type) bool {
    if (builtin.cpu.arch != .x86_64) return false;
    return switch (@typeInfo(R)) {
        .Struct => @sizeOf(R) > 16,
        else => false,
    };
}

fn requireConcreteArgs(comptime Args: type) void {
    const info = @typeInfo(Args);
    if (info != .Struct) @compileError("objc msg arguments must be a tuple");
    inline for (info.Struct.fields) |f| {
        if (f.type == comptime_int or f.type == comptime_float) {
            @compileError("objc msg argument has type " ++ @typeName(f.type) ++ "; cast it to a concrete integer or float. A comptime number is not passed in a register, so every later argument moves into the wrong arm64 register");
        }
    }
}

fn FnType(comptime R: type, comptime Args: type) type {
    const fields = @typeInfo(Args).Struct.fields;
    var params: [fields.len + 2]std.builtin.Type.Fn.Param = undefined;
    params[0] = .{ .is_generic = false, .is_noalias = false, .type = Id };
    params[1] = .{ .is_generic = false, .is_noalias = false, .type = Sel };
    for (fields, 0..) |f, i| params[i + 2] = .{ .is_generic = false, .is_noalias = false, .type = f.type };
    return *const @Type(.{ .Fn = .{
        .calling_convention = .C,
        .is_generic = false,
        .is_var_args = false,
        .return_type = R,
        .params = &params,
    } });
}

/// `[target name args...]` returning R.
///
/// Every argument must be a runtime type. A `comptime_int` / `comptime_float`
/// parameter is erased from the C ABI (it is a compile-time value, not a
/// register), so the arguments after it slide left. On arm64 that is fatal:
/// `nextEventMatchingMask:untilDate:inMode:dequeue:` then sees the BOOL `YES`
/// (the integer 1) in the `inMode:` NSString slot and dereferences 0x1.
pub fn msg(comptime R: type, target: Id, name: [:0]const u8, args: anytype) R {
    const Args = @TypeOf(args);
    comptime requireConcreteArgs(Args);
    const F = FnType(R, Args);
    const raw = if (usesStret(R)) rt.msgSend_stret.? else if (builtin.cpu.arch == .x86_64 and (R == f64 or R == f32)) rt.msgSend_fpret orelse rt.msgSend else rt.msgSend;
    const f: F = @ptrCast(@alignCast(raw));
    return @call(.auto, f, .{ target, sel(name) } ++ args);
}

/// `[[cls alloc] init]`-style helpers.
pub fn alloc(cls: [:0]const u8) Id {
    return msg(Id, class(cls), "alloc", .{});
}

/// Autoreleased NSString from UTF-8 bytes.
pub fn nsString(bytes: []const u8) Id {
    const s = msg(Id, alloc("NSString"), "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, bytes.ptr), @as(usize, bytes.len), @as(usize, 4) });
    return msg(Id, s, "autorelease", .{});
}

/// UTF-8 view of an NSString (valid while the string / pool lives).
pub fn utf8(s: Id) []const u8 {
    if (s == null) return "";
    const p = msg(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

pub fn release(obj: Id) void {
    if (obj != null) msg(void, obj, "release", .{});
}

test "objc: function type construction" {
    const F = FnType(void, struct { u64, NSRect });
    const info = @typeInfo(@typeInfo(F).Pointer.child).Fn;
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    try std.testing.expect(!usesStret(NSPoint));
}

test "objc: comptime_int is not an arm64 argument slot" {
    // `std.math.maxInt` is a comptime_int. Used raw as the NSEventMask, it
    // is omitted from the objc_msgSend call and the BOOL (1) lands in x4,
    // which AppKit reads as the run-loop mode and dereferences.
    const until: Id = null;
    const mode: Id = null;
    const bad = @typeInfo(@TypeOf(.{ std.math.maxInt(u64), until, mode, YES })).Struct.fields;
    try std.testing.expect(bad[0].type == comptime_int);
    try std.testing.expect(bad[0].is_comptime);

    const good = @typeInfo(@TypeOf(.{ @as(u64, std.math.maxInt(u64)), until, mode, YES })).Struct.fields;
    try std.testing.expect(good[0].type == u64);
    try std.testing.expect(good[1].type == Id);
    try std.testing.expect(good[2].type == Id);
    try std.testing.expect(good[3].type == BOOL);

    const F = FnType(Id, @TypeOf(.{ @as(u64, std.math.maxInt(u64)), until, mode, YES }));
    const params = @typeInfo(@typeInfo(F).Pointer.child).Fn.params;
    // self, _cmd, mask, untilDate, mode, dequeue
    try std.testing.expectEqual(@as(usize, 6), params.len);
    try std.testing.expect(params[2].type.? == u64);
    try std.testing.expect(params[3].type.? == Id);
    try std.testing.expect(params[4].type.? == Id);
    try std.testing.expect(params[5].type.? == BOOL);
}
