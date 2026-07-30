// 01_hello.mc — a complete UEFI application in one file, no imports.
//
//   ./run.ps1 uefi/01_hello.mc
//
// The firmware loads the .efi and calls efi_main with the image handle and
// the system table. Every service is a plain function pointer inside a
// spec-layout struct. minc structs use C-natural alignment.

// EFI_TABLE_HEADER - 24 bytes at the head of every standard table.
struct EfiTableHeader {
    u64 signature;
    u32 revision;
    u32 header_size;
    u32 crc32;
    u32 reserved;
}

// EFI_INPUT_KEY, filled by ReadKeyStroke.
struct EfiInputKey {
    u16 scan_code;
    u16 unicode_char;
}

// EFI_SIMPLE_TEXT_INPUT_PROTOCOL (ConIn), truncated after the members used.
// Every entry takes the protocol pointer itself as its first argument.
struct EfiTextInput {
    fn(void*, u64): u64 reset;
    fn(void*, EfiInputKey*): u64 read_key_stroke;
}

// EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL (ConOut), truncated the same way.
struct EfiTextOutput {
    fn(void*, u64): u64 reset;
    fn(void*, u16*): u64 output_string;
}

// EFI_SYSTEM_TABLE, truncated after con_out. Offsets up to here match the
// spec exactly; the fields beyond it are not needed.
struct EfiSystemTable {
    EfiTableHeader hdr;
    u16* firmware_vendor;
    u32 firmware_revision;
    void* console_in_handle;
    EfiTextInput* con_in;
    void* console_out_handle;
    EfiTextOutput* con_out;
}

// The console consumes UTF-16 and wants \r\n. Widen ASCII on the stack.
void puts(EfiSystemTable* st, u8* s) {
    u16[128] buf;
    i32 n = 0;
    for i32 i = 0; *(s + i) != 0; i++ {
        if n >= 124 {
            buf[n] = 0;
            st.con_out.output_string(st.con_out, buf);
            n = 0;
        }
        if *(s + i) == 10 {
            buf[n] = 13;
            n++;
        }
        buf[n] = cast(u16, *(s + i));
        n++;
    }
    buf[n] = 0;
    st.con_out.output_string(st.con_out, buf);
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    puts(st, "hello from minc on UEFI\n");

    // The vendor string is already UTF-16, hand it to the console as-is.
    puts(st, "firmware: ");
    st.con_out.output_string(st.con_out, st.firmware_vendor);
    puts(st, "\n\npress any key to exit\n");

    EfiInputKey key;
    while st.con_in.read_key_stroke(st.con_in, &key) != 0 { }
    return 0;
}
