use afl::fuzz;

#[link(name="lib-fuzz-me",kind="static")]
extern "C" {
 fn fuzz_tomlz(buffer:*const u8,size:usize);
}

fn main() {
    fuzz!(|data:&[u8]|{
        unsafe {
            fuzz_tomlz(data.as_ptr(),data.len());
        }
    })
}
