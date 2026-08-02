// idt.mc - the Interrupt Descriptor Table: 256 gates, one per vector.
//
// A handler is a minc @interrupt or @interrupt_err function, and its address
// goes into a gate. Load the GDT first, since the gates name its code
// selector.

u8[4096] idt_table;   // 256 gates * 16 bytes
u8[10] idt_ptr;       // IDTR: limit (2 bytes) + base (8 bytes)

// Handlers run under this selector (gdt.mc GDT_KCODE).
i32 IDT_CODE_SELECTOR = 0x08;

// A 64-bit interrupt gate. The handler address is split into three fields,
// a leftover from the 32-bit layout this extends.
struct IdtGate {
    u16 offset_low;
    u16 selector;
    u8 ist;
    u8 attr;
    u16 offset_mid;
    u32 offset_high;
    u32 reserved;
}

// Install a gate for `vec` pointing at `handler`. `attr` is the type and
// privilege byte. The narrowing casts truncate, so no masking.
void idt_set_gate_attr(i32 vec, u64 handler, u8 attr) {
    IdtGate* g = cast(IdtGate*, &idt_table[vec * 16]);
    g.offset_low = cast(u16, handler);
    g.selector = cast(u16, IDT_CODE_SELECTOR);
    g.ist = 0;                          // stay on the current stack
    g.attr = attr;
    g.offset_mid = cast(u16, handler >> 16);
    g.offset_high = cast(u32, handler >> 32);
    g.reserved = 0;
}

// A gate only ring 0 can reach. Every CPU exception uses one.
void idt_set_gate(i32 vec, u64 handler) {
    idt_set_gate_attr(vec, handler, 0x8E);   // present, DPL 0, interrupt gate
}

// A gate ring 3 may invoke with `int`. A syscall vector needs this, and only
// this: a DPL-0 gate raises #GP instead of entering the handler.
void idt_set_gate_user(i32 vec, u64 handler) {
    idt_set_gate_attr(vec, handler, 0xEE);   // present, DPL 3, interrupt gate
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
