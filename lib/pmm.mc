// pmm.mc - physical page-frame allocator.
//
// Free 4 KiB frames are kept on a singly linked list threaded through the free
// frames themselves. Each free frame's first 8 bytes hold the next frame's
// physical address, so the allocator needs no metadata of its own. This works
// because UEFI identity-maps RAM, so a physical address is usable as a pointer.

import efi;

const u64 PMM_FRAME = 4096;

u64 pmm_free_head = 0;      // physical address of the first free frame, 0 = empty
u64 pmm_free_count = 0;
u64 pmm_total_count = 0;

// The AP trampoline loads CR3 from 32-bit code, so the root page table has to be
// addressable in 32 bits. pmm_init keeps the first frame under this limit off the
// free list and pmm_alloc_low_frame hands it out. It becomes the live PML4 and
// is never returned.
const u64 PMM_LOW_LIMIT = 0x100000000;
u64 pmm_low_frame = 0;

void pmm_free_frame(u64 frame) {
    *cast(u64*, frame) = pmm_free_head;
    pmm_free_head = frame;
    pmm_free_count = pmm_free_count + 1;
}

// The reserved frame below PMM_LOW_LIMIT, or 0 once it is taken. Counted as free
// until then, so frame accounting matches pmm_alloc_frame.
u64 pmm_alloc_low_frame() {
    if pmm_low_frame == 0 { return 0; }
    u64 f = pmm_low_frame;
    pmm_low_frame = 0;
    pmm_free_count = pmm_free_count - 1;
    return f;
}

// Returns a frame's physical address, or 0 when RAM runs out. The frame still
// holds its stale free-list link, so zero it before use as a page table.
u64 pmm_alloc_frame() {
    if pmm_free_head == 0 { return 0; }
    u64 f = pmm_free_head;
    pmm_free_head = *cast(u64*, f);
    pmm_free_count = pmm_free_count - 1;
    return f;
}

// Put every conventional-memory frame at or above 1 MiB on the free list. What
// the firmware reserved is not EfiConventionalMemory and stays untouched: the
// loaded image, the framebuffer, the map buffer, the stack.
//
// EfiBootServicesCode and Data also become free at the exit, but this program
// runs on the firmware's stack, which lives in boot-services memory. Claiming
// those types would hand out the stack in use.
void pmm_init(EfiMemoryMap* mm) {
    // Stride by descriptor_size, which the firmware reports separately and may
    // exceed sizeof(EfiMemoryDescriptor).
    u64 pos = cast(u64, mm.buffer);
    u64 end = pos + mm.size;
    while pos < end {
        EfiMemoryDescriptor* d = cast(EfiMemoryDescriptor*, pos);
        if d.type == EFI_CONVENTIONAL_MEMORY {
            for u64 j = 0; j < d.number_of_pages; j++ {
                u64 frame = d.physical_start + j * PMM_FRAME;
                if frame < 0x100000 { continue; }                 // skip below 1 MiB
                if pmm_low_frame == 0 && frame < PMM_LOW_LIMIT {
                    pmm_low_frame = frame;                        // reserve the PML4
                    pmm_free_count = pmm_free_count + 1;
                    continue;
                }
                pmm_free_frame(frame);
            }
        }
        pos = pos + mm.descriptor_size;
    }
    pmm_total_count = pmm_free_count;
}

u64 pmm_free_mb() { return pmm_free_count * PMM_FRAME / (1024 * 1024); }
