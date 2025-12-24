const serzig = @import("serialize.zig");

pub const ser = struct {
    pub const Error = serzig.SerializationError;

    pub const any = serzig.serializeAny;

    pub const anyPointer = serzig.serializeAnyPointer;

    pub const @"bool" = serzig.serializeBool;
    pub const @"enum" = serzig.serializeEnum;
    pub const @"struct" = serzig.serializeStruct;
    pub const @"union" = serzig.serializeUnion;
    pub const @"void" = serzig.serializeVoid;
    pub const array = serzig.serializeArray;
    pub const float = serzig.serializeFloat;
    pub const int = serzig.serializeInt;
    pub const optional = serzig.serializeOptional;
    pub const pointer = serzig.serializeAnyPointer;
    pub const vector = serzig.serializeVector;
};

pub const deser = struct {
    pub const Error = serzig.DeserializationError;

    pub const any = serzig.deserializeAny;
    pub const anyAlloc = serzig.deserializeAnyAlloc;

    pub const anyPointer = serzig.deserializeAnyPointer;

    pub const @"bool" = serzig.deserializeBool;
    pub const @"enum" = serzig.deserializeEnum;
    pub const @"struct" = serzig.deserializeStruct;
    pub const @"union" = serzig.deserializeUnion;
    pub const @"void" = serzig.deserializeVoid;
    pub const array = serzig.deserializeArray;
    pub const float = serzig.deserializeFloat;
    pub const int = serzig.deserializeInt;
    pub const optional = serzig.deserializeOptional;
    pub const pointer = serzig.deserializeAnyPointer;
    pub const vector = serzig.deserializeVector;

    pub const structAlloc = serzig.deserializeStructAlloc;
    pub const unionAlloc = serzig.deserializeUnionAlloc;
    pub const arrayAlloc = serzig.deserializeArrayAlloc;
    pub const optionalAlloc = serzig.deserializeOptionalAlloc;
    pub const vectorAlloc = serzig.deserializeVectorAlloc;
};

test {
    _ = &serzig;
}
