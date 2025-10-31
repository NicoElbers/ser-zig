# ser-zig

A small library that can serialize and deserialize most primitive Zig types and
a select standard library types.

## Usage

## Include it

To include the library yourself run

```
zig fetch --save git+https://github.com/NicoElbers/ser-zig.git
```

then in your `build.zig` add

```zig
const ser_mod = b.dependency("ser", .{
    .target = target,
}).module("ser");
```

## Format

TODO, just look inside `serialize.zig` :)

<details>

<summary>Notable exceptions</summary>

- untagged unions `{packed,extern,} union {}`
  - Since we cannot generically know which field is active, I don't know how you
    would soundly serialize an untagged union
- errors `error.Foo` and error sets `error{ Foo, Bar }`
  - Since the values errors take on are not defined I cannot think of a sound
    way to serialize them.
- non slice pointers `*Foo` `[*]Foo` `[*c]Foo`
  - It would be very possible to serialize more pointers, at least single
    pointers or {many,c} pointers with a sentinel, I think it opens up a can of
    worms of foot-guns. I might change my mind on this in the future, but for now
    it's unsupported.

See `hasSerializableLayout` for the exact logic defining serializable types

</details>

## Support

I am only aiming to maintain zig master for now. To get the version currently used
zig version run

```
nix develop
```

or if you have `nix-direnv` allow it to load the `.envrc`
