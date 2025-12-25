const serzig = @import("serialize.zig");

/// Serialization primitives
pub const ser = struct {
    pub const Error = serzig.SerializationError;

    pub const any = serzig.serializeAny;

    pub const @"bool" = serzig.serializeBool;
    pub const @"enum" = serzig.serializeEnum;
    pub const @"struct" = serzig.serializeStruct;
    pub const @"union" = serzig.serializeUnion;
    pub const @"void" = serzig.serializeVoid;
    pub const array = serzig.serializeArray;
    pub const float = serzig.serializeFloat;
    pub const int = serzig.serializeInt;
    pub const onePointer = serzig.serializeOnePointer;
    pub const optional = serzig.serializeOptional;
    pub const pointer = serzig.serializePointer;
    pub const slice = serzig.serializeSlice;
    pub const vector = serzig.serializeVector;
};

/// Deserialization primitives
pub const deser = struct {
    pub const Error = serzig.DeserializationError;

    pub const any = serzig.deserializeAny;
    pub const anyAlloc = serzig.deserializeAnyAlloc;
    pub const freeAny = serzig.freeAny;

    pub const @"bool" = serzig.deserializeBool;
    pub const @"enum" = serzig.deserializeEnum;
    pub const @"struct" = serzig.deserializeStruct;
    pub const @"union" = serzig.deserializeUnion;
    pub const @"void" = serzig.deserializeVoid;
    pub const array = serzig.deserializeArray;
    pub const float = serzig.deserializeFloat;
    pub const int = serzig.deserializeInt;
    pub const onePointer = serzig.deserializeOnePointer;
    pub const optional = serzig.deserializeOptional;
    pub const pointer = serzig.deserializePointer;
    pub const slice = serzig.deserializeSlice;
    pub const vector = serzig.deserializeVector;

    pub const structAlloc = serzig.deserializeStructAlloc;
    pub const unionAlloc = serzig.deserializeUnionAlloc;
    pub const arrayAlloc = serzig.deserializeArrayAlloc;
    pub const optionalAlloc = serzig.deserializeOptionalAlloc;
    pub const vectorAlloc = serzig.deserializeVectorAlloc;

    pub const freeStruct = serzig.freeStruct;
    pub const freeUnion = serzig.freeUnion;
    pub const freeArray = serzig.freeArray;
    pub const freeOptional = serzig.freeOptional;
    pub const freeVector = serzig.freeVector;
};

test {
    _ = &serzig;
}
