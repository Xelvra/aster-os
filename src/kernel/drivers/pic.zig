const io = @import("../cpu/io.zig");

const pic1_command: u16 = 0x20;
const pic1_data: u16 = 0x21;
const pic2_command: u16 = 0xA0;
const pic2_data: u16 = 0xA1;

const icw1_init: u8 = 0x11;
const icw4_8086: u8 = 0x01;
const pic1_offset: u8 = 0x20;
const pic2_offset: u8 = 0x28;

pub fn remap() void {
    io.out8(pic1_command, icw1_init);
    io.out8(pic2_command, icw1_init);
    io.out8(pic1_data, pic1_offset);
    io.out8(pic2_data, pic2_offset);
    io.out8(pic1_data, 0x04);
    io.out8(pic2_data, 0x02);
    io.out8(pic1_data, icw4_8086);
    io.out8(pic2_data, icw4_8086);
    io.out8(pic1_data, 0xFF);
    io.out8(pic2_data, 0xFF);
}
