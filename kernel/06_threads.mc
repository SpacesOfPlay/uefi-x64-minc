// 06_threads.mc - two tasks sharing one core, switched by the timer.
//
//   ./run.ps1 kernel/06_threads.mc
//   ./run.ps1 kernel/06_threads.mc -Headless -Expect "both workers ran"
//
// Example 03 counted timer interrupts. This one uses them to switch tasks. A
// task's whole saved context is its stack pointer, so a switch means pushing
// the callee-saved registers, storing rsp, loading the next task's rsp, and
// popping them back. That is all __context_switch does.
//
// The switch happens inside the timer handler, after EOI. The interrupted task
// leaves its interrupt frame on its own stack and picks up from there when the
// scheduler returns to it.

import efi;
import console;
import gdt;
import idt;
import lapic;
import sched;

const i32 TIMER_VEC = 0x40;

u64 g_ticks = 0;
u64 work_a = 0;
u64 work_b = 0;

u8[8192] stack_a;
u8[8192] stack_b;

// EOI first, then switch. Switching first would leave the LAPIC waiting on an
// acknowledgement this core won't send until the task is scheduled again.
@interrupt void timer_isr() {
    atomic_add(&g_ticks, 1);
    lapic_eoi();
    sched_tick();
}

// Both workers only count. The console keeps a cursor position and a colour in
// globals, so two tasks printing into it would interleave mid-glyph. Task 0
// does the printing, and example 09 adds the lock that would fix it.
void task_a() {
    __sti();                                  // reached by ret, so the interrupt flag is clear
    while true { atomic_add(&work_a, 1); }
}

void task_b() {
    __sti();
    while true { atomic_add(&work_b, 1); }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "threads: one core, main thread + two workers\n\n");

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
    u32 count = lapic_timer_calibrate();

    // Task 0 is this code, so it is scheduled like the others. That is why the
    // printing below survives being preempted. The workers start suspended, and
    // the first timer tick after __sti switches into one of them.
    sched_init();
    // Task 1, 2
    sched_add(cast(u64, &task_a), cast(u64, &stack_a[0]) + 8192);
    sched_add(cast(u64, &task_b), cast(u64, &stack_b[0]) + 8192);

    lapic_timer_periodic(cast(u8, TIMER_VEC), count);
    __sti();

    for i32 s = 1; s <= 5; s++ {
        while atomic_load(&g_ticks) < cast(u64, s * 100) { __hlt(); }
        con_field_dec("t=", s);
        con_field_dec("s  a=", atomic_load(&work_a));
        con_field_dec("  b=", atomic_load(&work_b));
        con_puts("\n");
    }
    __cli();

    if work_a > 0 && work_b > 0 {
        con_cputs(CON_GREEN, "\nboth workers ran\n");
    } else {
        con_cputs(CON_RED, "\na worker never ran\n");
    }
    while true { __hlt(); }
}
