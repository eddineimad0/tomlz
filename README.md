A TOML parser written in zig that targets v1.0 specs of TOML.

## Supported zig versions
✅ [0.11.0](https://ziglang.org/documentation/0.11.0/)   

## Test suite coverage
[toml-test](https://github.com/toml-lang/toml-test) is a language-agnostic test suite to verify the correctness of TOML parsers and writers.

Currently only 2 tests(invalid set) are failing and 413 are passing.

## Usage
```zig
const std = @import("std");
const toml = @import("tomlz");
const io = std.io;
pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_allocator.deinit() == .ok);
    const allocator = gpa_allocator.allocator();

    // the toml parser takes an allocator and uses it internally for all allocations.
    var p = toml.Parser.init(gpa_allocator.allocator());
    // when done deinit the parser to free all allocated resources.
    defer p.deinit();


    const toml_input =
        \\message = "Hello, World!"
    ;
    // the TOML parser accepts a io.StreamSource as an input source.
    // the StreamSource should live as long as the parser.
    var toml_stream = io.StreamSource{
        .const_buffer = io.FixedBufferStream([]const u8){
            .buffer = src,
            .pos = 0,
        },
    };

    // use parse to start parsing the input source.
    var parsed = p.parse(&toml_stream) catch {
        std.log.err("The stream isn't a valid TOML document, {}\n",.{err});
        // handle error.
    };

    // parsed is of type toml.TomlTable which is an alias to 
    // std.StringHashMap(TomlValue).
    // toml.TomlValue type is a union with the following fields:
    // pub const TomlValue = union(TomlType) {
    //     Boolean: bool,
    //     Integer: i64,
    //     Float: f64,
    //     String: []const u8,
    //     Array: []TomlValue,
    //     Table: TomlTable,
    //     TablesArray: []TomlTable,
    //     DateTime: DateTime,
    // };
    // aside from DateTime all other types are standard zig types.
    // all data returned by the parser is owned by the parser and 
    // will be freed once deinit is called or if parse() is called again,
    // consider cloning anything you need to outlive the parser.


    var iter = parsed.iterator();
    while (iter.next()) |pair| {
        // the key is of type []const u8.
        std.debug.print("\n{s} => ", .{pair.key_ptr.*});
        switch (pair.value_ptr.*) {
            // ... do whatever
        }
    }
}
```

## Build options
The build.zig file contains various options that can be used to customize the behaviour of the parser when building, check it out for more details.
