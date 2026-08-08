/// Low-level CPU I/O: port access, CR3 and MSR. Shared by drivers and the
/// page-table walker so the asm helpers exist in exactly one place.
pub fn out8(port: u16, value: u8) void {
    asm volatile (
        \\outb %[val], %[port]
        :
        : [val] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn in8(port: u16) u8 {
    return asm volatile (
        \\inb %[port], %[val]
        : [val] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn in32(port: u16) u32 {
    return asm volatile ("inl %[port], %[val]"
        : [val] "={eax}" (-> u32),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[v]"
        : [v] "=r" (-> u64),
    );
}

pub fn readMsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [_] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}
