const std = @import("std");
const ShiftInt = std.math.Log2Int(usize);

const INPUT_CAP: usize = 16 * 1024 * 1024;
const OUTPUT_CAP: usize = INPUT_CAP;
const INPUT_CONTENT_TYPE = "image/gif";
const OUTPUT_CONTENT_TYPE = "image/gif";

var input_buf: [INPUT_CAP]u8 = undefined;
var output_buf: [OUTPUT_CAP]u8 = undefined;

var lossy_amount: u32 = 0;

const OptimizeError = error{
    InvalidGif,
    OutputOverflow,
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

fn lossyFrameKeepEvery(lossy: u32) u32 {
    // Mild scaling: lossy starts affecting animations around 25 and ramps up to keep 1/9 frames.
    if (lossy < 25) return 1;
    const step = 1 + (lossy / 25);
    return if (step > 9) 9 else step;
}

fn optimizeGif(input: []const u8, output: []u8, lossy: u32) OptimizeError!usize {
    var out_idx: usize = 0;
    var pos = try copyHeaderAndGlobalTable(input, output, &out_idx);

    const keep_every = lossyFrameKeepEvery(lossy);
    var frame_index: u32 = 0;

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

                        if (lossy > 0) {
                            // Lossy mode may drop plain-text overlays.
                            pending_gce_len = 0;
                            try skipSubBlocks(input, &pos);
                        } else {
                            if (pending_gce_len > 0) {
                                try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                                pending_gce_len = 0;
                            }
                            try writeByte(output, &out_idx, 0x21);
                            try writeByte(output, &out_idx, 0x01);
                            try writeByte(output, &out_idx, header_size);
                            try writeSlice(output, &out_idx, header_data);
                            try copySubBlocksRechunk(input, &pos, output, &out_idx);
                        }
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
                const this_frame = frame_index;
                frame_index += 1;

                if (pos + 9 > input.len) return error.InvalidGif;
                const desc = input[pos .. pos + 9];
                pos += 9;

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
                const lzw_min_code_size = input[pos];
                pos += 1;

                var keep_frame = true;
                if (lossy > 0 and keep_every > 1 and this_frame > 0) {
                    keep_frame = (this_frame % keep_every) == 0;
                }

                if (keep_frame) {
                    if (pending_gce_len > 0) {
                        try writeSlice(output, &out_idx, pending_gce[0..pending_gce_len]);
                        pending_gce_len = 0;
                    }
                    try writeByte(output, &out_idx, 0x2C);
                    try writeSlice(output, &out_idx, desc);
                    if (local_table_len > 0) {
                        try writeSlice(output, &out_idx, local_table);
                    }
                    try writeByte(output, &out_idx, lzw_min_code_size);
                    try copySubBlocksRechunk(input, &pos, output, &out_idx);
                } else {
                    pending_gce_len = 0;
                    try skipSubBlocks(input, &pos);
                }
            },
            else => return error.InvalidGif,
        }
    }
}

export fn run(input_size_in: u32) u32 {
    const input_size = @min(@as(usize, @intCast(input_size_in)), INPUT_CAP);
    const out_len = optimizeGif(input_buf[0..input_size], output_buf[0..], lossy_amount) catch return 0;
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
    const out_len = try optimizeGif(input[0..], out[0..], 0);

    try std.testing.expect(out_len < input.len);
    try std.testing.expectEqual(@as(u8, 0x3B), out[out_len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, out[0..out_len], "abc") == null);
}

test "lossy mode drops later animation frames" {
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
    const lossless_len = try optimizeGif(input[0..], lossless_out[0..], 0);

    var lossy_out: [512]u8 = undefined;
    const lossy_len = try optimizeGif(input[0..], lossy_out[0..], 100);

    try std.testing.expect(lossy_len < lossless_len);
}
