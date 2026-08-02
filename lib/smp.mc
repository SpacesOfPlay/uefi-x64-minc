// smp.mc - start the other cores.
//
// A core that has never run wakes in 16-bit real mode, so the kernel cannot
// hand it a 64-bit address to jump to. It gets a page number instead, and the
// code on that page has to walk it up through protected mode into long mode.
// That code is the trampoline below.
//
// It has to be machine code rather than minc, because minc compiles for long
// mode and none of these stages are in it yet. The page layout is fixed so
// every jump target and operand is a constant:
//
//   0x8000  16-bit code        0x8100  GDT (null, 32c, 32d, 64c, 64d)
//   0x8040  32-bit code        0x8130  GDTR (limit, base = 0x8100)
//   0x80C0  64-bit code        0x8140  CR3, 0x8148 entry, 0x8150 stack
//                              0x8158  set by the core once it has the stack
//
// CR3, entry and stack are patched in after the copy: the page tables to run on,
// the minc function to land in, and that core's stack. The 64-bit stage runs to
// 0x8100 exactly, so it cannot grow without moving the GDT.

import acpi;
import lapic;
import x86;

const u64 SMP_TRAMP = 0x8000;    // the trampoline page, below 1 MiB
const u64 SMP_TAKEN = 0x158;     // trampoline offset of the stack-taken flag
const u8 SMP_VEC = 8;            // SIPI vector; SMP_VEC << 12 == SMP_TRAMP
const i32 MAX_CORES = 64;

i32 smp_online = 0;              // cores that have checked in
u8[MAX_CORES] smp_apic_ids;      // what each one reported, in check-in order

// One stack per core. Bring-up is serialized, so a bump index is enough.
const u64 SMP_STACK = 16384;
u8[MAX_CORES*SMP_STACK] smp_stacks;      // core stacks
i32 smp_stack_idx = 0;

// One stack per core, so the array is the core limit. Returns 0 when spent.
u64 smp_alloc_stack() {
    if smp_stack_idx >= MAX_CORES { return 0; }
    i32 k = smp_stack_idx;
    smp_stack_idx = smp_stack_idx + 1;
    u64 top = cast(u64, &smp_stacks[0]) + cast(u64, k) * SMP_STACK + SMP_STACK;
    return ((top >> 4) << 4) - 8;      // 16-aligned, minus 8 for the call convention
}

// Write the three stages plus the GDT into the page.
void smp_build_tramp() {
    u8* t = cast(u8*, SMP_TRAMP);
    for i32 i = 0; i < 0x160; i++ { t[i] = 0; }

    // 16-bit: interrupts off, ds = cs, load the GDT, set CR0.PE, and far jump
    // to the 32-bit stage. That jump enters protected mode.
    u8[26] c16 = { 0xFA,                                      // cli
                   0x8C, 0xC8, 0x8E, 0xD8,                    // mov ax,cs; mov ds,ax
                   0x0F, 0x01, 0x16, 0x30, 0x01,              // lgdt [0x130]
                   0x0F, 0x20, 0xC0, 0x0C, 0x01, 0x0F, 0x22, 0xC0,   // cr0 |= PE
                   0x66, 0xEA, 0x40, 0x80, 0x00, 0x00, 0x08, 0x00 }; // ljmp 0x08:0x8040
    for i32 i = 0; i < 26; i++ { t[0x00 + i] = c16[i]; }

    // 32-bit: data segments, CR4.PAE, the kernel's CR3, EFER.LME, then CR0.PG.
    // Paging plus LME => long mode, the far jump activates it.
    u8[63] c32 = { 0xB8, 0x10, 0x00, 0x00, 0x00,              // mov eax,0x10
                   0x8E, 0xD8, 0x8E, 0xC0, 0x8E, 0xD0, 0x8E, 0xE0, 0x8E, 0xE8,
                   0x0F, 0x20, 0xE0, 0x0F, 0xBA, 0xE8, 0x05, 0x0F, 0x22, 0xE0,
                   0xA1, 0x40, 0x81, 0x00, 0x00,              // mov eax,[0x8140]
                   0x0F, 0x22, 0xD8,                          // mov cr3,eax
                   0xB9, 0x80, 0x00, 0x00, 0xC0, 0x0F, 0x32,  // rdmsr EFER
                   0x0F, 0xBA, 0xE8, 0x08, 0x0F, 0x30,        // set LME, wrmsr
                   0x0F, 0x20, 0xC0, 0x0F, 0xBA, 0xE8, 0x1F, 0x0F, 0x22, 0xC0,
                   0xEA, 0xC0, 0x80, 0x00, 0x00, 0x18, 0x00 }; // ljmp 0x18:0x80C0
    for i32 i = 0; i < 63; i++ { t[0x40 + i] = c32[i]; }

    // 64-bit: data segments, then SSE and AVX. minc emits VEX-encoded float
    // instructions, which raise #UD until CR4.OSXSAVE and XCR0 are set, and the
    // firmware does not set them on a core it never started. Then take the
    // stack and finally jump to the entry that was patched in.
    //
    // Flagging 0x8158 right after the stack load is what lets the BSP know the
    // slot is free. Before that store the core is still reading 0x8150.
    u8[64] c64 = { 0x66, 0xB8, 0x20, 0x00,                    // mov ax,0x20
                   0x8E, 0xD8, 0x8E, 0xC0, 0x8E, 0xD0, 0x8E, 0xE0, 0x8E, 0xE8,
                   0x0F, 0x20, 0xE0,                          // mov rax,cr4
                   0x48, 0x0D, 0x00, 0x06, 0x04, 0x00,        // OSFXSR|OSXMMEXCPT|OSXSAVE
                   0x0F, 0x22, 0xE0,                          // mov cr4,rax
                   0x31, 0xC9, 0xB8, 0x07, 0x00, 0x00, 0x00, 0x31, 0xD2,
                   0x0F, 0x01, 0xD1,                          // xsetbv XCR0 = x87|SSE|AVX
                   0x48, 0x8B, 0x24, 0x25, 0x50, 0x81, 0x00, 0x00,   // mov rsp,[0x8150]
                   0xC6, 0x04, 0x25, 0x58, 0x81, 0x00, 0x00, 0x01,   // mov byte [0x8158],1
                   0x48, 0x8B, 0x04, 0x25, 0x48, 0x81, 0x00, 0x00,   // mov rax,[0x8148]
                   0xFF, 0xE0 };                              // jmp rax
    for i32 i = 0; i < 64; i++ { t[0xC0 + i] = c64[i]; }

    // Needs a separate GDT because the kernel's is not reachable from real mode.
    // Null, then 32-bit code and data, then 64-bit code and data.
    u8[40] g = { 0, 0, 0, 0, 0, 0, 0, 0,
                 0xFF, 0xFF, 0, 0, 0, 0x9A, 0xCF, 0,
                 0xFF, 0xFF, 0, 0, 0, 0x92, 0xCF, 0,
                 0xFF, 0xFF, 0, 0, 0, 0x9A, 0xAF, 0,
                 0xFF, 0xFF, 0, 0, 0, 0x92, 0xAF, 0 };
    for i32 i = 0; i < 40; i++ { t[0x100 + i] = g[i]; }

    t[0x130] = 0x27; t[0x131] = 0x00;                         // limit = 40 - 1
    t[0x132] = 0x00; t[0x133] = 0x81;                         // base = 0x8100
    t[0x134] = 0x00; t[0x135] = 0x00;
}

// Core code entry point. Interrupts are off and it has no IDT.
// It records which core it is and halts.
//
// It reads its id from the LAPIC. atomic_add returns the previous value.
void smp_ap_entry() {
    u32 id = lapic_id();
    i32 slot = atomic_add(&smp_online, 1);
    if slot < MAX_CORES { smp_apic_ids[slot] = cast(u8, id); }
    while true { __hlt(); }
}

// Poll a trampoline flag for up to `ms`. True if it was set in time.
bool smp_wait_flag(u8* t, i32 ms) {
    for i32 i = 0; i < ms * 10; i++ {
        if atomic_load(cast(u64*, t + SMP_TAKEN)) != 0 { return true; }
        pit_delay_us(100);
    }
    return false;
}

// Poll the check-in count for up to `ms`. True if it reached `target` in time.
bool smp_wait_online(i32 target, i32 ms) {
    for i32 i = 0; i < ms * 10; i++ {
        if atomic_load(&smp_online) >= target { return true; }
        pit_delay_us(100);
    }
    return false;
}

// Start every enabled core except this one, one at a time, and return how many
// are running including this one.
//
// Serialized because the trampoline page holds a single stack pointer. The next
// core is started only once the previous one has read that slot, which is what
// the stack-taken flag reports. Waiting for the check-in instead would be wrong:
// a core that is merely slow has not reached the stack load yet, and giving up
// on it would hand its stack to the next core as well.
//
// AP  : Application Processors
// CR3 : Control Register 3, holds the page-directory base register (PDBR)
//
i32 smp_start_aps(u64 cr3, u64 entry) {
    // setup trampoline
    smp_build_tramp();
    // patch in values
    u8* t = cast(u8*, SMP_TRAMP);
    *cast(u64*, t + 0x140) = cr3;
    *cast(u64*, t + 0x148) = entry;

    // get current core id (bootstrap processor)
    u32 bsp = lapic_id();

    atomic_store(&smp_online, 0);
    for i32 i = 0; i < acpi_cpu_n; i++ {
        if !acpi_cpus[i].enabled { continue; }
        // skip the core we're currently on
        if cast(u32, acpi_cpus[i].apic_id) == bsp { continue; }

        i32 target = atomic_load(&smp_online) + 1;
        // patch in unique core stack pointer
        u64 stack = smp_alloc_stack();
        // out of stacks? exit loop
        if stack == 0 { break; }
        *cast(u64*, t + 0x150) = stack;
        atomic_store(cast(u64*, t + SMP_TAKEN), 0);

        // INIT, then two SIPIs, at the intervals the MP protocol asks for.
        lapic_send_init(acpi_cpus[i].apic_id);
        pit_delay_us(10000);
        lapic_send_sipi(acpi_cpus[i].apic_id, SMP_VEC);
        pit_delay_us(200);
        lapic_send_sipi(acpi_cpus[i].apic_id, SMP_VEC);
        pit_delay_us(200);

        // A core that never takes its stack never started,
        // re-use the stack for next core
        if !smp_wait_flag(t, 100) {
            smp_stack_idx = smp_stack_idx - 1;
            continue;
        }

        // Then wait for it to report in. Only the count depends on this.
        smp_wait_online(target, 100);
    }
    // add +1 for the bootstrap processor
    return atomic_load(&smp_online) + 1;
}
