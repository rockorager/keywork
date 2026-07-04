#include <stdint.h>
#include <stdio.h>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb-ft.h>
#include <hb.h>

typedef struct {
    uint32_t glyph_index;
    int32_t x_advance;
    int32_t y_advance;
    int32_t x_offset;
    int32_t y_offset;
} KeyworkGlyph;

static inline int keywork_fontconfig_match_default(char *out, size_t out_len) {
    if (out_len == 0) return 0;
    out[0] = '\0';

    if (!FcInit()) return 0;

    FcPattern *pattern = FcNameParse((const FcChar8 *)"sans");
    if (!pattern) return 0;

    FcConfigSubstitute(NULL, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);

    FcResult result = FcResultNoMatch;
    FcPattern *match = FcFontMatch(NULL, pattern, &result);
    FcPatternDestroy(pattern);
    if (!match) return 0;

    FcChar8 *file = NULL;
    int ok = FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch && file != NULL;
    if (ok) {
        int written = snprintf(out, out_len, "%s", (const char *)file);
        ok = written > 0 && (size_t)written < out_len;
    }

    FcPatternDestroy(match);
    return ok;
}

static inline int keywork_fontconfig_match_codepoint(uint32_t codepoint, char *out, size_t out_len) {
    if (out_len == 0) return 0;
    out[0] = '\0';

    if (!FcInit()) return 0;

    FcPattern *pattern = FcNameParse((const FcChar8 *)"sans");
    if (!pattern) return 0;

    FcCharSet *charset = FcCharSetCreate();
    if (!charset) {
        FcPatternDestroy(pattern);
        return 0;
    }
    int ok = FcCharSetAddChar(charset, (FcChar32)codepoint) && FcPatternAddCharSet(pattern, FC_CHARSET, charset);
    FcCharSetDestroy(charset);
    if (!ok) {
        FcPatternDestroy(pattern);
        return 0;
    }

    FcConfigSubstitute(NULL, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);

    FcResult result = FcResultNoMatch;
    FcPattern *match = FcFontMatch(NULL, pattern, &result);
    FcPatternDestroy(pattern);
    if (!match) return 0;

    FcChar8 *file = NULL;
    ok = FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch && file != NULL;
    if (ok) {
        int written = snprintf(out, out_len, "%s", (const char *)file);
        ok = written > 0 && (size_t)written < out_len;
    }

    FcPatternDestroy(match);
    return ok;
}

static inline unsigned int keywork_ft_get_char_index(FT_Face face, uint32_t codepoint) {
    return FT_Get_Char_Index(face, (FT_ULong)codepoint);
}

static inline int keywork_ft_set_pixel_size(FT_Face face, unsigned int pixels) {
    return FT_Set_Pixel_Sizes(face, 0, pixels) == 0;
}

static inline int keywork_ft_load_render_glyph(FT_Face face, unsigned int glyph_index) {
    if (FT_Load_Glyph(face, glyph_index, FT_LOAD_DEFAULT) != 0) return 0;
    return FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) == 0;
}

static inline unsigned int keywork_ft_bitmap_width(FT_Face face) {
    return face->glyph->bitmap.width;
}

static inline unsigned int keywork_ft_bitmap_rows(FT_Face face) {
    return face->glyph->bitmap.rows;
}

static inline int keywork_ft_bitmap_pitch(FT_Face face) {
    return face->glyph->bitmap.pitch;
}

static inline unsigned char *keywork_ft_bitmap_buffer(FT_Face face) {
    return face->glyph->bitmap.buffer;
}

static inline int keywork_ft_bitmap_left(FT_Face face) {
    return face->glyph->bitmap_left;
}

static inline int keywork_ft_bitmap_top(FT_Face face) {
    return face->glyph->bitmap_top;
}

static inline int keywork_ft_ascender(FT_Face face) {
    return (int)(face->size->metrics.ascender >> 6);
}

static inline int keywork_ft_line_height(FT_Face face) {
    return (int)(face->size->metrics.height >> 6);
}

static inline hb_font_t *keywork_hb_font_create(FT_Face face) {
    return hb_ft_font_create_referenced(face);
}

static inline unsigned int keywork_hb_shape_text(hb_font_t *font, const char *text, int len, KeyworkGlyph *out, unsigned int max) {
    hb_buffer_t *buffer = hb_buffer_create();
    if (!buffer) return 0;

    hb_buffer_add_utf8(buffer, text, len, 0, len);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font, buffer, NULL, 0);

    unsigned int count = 0;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &count);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);
    if (count > max) count = max;

    for (unsigned int i = 0; i < count; i += 1) {
        out[i].glyph_index = infos[i].codepoint;
        out[i].x_advance = positions[i].x_advance;
        out[i].y_advance = positions[i].y_advance;
        out[i].x_offset = positions[i].x_offset;
        out[i].y_offset = positions[i].y_offset;
    }

    hb_buffer_destroy(buffer);
    return count;
}
