// idt.mc - the Interrupt Descriptor Table: 256 gates, one per vector.
//
// A handler is a minc @interrupt or @interrupt_err function, and its address
// goes into a gate. Load the GDT first, since the gates name its code
// selector.

u8[4096] idt_table;   // 256 gates * 16 bytes
u8[10] idt_ptr;       // IDTR: limit (2 bytes) + base (8 bytes)

// Handlers run under this selector (gdt.mc GDT_KCODE).
i32 IDT_CODE_SELECTOR = 0x08;

// Install a 64-bit interrupt gate for `vec` pointing at `handler`. Present,
// ring 0.
void idt_set_gate(i32 vec, u64 handler) {
    i64 b = cast(i64, vec) * 16;
    *(idt_table + b + 0) = cast(u8, handler & 0xFF);
    *(idt_table + b + 1) = cast(u8, (handler >> 8) & 0xFF);
    *(idt_table + b + 2) = cast(u8, IDT_CODE_SELECTOR & 0xFF);
    *(idt_table + b + 3) = cast(u8, (IDT_CODE_SELECTOR >> 8) & 0xFF);
    *(idt_table + b + 4) = 0;       // IST = 0: stay on the current stack
    *(idt_table + b + 5) = 0x8E;    // present, DPL 0, 64-bit interrupt gate
    *(idt_table + b + 6) = cast(u8, (handler >> 16) & 0xFF);
    *(idt_table + b + 7) = cast(u8, (handler >> 24) & 0xFF);
    *(idt_table + b + 8) = cast(u8, (handler >> 32) & 0xFF);
    *(idt_table + b + 9) = cast(u8, (handler >> 40) & 0xFF);
    *(idt_table + b + 10) = cast(u8, (handler >> 48) & 0xFF);
    *(idt_table + b + 11) = cast(u8, (handler >> 56) & 0xFF);
    *(idt_table + b + 12) = 0; *(idt_table + b + 13) = 0;
    *(idt_table + b + 14) = 0; *(idt_table + b + 15) = 0;
}

// Build the IDTR and load it with lidt.
void idt_load() {
    u16* lim = cast(u16*, &idt_ptr[0]);
    *lim = 4095;                          // 256 gates * 16 - 1
    u64* base = cast(u64*, &idt_ptr[2]);
    *base = cast(u64, &idt_table[0]);
    __lidt(&idt_ptr[0]);
}

// Remap the two 8259 PICs away from the CPU exception vectors, then mask every
// line. The firmware leaves them where a stray IRQ would arrive as an
// exception. Remapped to 0x20-0x2F and masked, they stay quiet while the LAPIC
// drives interrupts.
void pic_remap_masked() {
    __outb(0x20, 0x11); __outb(0xA0, 0x11);   // ICW1: begin init, expect ICW4
    __outb(0x21, 0x20); __outb(0xA1, 0x28);   // ICW2: master->0x20, slave->0x28
    __outb(0x21, 0x04); __outb(0xA1, 0x02);   // ICW3: cascade on IRQ2
    __outb(0x21, 0x01); __outb(0xA1, 0x01);   // ICW4: 8086 mode
    __outb(0x21, 0xFF); __outb(0xA1, 0xFF);   // mask all lines
}
