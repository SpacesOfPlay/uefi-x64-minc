// spinlock.mc - a test-and-test-and-set lock on the atomic builtins.
//
// 0 is free, 1 is held. spin_lock reads the word with a relaxed load and only
// attempts the CAS when it reads free. A waiter re-reading keeps the cache
// line shared and puts nothing on the bus.
//
// ACQUIRE on lock and RELEASE on unlock keep the critical section's loads and
// stores from moving out.
//
// There is no interrupt-safe variant. Taking the lock in both ordinary code
// and an interrupt handler on one core deadlocks.

import atomic;

struct Spinlock {
    i32 held;
}

void spin_init(Spinlock* l) {
    atomic_store(&l.held, 0, RELAXED);
}

// Take the lock if it is free, otherwise fail. Never spins.
bool spin_trylock(Spinlock* l) {
    return atomic_cas(&l.held, 0, 1, ACQUIRE, RELAXED);
}

void spin_lock(Spinlock* l) {
    while true {
        if atomic_load(&l.held, RELAXED) == 0 {
            if atomic_cas(&l.held, 0, 1, ACQUIRE, RELAXED) { return; }
        }
        __pause();      // tells the core this is a spin loop
    }
}

void spin_unlock(Spinlock* l) {
    atomic_store(&l.held, 0, RELEASE);
}
