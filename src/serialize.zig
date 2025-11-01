pub const SerializationError = Writer.Error;
pub const DeserializationError = Reader.Error || Allocator.Error || error{Corrupt};

pub const output_endian: std.builtin.Endian = .little;

pub fn typeHashed(comptime T: type) u64 {
    const global = struct {
        comptime {
            _ = &T;
        }
        pub var mutex: std.Thread.Mutex = .{};
        pub var hash: u64 = 0;
    };

    const load = @atomicLoad(u64, &global.hash, .acquire);
    if (load != 0) {
        @branchHint(.likely);
        return load;
    }

    {
        global.mutex.lock();
        defer global.mutex.unlock();

        if (global.hash != 0) {
            return global.hash;
        }

        var wh: Wyhash = .init(0);
        typeHash(T, &wh);
        global.hash = wh.final();
        assert(global.hash != 0); // very very unlikely
    }

    return global.hash;
}

test typeHashed {
    try std.testing.expect(typeHashed(void) != typeHashed(u8));
}

pub fn typeHash(comptime T: type, h: *Wyhash) void {
    const update = struct {
        // This is a hacky mess, but it's not exposed so I don't really care
        pub fn update(hasher: *Wyhash, value: anytype) void {
            switch (@typeInfo(@TypeOf(value))) {
                .comptime_int => update(hasher, @as(u64, value)),
                .int => |info| {
                    const bits = @sizeOf(@TypeOf(value)) * 8;
                    const Int = @Type(.{ .int = .{ .bits = bits, .signedness = info.signedness } });
                    const v = @as(Int, value);
                    hasher.update(@ptrCast(&v));
                },
                .pointer => |info| switch (info.size) {
                    .slice => hasher.update(@ptrCast(value)),
                    .one, .c, .many => comptime unreachable,
                },
                .@"enum" => update(hasher, @intFromEnum(value)),
                .bool => update(hasher, @intFromBool(value)),
                else => @compileError(@typeName(@TypeOf(value))),
            }
        }
    }.update;

    switch (@typeInfo(T)) {
        .void => update(h, 0x944f79b977618c5c),

        .bool => update(h, 0x3555f6dfaad20701),

        .@"enum" => |info| {
            update(h, 0x53e97517b5e47dc1);
            typeHash(info.tag_type, h);
        },

        .float => |info| {
            update(h, 0xb87a017c0c9bbe19);
            update(h, info.bits);
        },
        .int => |info| {
            update(h, 0xf98c7d000dae5ef7);
            update(h, info.bits);
            update(h, info.signedness);
        },

        .pointer => |info| {
            update(h, 0x4074c124d170a19e);
            update(h, info.size);
            update(h, info.alignment);
            typeHash(info.child, h);
        },

        .vector => |info| {
            update(h, 0xf6b9b4b652b746d5);
            update(info.len);
            typeHash(info.child, h);
        },
        .array => |info| {
            update(h, 0xa808ae6440b45ce0);
            update(h, info.len);
            typeHash(info.child, h);
        },

        .@"struct" => |info| {
            update(h, 0x7cbb0290a9720c92);

            // We switch here because:
            // 1) packed and non packed have different serialization strategies
            // 2) auto and extern should be interchangable
            switch (info.layout) {
                .@"packed" => {
                    update(h, 0x92ef82ba7c4488ac);
                    typeHash(info.backing_integer.?, h);
                },
                .auto, .@"extern" => {
                    update(h, 0x34eb1692d96183c8);
                },
            }

            inline for (sortStructFields(T)) |field| {
                update(h, field.name);
                typeHash(field.type, h);
            }
        },

        .optional => |info| {
            update(h, 0x69d8119ec3c61182);
            typeHash(info.child, h);
        },

        .@"union" => |info| {
            update(h, 0x1761c42833e3fc7a);

            // two of the layouts are non serializable, but we allow it in a
            // typehash anyway
            update(h, info.layout);
            typeHash(info.tag_type.?, h);

            // NOTE: it's not fine to allow adding union variants because:
            // 1) A new variant might be bigger requiring more space to
            //    serialize
            // 2) There is no way to sort the fields such that an arbitrary
            //    new field will go to the end

            inline for (sortUnionFields(T)) |field| {
                update(h, field.name);
                typeHash(field.type, h);
            }
        },

        .type,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        => comptime unreachable, // comptime only

        .undefined,
        .noreturn,
        .@"anyframe",
        => comptime unreachable, // as far as I'm aware, uninstanciable

        .@"fn",
        .@"opaque",
        .frame,
        .null,
        => comptime unreachable, // undefined size

        .error_union,
        .error_set,
        => comptime unreachable, // compilation unit dependent
    }
}

test typeHash {
    const hash = typeHashed;

    try std.testing.expect(hash(void) == hash(void));
    try std.testing.expect(hash(void) != hash(u0));

    try std.testing.expect(hash(u0) != hash(u1));
    try std.testing.expect(hash(u32) != hash(i32));
    try std.testing.expect(hash(u32) != hash(f32));
    try std.testing.expect(hash([]u8) != hash([]u16));
    try std.testing.expect(hash([5]u8) != hash([5]u16));
    try std.testing.expect(hash([5]u8) != hash([4]u8));
    try std.testing.expect(hash(*[5]u8) != hash(*[4]u8));
    try std.testing.expect(hash(*[5]u8) != hash(*[5]u16));

    try std.testing.expect(hash(*[5]u8) == hash(*const [5]u8));
    try std.testing.expect(hash([]u8) == hash([]const u8));

    try std.testing.expect(hash(extern struct { foo: u8 }) != hash(extern struct { bar: u8 }));
    try std.testing.expect(hash(packed struct { foo: u8 }) != hash(packed struct { bar: u8 }));
    try std.testing.expect(hash(packed struct { foo: u8 }) != hash(extern struct { foo: u8 }));

    // Field order is independent
    try std.testing.expect(
        hash(extern struct { foo: u8, bar: u8 }) ==
            hash(extern struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(struct { foo: u8, bar: u8 }) ==
            hash(struct { bar: u8, foo: u8 }),
    );

    // Also between extern and auto
    try std.testing.expect(
        hash(struct { foo: u8, bar: u8 }) ==
            hash(extern struct { bar: u8, foo: u8 }),
    );

    // Except for packed, field order is very depenent here
    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(packed struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(extern struct { bar: u8, foo: u8 }),
    );

    try std.testing.expect(
        hash(packed struct { foo: u8, bar: u8 }) !=
            hash(struct { bar: u8, foo: u8 }),
    );
}

pub fn serialize(comptime T: type, value: *const T, w: *Writer) SerializationError!void {
    if (comptime !hasSerializableLayout(T)) {
        @compileError(@typeName(T) ++ " not serializable");
    }

    switch (@typeInfo(T)) {
        .void,
        => {}, // zst

        .bool => try serialize(u1, @ptrCast(value), w),

        .@"enum" => |info| try serialize(info.tag_type, &@intFromEnum(value.*), w),

        .float => |info| {
            const Int = @Type(.{ .int = .{ .bits = info.bits, .signedness = .unsigned } });
            try serialize(Int, @ptrCast(value), w);
        },
        .int => {
            // TODO: think about the c integers

            // {u,i}size does not have a defined layout, so we default to 64 bit
            // to ensure compatibility between 32 and 64 bit systems
            const Int = switch (T) {
                usize => u64,
                isize => i64,
                else => std.math.ByteAlignedInt(T),
            };

            try w.writeInt(Int, value.*, output_endian);
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                try serializeLength(value.len, w);

                if (info.child == u8) {
                    try w.writeAll(value.*);
                } else if (@sizeOf(info.child) != 0) {
                    // No need to serialize items of 0 ABI size

                    for (value.*) |*elem| {
                        try serialize(info.child, elem, w);
                    }
                }
            },
            .one => try serialize(info.child, value.*, w),

            .many,
            .c,
            => comptime unreachable,
        },

        .vector => |info| {
            if (@sizeOf(info.child) == 0) {
                // No need to serialize items of 0 ABI size

                return;
            }

            inline for (0..info.len) |i| {
                const v = value[i]; // avoid bit pointers
                try serialize(info.child, &v, w);
            }
        },
        .array => |info| {
            if (info.child == u8) {
                try w.writeAll(value);
            } else if (@sizeOf(info.child) != 0) {
                // No need to serialize items of 0 ABI size

                for (value) |*elem| {
                    try serialize(info.child, elem, w);
                }
            }
        },

        .@"struct" => |info| switch (info.layout) {
            .@"packed" => try serialize(info.backing_integer.?, &@bitCast(value.*), w),

            .auto,
            .@"extern",
            => {
                inline for (sortStructFields(T)) |field| {
                    try serialize(field.type, &@field(value.*, field.name), w);
                }
            },
        },

        .optional => |info| {
            // We use a bool effectively to say if the optional was null (0) or
            // will follow (1)
            if (value.*) |*v| {
                try serialize(u1, &@as(u1, 1), w);
                try serialize(info.child, v, w);
            } else {
                try serialize(u1, &@as(u1, 0), w);
            }
        },

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => comptime unreachable,
            .auto => {
                switch (value.*) {
                    inline else => |*pl, tag| {
                        try serialize(info.tag_type.?, &tag, w);
                        try serialize(@TypeOf(pl.*), pl, w);
                    },
                }
            },
        },

        else => comptime unreachable,
    }
}

pub fn deserializeNoAlloc(comptime T: type, r: *Reader) DeserializationError!T {
    return try deserialize(T, .failing, r);
}

pub fn deserialize(comptime T: type, gpa: Allocator, r: *Reader) DeserializationError!T {
    if (comptime !hasSerializableLayout(T)) {
        @compileError(@typeName(T) ++ " not serializable");
    }

    return switch (@typeInfo(T)) {
        .void,
        => {}, // zst

        .bool => switch (try deserializeNoAlloc(u1, r)) {
            0 => false,
            1 => true,
        },

        .@"enum" => |info| {
            const int = try deserializeNoAlloc(info.tag_type, r);
            return std.enums.fromInt(T, int) orelse return error.Corrupt;
        },

        .int => |info| {
            // {u,i}size does not have a defined layout, so we default to 64 bit
            // to ensure compatibility between 32 and 64 bit systems
            const bits = if (T == usize or T == isize) 64 else @bitSizeOf(T);
            const Int = std.math.ByteAlignedInt(
                @Type(.{ .int = .{ .bits = bits, .signedness = info.signedness } }),
            );

            const int = try r.takeInt(Int, output_endian);
            return std.math.cast(T, int) orelse return error.Corrupt;
        },

        .float => |info| blk: {
            const Int = @Type(.{ .int = .{ .bits = info.bits, .signedness = .unsigned } });
            const int = try deserializeNoAlloc(Int, r);
            break :blk @as(T, @bitCast(int));
        },

        .pointer => |info| switch (info.size) {
            .slice => {
                const length = try deserializeLength(r);

                const slice = try gpa.allocWithOptions(
                    info.child,
                    length,
                    .fromByteUnits(info.alignment),
                    info.sentinel(),
                );
                errdefer gpa.free(slice);

                if (info.child == u8) {
                    var fw: Writer = .fixed(slice);
                    r.streamExact(&fw, length) catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => return error.EndOfStream,
                        error.WriteFailed => unreachable,
                    };
                    assert(fw.end == length);
                } else if (@sizeOf(info.child) != 0) {
                    // No need to deserialize items of 0 ABI size

                    for (slice) |*elem| {
                        elem.* = try deserialize(info.child, gpa, r);
                    }
                }

                return slice;
            },
            .one => {
                const ptr = try gpa.create(info.child);
                errdefer gpa.destroy(ptr);

                ptr.* = try deserialize(info.child, gpa, r);
                return ptr;
            },

            .many,
            .c,
            => comptime unreachable,
        },

        .vector => |info| {
            var vec: T = undefined;

            if (@sizeOf(info.child) == 0) {
                // No need to deserialize items of 0 ABI size
                return vec;
            }

            inline for (0..info.len) |i| {
                vec[i] = try deserialize(info.child, gpa, r);
            }
            return vec;
        },
        .array => |info| {
            var arr: T = undefined;

            if (info.child == u8) {
                var fw: Writer = .fixed(&arr);
                r.streamExact(&fw, info.len) catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    error.EndOfStream => return error.EndOfStream,
                    error.WriteFailed => unreachable,
                };
                assert(fw.end == info.len);
            } else if (@sizeOf(info.child) != 0) {
                // No need to deserialize items of 0 ABI size

                for (&arr) |*elem| {
                    elem.* = try deserialize(info.child, gpa, r);
                }
            }

            return arr;
        },

        .@"struct" => |info| switch (info.layout) {
            .@"packed" => {
                const backing = try deserializeNoAlloc(info.backing_integer.?, r);
                return @as(T, @bitCast(backing));
            },

            .auto,
            .@"extern",
            => {
                var val: T = undefined;

                inline for (sortStructFields(T)) |field| {
                    @field(val, field.name) = try deserialize(field.type, gpa, r);
                }

                return val;
            },
        },

        .optional => |info| return switch (try deserializeNoAlloc(u1, r)) {
            0 => null,
            1 => try deserialize(info.child, gpa, r),
        },

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => comptime unreachable,
            .auto => {
                const tag = try deserializeNoAlloc(std.meta.Tag(T), r);

                switch (tag) {
                    inline else => |t| {
                        const name = @tagName(t);
                        const FT = @FieldType(T, name);
                        return @unionInit(T, name, try deserialize(FT, gpa, r));
                    },
                }
            },
        },

        else => comptime unreachable,
    };
}

test "serialization and deserialization" {
    const Arena = std.heap.ArenaAllocator;

    const tst = struct {
        pub fn tst(comptime T: type, arena: *Arena, val: T) !void {
            _ = arena.reset(.retain_capacity);
            var aw: Writer.Allocating = .init(arena.allocator());
            defer aw.deinit();

            try serialize(T, &val, &aw.writer);

            var fr: Reader = .fixed(aw.written());
            const copy = try deserialize(T, arena.allocator(), &fr);

            try std.testing.expectEqual(aw.written().len, fr.end);
            try std.testing.expectEqualDeep(val, copy);

            var aw2: Writer.Allocating = .init(arena.allocator());
            defer aw2.deinit();

            try serialize(T, &copy, &aw2.writer);

            // Serialization idempotency
            try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
        }
    }.tst;

    var a: Arena = .init(std.testing.allocator);
    defer a.deinit();

    var prng: Random.DefaultPrng = .init(std.testing.random_seed);
    const r = prng.random();

    try tst(u32, &a, r.int(u32));
    try tst(u5, &a, r.int(u5));
    try tst(u18, &a, r.int(u18));
    try tst(u0, &a, r.int(u0));
    try tst(u128, &a, r.int(u128));
    try tst(u256, &a, r.int(u256));

    try tst(i32, &a, r.intRangeLessThan(i32, std.math.minInt(i32), 0));
    try tst(i5, &a, r.intRangeLessThan(i5, std.math.minInt(i5), 0));
    try tst(i0, &a, 0);
    try tst(i1, &a, -1);

    try tst(usize, &a, r.int(usize));
    try tst(isize, &a, r.int(isize));

    try tst(f16, &a, 0x3d5b4405bc4fb61e.0); // r.float is cringe
    try tst(f32, &a, r.float(f32));
    try tst(f64, &a, r.float(f64));
    try tst(f80, &a, 0x25754d443887f65e.0); // r.float is cringe
    try tst(f128, &a, 0x67e5a4ab744ea376.0); // r.float is cringe

    inline for (.{ f16, f32, f64, f80, f128 }) |T| {
        try tst(T, &a, std.math.inf(T));
        try tst(T, &a, -std.math.inf(T));

        const nantst = struct {
            pub fn nantst(arena: *Arena, val: T) !void {
                _ = arena.reset(.retain_capacity);
                var aw: Writer.Allocating = .init(arena.allocator());
                defer aw.deinit();

                try serialize(T, &val, &aw.writer);

                var fr: Reader = .fixed(aw.written());
                const copy = try deserialize(T, arena.allocator(), &fr);

                try std.testing.expectEqual(aw.written().len, fr.end);

                // asBytes will use the ABI size, which for f80 is more
                // than the functional size. For some reason in those last
                // few bytes the original (`val`) has some garbage
                const byte_len = @divExact(@bitSizeOf(T), 8);

                // We can't do equality because NaN != Nan
                try std.testing.expectEqualSlices(
                    u8,
                    std.mem.asBytes(&val)[0..byte_len],
                    std.mem.asBytes(&copy)[0..byte_len],
                );

                var aw2: Writer.Allocating = .init(arena.allocator());
                defer aw2.deinit();

                try serialize(T, &copy, &aw2.writer);

                // Serialization idempotency
                try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
            }
        }.nantst;

        try nantst(&a, std.math.nan(T));
        try nantst(&a, std.math.snan(T));
    }

    try tst(bool, &a, true);
    try tst(bool, &a, false);
    try tst(void, &a, {});

    try tst(enum(u32) { foo }, &a, .foo);
    try tst(enum { foo }, &a, .foo);
    try tst(enum(u2) { foo }, &a, .foo);
    try tst(enum { foo, bar }, &a, .foo);

    try tst([]const u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([]const u32, &a, &.{});
    try tst([]const u8, &a, &.{ r.int(u8), r.int(u8), r.int(u8) });
    try tst([]const void, &a, &.{ {}, {}, {} });
    try tst([]const u0, &a, &.{ 0, 0, 0 });

    try tst([:0]const u8, &a, "Hello");

    try tst(*const [3]u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([3]u32, &a, .{ r.int(u32), r.int(u32), r.int(u32) });
    try tst([0]u32, &a, .{});
    try tst([3]u8, &a, .{ r.int(u8), r.int(u8), r.int(u8) });
    try tst([3]void, &a, .{ {}, {}, {} });
    try tst([3]u0, &a, .{ 0, 0, 0 });

    try tst(@Vector(3, u32), &a, .{ r.int(u32), r.int(u32), r.int(u32) });
    try tst(@Vector(0, u32), &a, .{});
    try tst(@Vector(3, u0), &a, .{ 0, 0, 0 });
    try tst(@Vector(4, bool), &a, .{ true, false, true, false });
    try tst(@Vector(4, u1), &a, .{ 1, 0, 1, 0 });

    try tst(?u32, &a, null);
    try tst(?u32, &a, r.int(u32));
    try tst(??u32, &a, @as(??u32, null));
    try tst(??u32, &a, @as(?u32, null));
    try tst(?*const [3]u32, &a, null);
    try tst(?*const [3]u32, &a, &.{ r.int(u32), r.int(u32), r.int(u32) });

    try tst(extern struct { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(extern struct { foo: [1]u32 }, &a, .{ .foo = .{r.int(u32)} });

    try tst(struct { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(struct { foo: [1]u32 }, &a, .{ .foo = .{r.int(u32)} });

    try tst(packed struct { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(packed struct(u5) { foo: u5 }, &a, .{ .foo = r.int(u5) });

    try tst(struct { u32 }, &a, .{r.int(u32)});
    try tst(struct { [1]u32 }, &a, .{.{r.int(u32)}});

    try tst(union(enum(u32)) { foo: u32 }, &a, .{ .foo = r.int(u32) });
    try tst(union(enum(u32)) { foo: u32, bar: u32 }, &a, .{ .foo = r.int(u32) });
}

test "serialization size" {
    const size = struct {
        pub fn size(comptime T: type, expected: usize) !void {
            var dw: Writer.Discarding = .init(&.{});
            const w = &dw.writer;

            const value: T = undefined;

            try serialize(T, &value, w);

            try std.testing.expectEqual(expected, dw.fullCount());
        }
    }.size;

    try size(i0, 0);
    try size(u0, 0);
    try size(void, 0);

    try size(u1, 1);
    try size(i1, 1);
    try size(u8, 1);
    try size(u9, 2);

    // also on 32 bit architectures
    try size(usize, 8);
    try size(isize, 8);

    try size(u18, 3);
    try size(u24, 3);
    try size(u32, 4);

    try size(f16, 2);
    try size(f32, 4);
    try size(f64, 8);
    try size(f80, 10);
    try size(f128, 16);

    try size(bool, 1);

    try size(enum { foo }, 0);
    try size(enum(u8) { foo }, 1);
    try size(enum { foo, bar }, 1);

    try size(?void, 1);
    try size(?bool, 2);
    try size(?u8, 2);
    try size(?u18, 4);

    try size([10]u8, 10);
    try size([10]u10, 20);

    // No bit packing, that just makes life hell
    try size(@Vector(4, bool), 4);
    try size(@Vector(4, u1), 4);
    try size(@Vector(4, i1), 4);
    try size([4]bool, 4);
    try size([4]u1, 4);
    try size([4]i1, 4);

    // 0 stays 0
    try size(void, 0);
    try size(i0, 0);
    try size(u0, 0);
    try size([0]u8, 0);
    try size(@Vector(0, u8), 0);
    try size([4]u0, 0);
    try size([4]i0, 0);
    try size(@Vector(4, u0), 0);
    try size(@Vector(4, i0), 0);

    // No padding
    try size(struct { foo: u8, bar: u1, baz: u24 }, 1 + 1 + 3);

    { // Can't serialize an undefined union
        const Union = union(enum(u8)) { foo: u8, bar: u1, baz: u24 };
        const expected = 1 + 3;

        var dw: Writer.Discarding = .init(&.{});
        const w = &dw.writer;

        const value: Union = .{ .baz = maxInt(u24) };

        try serialize(Union, &value, w);

        try std.testing.expectEqual(expected, dw.fullCount());
    }
}

test "serialized slice length" {
    const sliceSize = struct {
        pub fn sliceSize(
            comptime T: type,
            slice: []const T,
            expected_bytes: usize,
        ) !void {
            var dw: Writer.Discarding = .init(&.{});

            try serialize([]const T, &slice, &dw.writer);

            try std.testing.expectEqual(expected_bytes, dw.fullCount());
        }
    }.sliceSize;

    const gpa = std.testing.allocator;

    try sliceSize(u24, &.{ 1, 2, 3, 4, 5, 6 }, 1 + 6 * 3);

    {
        const slice = try gpa.alloc(u8, maxInt(u16) + 1);
        defer gpa.free(slice);

        try sliceSize(u8, slice[0..maxInt(u16)], 3 + maxInt(u16));
        try sliceSize(u8, slice[0 .. maxInt(u16) + 1], 9 + maxInt(u16) + 1);
    }
}

/// Optimized for small lengths.
/// We do a fairly simple approach where we:
/// 1) take a byte
/// 2) if the byte from (1) did not have the top bit set, that's
///    the length.
/// 3) if the byte from (1) is 0b1000_0000, take the next 2
///    bytes (u16) as length.
/// 4) if the byte from (1) is 0b1100_0000, take the next 8
///    bytes (u64) as length.
///
/// The thinking here is that:
/// * For very short slices you don't want to waste any bytes on
///   the length.
/// * On slices of 128 elements those 8 bytes might be something
///   but 3 bytes is only 'wasting' 1 byte, which is fine for
///   simplicity purposes.
/// * After 65535 elements, we just use all 8 bytes, it doesn't
///   matter anymore.
pub fn serializeLength(length: usize, w: *Writer) SerializationError!void {
    switch (@as(u64, length)) {
        0...maxInt(u7) => {
            const len: u7 = @intCast(length);
            try serialize(u7, &len, w);
        },
        maxInt(u7) + 1...maxInt(u16) => {
            const byte_len: u8 = 0b1000_0000;
            try serialize(u8, &byte_len, w);

            const len: u16 = @intCast(length);
            try serialize(u16, &len, w);
        },
        maxInt(u16) + 1...maxInt(u64) => {
            const byte_len: u8 = 0b1100_0000;
            try serialize(u8, &byte_len, w);

            const len: u64 = @intCast(length);
            try serialize(u64, &len, w);
        },
    }
}

/// Optimized for small lengths.
/// We do a fairly simple approach where we:
/// 1) take a byte
/// 2) if the byte from (1) did not have the top bit set, that's
///    the length.
/// 3) if the byte from (1) is 0b1000_0000, take the next 2
///    bytes (u16) as length.
/// 4) if the byte from (1) is 0b1100_0000, take the next 8
///    bytes (u64) as length.
///
/// The thinking here is that:
/// * For very short slices you don't want to waste any bytes on
///   the length.
/// * On slices of 128 elements those 8 bytes might be something
///   but 3 bytes is only 'wasting' 1 byte, which is fine for
///   simplicity purposes.
/// * After 65535 elements, we just use all 8 bytes, it doesn't
///   matter anymore.
pub fn deserializeLength(r: *Reader) DeserializationError!usize {
    const length_64: u64 = switch (try deserialize(u8, .failing, r)) {
        0...maxInt(u7) => |len| len,
        0b1000_0000 => try deserialize(u16, .failing, r),
        0b1100_0000 => try deserialize(u64, .failing, r),
        else => return error.Corrupt,
    };

    // If we cannot load the amount of elements, the file might as well be
    // corrupt
    return std.math.cast(usize, length_64) orelse
        return error.Corrupt;
}

test "serializing length" {
    const Arena = std.heap.ArenaAllocator;

    const tst = struct {
        pub fn tst(
            arena: *Arena,
            len: usize,
            expected_bytes: usize,
        ) !void {
            _ = arena.reset(.retain_capacity);

            var aw: Writer.Allocating = .init(arena.allocator());
            defer aw.deinit();

            try serializeLength(len, &aw.writer);

            try std.testing.expectEqual(expected_bytes, aw.written().len);

            var fr: Reader = .fixed(aw.written());

            const copy = try deserializeLength(&fr);

            try std.testing.expectEqual(aw.written().len, fr.end);
            try std.testing.expectEqual(len, copy);
        }
    }.tst;

    var a: Arena = .init(std.testing.allocator);
    defer a.deinit();

    for (0..maxInt(u7)) |len| {
        try tst(&a, len, 1);
    }
    try tst(&a, 0b0111_1111, 1);
    try tst(&a, 0b1000_0000, 3);

    try tst(&a, maxInt(u16), 3);
    try tst(&a, maxInt(u16) + 1, 9);
    try tst(&a, maxInt(u32), 9);

    if (@sizeOf(usize) >= 64) {
        try tst(&a, maxInt(u32) + 1, 9);
        try tst(&a, maxInt(u64), 9);
    }
}

pub fn serializeMultiArrayList(
    comptime T: type,
    mal: *const MultiArrayList(T),
    w: *Writer,
) SerializationError!void {
    const MT = MultiArrayList(T);
    const Field = MT.Field;

    try serializeLength(mal.len, w);
    inline for (sortStructFields(T)) |field| {
        const items = mal.items(std.meta.stringToEnum(Field, field.name).?);
        assert(items.len == mal.len);

        for (items) |*item| {
            try serialize(@TypeOf(item.*), item, w);
        }
    }
}

pub fn deserializeMultiArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!MultiArrayList(T) {
    const MT = MultiArrayList(T);
    const Field = MT.Field;

    const len = try deserializeLength(r);

    const byte_length = MT.capacityInBytes(len);
    const bytes = try gpa.alignedAlloc(u8, .of(T), byte_length);
    errdefer gpa.free(bytes);

    var mal: MultiArrayList(T) = .{
        .bytes = bytes.ptr,
        .len = len,
        .capacity = len,
    };

    inline for (sortStructFields(T)) |field| {
        const items = mal.items(std.meta.stringToEnum(Field, field.name).?);
        assert(items.len == len);

        for (items) |*item| {
            item.* = try deserialize(@TypeOf(item.*), gpa, r);
        }
    }

    return mal;
}

test "MultiArrayList serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 2, 100 }) |size| {
        var mal: MultiArrayList(Foo) = .empty;
        defer mal.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            try mal.append(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeMultiArrayList(Foo, &mal, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeMultiArrayList(Foo, gpa, &fr);
        defer copy.deinit(gpa);

        try eqlMultiArrayList(Foo, &mal, &copy);
    }
}

pub fn serializeArrayList(
    comptime T: type,
    al: *const ArrayList(T),
    w: *Writer,
) SerializationError!void {
    try serialize([]T, &al.items, w);
}

pub fn deserializeArrayList(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!ArrayList(T) {
    const items = try deserialize([]T, gpa, r);

    return .{
        .items = items,
        .capacity = items.len,
    };
}

test "ArrayList serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 100 }) |size| {
        var al: ArrayList(Foo) = .empty;
        defer al.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            try al.append(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeArrayList(Foo, &al, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeArrayList(Foo, gpa, &fr);
        defer copy.deinit(gpa);

        try std.testing.expectEqualSlices(Foo, al.items, copy.items);
    }
}

pub fn serializeArrayHashMap(
    comptime T: type,
    ahm: *const T,
    w: *Writer,
) SerializationError!void {
    const Data = T.Data;

    try serializeMultiArrayList(Data, &ahm.entries, w);
}

pub fn deserializeArrayHashMap(
    comptime T: type,
    gpa: Allocator,
    r: *Reader,
) DeserializationError!T {
    const Data = T.Data;

    var map: T = .{
        .entries = try deserializeMultiArrayList(Data, gpa, r),
    };
    errdefer map.deinit(gpa);

    try map.reIndex(gpa);

    return map;
}

test "AutoArrayHashMap serialization" {
    const gpa = std.testing.allocator;

    const Foo = struct { a: u8, b: u64, c: u32 };

    inline for (&.{ 0, 1, 100, 1_000 }) |size| {
        var aahm: AutoArrayHashMap(Foo, Foo) = .empty;
        defer aahm.deinit(gpa);

        var prng: Random.DefaultPrng = .init(std.testing.random_seed);
        const rand = prng.random();

        for (0..size) |_| {
            const gop: AutoArrayHashMap(Foo, Foo).GetOrPutResult = loop: while (true) {
                const gop = try aahm.getOrPut(gpa, .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) });
                if (gop.found_existing) continue;
                break :loop gop;
            };

            gop.value_ptr.* = .{ .a = rand.int(u8), .b = rand.int(u64), .c = rand.int(u32) };
        }

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();

        try serializeArrayHashMap(AutoArrayHashMap(Foo, Foo), &aahm, &aw.writer);

        var fr: Reader = .fixed(aw.written());

        var copy = try deserializeArrayHashMap(AutoArrayHashMap(Foo, Foo), gpa, &fr);
        defer copy.deinit(gpa);

        try eqlMultiArrayList(AutoArrayHashMap(Foo, Foo).Data, &aahm.entries, &copy.entries);

        var aw2: Writer.Allocating = .init(gpa);
        defer aw2.deinit();

        try serializeArrayHashMap(AutoArrayHashMap(Foo, Foo), &copy, &aw2.writer);

        // serliazation idempotency
        try std.testing.expectEqualSlices(u8, aw.written(), aw2.written());
    }
}

fn hasNoAllocLayout(comptime T: type) bool {
    if (!hasSerializableLayout(T)) return false;

    return switch (@typeInfo(T)) {
        .type,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        .undefined,
        .noreturn,
        .@"anyframe",
        .@"fn",
        .@"opaque",
        .frame,
        .null,
        .error_union,
        .error_set,
        => comptime unreachable,

        .@"enum",
        .void,
        .bool,
        .int,
        .float,
        => true, // trivial

        .pointer => false,

        inline .vector,
        .array,
        => |info| hasNoAllocLayout(info.child),

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!hasNoAllocLayout(field.type))
                    return false;
            }
            return true;
        },

        .optional => |info| hasNoAllocLayout(info.child),

        .@"union" => |info| {
            inline for (info.fields) |field| {
                if (!hasNoAllocLayout(field.type))
                    return false;
            }
            return true;
        },
    };
}

test hasNoAllocLayout {
    try std.testing.expect(hasNoAllocLayout(u8));
    try std.testing.expect(hasNoAllocLayout(?u8));
    try std.testing.expect(hasNoAllocLayout([10]u8));
    try std.testing.expect(hasNoAllocLayout(@Vector(10, u8)));
    try std.testing.expect(hasNoAllocLayout(struct { foo: u8, bar: u8 }));
    try std.testing.expect(hasNoAllocLayout(union(enum) { foo: u8, bar: u8 }));

    try std.testing.expect(!hasNoAllocLayout([]u8));
    try std.testing.expect(!hasNoAllocLayout(?[]u8));
    try std.testing.expect(!hasNoAllocLayout([10][]u8));
    try std.testing.expect(!hasNoAllocLayout(*[10]u8));
    try std.testing.expect(!hasNoAllocLayout(struct { foo: u8, baz: []u8, bar: u8 }));
    try std.testing.expect(!hasNoAllocLayout(union(enum) { foo: u8, baz: []u8, bar: u8 }));
}

fn hasSerializableLayout(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        => false, // comptime only

        .undefined,
        .noreturn,
        .@"anyframe",
        => false, // not instanciable

        .@"fn",
        .@"opaque",
        .frame,
        .null,
        => false, // undefined size

        .error_union,
        .error_set,
        => false, // compilation unit dependent

        .@"enum",
        .void,
        .bool,
        .int,
        .float,
        => true, // trivial

        .pointer => |info| switch (info.size) {
            .slice => hasSerializableLayout(info.child),
            .one => switch (@typeInfo(info.child)) {
                .array => hasSerializableLayout(info.child),
                else => false, // pointer bad
            },

            .many,
            .c,
            => false, // undefined size
        },

        inline .vector,
        .array,
        => |info| hasSerializableLayout(info.child),

        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (field.is_comptime or
                    !hasSerializableLayout(field.type))
                    return false;
            }
            return true;
        },

        .optional => |info| hasSerializableLayout(info.child),

        .@"union" => |info| switch (info.layout) {
            .@"extern", .@"packed" => false,
            .auto => {
                if (info.tag_type == null) return false; // undeserializable
                inline for (info.fields) |field| {
                    if (!hasSerializableLayout(field.type))
                        return false;
                }
                return true;
            },
        },
    };
}

test hasSerializableLayout {
    try std.testing.expect(!hasSerializableLayout(@TypeOf(type)));
    try std.testing.expect(!hasSerializableLayout(comptime_int));
    try std.testing.expect(!hasSerializableLayout(comptime_float));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(.enum_literal)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(undefined)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(anyopaque)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(&hasSerializableLayout)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(null)));
    try std.testing.expect(!hasSerializableLayout(@TypeOf(error.Test)));
    try std.testing.expect(!hasSerializableLayout(error{Test}));

    try std.testing.expect(hasSerializableLayout(enum(u32) { a }));
    try std.testing.expect(hasSerializableLayout(enum(u32) { a, b, c, d }));
    try std.testing.expect(hasSerializableLayout(void));
    try std.testing.expect(hasSerializableLayout(bool));
    try std.testing.expect(hasSerializableLayout(u8));
    try std.testing.expect(hasSerializableLayout(u0));
    try std.testing.expect(hasSerializableLayout(f32));

    try std.testing.expect(hasSerializableLayout([10]u32));
    try std.testing.expect(hasSerializableLayout(@Vector(10, u32)));

    try std.testing.expect(hasSerializableLayout([]u32));
    try std.testing.expect(hasSerializableLayout([][]u32));
    try std.testing.expect(hasSerializableLayout(*[10]u32));
    try std.testing.expect(!hasSerializableLayout(*u32));
    try std.testing.expect(!hasSerializableLayout([*]u32));
    try std.testing.expect(!hasSerializableLayout([*c]u32));

    try std.testing.expect(hasSerializableLayout(?u32));
    try std.testing.expect(hasSerializableLayout(?[]?u32));
    try std.testing.expect(hasSerializableLayout(??u32));

    try std.testing.expect(hasSerializableLayout(packed struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(extern struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(struct { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(struct { u32 }));
    try std.testing.expect(!hasSerializableLayout(packed struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(extern struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(struct { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(struct { u32, *u32, u32 }));

    try std.testing.expect(hasSerializableLayout(union(enum(u32)) { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(union(enum) { foo: u32 }));
    try std.testing.expect(hasSerializableLayout(union(enum) { foo }));
    try std.testing.expect(!hasSerializableLayout(union(enum(u32)) { foo: u32, bar: *u32, baz: u32 }));
    try std.testing.expect(!hasSerializableLayout(union { foo: u32 }));
    try std.testing.expect(!hasSerializableLayout(packed union { foo: u32 }));
    try std.testing.expect(!hasSerializableLayout(extern union { foo: u32 }));
}

fn sortUnionFields(comptime T: type) [@typeInfo(T).@"union".fields.len]UnionField {
    comptime {
        const lessThanFn = struct {
            pub fn lessThanFn(_: void, a: UnionField, b: UnionField) bool {
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

        const info = @typeInfo(T).@"union";
        @setEvalBranchQuota(10 * info.fields.len * info.fields.len);

        var fields: [info.fields.len]UnionField = undefined;
        @memcpy(&fields, info.fields);
        std.sort.insertion(UnionField, &fields, {}, lessThanFn);
        return fields;
    }
}

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

fn eqlMultiArrayList(comptime T: type, a: *const MultiArrayList(T), b: *const MultiArrayList(T)) !void {
    try std.testing.expectEqual(a.len, b.len);

    for (0..a.len) |idx| {
        try std.testing.expectEqualDeep(a.get(idx), b.get(idx));
    }
}

const std = @import("std");

const maxInt = std.math.maxInt;
const assert = std.debug.assert;

const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.Reader;
const MultiArrayList = std.MultiArrayList;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMapUnmanaged;
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Wyhash = std.hash.Wyhash;
const Type = std.builtin.Type;
const StructField = Type.StructField;
const UnionField = Type.UnionField;
