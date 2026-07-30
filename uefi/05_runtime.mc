// 05_runtime.mc — the runtime contract: portable minc on the firmware.
//
//   ./run.ps1 uefi/05_runtime.mc
//
// On --target uefi-x64 the ordinary builtins (write, alloc, free, exit, ...)
// compile to calls on __minc_* symbols the program itself provides. Back
// those with boot services and plain minc runs unchanged as a UEFI app.
// Only the symbols a program actually uses need to exist; the full contract
// also covers open / read / close / remove / realloc / memcpy / memset /
// get_argc / get_arg / qpc / qpf.

import efi;

// ---------------------------------------------------------------------
// The program. Nothing below this line touches UEFI — it compiles as-is
// with --target windows or linux.
// ---------------------------------------------------------------------

void put_str(u8* s) {
    i32 n = 0;
    while *(s + n) != 0 { n++; }
    write(stdout(), s, n);
}

void put_dec(i64 v) {
    noinit u8[24] buf;
    i32 i = 23;
    if v == 0 { i = 22; buf[22] = 48; }
    while v > 0 {
        i--;
        buf[i] = cast(u8, 48 + cast(i32, v % 10));
        v = v / 10;
    }
    write(stdout(), &buf[i], 23 - i);
}

i32 main() {
    put_str("primes under 100, from a heap-allocated sieve:\n\n  ");

    u8* sieve = alloc<u8>(100);
    for i32 i = 0; i < 100; i++ { *(sieve + i) = 1; }
    for i32 i = 2; i < 100; i++ {
        if *(sieve + i) == 0 { continue; }
        put_dec(i);
        put_str(" ");
        for i32 k = i * i; k < 100; k = k + i { *(sieve + k) = 0; }
    }
    free(sieve);

    put_str("\n\ndone.\n");
    return 0;
}

// ---------------------------------------------------------------------
// The runtime: the __minc_* symbols the builtins above land on.
// ---------------------------------------------------------------------

EfiSystemTable* rt_st = null;

// write() on stdout/stderr: bounded bytes to the console, widened to UTF-16
// with \n expanded to \r\n.
i32 __minc_write(i64 handle, void* buf, i32 count) {
    u8* s = cast(u8*, buf);
    u16[128] w;
    i32 n = 0;
    for i32 i = 0; i < count; i++ {
        if n >= 124 {
            w[n] = 0;
            rt_st.con_out.output_string(rt_st.con_out, w);
            n = 0;
        }
        if *(s + i) == 10 {
            w[n] = 13;
            n++;
        }
        w[n] = cast(u16, *(s + i));
        n++;
    }
    w[n] = 0;
    rt_st.con_out.output_string(rt_st.con_out, w);
    return count;
}

void* __minc_alloc(i64 n) { return efi_alloc(rt_st, cast(u64, n)); }
void __minc_free(void* p) { if p != null { efi_free(rt_st, p); } }

void* __minc_memcpy(void* dst, void* src, i64 n) {
    efi_copy_mem(rt_st, dst, src, cast(u64, n));
    return dst;
}
void* __minc_memset(void* dst, i32 c, i64 n) {
    efi_set_mem(rt_st, dst, cast(u64, n), cast(u8, c));
    return dst;
}

// exit() has nowhere to return to; report and wait forever.
void __minc_exit(i32 code) {
    efi_puts(rt_st, "\n[exit called]\n");
    while true { efi_stall(rt_st, 1000000); }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    rt_st = st;
    main();
    efi_puts(st, "\npress any key to exit\n");
    efi_wait_key(st);
    return 0;
}
