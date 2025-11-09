pub fn writeLeb128(w: *Writer, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    const info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError(@tagName(T) ++ " not supported"),
    };

    const BoundInt = @Type(.{ .int = .{ .bits = 7, .signedness = info.signedness } });
    if (info.bits <= 7 or (value >= std.math.minInt(BoundInt) and value <= std.math.maxInt(BoundInt))) {
        const SByte = @Type(.{ .int = .{ .bits = 8, .signedness = info.signedness } });
        const byte = switch (info.signedness) {
            .signed => @as(SByte, @intCast(value)) & 0x7F,
            .unsigned => @as(SByte, @intCast(value)),
        };
        try w.writeByte(@bitCast(byte));
        return;
    }

    const Byte = packed struct { bits: u7, more: bool };
    const Int = std.math.ByteAlignedInt(T);

    const max_bytes = @divFloor(info.bits - 1, 7) + 1;

    var val: Int = value;
    for (0..max_bytes) |_| {
        const more = switch (info.signedness) {
            .signed => val >> 6 != val >> (info.bits - 1),
            .unsigned => val > std.math.maxInt(u7),
        };

        try w.writeByte(@bitCast(@as(Byte, .{
            .bits = @intCast(val & 0x7F),
            .more = more,
        })));

        if (!more) return;

        val >>= 7;
    } else unreachable;
}

pub const TakeLeb128Error = Reader.Error || error{Overflow};
pub fn takeLeb128(r: *Reader, comptime T: type) TakeLeb128Error!T {
    const info = switch (@typeInfo(T)) {
        .int => |info| info,
        else => @compileError(@tagName(T) ++ " not supported"),
    };
    const Byte = packed struct { bits: u7, more: bool };

    if (info.bits <= 7) {
        var byte: Byte = undefined;
        const SBits = @Type(.{ .int = .{ .bits = 7, .signedness = info.signedness } });

        byte = @bitCast(try r.takeByte());
        const val = std.math.cast(T, @as(SBits, @bitCast(byte.bits))) orelse error.Overflow;

        const allowed_bits: u7 = switch (info.signedness) {
            .unsigned => 0,
            .signed => blk: {
                const negative = byte.bits & 0b0100_0000 != 0;
                break :blk if (negative) std.math.maxInt(u7) else 0;
            },
        };

        var fits = true;
        while (byte.more) {
            byte = @bitCast(try r.takeByte());

            if (byte.bits != allowed_bits) fits = false;
        }

        return if (fits) blk: {
            @branchHint(.likely);
            break :blk val;
        } else error.Overflow;
    }

    const Unsigned = @Type(.{ .int = .{ .bits = info.bits, .signedness = .unsigned } });
    const UInt = std.math.ByteAlignedInt(Unsigned);
    const Int = std.math.ByteAlignedInt(T);
    const LogInt = std.math.Log2Int(UInt);

    const State = union(enum) {
        reading,
        full,
        fixup,
    };

    var byte: Byte = undefined;
    var val: UInt = 0;
    var bits_written: LogInt = 0;
    sw: switch (@as(State, .reading)) {
        .reading => {
            const max_bytes = @divFloor(info.bits - 1, 7) + 1;
            inline for (0..max_bytes) |iteration| {
                const shift = iteration * 7;

                byte = @bitCast(try r.takeByte());

                const extended: UInt = byte.bits;
                val |= extended << shift;

                const want_another_u7 = shift + 7 < info.bits;
                if (!want_another_u7) continue :sw .full;

                if (!byte.more) {
                    bits_written = shift + 7;
                    continue :sw .fixup;
                }
            }
            comptime unreachable;
        },
        .full => {
            const bits_remaining = @mod(info.bits, 7);

            var fits = true;
            const allowed_bits: u7 = switch (info.signedness) {
                .unsigned => blk: {
                    if (bits_remaining != 0) {
                        const zero_mask: u7 = @as(u7, std.math.maxInt(u7)) << bits_remaining;
                        if (zero_mask & byte.bits != 0) fits = false;
                    }

                    break :blk 0;
                },
                .signed => blk: {
                    const sign_bit_mask = @as(UInt, 1) << (info.bits - 1);
                    const negative = sign_bit_mask & val != 0;

                    const value_sign: i7 = if (negative) @bitCast(@as(u7, std.math.maxInt(u7))) else 0;

                    const bits: i7 = @bitCast(byte.bits);
                    const bits_sign = bits >> bits_remaining; // sign extends

                    if (bits_remaining != 0 and bits_sign != value_sign) fits = false;

                    const sign_extend_mask = std.math.shl(UInt, std.math.maxInt(UInt), info.bits);
                    if (sign_extend_mask != 0 and negative) {
                        val |= sign_extend_mask;
                    }

                    break :blk @bitCast(value_sign);
                },
            };

            while (byte.more) {
                @branchHint(.unlikely);
                byte = @bitCast(try r.takeByte());
                if (byte.bits != allowed_bits) fits = false;
            }

            return if (fits) blk: {
                @branchHint(.likely);
                break :blk std.math.cast(T, @as(Int, @bitCast(val))) orelse error.Overflow;
            } else error.Overflow;
        },
        .fixup => {
            if (info.signedness == .signed) {
                if ((byte.bits & 0b0100_0000) != 0 and // is negative
                    bits_written < (@typeInfo(UInt).int.bits)) // needs extension
                {
                    const sign_extend_mask = @as(UInt, std.math.maxInt(UInt)) << bits_written;
                    val |= sign_extend_mask;
                }
            }
            return std.math.cast(T, @as(Int, @bitCast(val))) orelse error.Overflow;
        },
    }
}
const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
