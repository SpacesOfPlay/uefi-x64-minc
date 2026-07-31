// paging.mc - build x86-64 4-level page tables and switch to them.
//
// After ExitBootServices the program still runs on the firmware's identity map.
// This builds fresh PML4/PDPT/PD/PT tables out of the frame allocator, maps the
// RAM the firmware reported plus the framebuffer, and loads CR3. Long mode and
// PAE are already on, so writing CR3 is the whole transition, and execution
// continues because virtual equals physical.
//
// Only reported RAM is mapped, not a blanket 4 GiB, so a stray access outside
// it raises #PF instead of reaching unrelated MMIO.

import efi;
import pmm;

u64 PTE_P = 0x1;      // present
u64 PTE_RW = 0x2;     // writable
u64 PTE_US = 0x4;     // user-accessible from ring 3
u64 PTE_PS = 0x80;    // 2 MiB page at the PD level

u64 PAGE_2MB = 0x200000;

u64 paging_pml4 = 0;

// pmm frames carry a stale free-list link, so clear one before use as a table.
void paging_zero_frame(u64 f) {
    u64* p = cast(u64*, f);
    for i32 i = 0; i < 512; i++ { *(p + i) = 0; }
}

// Physical address of the child table at table[idx], allocating and zeroing one
// when the entry is absent. An entry holds a 4 KiB-aligned address in bits
// 12-51, so (e >> 12) << 12 recovers it.
u64 paging_child(u64* table, i32 idx) {
    u64 e = *(table + idx);
    if (e & PTE_P) != 0 { return (e >> 12) << 12; }
    u64 nf = pmm_alloc_frame();
    paging_zero_frame(nf);
    *(table + idx) = nf | PTE_RW | PTE_P;
    return nf;
}

// Map a 2 MiB page. phys must be 2 MiB aligned.
void paging_map_2mb(u64 pml4, u64 virt, u64 phys) {
    i32 i4 = cast(i32, (virt >> 39) & 0x1FF);
    i32 i3 = cast(i32, (virt >> 30) & 0x1FF);
    i32 i2 = cast(i32, (virt >> 21) & 0x1FF);
    u64 pdpt = paging_child(cast(u64*, pml4), i4);
    u64 pd = paging_child(cast(u64*, pdpt), i3);
    u64* t2 = cast(u64*, pd);
    *(t2 + i2) = phys | PTE_PS | PTE_RW | PTE_P;
}

// Map one 4 KiB page. An address that was never mapped before needs no TLB
// flush, so nothing here reloads CR3.
void paging_map_4kb(u64 pml4, u64 virt, u64 phys) {
    i32 i4 = cast(i32, (virt >> 39) & 0x1FF);
    i32 i3 = cast(i32, (virt >> 30) & 0x1FF);
    i32 i2 = cast(i32, (virt >> 21) & 0x1FF);
    i32 i1 = cast(i32, (virt >> 12) & 0x1FF);
    u64 pdpt = paging_child(cast(u64*, pml4), i4);
    u64 pd = paging_child(cast(u64*, pdpt), i3);
    u64 pt = paging_child(cast(u64*, pd), i2);
    u64* t1 = cast(u64*, pt);
    *(t1 + i1) = phys | PTE_RW | PTE_P;
}

// Set US on the 2 MiB page covering `virt` and on every table above it. A
// ring-3 access needs US at all three levels, so all three are marked.
//
// This exposes the whole 2 MiB, which here also holds kernel code. It shows how
// the bit works rather than acting as an isolation boundary. The caller must
// reload CR3 afterwards, because these entries are already in the TLB.
void paging_mark_user_2mb(u64 virt) {
    i32 i4 = cast(i32, (virt >> 39) & 0x1FF);
    i32 i3 = cast(i32, (virt >> 30) & 0x1FF);
    i32 i2 = cast(i32, (virt >> 21) & 0x1FF);
    u64* t4 = cast(u64*, paging_pml4);
    *(t4 + i4) = *(t4 + i4) | PTE_US;
    u64* t3 = cast(u64*, (*(t4 + i4) >> 12) << 12);
    *(t3 + i3) = *(t3 + i3) | PTE_US;
    u64* t2 = cast(u64*, (*(t3 + i3) >> 12) << 12);
    *(t2 + i2) = *(t2 + i2) | PTE_US;
}

// Identity-map [base, end) with 2 MiB pages. base rounds down to a 2 MiB
// boundary, and the last page started below end covers the tail.
void paging_map_range_2mb(u64 base, u64 end) {
    u64 addr = (base >> 21) << 21;
    while addr < end {
        paging_map_2mb(paging_pml4, addr, addr);
        addr = addr + PAGE_2MB;
    }
}

// EFI memory types that are real DRAM. Reserved (0), unusable (8), MMIO (11),
// IO-port space (12) and PAL code (13) are not. Note this keeps boot-services
// and loader memory mapped, which is where the running image, the map buffer
// and the stack live.
bool paging_is_ram(u32 t) {
    if t == 0 || t == 8 || t == 11 || t == 12 || t == 13 { return false; }
    return true;
}

// Build the tables and load CR3. fb_base and fb_bytes describe the framebuffer,
// which is MMIO above RAM and so is not covered by the memory-map walk.
void paging_init(EfiMemoryMap* mm, u64 fb_base, u64 fb_bytes) {
    paging_pml4 = pmm_alloc_frame();
    paging_zero_frame(paging_pml4);

    u8* p = cast(u8*, mm.buffer);
    i64 count = cast(i64, mm.size / mm.descriptor_size);
    for i64 i = 0; i < count; i++ {
        EfiMemoryDescriptor* d = cast(EfiMemoryDescriptor*, p + i * cast(i64, mm.descriptor_size));
        if paging_is_ram(d.type) {
            paging_map_range_2mb(d.physical_start, d.physical_start + d.number_of_pages * 4096);
        }
    }

    if fb_base != 0 { paging_map_range_2mb(fb_base, fb_base + fb_bytes); }

    __write_cr3(paging_pml4);
}
