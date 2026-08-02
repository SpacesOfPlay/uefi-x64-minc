// lapic.mc - the local APIC: the per-CPU interrupt controller and its timer.
//
// Registers are memory-mapped at the base the APIC-base MSR (0x1B) reports,
// one register per 16-byte slot. The optimizer must not cache or hoist MMIO,
// so every access goes through the atomic builtins, which force a real mov.

u64 lapic_base = 0;

// LAPIC register offsets.
const u32 LAPIC_ID    = 0x20;    // this core's APIC id, in bits 31:24
const u32 LAPIC_SVR   = 0xF0;    // spurious interrupt vector (bit 8 = APIC enable)
const u32 LAPIC_EOI   = 0xB0;    // end-of-interrupt
const u32 LAPIC_ICRL  = 0x300;   // interrupt command, low half (writing it sends)
const u32 LAPIC_ICRH  = 0x310;   // interrupt command, high half (destination)
const u32 LAPIC_TIMER = 0x320;   // LVT timer (vector + mode)
const u32 LAPIC_TICR  = 0x380;   // timer initial count
const u32 LAPIC_TCCR  = 0x390;   // timer current count
const u32 LAPIC_TDCR  = 0x3E0;   // timer divide config

void lapic_set_base(u64 base) { lapic_base = base; }

u32 lapic_read(u32 reg) {
    return atomic_load(cast(u32*, lapic_base + cast(u64, reg)));
}
void lapic_write(u32 reg, u32 v) {
    atomic_store(cast(u32*, lapic_base + cast(u64, reg)), v);
}

// Enable the LAPIC: set bit 8 of the SVR and a spurious vector of 0xFF.
void lapic_enable() { lapic_write(LAPIC_SVR, lapic_read(LAPIC_SVR) | 0x100 | 0xFF); }

void lapic_eoi() { lapic_write(LAPIC_EOI, 0); }

// Which core is this code running on. Readable from any core in any context.
u32 lapic_id() { return lapic_read(LAPIC_ID) >> 24; }

// Send an inter-processor interrupt. The destination goes in the high half,
// and writing the low half sends it. Bit 12 stays set until it is accepted.
void lapic_ipi(u8 apic_id, u32 low) {
    lapic_write(LAPIC_ICRH, cast(u32, apic_id) << 24);
    lapic_write(LAPIC_ICRL, low);
    i32 spins = 0;
    while (lapic_read(LAPIC_ICRL) & 0x1000) != 0 && spins < 1000000 {
        __pause();
        spins = spins + 1;
    }
}

// The two IPIs that start a core. INIT resets it to a wait-for-SIPI state, and
// the SIPI tells it which page to start executing at: vector 8 means 0x8000.
void lapic_send_init(u8 apic_id) { lapic_ipi(apic_id, 0x00004500); }
void lapic_send_sipi(u8 apic_id, u8 vec) { lapic_ipi(apic_id, 0x00004600 | cast(u32, vec)); }

// Fire `vector` every `count` timer ticks, with the divider at 16.
void lapic_timer_periodic(u8 vector, u32 count) {
    lapic_write(LAPIC_TDCR, 0x3);                            // divide by 16
    lapic_write(LAPIC_TIMER, cast(u32, vector) | 0x20000);   // bit 17 = periodic
    lapic_write(LAPIC_TICR, count);
}

// Measure the LAPIC timer rate against a polled PIT, channel 2 over ~10 ms.
// Returns the count for a ~100 Hz periodic tick.
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
