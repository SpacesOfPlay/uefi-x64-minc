// 02_traps.mc — own the CPU's fault path: GDT, IDT, and a page fault caught
// by a minc function.
//
//   ./run.ps1 kernel/02_traps.mc
//   ./run.ps1 kernel/02_traps.mc -Headless -Expect "CPU EXCEPTION"
//
// @interrupt and @interrupt_err mark a function as an interrupt handler: the
// compiler emits the register save/restore and the iretq, and the handler
// receives a pointer to the saved frame. Its address goes straight into an
// IDT gate. @interrupt_err is for the vectors where the CPU pushes an error
// code (#PF, #GP); the frame then carries it.
//
// Without handlers a fault on bare metal faults and silently reboots
// the machine. With them it becomes a register dump.

import efi;
import x86;
import gdt;
import idt;
import trap;

// A non-canonical x64 address: bit 47 set, upper bits clear. Dereferencing
// it is a #GP on any machine, no matter what the firmware mapped.
u64 WILD = 0x0000800000000000;

// #DE pushes no error code: @interrupt, and the frame has no error_code slot.
@interrupt void de_handler(IntrFrame* tf) {
    serial_puts("\n*** CPU EXCEPTION: #DE divide-error *** rip=");
    trap_hex(tf.rip);
    serial_puts("\nhalt.\n");
    __cli();
    while true { __hlt(); }
}

@interrupt_err void gp_handler(TrapFrame* tf) {
    trap_dump("#GP general-protection", tf);
    serial_puts("halt.\n");
    __cli();
    while true { __hlt(); }
}

// The dump prints cr2 — the CPU latched the faulting address there.
@interrupt_err void pf_handler(TrapFrame* tf) {
    trap_dump("#PF page-fault", tf);
    serial_puts("halt.\n");
    __cli();
    while true { __hlt(); }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    serial_init();
    serial_puts("traps: leaving boot services\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        serial_puts("ExitBootServices failed\n");
        while true { __hlt(); }
    }
    __cli();

    gdt_init();                                    // our segments, our rules
    idt_set_gate(0, cast(u64, &de_handler));       // #DE
    idt_set_gate(13, cast(u64, &gp_handler));      // #GP
    idt_set_gate(14, cast(u64, &pf_handler));      // #PF
    idt_load();

    serial_puts("dereferencing wild pointer ");
    trap_hex(WILD);
    serial_puts(" on purpose...\n");

    u64 v = *cast(u64*, WILD);                     // #GP — does not return

    serial_puts("no fault?! value=");
    trap_hex(v);
    serial_puts("\n");
    while true { __hlt(); }
}
