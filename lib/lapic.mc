// lapic.mc — the local APIC: the per-CPU interrupt controller and its timer.
//
// Registers are memory-mapped at the base the APIC-base MSR (0x1B) reports,
// one register per 16-byte slot. MMIO must not be cached or hoisted by the
// optimizer, every access goes through the atomic builtins which forces
// a real 'mov'.

u64 lapic_base = 0;

// LAPIC register offsets.
u32 LAPIC_SVR   = 0xF0;    // spurious interrupt vector (bit 8 = APIC enable)
u32 LAPIC_EOI   = 0xB0;    // end-of-interrupt
u32 LAPIC_TIMER = 0x320;   // LVT timer (vector + mode)
u32 LAPIC_TICR  = 0x380;   // timer initial count
u32 LAPIC_TCCR  = 0x390;   // timer current count
u32 LAPIC_TDCR  = 0x3E0;   // timer divide config

void lapic_set_base(u64 base) { lapic_base = base; }

u32 lapic_read(u32 reg) {
    return atomic_load(cast(u32*, lapic_base + cast(u64, reg)));
}
void lapic_write(u32 reg, u32 v) {
    atomic_store(cast(u32*, lapic_base + cast(u64, reg)), v);
}

// Software-enable the LAPIC: set bit 8 of the SVR and a spurious vector (0xFF).
void lapic_enable() { lapic_write(LAPIC_SVR, lapic_read(LAPIC_SVR) | 0x100 | 0xFF); }

void lapic_eoi() { lapic_write(LAPIC_EOI, 0); }

// Start the LAPIC timer firing `vector` periodically every `count` ticks
// (divide by 16).
void lapic_timer_periodic(u8 vector, u32 count) {
    lapic_write(LAPIC_TDCR, 0x3);                            // divide by 16
    lapic_write(LAPIC_TIMER, cast(u32, vector) | 0x20000);   // bit 17 = periodic
    lapic_write(LAPIC_TICR, count);
}

// Measure the LAPIC timer rate against a polled PIT (channel 2, ~10 ms) and
// return the count for a ~100 Hz periodic tick.
u32 lapic_timer_calibrate() {
    u8 p = __inb(0x61);
    __outb(0x61, cast(u8, (cast(i32, p) & 0xFC) | 1));       // ch2 gate on, speaker off
    __outb(0x43, 0xB0);                                      // ch2, lo/hi byte, mode 0
    i32 c = 11932;                                           // ~10 ms @ 1.193182 MHz
    __outb(0x42, cast(u8, c & 0xFF));
    __outb(0x42, cast(u8, (c >> 8) & 0xFF));
    lapic_write(LAPIC_TDCR, 0x3);                            // divide by 16
    lapic_write(LAPIC_TIMER, 0x10000);                       // masked, one-shot
    lapic_write(LAPIC_TICR, 0xFFFFFFFF);                     // start counting down
    while (__inb(0x61) & 0x20) == 0 { }                      // wait for ch2 OUT high
    u32 cur = lapic_read(LAPIC_TCCR);
    return 0xFFFFFFFF - cur;                                 // 10 ms of ticks == count for 100 Hz
}
