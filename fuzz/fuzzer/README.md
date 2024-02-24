# Requirement
> cargo install cargo-afl
* C compiler (gcc, clang)
* make
* [afl.rs](https://rust-fuzz.github.io/book/afl/setup.html)

# Supported platforms
afl only works on x86-64 Linux, x86-64 macOS, and ARM64 macOS.

# Setup
1. run the following command in the zig project root dir
> $ zig build fuzz

this will build a fuzzing entry point for our toml parser as a static library and copies it to link directory.

2. build the fuzzer using the following command:
> $ cargo afl build

3. now we are ready to start fuzzing we can run the following command:
> $ cargo afl fuzz -i [input directory] -o [output directory] target/debug/fuzzing

the seed dirctory can be used for input.

