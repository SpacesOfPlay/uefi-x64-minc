// 07_ring3.mc - drop to ring 3 and come back.
//
//   ./run.ps1 kernel/07_ring3.mc
//   ./run.ps1 kernel/07_ring3.mc -Headless -Expect "back in ring 0"
//
// Everything so far ran at ring 0, where every instruction is allowed. Ring 3
// is the other side: no port I/O, no control registers, no descriptor tables,
// and only the pages marked user-accessible. Getting there is an iretq with a
// user code selector, which is what __enter_user does.
//
// Coming back needs a gate the CPU will take from ring 3. We install two. An
// int 0x80 vector with DPL 3 lets the user ask for something, and #GP catches
// it when the user code oversteps.

import efi;
import console;
import pmm;
import paging;
import gdt;
import idt;
import trap;

const u64 SYS_WRITE = 1;

u64 g_kernel_save = 0;      // where __enter_user parks the ring-0 context
u8[16384] user_stack;

// tf.cs holds the caller's code selector and its low two bits are the
// privilege level, so the kernel can see who called without being told.
//
// tf.rdi is a pointer the user chose. A real kernel would check it points
// somewhere that user is allowed to read before dereferencing it.
@interrupt void syscall_gate(IntrFrame* tf) {
    if tf.rax != SYS_WRITE { return; }
    con_field_dec("  kernel: write from cpl ", cast(i64, tf.cs & 3));
    con_field_hex(", cs=", tf.cs);
    con_puts("\n");
    con_cputs(CON_YELLOW, cast(u8*, tf.rdi));
}

// __leave_user restores the ring-0 stack pointer __enter_user saved and returns
// there, so it abandons this handler's frame and never comes back.
@interrupt_err void gp_handler(TrapFrame* tf) {
    con_cputs(CON_RED, "  #GP ");
    con_field_hex("rip=", tf.rip);
    con_cputs(CON_GRAY, "  ring 3 is not allowed to do that\n");
    __leave_user(&g_kernel_save);
}

// Ring 3 can't reach the console. con_puts writes the framebuffer and drives
// COM1 with __outb, and both are denied here, so every line goes through the
// kernel.
void user_main() {
    __syscall(SYS_WRITE, cast(u64, "hello from ring 3\n"));
    __cli();                                              // privileged, so this faults
    __syscall(SYS_WRITE, cast(u64, "not reached\n"));
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "ring 3: leaving ring 0 and coming back\n\n");

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
    idt_set_gate(13, cast(u64, &gp_handler));             // #GP
    idt_load();

    // Ring 3 only reaches pages with US set at every level of the walk. Mark
    // the ones holding the user function and its stack, then reload CR3,
    // because those entries are already cached in the TLB.
    paging_mark_user_2mb(cast(u64, &user_main));
    paging_mark_user_2mb(cast(u64, &user_stack[0]));
    __write_cr3(paging_pml4);

    con_cputs(CON_GRAY, "entering ring 3\n");
    __enter_user(cast(u64, &user_main),
                 cast(u64, &user_stack[0]) + 16384 - 8,
                 &g_kernel_save);

    con_cputs(CON_GREEN, "\nback in ring 0\n");
    while true { __hlt(); }
}
