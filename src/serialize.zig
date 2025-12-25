pub const SerializationError = Writer.Error;
pub const DeserializationError = Reader.Error || error{Corrupt};
pub const DeserializationAllocError = DeserializationError || Allocator.Error;

pub const endian: std.builtin.Endian = .little;

fn cannotBeSerialized(comptime T: type) void {
    @compileError(@typeName(T) ++ " cannot be serialized");
}

fn requiresAllocation(comptime T: type) void {
    @compileError(@typeName(T) ++ " requires allocation");
}

pub fn serializeAny(comptime T: type, w: *Writer, value: T) SerializationError!void {
    try switch (@typeInfo(T)) {
        .@"enum" => serializeEnum(T, w, value),
        .@"struct" => serializeStruct(T, w, value),
        .@"union" => serializeUnion(T, w, value),
        .array => serializeArray(T, w, value),
        .bool => serializeBool(w, value),
        .float => serializeFloat(T, w, value),
        .int => serializeInt(T, w, value),
        .optional => serializeOptional(T, w, value),
        .pointer => serializePointer(T, w, value),
        .vector => serializeVector(T, w, value),
        .void => serializeVoid(w),
        else => cannotBeSerialized(T),
    };
}

pub fn deserializeAny(comptime T: type, r: *Reader) DeserializationError!T {
    return try switch (@typeInfo(T)) {
        .@"enum" => deserializeEnum(T, r),
        .@"struct" => deserializeStruct(T, r),
        .@"union" => deserializeUnion(T, r),
        .array => deserializeArray(T, r),
        .bool => deserializeBool(r),
        .float => deserializeFloat(T, r),
        .int => deserializeInt(T, r),
        .optional => deserializeOptional(T, r),
        .pointer => requiresAllocation(T),
        .vector => deserializeVector(T, r),
        .void => deserializeVoid(r),
        else => cannotBeSerialized(T),
    };
}

pub fn deserializeAnyAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try switch (@typeInfo(T)) {
        .@"enum" => deserializeEnum(T, r),
        .@"struct" => deserializeStructAlloc(T, r, gpa),
        .@"union" => deserializeUnionAlloc(T, r, gpa),
        .array => deserializeArrayAlloc(T, r, gpa),
        .bool => deserializeBool(r),
        .float => deserializeFloat(T, r),
        .int => deserializeInt(T, r),
        .optional => deserializeOptionalAlloc(T, r, gpa),
        .pointer => deserializePointer(T, r, gpa),
        .vector => deserializeVectorAlloc(T, r, gpa),
        .void => deserializeVoid(r),
        else => cannotBeSerialized(T),
    };
}

pub fn freeAny(comptime T: type, gpa: Allocator, value: T) void {
    return switch (@typeInfo(T)) {
        .@"enum" => {},
        .@"struct" => freeStruct(T, gpa, value),
        .@"union" => freeUnion(T, gpa, value),
        .array => freeArray(T, gpa, value),
        .bool => {},
        .float => {},
        .int => {},
        .optional => freeOptional(T, gpa, value),
        .pointer => freePointer(T, gpa, value),
        .vector => freeVector(T, gpa, value),
        .void => {},
        else => {},
    };
}

pub fn serializeVoid(_: *Writer) SerializationError!void {}
pub fn deserializeVoid(_: *Reader) DeserializationError!void {}

test "{de,}serialize void" {
    var buf: [0]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var r: Reader = .fixed(&buf);

    try serializeAny(void, &w, {});
    try serializeVoid(&w);

    try deserializeAny(void, &r);
    try deserializeAnyAlloc(void, &r, .failing);
    try deserializeVoid(&r);
}

pub fn serializeInt(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .int => |info| switch (T) {
            usize, isize => {
                comptime assert(info.bits <= 64); // We assume 128 bit systems will not exist
                const StableInt = @Int(info.signedness, 64);
                return try serializeInt(StableInt, w, value);
            },
            c_char,
            c_int,
            c_long,
            c_longdouble,
            c_longlong,
            c_short,
            c_uint,
            c_ulong,
            c_ulonglong,
            c_ushort,
            => @compileError(@typeName(T) ++ " does not have a well defined size"),
            else => info,
        },
        .comptime_int => @compileError("Cannot serialize comptime_int, please cast it to a runtime int"),
        else => @compileError(@typeName(T) ++ " is not an integer"),
    };

    switch (info.bits) {
        0...8 => {
            const SByte = @Int(info.signedness, 8);
            try w.writeInt(SByte, value, endian);
        },
        else => try leb.writeLeb128(w, value),
    }
}

pub fn deserializeInt(comptime T: type, r: *Reader) DeserializationError!T {
    const info = switch (@typeInfo(T)) {
        .int => |info| switch (T) {
            usize, isize => {
                comptime assert(info.bits <= 64); // We assume 128 bit systems will not exist
                const StableInt = @Int(info.signedness, 64);
                return math.cast(T, try deserializeInt(StableInt, r)) orelse error.Corrupt;
            },
            c_char,
            c_int,
            c_long,
            c_longdouble,
            c_longlong,
            c_short,
            c_uint,
            c_ulong,
            c_ulonglong,
            c_ushort,
            => @compileError(@typeName(T) ++ " does not have a well defined size"),
            else => info,
        },
        .comptime_int => @compileError("Cannot serialize comptime_int, please cast it to a runtime int"),
        else => @compileError(@typeName(T) ++ " is not an integer"),
    };

    switch (info.bits) {
        0...8 => {
            const SByte = @Int(info.signedness, 8);
            return math.cast(T, try r.takeInt(SByte, endian)) orelse error.Corrupt;
        },
        else => return leb.takeLeb128(r, T) catch |err| switch (err) {
            error.ReadFailed => |e| e,
            error.EndOfStream => |e| e,
            error.Overflow => error.Corrupt,
        },
    }
}

test "{de,}serialize integers" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            var buf: [100]u8 = undefined;
            var buf2: [100]u8 = undefined;

            var w: Writer = .fixed(&buf);
            try serializeInt(T, &w, value);

            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeInt(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, .failing, found);
                try std.testing.expectEqual(value, found);
            }

            var w2: Writer = .fixed(&buf2);
            try serializeAny(T, &w2, value);
            try std.testing.expectEqualSlices(u8, w.buffered(), w2.buffered());
        }
    }.tst;

    try tst(u0, 0);
    try tst(i0, 0);
    try tst(i1, -1);
    try tst(u8, 123);
    try tst(u8, math.maxInt(u8));
    try tst(u9, 266);
    try tst(u9, math.maxInt(u9));
    try tst(u64, math.maxInt(u64));
    try tst(i64, math.maxInt(i64));
    try tst(i64, math.minInt(i64));
}

pub fn serializeFloat(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .float => |i| i,
        .comptime_float => @compileError("Cannot serialize comptime_float, please cast it to a runtime float"),
        else => @compileError(@typeName(T) ++ " is not a float"),
    };

    const BackingInt = @Int(.unsigned, info.bits);
    try w.writeInt(BackingInt, @bitCast(value), endian);
}

pub fn deserializeFloat(comptime T: type, r: *Reader) DeserializationError!T {
    const info = switch (@typeInfo(T)) {
        .float => |i| i,
        .comptime_float => @compileError("Cannot serialize comptime_float, please cast it to a runtime float"),
        else => @compileError(@typeName(T) ++ " is not a float"),
    };

    const BackingInt = @Int(.unsigned, info.bits);
    return @bitCast(try r.takeInt(BackingInt, endian));
}

test "{de,}serialize float" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            var buf: [100]u8 = undefined;
            var buf2: [100]u8 = undefined;

            var w: Writer = .fixed(&buf);
            try serializeFloat(T, &w, value);

            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeFloat(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, .failing, found);
                try std.testing.expectEqual(value, found);
            }

            var w2: Writer = .fixed(&buf2);
            try serializeAny(T, &w2, value);
            try std.testing.expectEqualSlices(u8, w.buffered(), w2.buffered());
        }
    }.tst;

    try tst(f16, 0);
    try tst(f16, -1);
    try tst(f16, 1);
    try tst(f16, math.pi);
    try tst(f16, math.floatMax(f16));
    try tst(f16, math.floatMin(f16));

    try tst(f32, 0);
    try tst(f32, -1);
    try tst(f32, 1);
    try tst(f32, math.pi);
    try tst(f32, math.floatMax(f16));
    try tst(f32, math.floatMin(f16));

    try tst(f64, 0);
    try tst(f64, -1);
    try tst(f64, 1);
    try tst(f64, math.pi);
    try tst(f64, math.floatMax(f16));
    try tst(f64, math.floatMin(f16));

    try tst(f80, 0);
    try tst(f80, -1);
    try tst(f80, 1);
    try tst(f80, math.pi);
    try tst(f80, math.floatMax(f16));
    try tst(f80, math.floatMin(f16));

    try tst(f128, 0);
    try tst(f128, -1);
    try tst(f128, 1);
    try tst(f128, math.pi);
    try tst(f128, math.floatMax(f16));
    try tst(f128, math.floatMin(f16));
}

pub fn serializeBool(w: *Writer, value: bool) SerializationError!void {
    try w.writeByte(@intFromBool(value));
}

pub fn deserializeBool(r: *Reader) DeserializationError!bool {
    return switch (try r.takeByte()) {
        0 => false,
        1 => true,
        else => error.Corrupt,
    };
}

test "{de,}serialize bool" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            var buf: [1]u8 = undefined;
            var buf2: [1]u8 = undefined;

            var w: Writer = .fixed(&buf);
            try serializeBool(&w, value);

            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeBool(&r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(w.buffered());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, .failing, found);
                try std.testing.expectEqual(value, found);
            }

            var w2: Writer = .fixed(&buf2);
            try serializeAny(T, &w2, value);
            try std.testing.expectEqualSlices(u8, w.buffered(), w2.buffered());
        }
    }.tst;

    try tst(bool, true);
    try tst(bool, false);
}

pub fn serializePointer(comptime T: type, w: *Writer, value: T) SerializationError!void {
    try switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => serializeOnePointer(T, w, value),
            .slice,
            .many,
            => serializeSlice(T, w, value),
            .c => cannotBeSerialized(T),
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    };
}

pub fn deserializePointer(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => deserializeOnePointer(T, r, gpa),
            .slice,
            .many,
            => deserializeSlice(T, r, gpa),
            .c => cannotBeSerialized(T),
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    };
}

pub fn freePointer(comptime T: type, gpa: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => freeOnePointer(T, gpa, value),
            .slice,
            .many,
            => freeSlice(T, gpa, value),
            .c => cannotBeSerialized(T),
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    }
}

pub fn serializeOnePointer(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => @compileError(@typeName(T) ++ " is a type of slice, prefer serializeSlice"),
            .c => cannotBeSerialized(T),
            .one => info,
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    };

    if (info.alignment < @alignOf(info.child)) {
        const copy = value.*;
        try serializeAny(info.child, w, copy);
    } else try serializeAny(info.child, w, value.*);
}

pub fn deserializeOnePointer(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => @compileError(@typeName(T) ++ " is a type of slice, prefer deserializeSlice"),
            .c => cannotBeSerialized(T),
            .one => info,
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    };

    const NonConst = @Pointer(info.size, .{
        .@"const" = false,
        .@"volatile" = info.is_volatile,
        .@"allowzero" = info.is_allowzero,
        .@"addrspace" = info.address_space,
        .@"align" = info.alignment,
    }, info.child, info.sentinel());

    const raw_bytes = try gpa.allocWithOptions(
        u8,
        @sizeOf(info.child),
        .fromByteUnits(info.alignment),
        null,
    );
    errdefer gpa.free(raw_bytes);

    const ptr: NonConst = @ptrCast(raw_bytes);

    ptr.* = try deserializeAnyAlloc(info.child, r, gpa);

    return ptr;
}

pub fn freeOnePointer(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => @compileError(@typeName(T) ++ " is a type of slice, prefer freeSlice"),
            .c => cannotBeSerialized(T),
            .one => info,
        },
        else => @compileError(@typeName(T) ++ " is not a pointer"),
    };

    freeAny(info.child, gpa, value.*);
    gpa.destroy(value);
}

test "{de,}serialize single pointers" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeOnePointer(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeOnePointer(T, &r, gpa);
                defer freeOnePointer(T, gpa, found);
                try std.testing.expectEqual(value.*, found.*);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, gpa);
                defer freeAny(T, gpa, found);
                try std.testing.expectEqual(value.*, found.*);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const void_ptr: *void = try arena.create(void);
    const u64_ptr: *u64 = try arena.create(u64);
    const byte_ptr: *u8 = try arena.create(u8);

    u64_ptr.* = 123456789;
    byte_ptr.* = 123;

    try tst(*void, void_ptr);
    try tst(*u64, u64_ptr);
    try tst(*u8, byte_ptr);
    try tst(*allowzero align(1) const u64, u64_ptr);
    try tst(*const u8, byte_ptr);
}

pub fn serializeSlice(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => info,
            .c => cannotBeSerialized(T),
            .one => @compileError(@typeName(T) ++ " is not a type of slice, prefer serializePointer"),
        },
        else => @compileError(@typeName(T) ++ " is not a slice"),
    };

    const slice = switch (info.size) {
        .many => if (info.sentinel()) |sentinel| blk: {
            if (!info.is_volatile and
                info.alignment >= @alignOf(info.child))
            {
                const len = mem.indexOfSentinel(info.child, sentinel, value);
                break :blk value[0..len :sentinel];
            }

            var i: usize = 0;
            while (value[i] != sentinel) {
                i += 1;
            }
            break :blk value[0..i :sentinel];
        } else @compileError("Cannot infer length of " ++ @typeName(T)),
        .slice => value,
        else => comptime unreachable,
    };

    try serializeInt(usize, w, slice.len);

    if (info.child == u8 and
        info.alignment >= @alignOf(u8) and
        !info.is_volatile)
    {
        return try w.writeAll(slice);
    }

    for (slice) |inner| {
        try serializeAny(info.child, w, inner);
    }
}

pub fn deserializeSlice(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => info,
            .c => cannotBeSerialized(T),
            else => @compileError(@typeName(T) ++ " is not a slice, prefer deserializePointer"),
        },
        else => @compileError(@typeName(T) ++ " is not a slice"),
    };

    const len = try deserializeInt(usize, r);

    const slice = try gpa.allocWithOptions(
        info.child,
        len,
        .fromByteUnits(info.alignment),
        info.sentinel(),
    );
    errdefer gpa.free(slice);

    if (info.child == u8 and
        info.alignment >= @alignOf(u8) and
        !info.is_volatile)
    {
        try r.readSliceAll(slice);
        return slice;
    }

    for (slice) |*inner| {
        inner.* = try deserializeAnyAlloc(info.child, r, gpa);
    }

    return switch (info.size) {
        .many => slice.ptr,
        .slice => slice,
        else => comptime unreachable,
    };
}

pub fn freeSlice(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .many,
            .slice,
            => info,
            .c => cannotBeSerialized(T),
            else => @compileError(@typeName(T) ++ " is not a slice, prefer freePointer"),
        },
        else => @compileError(@typeName(T) ++ " is not a slice"),
    };

    const slice = switch (info.size) {
        .many => if (info.sentinel()) |sentinel| blk: {
            if (!info.is_volatile and
                info.alignment >= @alignOf(info.child))
            {
                const len = mem.indexOfSentinel(info.child, sentinel, value);
                break :blk value[0..len :sentinel];
            }

            var i: usize = 0;
            while (value[i] != sentinel) {
                i += 1;
            }
            break :blk value[0..i :sentinel];
        } else @compileError("Cannot infer length of " ++ @typeName(T)),
        .slice => value,
        else => comptime unreachable,
    };

    for (slice) |inner| {
        freeAny(info.child, gpa, inner);
    }

    gpa.free(slice);
}

test "{de,}serialize slices" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const Child = @typeInfo(T).pointer.child;

            const gpa = std.testing.allocator;

            const len = switch (@typeInfo(T).pointer.size) {
                .slice => value.len,
                .many => mem.len(value),
                else => comptime unreachable,
            } + @intFromBool(@typeInfo(T).pointer.sentinel() != null);

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeSlice(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeSlice(T, &r, gpa);
                defer freeSlice(T, gpa, found);
                try std.testing.expectEqualSlices(Child, value[0..len], found[0..len]);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, gpa);
                defer freeAny(T, gpa, found);
                try std.testing.expectEqualSlices(Child, value[0..len], found[0..len]);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const void_slice = try arena.alignedAlloc(void, .fromByteUnits(128), 123);
    const u64_slice = try arena.allocSentinel(u64, 23, 123);
    const byte_slice = try arena.allocWithOptions(u8, 345, .fromByteUnits(64), 69);

    @memset(u64_slice, 420);
    @memset(byte_slice, 100);

    try tst([]void, void_slice);
    try tst([]const void, void_slice);
    try tst([]align(128) void, void_slice);
    try tst([]align(128) const void, void_slice);

    try tst([]u64, u64_slice);
    try tst([]const u64, u64_slice);
    try tst([:123]u64, u64_slice);
    try tst([:123]const u64, u64_slice);
    try tst([*:123]u64, u64_slice.ptr);
    try tst([*:123]const u64, u64_slice.ptr);

    try tst([]u8, byte_slice);
    try tst([]const u8, byte_slice);
    try tst([]align(64) u8, byte_slice);
    try tst([]align(64) const u8, byte_slice);
    try tst([:69]u8, byte_slice);
    try tst([:69]const u8, byte_slice);
    try tst([:69]align(64) u8, byte_slice);
    try tst([:69]align(64) const u8, byte_slice);
    try tst([*:69]u8, byte_slice.ptr);
    try tst([*:69]const u8, byte_slice.ptr);
    try tst([*:69]align(64) u8, byte_slice.ptr);
    try tst([*:69]align(64) const u8, byte_slice.ptr);
}

pub fn serializeArray(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .array => |i| i,
        else => @compileError(@typeName(T) ++ " is not an array"),
    };

    if (info.child == u8) {
        return try w.writeAll(&value);
    }

    for (value) |inner| {
        try serializeAny(info.child, w, inner);
    }
}

pub fn deserializeArray(comptime T: type, r: *Reader) DeserializationError!T {
    return try deserializeArrayAny(T, .no_alloc, r, {});
}

pub fn deserializeArrayAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try deserializeArrayAny(T, .alloc, r, gpa);
}

fn deserializeArrayAny(
    comptime T: type,
    comptime alloc: Alloc,
    r: *Reader,
    gpa: alloc.Gpa(),
) alloc.Error()!T {
    const info = switch (@typeInfo(T)) {
        .array => |i| i,
        else => @compileError(@typeName(T) ++ " is not an array"),
    };

    var res: T = undefined;

    if (info.child == u8) {
        try r.readSliceAll(&res);
        return res;
    }

    for (&res) |*inner| {
        inner.* = try alloc.deser(info.child, r, gpa);
    }
    return res;
}

pub fn freeArray(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .array => |i| i,
        else => @compileError(@typeName(T) ++ " is not an array"),
    };

    for (value) |inner| {
        freeAny(info.child, gpa, inner);
    }
}

test "{de,}serialize array" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeArray(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeArray(T, &r);
                defer freeArray(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                try std.testing.expectEqual(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    const byte_arr: [36]u8 = @splat(13);
    const u64_arr: [12]u64 = @splat(24);

    try tst([36]u8, byte_arr);
    try tst([12]u64, u64_arr);
}

pub fn serializeStruct(comptime T: type, w: *Writer, value: T) SerializationError!void {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError(@typeName(T) ++ " is not a struct"),
    }

    inline for (comptime sortStructFields(T)) |field| {
        const F = @FieldType(T, field.name);
        try serializeAny(F, w, @field(value, field.name));
    }
}

pub fn deserializeStruct(comptime T: type, r: *Reader) DeserializationError!T {
    return try deserializeStructAny(T, .no_alloc, r, {});
}

pub fn deserializeStructAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try deserializeStructAny(T, .alloc, r, gpa);
}

pub fn deserializeStructAny(
    comptime T: type,
    comptime alloc: Alloc,
    r: *Reader,
    gpa: alloc.Gpa(),
) alloc.Error()!T {
    switch (@typeInfo(T)) {
        .@"struct" => {},
        else => @compileError(@typeName(T) ++ " is not a struct"),
    }

    var res: T = undefined;
    inline for (comptime sortStructFields(T)) |field| {
        const F = @FieldType(T, field.name);
        @field(res, field.name) = try alloc.deser(F, r, gpa);
    }
    return res;
}

pub fn freeStruct(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |i| i,
        else => @compileError(@typeName(T) ++ " is not a struct"),
    };

    inline for (info.fields) |field| {
        freeAny(field.type, gpa, @field(value, field.name));
    }
}

test "{de,}serialize struct" {
    const eql = struct {
        pub fn eql(a: anytype, b: anytype) !void {
            inline for (sortStructFields(@TypeOf(a))) |field| {
                try std.testing.expectEqual(@field(a, field.name), @field(b, field.name));
            }
        }
    }.eql;

    const tst = struct {
        pub fn tst(comptime T1: type, comptime T2: type, value: T1) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeStruct(T1, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeStruct(T2, &r);
                defer freeStruct(T2, gpa, found);
                try eql(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T2, &r);
                try eql(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T2, &r, .failing);
                defer freeAny(T2, gpa, found);
                try eql(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T1, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    const Foo1 = extern struct {
        a: u8,
        b: u16,
        c: u8,

        pub const data: @This() = .{
            .a = 123,
            .b = 12345,
            .c = 213,
        };
    };

    const Foo2 = struct {
        c: u8,
        a: u8,
        b: u16,

        pub const data: @This() = .{
            .a = 123,
            .b = 12345,
            .c = 213,
        };
    };

    try tst(Foo1, Foo1, .data);
    try tst(Foo2, Foo2, .data);
    try tst(Foo1, Foo2, .data);
    try tst(Foo2, Foo1, .data);
}

pub fn serializeOptional(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .optional => |i| i,
        else => @compileError(@typeName(T) ++ " is not an optional"),
    };

    if (value) |inner| {
        try serializeBool(w, true);
        try serializeAny(info.child, w, inner);
    } else {
        try serializeBool(w, false);
    }
}

pub fn deserializeOptional(comptime T: type, r: *Reader) DeserializationError!T {
    return try deserializeOptionalAny(T, .no_alloc, r, {});
}

pub fn deserializeOptionalAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try deserializeOptionalAny(T, .alloc, r, gpa);
}

pub fn deserializeOptionalAny(
    comptime T: type,
    comptime alloc: Alloc,
    r: *Reader,
    gpa: alloc.Gpa(),
) alloc.Error()!T {
    const info = switch (@typeInfo(T)) {
        .optional => |i| i,
        else => @compileError(@typeName(T) ++ " is not an optional"),
    };

    const has_value = try deserializeBool(r);

    if (!has_value) return null;

    return try alloc.deser(info.child, r, gpa);
}

pub fn freeOptional(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .optional => |i| i,
        else => @compileError(@typeName(T) ++ " is not an optional"),
    };

    if (value) |inner| {
        freeAny(info.child, gpa, inner);
    }
}

test "{de,}serialize optional" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeOptional(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeOptional(T, &r);
                defer freeOptional(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, gpa, value);
                try std.testing.expectEqual(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    try tst(?u64, null);
    try tst(?u64, 123456890);
}

pub fn serializeEnum(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |i| i,
        else => @compileError(@typeName(T) ++ " is not an enum"),
    };

    const Tag = info.tag_type;
    try serializeInt(Tag, w, @intFromEnum(value));
}

pub fn deserializeEnum(comptime T: type, r: *Reader) DeserializationError!T {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |i| i,
        else => @compileError(@typeName(T) ++ " is not an enum"),
    };

    const Tag = info.tag_type;
    const int = try deserializeInt(Tag, r);
    return std.enums.fromInt(T, int) orelse error.Corrupt;
}

test "{de,}serialize enum" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeEnum(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeEnum(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    try tst(enum { foo, bar, baz }, .foo);
    try tst(enum(u8) { foo, bar, baz }, .bar);
    try tst(enum(u8) { foo, _ }, @enumFromInt(4));
}

pub fn serializeUnion(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => cannotBeSerialized(T),
            .auto => info,
        },
        else => @compileError(@typeName(T) ++ " is not a union"),
    };

    const Tag = info.tag_type orelse cannotBeSerialized(T);

    switch (value) {
        inline else => |pl, t| {
            const name = @tagName(t);
            const F = @FieldType(T, name);

            try serializeEnum(Tag, w, t);
            try serializeAny(F, w, pl);
        },
    }
}

pub fn deserializeUnion(comptime T: type, r: *Reader) DeserializationError!T {
    return deserializeUnionAny(T, .no_alloc, r, {});
}

pub fn deserializeUnionAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return deserializeUnionAny(T, .alloc, r, gpa);
}

inline fn deserializeUnionAny(
    comptime T: type,
    comptime alloc: Alloc,
    r: *Reader,
    gpa: alloc.Gpa(),
) alloc.Error()!T {
    const info = switch (@typeInfo(T)) {
        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => cannotBeSerialized(T),
            .auto => info,
        },
        else => @compileError(@typeName(T) ++ " is not a union"),
    };

    const Tag = info.tag_type orelse cannotBeSerialized(T);

    const tag = try deserializeEnum(Tag, r);
    switch (tag) {
        inline else => |t| {
            const name = @tagName(t);
            const F = @FieldType(T, name);
            return @unionInit(T, name, try alloc.deser(F, r, gpa));
        },
    }
}

pub fn freeUnion(comptime T: type, gpa: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => cannotBeSerialized(T),
            .auto => {},
        },
        else => @compileError(@typeName(T) ++ " is not a union"),
    }

    switch (value) {
        inline else => |pl, t| {
            const name = @tagName(t);
            const F = @FieldType(T, name);
            freeAny(F, gpa, pl);
        },
    }
}

test "{de,}serialize union" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeUnion(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeUnion(T, &r);
                defer freeUnion(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    try tst(union(enum) { foo, bar, baz }, .foo);
    try tst(union(enum) { foo: u8, bar, baz: u32 }, .{ .foo = 12 });
    try tst(union(enum) { foo: u8, bar, baz: u32 }, .{ .baz = 12123456 });
}

pub fn serializeVector(comptime T: type, w: *Writer, value: T) SerializationError!void {
    const info = switch (@typeInfo(T)) {
        .vector => |i| i,
        else => @compileError(@typeName(T) ++ " is not a vector"),
    };

    const Array = [info.len]info.child;

    for (&@as(Array, @bitCast(value))) |inner| {
        try serializeAny(info.child, w, inner);
    }
}

pub fn deserializeVector(comptime T: type, r: *Reader) DeserializationError!T {
    return try deserializeVectorAny(T, .no_alloc, r, {});
}

pub fn deserializeVectorAlloc(comptime T: type, r: *Reader, gpa: Allocator) DeserializationAllocError!T {
    return try deserializeVectorAny(T, .alloc, r, gpa);
}

fn deserializeVectorAny(comptime T: type, comptime alloc: Alloc, r: *Reader, gpa: alloc.Gpa()) alloc.Error()!T {
    const info = switch (@typeInfo(T)) {
        .vector => |i| i,
        else => @compileError(@typeName(T) ++ " is not a vector"),
    };

    const Array = [info.len]info.child;
    var res: Array = undefined;

    for (&res) |*inner| {
        inner.* = try alloc.deser(info.child, r, gpa);
    }

    return @bitCast(res);
}

pub fn freeVector(comptime T: type, gpa: Allocator, value: T) void {
    const info = switch (@typeInfo(T)) {
        .vector => |i| i,
        else => @compileError(@typeName(T) ++ " is not a vector"),
    };

    const Array = [info.len]info.child;

    for (&@as(Array, @bitCast(value))) |inner| {
        freeAny(info.child, gpa, inner);
    }
}

test "{de,}serialize vector" {
    const tst = struct {
        pub fn tst(comptime T: type, value: T) !void {
            const gpa = std.testing.allocator;

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try serializeVector(T, &aw.writer, value);

            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeVector(T, &r);
                defer freeVector(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAny(T, &r);
                try std.testing.expectEqual(value, found);
            }
            {
                var r: Reader = .fixed(aw.written());
                const found = try deserializeAnyAlloc(T, &r, .failing);
                defer freeAny(T, gpa, found);
                try std.testing.expectEqual(value, found);
            }

            var aw2: Writer.Allocating = .init(gpa);
            defer aw2.deinit();
            try serializeAny(T, &aw2.writer, value);
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    const byte_vec: @Vector(8, u8) = @splat(13);
    const u64_vec: @Vector(3, u64) = @splat(24);
    var bool_vec: @Vector(5, bool) = @splat(true);
    bool_vec[1] = false;

    try tst(@Vector(8, u8), byte_vec);
    try tst(@Vector(3, u64), u64_vec);
    try tst(@Vector(5, bool), bool_vec);
}

const Alloc = enum {
    alloc,
    no_alloc,

    pub fn deser(comptime alloc: Alloc, comptime T: type, r: *Reader, gpa: alloc.Gpa()) alloc.Error()!T {
        return try switch (alloc) {
            .alloc => deserializeAnyAlloc(T, r, gpa),
            .no_alloc => deserializeAny(T, r),
        };
    }

    pub fn Error(comptime alloc: Alloc) type {
        return switch (alloc) {
            .no_alloc => DeserializationError,
            .alloc => DeserializationAllocError,
        };
    }

    pub fn Gpa(comptime alloc: Alloc) type {
        return switch (alloc) {
            .no_alloc => void,
            .alloc => Allocator,
        };
    }
};

fn sortStructFields(comptime T: type) [@typeInfo(T).@"struct".fields.len]StructField {
    comptime {
        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(10 * info.fields.len * info.fields.len);

        switch (info.layout) {
            .@"packed" => {
                // The bit layout of packed structs really matter, especially since
                // our serialization strategy is to just write out the backing
                // integer, therefore we sort on bit offset

                const lessThanFn = struct {
                    pub fn lessThanFn(_: void, a: StructField, b: StructField) bool {
                        return @bitOffsetOf(T, a.name) < @bitOffsetOf(T, b.name);
                    }
                }.lessThanFn;

                var fields: [info.fields.len]StructField = undefined;
                @memcpy(&fields, info.fields);
                std.sort.insertion(StructField, &fields, {}, lessThanFn);
                return fields;
            },
            .@"extern", .auto => {
                // The layout of auto/extern sturcts matters a lot less, as long
                // as it's consistent with serialization and deserialization.
                // Therefore we can safely sort by field names to be a little
                // more lenient with reordering of fields.

                const lessThanFn = struct {
                    pub fn lessThanFn(_: void, a: StructField, b: StructField) bool {
                        const end = @min(a.name.len, b.name.len);
                        for (a.name[0..end], b.name[0..end]) |a_byte, b_byte| {
                            switch (std.math.order(a_byte, b_byte)) {
                                .lt => return true,
                                .eq => {},
                                .gt => return false,
                            }
                        }
                        return a.name.len < b.name.len;
                    }
                }.lessThanFn;

                var fields: [info.fields.len]StructField = undefined;
                @memcpy(&fields, info.fields);
                std.sort.insertion(StructField, &fields, {}, lessThanFn);
                return fields;
            },
        }
    }
}

const std = @import("std");
const mem = std.mem;
const math = std.math;
const leb = @import("leb.zig");

const assert = std.debug.assert;

const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.Reader;
const Allocator = mem.Allocator;
const StructField = std.builtin.Type.StructField;
