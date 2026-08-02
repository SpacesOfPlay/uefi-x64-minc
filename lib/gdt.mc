// gdt.mc - a flat long-mode GDT and a TSS, replacing the firmware's.
//
// After ExitBootServices the CPU still uses the firmware's descriptor tables.
// Installing our own code and data segments removes that dependency and gives
// the IDT a known code selector for its handlers.
//
// Slots 3 and 4 are what ring 3 runs on. Their positions aren't a free choice:
// the compiler emits the selectors 0x1B and 0x23 literally in __enter_user, so
// user code has to be slot 3 and user data slot 4.
//
// The TSS holds RSP0, the ring-0 stack the CPU switches to when ring 3 traps.
// Without it a syscall from ring 3 has nowhere to push its interrupt frame.

u8[56] gdt;        // 7 slots: null, kcode, kdata, ucode, udata, TSS (2 slots)
u8[10] gdt_ptr;    // GDTR: limit (2 bytes) + base (8 bytes)
u8[104] tss;       // 64-bit Task State Segment
u8[16384] gdt_kstack;   // the stack a ring 3 -> ring 0 trap lands on

i32 GDT_KCODE = 0x08;
i32 GDT_KDATA = 0x10;
i32 GDT_UCODE = 0x18;   // ring 3 adds its RPL, giving 0x1B
i32 GDT_UDATA = 0x20;   // 0x23
i32 GDT_TSS = 0x28;

struct GdtDesc {
    u16 limit_low;
    u16 base_low;
    u8 base_mid;
    u8 access;
    u8 gran;
    u8 base_high;
}

struct GdtTssDesc {
    u16 limit_low;
    u16 base_low;
    u8 base_mid;
    u8 access;
    u8 gran;
    u8 base_high;
    u32 base_upper;
    u32 reserved;
}

// Flat 8-byte descriptor: base 0, limit 0xFFFFF. `access` is the access byte
// and `gran` the granularity byte.
void gdt_set(i32 idx, u8 access, u8 gran) {
    GdtDesc* d = cast(GdtDesc*, &gdt[idx * 8]);
    d.limit_low = 0xFFFF;
    d.base_low = 0;
    d.base_mid = 0;
    d.access = access;
    d.gran = gran;
    d.base_high = 0;
}

// A 64-bit TSS descriptor is a system descriptor and takes two slots, because
// it carries a full 64-bit base. The narrowing casts truncate, so no masking.
void gdt_set_tss(i32 idx, u64 base, u32 limit) {
    GdtTssDesc* d = cast(GdtTssDesc*, &gdt[idx * 8]);
    d.limit_low = cast(u16, limit);
    d.base_low = cast(u16, base);
    d.base_mid = cast(u8, base >> 16);
    d.access = 0x89;                        // present, available 64-bit TSS
    d.gran = cast(u8, (limit >> 16) & 0x0F);
    d.base_high = cast(u8, base >> 24);
    d.base_upper = cast(u32, base >> 32);
    d.reserved = 0;
}

// Build and load the GDT and TSS, reload the segment registers, load the task
// register. Call with interrupts disabled, before installing the IDT.
void gdt_init() {
    gdt_set(0, 0, 0);           // null
    gdt_set(1, 0x9A, 0xAF);     // kernel code: present, ring 0, exec/read, long mode
    gdt_set(2, 0x92, 0xCF);     // kernel data: present, ring 0, read/write
    gdt_set(3, 0xFA, 0xAF);     // user code:   present, ring 3, exec/read, long mode
    gdt_set(4, 0xF2, 0xCF);     // user data:   present, ring 3, read/write

    u64* rsp0 = cast(u64*, &tss[4]);
    *rsp0 = cast(u64, &gdt_kstack[0]) + 16384;
    // The I/O permission bitmap offset equals the TSS limit plus one, which
    // means there is no bitmap, so ring-3 port I/O traps.
    u16* iopb = cast(u16*, &tss[102]);
    *iopb = 104;
    gdt_set_tss(5, cast(u64, &tss[0]), 103);

    u16* lim = cast(u16*, &gdt_ptr[0]);
    *lim = 55;                            // 7 slots * 8 - 1
    u64* base = cast(u64*, &gdt_ptr[2]);  // unaligned store is fine on x86
    *base = cast(u64, &gdt[0]);

    __lgdt(&gdt_ptr[0]);
    __set_segments(GDT_KCODE, GDT_KDATA);
    __ltr(GDT_TSS);
}
