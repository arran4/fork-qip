const std = @import("std");
const ShiftInt = std.math.Log2Int(usize);
const CodeShift = std.math.Log2Int(u16);

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "image/gif";
const OUTPUT_CONTENT_TYPE = "image/gif";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;
var lzw_in_buf: [INPUT_CAP]u8 = undefined;
var lzw_out_buf: [INPUT_CAP]u8 = undefined;
var index_buf: [INPUT_CAP]u8 = undefined;

var lossy_amount: u32 = 0;
var max_colors: u32 = 256;

const OptimizeError = error{
    InvalidGif,
    OutputOverflow,
};

const PaletteMap = struct {
    old_count: usize,
    padded_count: usize,
    size_code: u8, // value stored in GIF packed field low 3 bits
    changed: bool,
    old_to_new: [256]u8,
    table_bytes: [256 * 3]u8,
};

export fn input_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&input_buf)));
}

export fn input_bytes_cap() u32 {
    return @as(u32, @intCast(INPUT_CAP));
}

export fn output_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(&output_buf)));
}

export fn output_bytes_cap() u32 {
    return @as(u32, @intCast(OUTPUT_CAP));
}

export fn input_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(INPUT_CONTENT_TYPE.ptr)));
}

export fn input_content_type_size() u32 {
    return @as(u32, @intCast(INPUT_CONTENT_TYPE.len));
}

export fn output_content_type_ptr() u32 {
    return @as(u32, @intCast(@intFromPtr(OUTPUT_CONTENT_TYPE.ptr)));
}

export fn output_content_type_size() u32 {
    return @as(u32, @intCast(OUTPUT_CONTENT_TYPE.len));
}

export fn uniform_set_lossy(value: u32) u32 {
    lossy_amount = if (value > 200) 200 else value;
    return lossy_amount;
}

export fn uniform_set_max_colors(value: u32) u32 {
    max_colors = if (value == 0 or value > 256) 256 else value;
    return max_colors;
}

fn writeByte(output: []u8, out_idx: *usize, b: u8) OptimizeError!void {
    if (out_idx.* >= output.len) return error.OutputOverflow;
    output[out_idx.*] = b;
    out_idx.* += 1;
}

fn writeSlice(output: []u8, out_idx: *usize, s: []const u8) OptimizeError!void {
    if (out_idx.* + s.len > output.len) return error.OutputOverflow;
    @memcpy(output[out_idx.* .. out_idx.* + s.len], s);
    out_idx.* += s.len;
}

fn parseSubBlockLength(input: []const u8, pos: *usize) OptimizeError!usize {
    if (pos.* >= input.len) return error.InvalidGif;
    const n = input[pos.*];
    pos.* += 1;
    return n;
}

fn skipSubBlocks(input: []const u8, pos: *usize) OptimizeError!void {
    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) return;
        if (pos.* + block_len > input.len) return error.InvalidGif;
        pos.* += block_len;
    }
}

// Canonical O3-style packing: consolidate data sub-blocks into 255-byte chunks.
fn copySubBlocksRechunk(input: []const u8, pos: *usize, output: []u8, out_idx: *usize) OptimizeError!void {
    var carry: [255]u8 = undefined;
    var carry_len: usize = 0;

    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) break;
        if (pos.* + block_len > input.len) return error.InvalidGif;

        var i: usize = 0;
        while (i < block_len) : (i += 1) {
            carry[carry_len] = input[pos.* + i];
            carry_len += 1;
            if (carry_len == carry.len) {
                try writeByte(output, out_idx, 255);
                try writeSlice(output, out_idx, carry[0..]);
                carry_len = 0;
            }
        }
        pos.* += block_len;
    }

    if (carry_len > 0) {
        try writeByte(output, out_idx, @as(u8, @intCast(carry_len)));
        try writeSlice(output, out_idx, carry[0..carry_len]);
    }
    try writeByte(output, out_idx, 0);
}

fn copyHeaderAndGlobalTable(input: []const u8, output: []u8, out_idx: *usize) OptimizeError!usize {
    if (input.len < 13) return error.InvalidGif;
    const header = input[0..6];
    if (!std.mem.eql(u8, header, "GIF87a") and !std.mem.eql(u8, header, "GIF89a")) {
        return error.InvalidGif;
    }

    try writeSlice(output, out_idx, input[0..13]);

    var pos: usize = 13;
    const packed_fields = input[10];
    if ((packed_fields & 0x80) != 0) {
        const table_bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
        const table_entries: usize = @as(usize, 1) << @as(ShiftInt, @intCast(table_bits));
        const table_len: usize = table_entries * 3;
        if (pos + table_len > input.len) return error.InvalidGif;
        try writeSlice(output, out_idx, input[pos .. pos + table_len]);
        pos += table_len;
    }

    return pos;
}

fn quantizeChannel(value: u8, levels: u16) u8 {
    if (levels <= 1) return 0;

    const max_index: u32 = @as(u32, levels) - 1;
    const index = (@as(u32, value) * max_index + 127) / 255;
    const q = (index * 255 + (max_index / 2)) / max_index;
    return @as(u8, @intCast(q));
}

fn choosePaletteLevels(limit: u32) [3]u16 {
    var levels = [3]u16{ 1, 1, 1 };
    var product: u32 = 1;

    while (true) {
        var best_dim: usize = 3;
        var best_product: u32 = 0;
        var best_level: u16 = std.math.maxInt(u16);

        var dim: usize = 0;
        while (dim < 3) : (dim += 1) {
            const current_level = @as(u32, levels[dim]);
            const candidate = (product / current_level) * (current_level + 1);
            if (candidate > limit) continue;
            if (candidate > best_product or (candidate == best_product and levels[dim] < best_level)) {
                best_dim = dim;
                best_product = candidate;
                best_level = levels[dim];
            }
        }

        if (best_dim == 3) break;
        levels[best_dim] += 1;
        product = best_product;
    }

    return levels;
}

fn pow2CeilAtLeast2(value: usize) usize {
    var p: usize = 2;
    while (p < value and p < 256) : (p <<= 1) {}
    return p;
}

fn log2ExactPow2(value: usize) ShiftInt {
    var bits: ShiftInt = 0;
    var v = value;
    while (v > 1) : (v >>= 1) {
        bits += 1;
    }
    return bits;
}

fn minCodeSizeForPaletteEntries(entries: usize) u8 {
    const bits: u8 = @as(u8, @intCast(log2ExactPow2(entries)));
    return if (bits < 2) 2 else bits;
}

fn buildPaletteMap(table: []const u8, palette_limit: u32) OptimizeError!PaletteMap {
    const entry_count = table.len / 3;
    if (entry_count == 0 or entry_count > 256) return error.InvalidGif;

    var out: PaletteMap = undefined;
    out.old_count = entry_count;
    out.padded_count = entry_count;
    out.size_code = @as(u8, @intCast(log2ExactPow2(entry_count) - 1));
    out.changed = false;

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        out.old_to_new[i] = @as(u8, @intCast(if (i < entry_count) i else 0));
    }
    @memcpy(out.table_bytes[0..table.len], table);
    if (table.len < out.table_bytes.len) {
        @memset(out.table_bytes[table.len..], 0);
    }

    if (palette_limit >= entry_count) {
        return out;
    }

    const levels = choosePaletteLevels(palette_limit);
    var unique_keys: [256]u32 = undefined;
    var unique_count: usize = 0;

    i = 0;
    while (i < entry_count) : (i += 1) {
        const base = i * 3;
        const qr = quantizeChannel(table[base], levels[0]);
        const qg = quantizeChannel(table[base + 1], levels[1]);
        const qb = quantizeChannel(table[base + 2], levels[2]);
        const key = (@as(u32, qr) << 16) | (@as(u32, qg) << 8) | @as(u32, qb);

        var found: usize = unique_count;
        var j: usize = 0;
        while (j < unique_count) : (j += 1) {
            if (unique_keys[j] == key) {
                found = j;
                break;
            }
        }
        if (found == unique_count) {
            unique_keys[unique_count] = key;
            unique_count += 1;
        }
        out.old_to_new[i] = @as(u8, @intCast(found));
    }

    const required_count = if (unique_count < 2) @as(usize, 2) else unique_count;
    const padded_count = pow2CeilAtLeast2(required_count);
    out.padded_count = padded_count;
    out.size_code = @as(u8, @intCast(log2ExactPow2(padded_count) - 1));
    out.changed = true;

    i = 0;
    while (i < padded_count) : (i += 1) {
        const base = i * 3;
        if (i < unique_count) {
            const key = unique_keys[i];
            out.table_bytes[base] = @as(u8, @intCast((key >> 16) & 0xFF));
            out.table_bytes[base + 1] = @as(u8, @intCast((key >> 8) & 0xFF));
            out.table_bytes[base + 2] = @as(u8, @intCast(key & 0xFF));
        } else {
            out.table_bytes[base] = 0;
            out.table_bytes[base + 1] = 0;
            out.table_bytes[base + 2] = 0;
        }
    }
    if (padded_count * 3 < out.table_bytes.len) {
        @memset(out.table_bytes[padded_count * 3 ..], 0);
    }

    return out;
}

fn lossyDerivedPaletteLimit(lossy: u32) u32 {
    if (lossy == 0) return 256;
    const reduction = (lossy * 254 + 199) / 200;
    const limit = if (reduction >= 254) 2 else (256 - reduction);
    return if (limit < 2) 2 else limit;
}

fn effectivePaletteLimit(palette_limit: u32, lossy: u32) u32 {
    const lossy_limit = lossyDerivedPaletteLimit(lossy);
    return if (palette_limit < lossy_limit) palette_limit else lossy_limit;
}

fn collectSubBlocks(input: []const u8, pos: *usize, out: []u8) OptimizeError!usize {
    var out_len: usize = 0;
    while (true) {
        const block_len = try parseSubBlockLength(input, pos);
        if (block_len == 0) return out_len;
        if (pos.* + block_len > input.len) return error.InvalidGif;
        if (out_len + block_len > out.len) return error.OutputOverflow;
        @memcpy(out[out_len .. out_len + block_len], input[pos.* .. pos.* + block_len]);
        out_len += block_len;
        pos.* += block_len;
    }
}

fn writeSubBlocks(output: []u8, out_idx: *usize, data: []const u8) OptimizeError!void {
    var i: usize = 0;
    while (i < data.len) {
        const chunk = @min(@as(usize, 255), data.len - i);
        try writeByte(output, out_idx, @as(u8, @intCast(chunk)));
        try writeSlice(output, out_idx, data[i .. i + chunk]);
        i += chunk;
    }
    try writeByte(output, out_idx, 0);
}

fn lzwDecodeIndices(compressed: []const u8, min_code_size: u8, expected_len: usize, out: []u8) OptimizeError!usize {
    if (min_code_size < 2 or min_code_size > 8) return error.InvalidGif;
    if (expected_len > out.len) return error.OutputOverflow;

    const clear: u16 = @as(u16, 1) << @as(CodeShift, @intCast(min_code_size));
    const end: u16 = clear + 1;
    const first_code: u16 = clear + 2;
    var next_code: u16 = first_code;
    var code_size: u8 = min_code_size + 1;

    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;

    var bit_pos: usize = 0;
    var out_len: usize = 0;
    var old_code: i32 = -1;
    var first_char: u8 = 0;

    while (true) {
        var code: u16 = 0;
        var bit_i: u8 = 0;
        while (bit_i < code_size) : (bit_i += 1) {
            if (bit_pos >= compressed.len * 8) return error.InvalidGif;
            const byte = compressed[bit_pos / 8];
            const bit = (byte >> @as(u3, @intCast(bit_pos & 7))) & 1;
            code |= (@as(u16, bit) << @as(CodeShift, @intCast(bit_i)));
            bit_pos += 1;
        }

        if (code == clear) {
            next_code = first_code;
            code_size = min_code_size + 1;
            old_code = -1;
            continue;
        }
        if (code == end) break;

        if (old_code < 0) {
            if (code >= clear) return error.InvalidGif;
            if (out_len >= expected_len) return error.InvalidGif;
            out[out_len] = @as(u8, @intCast(code));
            out_len += 1;
            first_char = @as(u8, @intCast(code));
            old_code = @as(i32, @intCast(code));
            continue;
        }

        var stack_len: usize = 0;
        const current = code;

        if (current == next_code) {
            var walk = @as(u16, @intCast(old_code));
            while (walk >= clear) {
                if (walk >= 4096 or stack_len >= stack.len) return error.InvalidGif;
                stack[stack_len] = suffix[walk];
                stack_len += 1;
                walk = prefix[walk];
            }
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = @as(u8, @intCast(walk));
            stack_len += 1;
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = first_char;
            stack_len += 1;
            first_char = @as(u8, @intCast(walk));
        } else if (current < next_code) {
            var walk = current;
            while (walk >= clear) {
                if (walk >= 4096 or stack_len >= stack.len) return error.InvalidGif;
                stack[stack_len] = suffix[walk];
                stack_len += 1;
                walk = prefix[walk];
            }
            if (stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = @as(u8, @intCast(walk));
            stack_len += 1;
            first_char = @as(u8, @intCast(walk));
        } else {
            return error.InvalidGif;
        }

        while (stack_len > 0) {
            stack_len -= 1;
            if (out_len >= expected_len) return error.InvalidGif;
            out[out_len] = stack[stack_len];
            out_len += 1;
        }

        if (next_code < 4096) {
            prefix[next_code] = @as(u16, @intCast(old_code));
            suffix[next_code] = first_char;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @as(CodeShift, @intCast(code_size))) and code_size < 12) {
                code_size += 1;
            }
        }

        old_code = @as(i32, @intCast(current));
    }

    if (out_len < expected_len) return error.InvalidGif;
    return out_len;
}

fn findLzwDictEntry(dict_prefix: []const u16, dict_char: []const u8, first_code: u16, next_code: u16, prefix_code: u16, ch: u8) ?u16 {
    var code: u16 = first_code;
    if (next_code < code) return null;
    while (code < next_code) : (code += 1) {
        if (dict_prefix[code] == prefix_code and dict_char[code] == ch) {
            return code;
        }
    }
    return null;
}

fn lzwEncodeIndices(indices: []const u8, min_code_size: u8, out: []u8) OptimizeError!usize {
    if (min_code_size < 2 or min_code_size > 8) return error.InvalidGif;

    const clear: u16 = @as(u16, 1) << @as(CodeShift, @intCast(min_code_size));
    const end: u16 = clear + 1;
    const first_code: u16 = clear + 2;

    var dict_prefix: [4096]u16 = undefined;
    var dict_char: [4096]u8 = undefined;
    var next_code: u16 = first_code;
    var code_size: u8 = min_code_size + 1;

    var out_len: usize = 0;
    var bitbuf: u32 = 0;
    var bitcount: u8 = 0;

    const writeCode = struct {
        fn run(code: u16, code_bits: u8, out_buf: []u8, out_pos: *usize, bit_buffer: *u32, bit_count: *u8) OptimizeError!void {
            bit_buffer.* |= (@as(u32, code) << @as(u5, @intCast(bit_count.*)));
            bit_count.* += code_bits;
            while (bit_count.* >= 8) {
                if (out_pos.* >= out_buf.len) return error.OutputOverflow;
                out_buf[out_pos.*] = @as(u8, @intCast(bit_buffer.* & 0xFF));
                out_pos.* += 1;
                bit_buffer.* >>= 8;
                bit_count.* -= 8;
            }
        }
    }.run;

    try writeCode(clear, code_size, out, &out_len, &bitbuf, &bitcount);

    if (indices.len == 0) {
        try writeCode(end, code_size, out, &out_len, &bitbuf, &bitcount);
    } else {
        var prefix_code: u16 = indices[0];
        var i: usize = 1;
        while (i < indices.len) : (i += 1) {
            const ch = indices[i];
            const found = findLzwDictEntry(dict_prefix[0..], dict_char[0..], first_code, next_code, prefix_code, ch);
            if (found) |code| {
                prefix_code = code;
                continue;
            }

            try writeCode(prefix_code, code_size, out, &out_len, &bitbuf, &bitcount);

            if (next_code < 4096) {
                dict_prefix[next_code] = prefix_code;
                dict_char[next_code] = ch;
                next_code += 1;
                if (next_code == (@as(u16, 1) << @as(CodeShift, @intCast(code_size))) and code_size < 12) {
                    code_size += 1;
                }
            } else {
                try writeCode(clear, code_size, out, &out_len, &bitbuf, &bitcount);
                next_code = first_code;
                code_size = min_code_size + 1;
            }

            prefix_code = @as(u16, ch);
        }

        try writeCode(prefix_code, code_size, out, &out_len, &bitbuf, &bitcount);
        try writeCode(end, code_size, out, &out_len, &bitbuf, &bitcount);
    }

    if (bitcount > 0) {
        if (out_len >= out.len) return error.OutputOverflow;
        out[out_len] = @as(u8, @intCast(bitbuf & 0xFF));
        out_len += 1;
    }

    return out_len;
}

fn countImageDescriptorBlocks(input: []const u8) OptimizeError!u32 {
    if (input.len < 13) return error.InvalidGif;
    if (!std.mem.eql(u8, input[0..6], "GIF87a") and !std.mem.eql(u8, input[0..6], "GIF89a")) {
        return error.InvalidGif;
    }

    var pos: usize = 13;
    const packed_fields = input[10];
    if ((packed_fields & 0x80) != 0) {
        const bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
        const table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
        if (pos + table_len > input.len) return error.InvalidGif;
        pos += table_len;
    }

    var count: u32 = 0;
    while (true) {
        if (pos >= input.len) return error.InvalidGif;
        const block_id = input[pos];
        pos += 1;

        switch (block_id) {
            0x3B => return count,
            0x21 => {
                if (pos >= input.len) return error.InvalidGif;
                const label = input[pos];
                pos += 1;

                switch (label) {
                    0xF9 => {
                        if (pos >= input.len) return error.InvalidGif;
                        const sz = input[pos];
                        pos += 1;
                        if (pos + sz > input.len) return error.InvalidGif;
                        pos += sz;
                        if (pos >= input.len or input[pos] != 0) return error.InvalidGif;
                        pos += 1;
                    },
                    0xFE => try skipSubBlocks(input, &pos),
                    else => {
                        if (pos >= input.len) return error.InvalidGif;
                        const header_sz = input[pos];
                        pos += 1;
                        if (pos + header_sz > input.len) return error.InvalidGif;
                        pos += header_sz;
                        try skipSubBlocks(input, &pos);
                    },
                }
            },
            0x2C => {
                count += 1;
                if (pos + 9 > input.len) return error.InvalidGif;
                const desc = input[pos .. pos + 9];
                pos += 9;
                const desc_packed = desc[8];
                if ((desc_packed & 0x80) != 0) {
                    const bits: u8 = @as(u8, @intCast((desc_packed & 0x07) + 1));
                    const local_table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
                    if (pos + local_table_len > input.len) return error.InvalidGif;
                    pos += local_table_len;
                }
                if (pos >= input.len) return error.InvalidGif;
                pos += 1; // lzw min code size
                try skipSubBlocks(input, &pos);
            },
            else => return error.InvalidGif,
        }
    }
}

fn readU16LE(bytes: []const u8, off: usize) OptimizeError!u16 {
    if (off + 1 >= bytes.len) return error.InvalidGif;
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn pixelCountFromImageDescriptor(desc: []const u8) OptimizeError!usize {
    if (desc.len < 9) return error.InvalidGif;
    const w = try readU16LE(desc, 4);
    const h = try readU16LE(desc, 6);
    if (w == 0 or h == 0) return error.InvalidGif;
    const prod = @as(u64, w) * @as(u64, h);
    if (prod > INPUT_CAP) return error.OutputOverflow;
    return @as(usize, @intCast(prod));
}

fn optimizeGif(input: []const u8, output: []u8, lossy: u32, palette_limit: u32) OptimizeError!usize {
    var out_idx: usize = 0;
    if (palette_limit == 0 or palette_limit > 256) return error.InvalidGif;
    const effective_palette_limit = effectivePaletteLimit(palette_limit, lossy);

    var pos = try copyHeaderAndGlobalTable(input, output, &out_idx);

    const has_global_table = (input[10] & 0x80) != 0;
    var global_map: PaletteMap = undefined;
    var have_global_map = false;
    if (has_global_table) {
        const table_bits: u8 = @as(u8, @intCast((input[10] & 0x07) + 1));
        const table_entries: usize = @as(usize, 1) << @as(ShiftInt, @intCast(table_bits));
        const table_len: usize = table_entries * 3;
        const gct_start: usize = 13;
        const gct_end: usize = gct_start + table_len;
        if (gct_end > input.len) return error.InvalidGif;

        global_map = try buildPaletteMap(input[gct_start..gct_end], effective_palette_limit);
        have_global_map = true;
        if (global_map.changed) {
            out_idx = 13;
            output[10] = (output[10] & 0xF8) | (global_map.size_code & 0x07);
            try writeSlice(output, &out_idx, global_map.table_bytes[0 .. global_map.padded_count * 3]);
        }
        pos = gct_end;
    }

    var pending_gce: [259]u8 = undefined;
    var pending_gce_len: usize = 0;

    while (true) {
        if (pos >= input.len) return error.InvalidGif;
        const block_id = input[pos];
        pos += 1;

        switch (block_id) {
            0x3B => {
                // GIF trailer.
                pending_gce_len = 0;
                try writeByte(output, &out_idx, 0x3B);
                // Preserve any trailing bytes if present.
                if (pos < input.len) try writeSlice(output, &out_idx, input[pos..]);
                return out_idx;
            },
            0x21 => {
                if (pos >= input.len) return error.InvalidGif;
                const label = input[pos];
                pos += 1;

                switch (label) {
                    0xF9 => {
                        // Graphic Control Extension: hold until next rendering block.
                        if (pos >= input.len) return error.InvalidGif;
                        const gce_size = input[pos];
                        pos += 1;
                        if (pos + gce_size > input.len) return error.InvalidGif;
                        if (pos >= input.len) return error.InvalidGif;
                        const gce_data = input[pos .. pos + gce_size];
                        pos += gce_size;
                        const terminator = input[pos];
                        pos += 1;
                        if (terminator != 0) return error.InvalidGif;

                        const total_len: usize = 4 + gce_size;
                        pending_gce[0] = 0x21;
                        pending_gce[1] = 0xF9;
                        pending_gce[2] = gce_size;
                        @memcpy(pending_gce[3 .. 3 + gce_data.len], gce_data);
                        pending_gce[3 + gce_data.len] = 0;
                        pending_gce_len = total_len;
                    },
                    0xFE => {
                        // O3 behavior: strip comment extensions.
                        try skipSubBlocks(input, &pos);
                    },
                    0x01 => {
                        // Plain-text extension is a rendering block.
                        if (pos >= input.len) return error.InvalidGif;
                        const header_size = input[pos];
                        pos += 1;
                        if (pos + header_size > input.len) return error.InvalidGif;
                        const header_data = input[pos .. pos + header_size];
                        pos += header_size;
                        if (pending_gce_len > 0) {
                            try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                            pending_gce_len = 0;
                        }
                        try writeByte(output, &out_idx, 0x21);
                        try writeByte(output, &out_idx, 0x01);
                        try writeByte(output, &out_idx, header_size);
                        try writeSlice(output, &out_idx, header_data);
                        try copySubBlocksRechunk(input, &pos, output, &out_idx);
                    },
                    else => {
                        // Application/unknown extensions: keep, but re-chunk their sub-block payload.
                        if (pos >= input.len) return error.InvalidGif;
                        const header_size = input[pos];
                        pos += 1;
                        if (pos + header_size > input.len) return error.InvalidGif;
                        const header_data = input[pos .. pos + header_size];
                        pos += header_size;

                        try writeByte(output, &out_idx, 0x21);
                        try writeByte(output, &out_idx, label);
                        try writeByte(output, &out_idx, header_size);
                        try writeSlice(output, &out_idx, header_data);
                        try copySubBlocksRechunk(input, &pos, output, &out_idx);
                    },
                }
            },
            0x2C => {
                // Image Descriptor (rendering block).
                if (pos + 9 > input.len) return error.InvalidGif;
                const desc = input[pos .. pos + 9];
                pos += 9;
                var desc_out: [9]u8 = undefined;
                @memcpy(desc_out[0..], desc);

                const packed_fields = desc[8];
                var local_table_len: usize = 0;
                if ((packed_fields & 0x80) != 0) {
                    const bits: u8 = @as(u8, @intCast((packed_fields & 0x07) + 1));
                    local_table_len = (@as(usize, 1) << @as(ShiftInt, @intCast(bits))) * 3;
                }
                if (pos + local_table_len > input.len) return error.InvalidGif;
                const local_table = input[pos .. pos + local_table_len];
                pos += local_table_len;

                if (pos >= input.len) return error.InvalidGif;
                const lzw_min_code_size_in = input[pos];
                pos += 1;

                var local_map: PaletteMap = undefined;
                var active_map: ?*const PaletteMap = null;
                var remap_needed = false;

                if (local_table_len > 0) {
                    local_map = try buildPaletteMap(local_table, effective_palette_limit);
                    active_map = &local_map;
                    remap_needed = local_map.changed;
                    if (local_map.changed) {
                        desc_out[8] = (desc_out[8] & 0xF8) | (local_map.size_code & 0x07);
                    }
                } else if (have_global_map) {
                    active_map = &global_map;
                    remap_needed = global_map.changed;
                }

                if (remap_needed and pending_gce_len >= 8 and pending_gce[1] == 0xF9 and pending_gce[2] >= 4) {
                    const gce_packed = pending_gce[3];
                    if ((gce_packed & 0x01) != 0 and active_map != null) {
                        const old_transparent = pending_gce[6];
                        pending_gce[6] = active_map.?.old_to_new[old_transparent];
                    }
                }

                if (pending_gce_len > 0) {
                    try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                    pending_gce_len = 0;
                }
                try writeByte(output, &out_idx, 0x2C);
                try writeSlice(output, &out_idx, desc_out[0..]);
                if (local_table_len > 0) {
                    if (local_map.changed) {
                        try writeSlice(output, &out_idx, local_map.table_bytes[0 .. local_map.padded_count * 3]);
                    } else {
                        try writeSlice(output, &out_idx, local_table);
                    }
                }

                if (!remap_needed or active_map == null) {
                    try writeByte(output, &out_idx, lzw_min_code_size_in);
                    try copySubBlocksRechunk(input, &pos, output, &out_idx);
                    continue;
                }

                const compressed_len = try collectSubBlocks(input, &pos, lzw_in_buf[0..]);
                const pixel_count = try pixelCountFromImageDescriptor(desc);
                _ = try lzwDecodeIndices(lzw_in_buf[0..compressed_len], lzw_min_code_size_in, pixel_count, index_buf[0..pixel_count]);

                var i: usize = 0;
                while (i < pixel_count) : (i += 1) {
                    index_buf[i] = active_map.?.old_to_new[index_buf[i]];
                }

                const lzw_min_code_size_out = minCodeSizeForPaletteEntries(active_map.?.padded_count);
                try writeByte(output, &out_idx, lzw_min_code_size_out);

                const encoded_len = try lzwEncodeIndices(index_buf[0..pixel_count], lzw_min_code_size_out, lzw_out_buf[0..]);
                try writeSubBlocks(output, &out_idx, lzw_out_buf[0..encoded_len]);
            },
            else => return error.InvalidGif,
        }
    }
}

export fn run(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const out_len = optimizeGif(input_buf[0..input_size], output_buf[0..], lossy_amount, max_colors) catch return 0;
    return @as(u32, @intCast(out_len));
}

test "strips comment extension and keeps valid trailer" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, // LSD with global table
        0x00, 0x00, 0x00, 0xff, 0xff, 0xff, // GCT (2 entries)
        0x21, 0xFE, 0x03, 'a', 'b', 'c', 0x00, // comment ext
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // image desc
        0x02, // LZW min code size
        0x02, 0x44, 0x01, 0x00, // image data
        0x3B, // trailer
    };

    var out: [256]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 0, 256);

    try std.testing.expect(out_len < input.len);
    try std.testing.expectEqual(@as(u8, 0x3B), out[out_len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, out[0..out_len], "abc") == null);
}

test "lossy mode preserves animation frames" {
    const input = [_]u8{
        'G',  'I',  'F',  '8',  '9',  'a',
        0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff,
        0xff,
        // Frame 0
        0x21, 0xF9, 0x04, 0x04, 0x01,
        0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00,
        // Frame 1
        0x21, 0xF9, 0x04, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x2C, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var lossless_out: [512]u8 = undefined;
    const lossless_len = try optimizeGif(input[0..], lossless_out[0..], 0, 256);

    var lossy_out: [512]u8 = undefined;
    const lossy_len = try optimizeGif(input[0..], lossy_out[0..], 100, 256);

    const lossless_frames = try countImageDescriptorBlocks(lossless_out[0..lossless_len]);
    const lossy_frames = try countImageDescriptorBlocks(lossy_out[0..lossy_len]);
    try std.testing.expectEqual(lossless_frames, lossy_frames);
    try std.testing.expectEqual(@as(u32, 2), lossy_frames);
}

test "max_colors quantizes global palette" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x81, 0x00, 0x00, // 4-color global table
        0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x2C, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var out: [512]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 0, 2);
    try std.testing.expect(out_len > 19);
    try std.testing.expectEqual(@as(u8, 0), out[10] & 0x07); // 2-color table

    const table_len: usize = (@as(usize, 1) << @as(ShiftInt, @intCast((out[10] & 0x07) + 1))) * 3;
    try std.testing.expectEqual(@as(usize, 6), table_len);
    const table = out[13 .. 13 + table_len];
    const entry_count = table.len / 3;
    var distinct: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const ib = i * 3;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const jb = j * 3;
            if (table[ib] == table[jb] and table[ib + 1] == table[jb + 1] and table[ib + 2] == table[jb + 2]) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    try std.testing.expect(distinct <= 2);
}

test "lossy can quantize palette without max_colors" {
    const input = [_]u8{
        'G', 'I', 'F', '8', '9', 'a',
        0x01, 0x00, 0x01, 0x00, 0x81, 0x00, 0x00, // 4-color global table
        0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0xFF, 0x2C, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    };

    var out: [512]u8 = undefined;
    const out_len = try optimizeGif(input[0..], out[0..], 200, 256);
    try std.testing.expect(out_len > 19);
    try std.testing.expectEqual(@as(u8, 0), out[10] & 0x07); // lossy drives toward 2 colors

    const table_len: usize = (@as(usize, 1) << @as(ShiftInt, @intCast((out[10] & 0x07) + 1))) * 3;
    const table = out[13 .. 13 + table_len];
    const entry_count = table.len / 3;
    var distinct: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const ib = i * 3;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            const jb = j * 3;
            if (table[ib] == table[jb] and table[ib + 1] == table[jb + 1] and table[ib + 2] == table[jb + 2]) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    try std.testing.expect(distinct <= 2);
}
