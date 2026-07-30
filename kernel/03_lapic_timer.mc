// 03_lapic_timer.mc — a heartbeat: the local APIC timer drives a minc
// interrupt handler 100 times a second.
//
//   ./run.ps1 kernel/03_lapic_timer.mc
//   ./run.ps1 kernel/03_lapic_timer.mc -Headless -Expect "500 ticks"
//
// The full sequence for periodic interrupts on bare metal: own GDT and IDT,
// legacy PICs parked, LAPIC located via the APIC-base MSR and enabled, timer
// calibrated against the PIT, then __sti. Between ticks the CPU sleeps in
// __hlt instead of spinning.

import efi;
import x86;
import gdt;
import idt;
import lapic;

i32 TIMER_VEC = 0x40;    // clear of the CPU exceptions and the parked PICs
u64 g_ticks = 0;

void put_dec(i64 v) {
    if v == 0 { serial_putc(48); return; }
    noinit u8[24] t;
    i32 n = 0;
    while v > 0 {
        t[n] = cast(u8, 48 + cast(i32, v % 10));
        n++;
        v = v / 10;
    }
    for i32 i = n - 1; i >= 0; i-- { serial_putc(t[i]); }
}

// The tick. Interrupt handlers share g_ticks with main(): the atomic builtins
// keep the accesses real loads and stores the optimizer cannot cache.
@interrupt void timer_isr() {
    atomic_add(&g_ticks, cast(u64, 1));
    lapic_eoi();
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    serial_init();
    serial_puts("lapic timer: leaving boot services\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        serial_puts("ExitBootServices failed\n");
        while true { __hlt(); }
    }
    __cli();

    gdt_init();
    idt_set_gate(TIMER_VEC, cast(u64, &timer_isr));
    idt_load();
    pic_remap_masked();

    // The APIC-base MSR holds the MMIO base; the firmware maps it 1:1.
    lapic_set_base(__rdmsr(0x1B) & 0x000FFFFFFFFFF000);
    lapic_enable();

    u32 count = lapic_timer_calibrate();
    serial_puts("calibrated: ");
    put_dec(cast(i64, count));
    serial_puts(" timer counts per 10 ms\n");

    lapic_timer_periodic(cast(u8, TIMER_VEC), count);
    __sti();
    serial_puts("running at 100 Hz, sleeping in __hlt between ticks\n\n");

    for i32 s = 1; s <= 5; s++ {
        while atomic_load(&g_ticks) < cast(u64, s * 100) { __hlt(); }
        serial_puts("uptime ");
        put_dec(s);
        serial_puts(" s\n");
    }
    __cli();

    serial_puts("\ndone: 500 ticks in 5 s. halt.\n");
    while true { __hlt(); }
}
