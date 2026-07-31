// gdt.mc - a flat long-mode GDT to replace the firmware's.
//
// After ExitBootServices the CPU still uses the firmware's descriptor tables.
// Installing our own code and data segments removes that dependency and gives
// the IDT a known code selector for its handlers. Ring 0 only, no user
// segments and no TSS.

u8[24] gdt;        // 3 slots: null, code, data
u8[10] gdt_ptr;    // GDTR: limit (2 bytes) + base (8 bytes)

i32 GDT_KCODE = 0x08;
i32 GDT_KDATA = 0x10;

// Flat 8-byte descriptor: base 0, limit 0xFFFFF. `access` is the access byte
// and `gran` the granularity byte.
void gdt_set(i32 idx, u8 access, u8 gran) {
    i64 b = cast(i64, idx) * 8;
    *(gdt + b + 0) = 0xFF; *(gdt + b + 1) = 0xFF;               // limit 15:0
    *(gdt + b + 2) = 0; *(gdt + b + 3) = 0; *(gdt + b + 4) = 0; // base 23:0
    *(gdt + b + 5) = access;
    *(gdt + b + 6) = gran;
    *(gdt + b + 7) = 0;                                          // base 31:24
}

// Build and load the GDT, then reload the segment registers to our selectors.
// Call with interrupts disabled, before installing the IDT.
void gdt_init() {
    gdt_set(0, 0, 0);           // null
    gdt_set(1, 0x9A, 0xAF);     // code: present, ring 0, exec/read, long mode
    gdt_set(2, 0x92, 0xCF);     // data: present, ring 0, read/write

    u16* lim = cast(u16*, &gdt_ptr[0]);
    *lim = 23;                            // 3 slots * 8 - 1
    u64* base = cast(u64*, &gdt_ptr[2]);  // unaligned store is fine on x86
    *base = cast(u64, &gdt[0]);

    __lgdt(&gdt_ptr[0]);
    __set_segments(GDT_KCODE, GDT_KDATA);
}
