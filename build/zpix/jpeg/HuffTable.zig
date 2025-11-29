// lut_size is the log-2 size of the Huffman decoder's look-up table.
pub const lut_size = 8;
// max_num_codes is the maximum (inclusive) number of codes in a Huffman tree.
pub const max_num_codes = 256;
// max_code_length is the maximum (inclusive) number of bits in a Huffman code.
pub const max_code_length = 16;

const HuffTable = @This();

// num_codes is the number of codes in the tree
num_codes: i32 = 0,
// lut is the look-up table for the next lut_size bits in the bit-stream.
// The high 8 bits of the u16 are the encoded value. The low 8 bits
// are 1 plus the code length, or 0 if the value is too large to fit in
// lut_size bits.
lut: [1 << lut_size]u16 = [_]u16{0} ** (1 << lut_size),
// vals are the decoded values, sorted by their encoding.
vals: [max_num_codes]u8 = [_]u8{0} ** max_num_codes,
// min_codes[i] is the minimum code of length i, or -1 if there are no
// codes of that length.
min_codes: [max_num_codes]i32 = [_]i32{0} ** max_num_codes,
// max_codes[i] is the maximum code of length i, or -1 if there are no
// codes of that length.
max_codes: [max_num_codes]i32 = [_]i32{0} ** max_num_codes,
// valsIndices[i] is the index into vals of min_codes[i].
vals_indices: [max_num_codes]i32 = [_]i32{0} ** max_num_codes,

pub fn clearLut(self: *HuffTable) void {
    for (&self.lut) |*x| {
        x.* = 0;
    }
}
