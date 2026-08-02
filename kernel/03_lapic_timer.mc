// 03_lapic_timer.mc - the local APIC timer drives a minc interrupt handler
// 100 times a second.
//
//   ./run.ps1 kernel/03_lapic_timer.mc
//   ./run.ps1 kernel/03_lapic_timer.mc -Headless -Expect "500 ticks"
//
// The sequence for periodic interrupts on bare metal: install a GDT and IDT,
// mask the legacy PICs, locate the LAPIC through the APIC-base MSR and enable
// it, calibrate the timer against the PIT, then __sti. Between ticks the CPU
// waits in __hlt instead of spinning.

import efi;
import console;
import gdt;
import idt;
import lapic;

const i32 TIMER_VEC = 0x40;    // clear of the CPU exceptions and the masked PICs
u64 g_ticks = 0;

// The tick. The handler shares g_ticks with efi_main, so both use the atomic
// builtins. Those keep the accesses as real loads and stores the optimizer
// cannot cache.
//
// This handler only counts, for three reasons. It would corrupt the console
// cursor state efi_main is using. It returns through iretq, and the ISR
// prologue does not save the volatile XMM registers. One line per tick also
// exceeds a 38400-baud UART, which needs ~260 us a byte against a 10 ms
// budget.
@interrupt void timer_isr() {
    atomic_add(&g_ticks, 1);
    lapic_eoi();
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "lapic timer: leaving boot services\n\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        con_puts("ExitBootServices failed\n");
        while true { __hlt(); }
    }
    __cli();

    gdt_init();
    idt_set_gate(TIMER_VEC, cast(u64, &timer_isr));
    idt_load();
    pic_remap_masked();

    // The APIC-base MSR holds the MMIO base. The firmware maps it 1:1.
    lapic_set_base(__rdmsr(0x1B) & 0x000FFFFFFFFFF000);
    lapic_enable();

    u32 count = lapic_timer_calibrate();
    con_field_dec("calibrated: ", count);
    con_cputs(CON_GRAY, " timer counts per 10 ms\n");

    lapic_timer_periodic(cast(u8, TIMER_VEC), count);
    __sti();
    con_puts("running at 100 Hz, __hlt between ticks\n\n");

    for i32 s = 1; s <= 5; s++ {
        while atomic_load(&g_ticks) < cast(u64, s * 100) { __hlt(); }
        con_field_dec("uptime ", s);
        con_cputs(CON_GRAY, " s\n");
    }
    __cli();

    con_cputs(CON_CYAN, "\ndone: 500 ticks in 5 s. halt.\n");
    while true { __hlt(); }
}
