//! Build-generated SPIR-V for the Vulkan compositor pipelines.

const std = @import("std");

pub const quad_instanced = spirvWords(@embedFile("vulkan-quad"));
pub const solid_instanced = spirvWords(@embedFile("vulkan-solid"));
pub const image_alpha_instanced = spirvWords(@embedFile("vulkan-image"));
pub const crossfade_instanced = spirvWords(@embedFile("vulkan-crossfade"));
pub const image_nearest_instanced = spirvWords(@embedFile("vulkan-image-nearest"));
pub const image_nearest_gamma22_instanced = spirvWords(@embedFile("vulkan-image-nearest-gamma22"));
pub const backdrop_image_instanced = spirvWords(@embedFile("vulkan-backdrop-image"));
pub const image_catmull_rom_instanced = spirvWords(@embedFile("vulkan-image-catmull-rom"));
pub const image_area_instanced = spirvWords(@embedFile("vulkan-image-area"));
pub const video_manual_instanced = spirvWords(@embedFile("vulkan-video-manual"));
pub const shadow_instanced = spirvWords(@embedFile("vulkan-shadow"));
pub const blur_downsample = spirvWords(@embedFile("vulkan-blur-downsample"));
pub const blur_upsample = spirvWords(@embedFile("vulkan-blur-upsample"));
pub const output_encode = spirvWords(@embedFile("vulkan-encode"));
pub const output_encode_calibrated = spirvWords(@embedFile("vulkan-encode-calibrated"));

fn spirvWords(comptime bytes: []const u8) [bytes.len / @sizeOf(u32)]u32 {
    @setEvalBranchQuota(50_000);
    comptime std.debug.assert(bytes.len >= @sizeOf(u32));
    comptime std.debug.assert(bytes.len % @sizeOf(u32) == 0);

    var words: [bytes.len / @sizeOf(u32)]u32 = undefined;
    for (&words, 0..) |*word, index| {
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    }
    std.debug.assert(words[0] == 0x07230203);
    return words;
}
