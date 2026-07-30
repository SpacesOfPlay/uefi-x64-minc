# minc on UEFI x64

minc compiles freestanding UEFI applications directly:

```
minc app.mc --target uefi-x64 -o app.efi
```

The output is a bootable PE32+ image. No assembler, no linker, no libc, no
SDK — the compiler writes the file the firmware loads. These examples show
what that unlocks, from "hello" on the firmware console to a bare-metal
timer interrupt.

## Install minc

Install minc first:

```
# Windows
powershell -c "irm minc.dev/install.ps1 | iex"

# macOS / Linux
curl -fsSL https://minc.dev/install | bash
```

## Layout

The examples split at **ExitBootServices** — the point where a UEFI program
stops being the firmware's guest.

| Directory | World | You have |
|---|---|---|
| `uefi/` | Boot services | Console, graphics, files, allocator - on firmware |
| `kernel/` | After ExitBootServices | The hardware. Port I/O, descriptor tables, interrupts |
| `lib/` | Shared | Spec-layout EFI tables and bare-metal helpers the examples import |

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
- Array bounds checking works as on every target; a violation halts.
- Everything else is the ordinary language: structs, imports, `defer`,
  generics, floats.

## Examples

### `uefi/` — the firmware is alive

| File | Shows |
|---|---|
| `01_hello.mc` | A complete UEFI app in one file, no imports. The system table declared from scratch, text out, key in. |
| `02_gop.mc` | Graphics Output Protocol: a linear framebuffer, pixels, scaled bitmap text. |
| `03_memory_map.mc` | GetMemoryMap: what RAM exists and who owns it. |
| `04_files.mc` | The boot volume: opens `\EFI\BOOT\BOOTX64.EFI` and checks its PE signature. |
| `05_runtime.mc` | The runtime contract: back `write`/`alloc`/`free` with boot services and an unmodified portable `main()` runs on the firmware. |

### `kernel/` — the firmware is gone

After ExitBootServices these examples drive COM1 directly, so `run.ps1` boots
them with no VGA device: the QEMU window *is* their serial console.

| File | Shows |
|---|---|
| `01_exit_boot_services.mc` | Crossing the line. Serial console over raw port I/O, the final memory map, control registers, an echo loop. |
| `02_traps.mc` | Own GDT and IDT. A deliberate page fault caught by an `@interrupt_err` minc function: full register dump instead of a triple-fault reboot. |
| `03_lapic_timer.mc` | The local APIC timer calibrated against the PIT, firing an `@interrupt` handler at 100 Hz while the CPU sleeps in `__hlt`. |

## Interrupt handlers

`@interrupt` (no CPU error code) and `@interrupt_err` (vectors that push one:
#PF, #GP, ...) turn a minc function into an interrupt handler. The compiler
emits the register save/restore and the `iretq`; the handler optionally
takes a pointer to the saved frame (`IntrFrame*` / `TrapFrame*`, defined in
`lib/trap.mc`) and may modify it. Writes to the frame change the state the
interrupted code resumes with. The function's address goes straight into an
IDT gate.

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

The examples use the first five groups. The last row is used for a
real kernel functionality like schedulers, ring-3 user code, syscalls.

MMIO note: device registers (like the LAPIC's) must be read and written
through the `atomic_load` / `atomic_store` builtins so the optimizer never
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

Only the symbols a program's builtins actually reach must exist. A program
that never calls `open()` needs no `__minc_open`. `uefi/05_runtime.mc` backs
the contract with boot services in under a hundred lines; a kernel would
back it with its own drivers instead, and the same portable code runs there
too.

## Real hardware

Any example boots from a USB stick: format it FAT32, copy the built `.efi`
to `\EFI\BOOT\BOOTX64.EFI`, and boot with Secure Boot disabled. The `uefi/`
examples talk to the screen; the `kernel/` examples only talk to a serial 
port.
