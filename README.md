# minc on UEFI x64

minc compiles freestanding UEFI applications directly:

```
minc app.mc --target uefi-x64 -o app.efi
```

The output is a bootable PE32+ image. No assembler, no linker, no libc, no SDK.
The compiler writes the file the firmware loads. These examples run from
"hello" on the firmware console to a bare-metal timer interrupt.

## Install minc

Install minc first:

```
# Windows
powershell -c "irm minc.dev/install.ps1 | iex"

# macOS / Linux
curl -fsSL https://minc.dev/install | bash
```

## Layout

The examples split at **ExitBootServices**, the call that ends the firmware's
services.

| Directory | World | You have |
|---|---|---|
| `uefi/` | Boot services | Console, graphics, files, allocator - on firmware |
| `kernel/` | After ExitBootServices | The hardware. Port I/O, descriptor tables, interrupts |
| `lib/` | Shared | Spec-layout EFI tables, a framebuffer console, page tables, and bare-metal helpers the examples import |

## Quick start

Requirements: a minc compiler, and QEMU with OVMF firmware
(`pacman -S mingw-w64-x86_64-qemu` under MSYS2, or set `MINC_QEMU` /
`MINC_OVMF_CODE` / `MINC_OVMF_VARS`).

```powershell
$env:MINC = "install\path\"           # or put minc on PATH
./run.ps1 uefi/01_hello.mc            # compile + boot; all output in the QEMU window
```

## The target

- The entry point is `u64 efi_main(void* image_handle, EfiSystemTable* st)`.
  The firmware calls it with the Microsoft x64 convention, so firmware services 
  are reached by calling plain minc function-pointer fields in spec-layout structs.
- `when os(uefi) { }` selects UEFI-specific code at compile time.
- Array bounds checking works as on every target. A violation halts.
- Everything else is the ordinary language: structs, imports, `defer`,
  generics, floats.

## Examples

### `uefi/` - boot services available

| File | Shows |
|---|---|
| `01_hello.mc` | A complete UEFI app in one file, no imports. The system table declared from scratch, text out, key in. |
| `02_gop.mc` | Graphics Output Protocol: a linear framebuffer, pixels, scaled bitmap text. |
| `03_memory_map.mc` | GetMemoryMap: what RAM exists and who owns it. |
| `04_files.mc` | The boot volume: opens `\EFI\BOOT\BOOTX64.EFI` and checks its PE signature. |
| `05_runtime.mc` | The runtime contract: back `write`/`alloc`/`free` with boot services and an unmodified portable `main()` runs on the firmware. |

### `kernel/` - after ExitBootServices

After ExitBootServices there is no console. `lib/console.mc` reads the framebuffer
address from the firmware before the exit, then draws into it with an 8x8
bitmap font. Output also goes to COM1, which `run.ps1 -Headless` tests read.
Input comes from the PS/2 keyboard or the serial port, whichever has a byte
ready.

| File | Shows |
|---|---|
| `01_exit_boot_services.mc` | The handoff. The screen and COM1 captured beforehand, the final memory map, control registers, an echo loop. |
| `02_traps.mc` | Own GDT and IDT. A deliberate fault handled by an `@interrupt_err` minc function: full register dump instead of a triple-fault reboot. |
| `03_lapic_timer.mc` | The local APIC timer calibrated against the PIT, firing an `@interrupt` handler at 100 Hz while the CPU sleeps in `__hlt`. |
| `04_paging.mc` | Stop using the firmware's identity map. A frame allocator over the memory map, fresh 4-level page tables built from it, and a CR3 switch. |
| `05_demand_paging.mc` | A page fault the kernel repairs: allocate a frame, map it at the faulting address, return, and the read resumes. Also one frame mapped at two addresses. |
| `06_threads.mc` | Preemptive round-robin. A task's whole context is its stack pointer, and the timer handler switches between three of them. |
| `07_ring3.mc` | User segments, a TSS, and `__enter_user`. Ring 3 asks the kernel to print through an `int 0x80` gate, then tries a privileged instruction and gets `#GP`. |
| `08_syscall.mc` | A syscall ABI: a number in `rax`, an argument in `rdi`, the result written back into the saved frame. One call sets IF there, and the timer starts preempting ring 3. |
| `09_atomics.mc` | A timer handler observes a multi-store update half done. `__cli` and `__sti` is needed to block interrupts, a test-and-test-and-set spinlock shows the multi-core version. |

## Interrupt handlers

`@interrupt` and `@interrupt_err` turn a minc function into an interrupt
handler. Use `@interrupt_err` on vectors that push an error code, such as #PF
and #GP. The compiler emits the register save/restore and the `iretq`. The
handler may take a pointer to the saved frame, `IntrFrame*` or `TrapFrame*`,
both defined in `lib/trap.mc`. Writes to the frame change the state the
interrupted code resumes with. The function's address goes into an IDT gate.

## Intrinsics

Bare-metal builtins available on this target. No import needed.

| Group | Intrinsics |
|---|---|
| Port I/O | `__inb` `__outb` `__inw` `__outw` |
| CPU control | `__cli` `__sti` `__hlt` `__pause` |
| MSRs | `__rdmsr(msr)` `__wrmsr(msr, val)` `__xsetbv` |
| Control registers | `__read_cr0/2/3/4` `__write_cr0/3/4` |
| Descriptor tables | `__lgdt(ptr)` `__lidt(ptr)` `__ltr(sel)` `__set_segments(cs, ds)` |
| Threads & rings | `__context_switch` `__call_on_stack` `__enter_user` `__leave_user` `__syscall` `__syscall_setup` `__fast_syscall` `__fpu_save` `__fpu_restore` |

The examples use the first five groups. The last row covers schedulers, ring-3
user code and syscalls.

MMIO note: device registers such as the LAPIC's must be read and written
through the `atomic_load` and `atomic_store` builtins, so the optimizer never
caches or hoists the access. `lib/lapic.mc` shows the pattern.

## The runtime contract

On this target the portable builtins compile to calls on `__minc_*` symbols
the program itself provides:

| Builtin | Symbol | | Builtin | Symbol |
|---|---|---|---|---|
| `write` | `__minc_write` | | `alloc` | `__minc_alloc` |
| `read` | `__minc_read` | | `free` | `__minc_free` |
| `open` | `__minc_open` | | `realloc` | `__minc_realloc` |
| `close` | `__minc_close` | | `memcpy` | `__minc_memcpy` |
| `remove` | `__minc_remove` | | `memset` | `__minc_memset` |
| `exit` | `__minc_exit` | | `qpc` / `qpf` | `__minc_qpc` / `__minc_qpf` |
| `get_argc` / `get_arg` | `__minc_argc` / `__minc_arg` | | | |

Only the symbols a program's builtins reach must exist. A program that never
calls `open()` needs no `__minc_open`. `uefi/05_runtime.mc` backs the contract
with boot services in under a hundred lines. A kernel would back it with its
own drivers, and the same portable code runs there.

## Real hardware

Any example boots from a USB stick. Format it FAT32, copy the built `.efi` to
`\EFI\BOOT\BOOTX64.EFI`, and boot with Secure Boot disabled. Every example
draws on the screen. The `kernel/` examples write to COM1 as well.
