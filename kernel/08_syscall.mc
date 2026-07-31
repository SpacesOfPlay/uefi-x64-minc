// 08_syscall.mc - a syscall ABI, and ring 3 running preempted.
//
//   ./run.ps1 kernel/08_syscall.mc
//   ./run.ps1 kernel/08_syscall.mc -Headless -Expect "ring 3 exited"
//
// Example 07 made one call into the kernel. This turns that into an interface:
// a number in rax picks the service, rdi carries the argument, and the handler
// writes the result back into rax. The saved frame is the whole ABI. What the
// handler stores there is what ring 3 resumes with.
//
// The last call uses that to set IF in the caller's saved flags. __enter_user
// starts ring 3 with interrupts off and ring 3 can't run sti, so until the
// kernel agrees, nothing can take the CPU back. Once it does, the timer
// preempts ring 3 like any other code.

import efi;
import console;
import pmm;
import paging;
import gdt;
import idt;
import lapic;
import trap;

i32 TIMER_VEC = 0x40;

u64 SYS_WRITE       = 1;        // print a string
u64 SYS_WRITE_DEC   = 2;        // print a number
u64 SYS_ADD         = 3;        // return arg + 2
u64 SYS_IRQ_ON      = 4;        // set IF in the caller's saved flags
u64 SYS_EXIT        = 5;        // leave ring 3

u64 g_ticks = 0;
u64 g_kernel_save = 0;
u8[16384] user_stack;

// The timer lands here even while ring 3 is running. The CPU switches to the
// stack in TSS.RSP0 first, which is the reason ring 3 needs a TSS at all.
@interrupt void timer_isr() {
    atomic_add(&g_ticks, 1);
    lapic_eoi();
}

// syscall receiver
@interrupt void syscall_gate(IntrFrame* tf) {
    if tf.rax == SYS_WRITE {
        con_cputs(CON_YELLOW, cast(u8*, tf.rdi));
    }
    else if tf.rax == SYS_WRITE_DEC {
        con_field_dec("> kernel: ring 3 sent: ", cast(i64, tf.rdi));
        con_puts("\n");
    }
    else if tf.rax == SYS_ADD {
        con_field_dec("> kernel: ring 3 called add with: ", cast(i64, tf.rdi));
        con_puts("\n");
        tf.rax = tf.rdi + 2;              // the value ring 3 finds in rax
    }
    else if tf.rax == SYS_IRQ_ON {
        tf.rflags = tf.rflags | 0x200;    // IF, applied by the iretq below
        con_cputs(CON_GRAY, "> kernel: interrupts ON for ring 3, timer is started\n");
    }
    else if tf.rax == SYS_EXIT {
        con_field_dec("> kernel: exit after ", cast(i64, atomic_load(&g_ticks)));
        con_cputs(CON_GRAY, " timer ticks in ring 3\n");
        __leave_user(&g_kernel_save);     // does not return
    }
}

void user_main() {
    __syscall(SYS_WRITE, cast(u64, "hello from ring 3\n"));

    // The kernel computes, ring 3 receives it in rax and hands it straight
    // back. If the number survives the round trip, the return path works.
    u64 answer = __syscall(SYS_ADD, 40);
    __syscall(SYS_WRITE_DEC, answer);

    // Nothing but the timer handler advances g_ticks, and the timer can't fire
    // until the kernel sets IF. So this loop only ends if ring 3 is preemptible.
    __syscall(SYS_IRQ_ON, 0);

    // Silly way to time things
    while atomic_load(&g_ticks) < 200 { }
    __syscall(SYS_WRITE, cast(u64, "ring 3: ticks hit 200\n"));
    while atomic_load(&g_ticks) < 400 { }
    __syscall(SYS_WRITE, cast(u64, "ring 3: ticks hit 400\n"));
    while atomic_load(&g_ticks) < 600 { }
    __syscall(SYS_WRITE, cast(u64, "ring 3: ticks hit 600\n"));

    // call exit
    __syscall(SYS_EXIT, 0);
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "syscall: ring 3 asking the kernel for things\n\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    pmm_init(&mm);
    paging_init(&mm, con_fb, cast(u64, con_h * con_pitch * 4));

    gdt_init();
    idt_set_gate_user(0x80, cast(u64, &syscall_gate));
    idt_set_gate(TIMER_VEC, cast(u64, &timer_isr));
    idt_load();
    pic_remap_masked();

    // The LAPIC is MMIO, so paging_init's walk over the 
    // memory map didn't cover it.
    u64 lapic_base = __rdmsr(0x1B) & 0x000FFFFFFFFFF000;
    paging_map_2mb(paging_pml4, lapic_base, lapic_base);

    lapic_set_base(lapic_base);
    lapic_enable();
    lapic_timer_periodic(cast(u8, TIMER_VEC), lapic_timer_calibrate());

    paging_mark_user_2mb(cast(u64, &user_main));
    paging_mark_user_2mb(cast(u64, &user_stack[0]));
    __write_cr3(paging_pml4);

    // Ring 0 stays with interrupts off. Only ring 3 gets them, and only after
    // it asks, so the timer ticks counted below all happened in user mode.
    __enter_user(cast(u64, &user_main),
                 cast(u64, &user_stack[0]) + 16384 - 8,
                 &g_kernel_save);

    con_cputs(CON_GREEN, "\nring 3 exited\n");
    while true { __hlt(); }
}
