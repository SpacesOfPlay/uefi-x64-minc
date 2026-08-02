// 09_atomics.mc - interrupts and spinlock.
//
//   ./run.ps1 kernel/09_atomics.mc
//   ./run.ps1 kernel/09_atomics.mc -Headless -Expect "atomics ok"
//
// A single aligned store is atomic. An update spanning several stores is not,
// and a timer handler can observe it half done.
//
// On one core __cli and __sti disables/enable interrupts. On multi-core systems
// a spinlock is required instead. This example shows both approaches.
//

import efi;
import console;
import gdt;
import idt;
import lapic;
import atomic;
import spinlock;

const i32 TIMER_VEC = 0x40;
const i32 FIELDS = 8;
const u64 ROUND = 300;              // timer ticks per measurement

u64 g_ticks = 0;
u64[8] record;                // all fields hold the same value between updates
u64 torn = 0;                 // times the handler read fields that disagreed

@interrupt void timer_isr() {
    u64 first = atomic_load(&record[0], RELAXED);
    bool same = true;
    for i32 i = 1; i < FIELDS; i++ {
        if atomic_load(&record[i], RELAXED) != first { same = false; }
    }
    if !same { atomic_add(&torn, 1); }
    atomic_add(&g_ticks, 1);
    lapic_eoi();
}

// Refill the record for ROUND ticks. With `mask` set, interrupts are off for
// the duration of each update.
u64 measure(bool mask) {
    atomic_store(&torn, 0);
    u64 v = atomic_load(&record[0], RELAXED);
    u64 until = atomic_load(&g_ticks) + ROUND;
    while atomic_load(&g_ticks) < until {
        v = v + 1;
        if mask { __cli(); }
        for i32 i = 0; i < FIELDS; i++ { atomic_store(&record[i], v, RELAXED); }
        if mask { __sti(); }
    }
    return atomic_load(&torn);
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "atomics: interrupt masking and the spinlock\n\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    gdt_init();
    idt_set_gate(TIMER_VEC, cast(u64, &timer_isr));
    idt_load();
    pic_remap_masked();

    lapic_set_base(__rdmsr(0x1B) & 0x000FFFFFFFFFF000);
    lapic_enable();
    lapic_timer_periodic(cast(u8, TIMER_VEC), lapic_timer_calibrate());
    __sti();

    u64 irq_on = measure(false);
    u64 irq_off = measure(true);
    __cli();

    con_field_dec("interrupts on:  partial updates seen ", cast(i64, irq_on));
    con_field_dec(" in ", cast(i64, ROUND));
    con_cputs(CON_GRAY, " ticks\n");
    con_field_dec("interrupts off: partial updates seen ", cast(i64, irq_off));
    con_field_dec(" in ", cast(i64, ROUND));
    con_cputs(CON_GRAY, " ticks\n\n");

    bool ok = irq_on > 0 && irq_off == 0;

    // The multi-core equivalent. One core can only check the state changes.
    Spinlock lock;
    spin_init(&lock);

    con_cputs(CON_GRAY, "spin_trylock on a held lock: ");
    spin_lock(&lock);
    bool taken1 = spin_trylock(&lock);      // expect false
    if taken1 { con_cputs(CON_RED, "true\n"); } else { con_cputs(CON_YELLOW, "false\n"); }
    spin_unlock(&lock);

    con_cputs(CON_GRAY, "spin_trylock after unlock:   ");
    bool taken2 = spin_trylock(&lock);      // expect true
    if taken2 { con_cputs(CON_YELLOW, "true\n"); } else { con_cputs(CON_RED, "false\n"); }
    spin_unlock(&lock);

    if taken1 || !taken2 { ok = false; }
    if ok { con_cputs(CON_GREEN, "\natomics ok\n"); }
    else {  con_cputs(CON_RED, "\natomics failed\n"); }
    while true { __hlt(); }
}
