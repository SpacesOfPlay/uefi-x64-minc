// trap.mc - CPU exception frame layout and a register dump.
//
// An @interrupt_err handler receives a pointer to this frame: the 15 GPRs the
// ISR prologue pushed (R15 first, at the lowest address), the hardware error
// code the CPU pushed, then the interrupt stack frame (RIP/CS/RFLAGS/RSP/SS).
// The field order matches that push order, so a handler declared
// `@interrupt_err void h(TrapFrame* tf)` can read any saved register.
//
// The exception handlers use this to print a register dump instead of
// rebooting.

import console;

struct TrapFrame {
    u64 r15; u64 r14; u64 r13; u64 r12;
    u64 r11; u64 r10; u64 r9;  u64 r8;
    u64 rdi; u64 rsi; u64 rbp; u64 rbx;
    u64 rdx; u64 rcx; u64 rax;
    u64 error_code;
    u64 rip; u64 cs; u64 rflags; u64 rsp; u64 ss;
}

// Same as TrapFrame without the hardware error code. This is what an
// @interrupt handler sees on a vector that pushes no error code, such as the
// int 0x80 syscall gate. The handler reads and writes the saved registers
// directly. Writing `rax` sets the value the interrupted code resumes with.
// `cs & 3` is the caller's privilege level (3 = ring 3).
struct IntrFrame {
    u64 r15; u64 r14; u64 r13; u64 r12;
    u64 r11; u64 r10; u64 r9;  u64 r8;
    u64 rdi; u64 rsi; u64 rbp; u64 rbx;
    u64 rdx; u64 rcx; u64 rax;
    u64 rip; u64 cs; u64 rflags; u64 rsp; u64 ss;
}

// Recursion depth inside trap_dump. A bad framebuffer base makes the first
// store fault, which re-enters the handler and recurses until the stack runs
// out. The second entry drops the screen and keeps the serial dump.
i32 trap_depth = 0;

// Dump the full trap frame. `name` names the vector, e.g. "#PF page-fault".
// CR2 holds the faulting linear address on a page fault and is read live,
// since the CPU latches it at the fault.
//
// Two registers per line with fixed-width labels, so both columns align. At
// 16px glyphs the console is 63 columns on a 1024x768 screen, and three
// registers per line do not fit.
void trap_dump(u8* name, TrapFrame* tf) {
    trap_depth = trap_depth + 1;
    if trap_depth > 1 { con_fb = 0; }

    con_puts("\n");
    con_cputs(CON_RED, "*** CPU EXCEPTION: ");
    con_cputs(CON_RED, name);
    con_cputs(CON_RED, " ***\n");
    con_field_hex("   error=", tf.error_code);
    con_field_hex("     rip=", tf.rip);
    con_field_hex("\n      cs=", tf.cs);
    con_field_hex("  rflags=", tf.rflags);
    con_field_hex("\n     rsp=", tf.rsp);
    con_field_hex("     cr2=", __read_cr2());
    con_field_hex("\n     rax=", tf.rax);
    con_field_hex("     rbx=", tf.rbx);
    con_field_hex("\n     rcx=", tf.rcx);
    con_field_hex("     rdx=", tf.rdx);
    con_field_hex("\n     rsi=", tf.rsi);
    con_field_hex("     rdi=", tf.rdi);
    con_field_hex("\n     rbp=", tf.rbp);
    con_field_hex("      r8=", tf.r8);
    con_field_hex("\n      r9=", tf.r9);
    con_field_hex("     r10=", tf.r10);
    con_field_hex("\n     r11=", tf.r11);
    con_field_hex("     r12=", tf.r12);
    con_field_hex("\n     r13=", tf.r13);
    con_field_hex("     r14=", tf.r14);
    con_field_hex("\n     r15=", tf.r15);
    con_puts("\n");
}
