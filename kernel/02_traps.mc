// 02_traps.mc - take over the CPU's fault path: GDT, IDT, and a fault handled
// by a minc function.
//
//   ./run.ps1 kernel/02_traps.mc
//   ./run.ps1 kernel/02_traps.mc -Headless -Expect "CPU EXCEPTION"
//
// @interrupt and @interrupt_err mark a function as an interrupt handler. The
// compiler emits the register save/restore and the iretq, and the handler
// receives a pointer to the saved frame. Its address goes into an IDT gate.
// @interrupt_err is for vectors where the CPU pushes an error code, such as
// #PF and #GP. The frame then carries that code.
//
// Without handlers a fault reboots the machine. With them it prints a register
// dump to the screen and the serial log.

import efi;
import console;
import gdt;
import idt;
import trap;

// A non-canonical x64 address: bit 47 set, upper bits clear. Dereferencing it
// raises #GP on any machine, whatever the firmware mapped.
const u64 WILD = 0x0000800000000000;

// #DE pushes no error code, so this is @interrupt and the frame has no
// error_code field.
@interrupt void de_handler(IntrFrame* tf) {
    con_cputs(CON_RED, "\n*** CPU EXCEPTION: #DE divide-error ***\n");
    con_field_hex("  rip=", tf.rip);
    con_puts("\nhalt.\n");
    __cli();
    while true { __hlt(); }
}

@interrupt_err void gp_handler(TrapFrame* tf) {
    trap_dump("#GP general-protection", tf);
    con_puts("halt.\n");
    __cli();
    while true { __hlt(); }
}

// The dump prints cr2, where the CPU latched the faulting address.
@interrupt_err void pf_handler(TrapFrame* tf) {
    trap_dump("#PF page-fault", tf);
    con_puts("halt.\n");
    __cli();
    while true { __hlt(); }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "traps: leaving boot services\n\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        con_puts("ExitBootServices failed\n");
        while true { __hlt(); }
    }
    __cli();

    gdt_init();                                    // our own segments
    idt_set_gate(0, cast(u64, &de_handler));       // #DE
    idt_set_gate(13, cast(u64, &gp_handler));      // #GP
    idt_set_gate(14, cast(u64, &pf_handler));      // #PF
    idt_load();

    con_cputs(CON_DIM, "dereferencing a wild pointer on purpose:\n");
    con_field_hex("  ", WILD);
    con_puts("\n");

    u64 v = *cast(u64*, WILD);                     // #GP, does not return

    con_field_hex("no fault?! value=", v);
    con_puts("\n");
    while true { __hlt(); }
}
