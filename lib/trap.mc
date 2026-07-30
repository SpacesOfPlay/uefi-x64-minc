// trap.mc — CPU exception frame layout and a serial register dump.
//
// An @interrupt_err handler receives a pointer to this frame: the 15 GPRs the
// ISR prologue pushed (R15 first, at the lowest address), the hardware error
// code the CPU pushed, then the interrupt stack frame (RIP/CS/RFLAGS/RSP/SS).
// The field order matches that push order, so that a handler declared
// `@interrupt_err void h(TrapFrame* tf)` can read any saved register.
//
// Used by the kernel's exception handlers to turn a fault into a diagnosable
// serial dump instead of a silent reboot.

import x86;

struct TrapFrame {
    u64 r15; u64 r14; u64 r13; u64 r12;
    u64 r11; u64 r10; u64 r9;  u64 r8;
    u64 rdi; u64 rsi; u64 rbp; u64 rbx;
    u64 rdx; u64 rcx; u64 rax;
    u64 error_code;
    u64 rip; u64 cs; u64 rflags; u64 rsp; u64 ss;
}

// Same as TrapFrame but without the hardware error code. The layout an
// @interrupt handler (no error-code vector, e.g. the int 0x80 syscall gate)
// sees. The handler reads/writes the saved registers directly; writing `rax`
// sets the value the interrupted code resumes with. `cs & 3` is the caller's
// privilege level (3 = ring 3).
struct IntrFrame {
    u64 r15; u64 r14; u64 r13; u64 r12;
    u64 r11; u64 r10; u64 r9;  u64 r8;
    u64 rdi; u64 rsi; u64 rbp; u64 rbx;
    u64 rdx; u64 rcx; u64 rax;
    u64 rip; u64 cs; u64 rflags; u64 rsp; u64 ss;
}

void trap_hex(u64 v) {
    serial_puts("0x");
    for i32 i = 0; i < 16; i++ {
        u8 nib = cast(u8, (v >> cast(u64, (15 - i) * 4)) & 0xF);
        if nib < 10 { serial_putc(cast(u8, 48 + nib)); }
        else { serial_putc(cast(u8, 87 + nib)); }
    }
}

void trap_field(u8* label, u64 v) {
    serial_puts(label);
    trap_hex(v);
}

// Dump the full trap frame over the serial console. `name` names the vector
// (e.g. "#PF page-fault"). CR2 (the faulting linear address) is meaningful
// for page faults; it is read live since the CPU latches it on the fault.
void trap_dump(u8* name, TrapFrame* tf) {
    serial_puts("\n*** CPU EXCEPTION: ");
    serial_puts(name);
    serial_puts(" ***\n");
    trap_field("  error=", tf.error_code);
    trap_field("  rip=", tf.rip);
    trap_field("  cs=", tf.cs);
    trap_field("\n  rflags=", tf.rflags);
    trap_field("  rsp=", tf.rsp);
    trap_field("  cr2=", __read_cr2());
    trap_field("\n  rax=", tf.rax);
    trap_field(" rbx=", tf.rbx);
    trap_field(" rcx=", tf.rcx);
    trap_field(" rdx=", tf.rdx);
    trap_field("\n  rsi=", tf.rsi);
    trap_field(" rdi=", tf.rdi);
    trap_field(" rbp=", tf.rbp);
    trap_field("\n  r8 =", tf.r8);
    trap_field(" r9 =", tf.r9);
    trap_field(" r10=", tf.r10);
    trap_field(" r11=", tf.r11);
    trap_field("\n  r12=", tf.r12);
    trap_field(" r13=", tf.r13);
    trap_field(" r14=", tf.r14);
    trap_field(" r15=", tf.r15);
    serial_puts("\n");
}
