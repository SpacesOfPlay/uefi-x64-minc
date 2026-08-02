// sched.mc - preemptive round-robin scheduler for one core.
//
// A task's whole saved context is its stack pointer. __context_switch pushes
// the six callee-saved registers, stores rsp into the outgoing task, loads the
// incoming task's rsp, pops the six back and returns into wherever that task
// stopped. Nothing else is saved, so a task is one u64.
//
// The timer handler calls sched_tick after EOI and preemption needs no other
// machinery. A new task starts from a bootstrap frame shaped exactly like one
// __context_switch left behind, so the first switch returns into its entry.
//
// The caller owns the stacks. sched_add takes the top of one.

struct Task {
    u64 saved_rsp;     // suspended stack pointer, the whole context
    i32 id;
    i32 used;
}

const i32 SCHED_MAX = 8;

Task[8] sched_tasks;
i32 sched_count = 0;
i32 sched_cur = 0;

// Adopt the running code as task 0. Its saved_rsp is filled in by the first
// switch away from it.
void sched_init() {
    sched_tasks[0].saved_rsp = 0;
    sched_tasks[0].id = 0;
    sched_tasks[0].used = 1;
    sched_count = 1;
    sched_cur = 0;
}

// Create a task starting at `entry`, running on the stack ending at
// `stack_top`. Returns the task id, or -1 when the table is full.
//
// `entry` must call __sti() as its first action. Its first run arrives through
// ret, not iretq, so it inherits interrupts disabled from the switch and would
// never be preempted. It must also never return, since there is no frame below
// it to return into.
i32 sched_add(u64 entry, u64 stack_top) {
    if sched_count >= SCHED_MAX { return -1; }
    i32 i = sched_count;

    // 16-aligned, minus 8, so `entry` sees rsp % 16 == 8. That is what a
    // function expects just after a call pushed the return address.
    u64 sp = ((stack_top >> 4) << 4) - 8;
    sp = sp - 8; *cast(u64*, sp) = entry;   // ret target, popped last
    sp = sp - 8; *cast(u64*, sp) = 0;       // rbp
    sp = sp - 8; *cast(u64*, sp) = 0;       // rbx
    sp = sp - 8; *cast(u64*, sp) = 0;       // r12
    sp = sp - 8; *cast(u64*, sp) = 0;       // r13
    sp = sp - 8; *cast(u64*, sp) = 0;       // r14
    sp = sp - 8; *cast(u64*, sp) = 0;       // r15, popped first

    sched_tasks[i].saved_rsp = sp;
    sched_tasks[i].id = i;
    sched_tasks[i].used = 1;
    sched_count = sched_count + 1;
    return i;
}

// Round-robin to the next task. Call from the timer handler after EOI. A no-op
// until there are at least two tasks.
void sched_tick() {
    if sched_count < 2 { return; }
    i32 old = sched_cur;
    i32 next = old + 1;
    if next >= sched_count { next = 0; }
    sched_cur = next;
    __context_switch(&sched_tasks[old].saved_rsp, sched_tasks[next].saved_rsp);
}
