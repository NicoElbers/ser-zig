const funcs = @import("serialize.zig");

pub const typeHash = funcs.typeHash;
pub const typeHashed = funcs.typeHashed;

pub const serialize = struct {
    pub const Error = funcs.SerializationError;

    pub const value = funcs.serialize;

    pub const multiArrayList = funcs.serializeMultiArrayList;
    pub const arrayList = funcs.serializeArrayList;

    pub const arrayHashMap = funcs.serializeArrayHashMap;
};

pub const deserialize = struct {
    pub const Error = funcs.DeserializationError;

    pub const value = funcs.deserialize;

    pub const multiArrayList = funcs.deserializeMultiArrayList;
    pub const arrayList = funcs.deserializeArrayList;

    pub const arrayHashMap = funcs.deserializeArrayHashMap;
};

test {
    _ = &funcs;
}
