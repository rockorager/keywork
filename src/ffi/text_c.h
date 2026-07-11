#include <stdint.h>
#include <stdio.h>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_TRUETYPE_TABLES_H
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

/// Fontconfig's sorted candidate list for a set of required codepoints.
/// Unlike FcFontMatch, the full FcFontSort order lets callers walk past
/// candidates whose real cmap or shaping coverage falls short of what
/// the fontconfig charset promised. Destroy with
/// keywork_fontconfig_sort_destroy.
static inline FcFontSet *keywork_fontconfig_sort_codepoints(const uint32_t *codepoints, unsigned int count, int prefer_color) {
    if (!FcInit()) return NULL;

    FcPattern *pattern = FcNameParse((const FcChar8 *)"sans");
    if (!pattern) return NULL;
    if (prefer_color) FcPatternAddBool(pattern, FC_COLOR, FcTrue);

    if (count > 0) {
        FcCharSet *charset = FcCharSetCreate();
        if (!charset) {
            FcPatternDestroy(pattern);
            return NULL;
        }
        int ok = 1;
        for (unsigned int i = 0; i < count; i += 1) {
            ok = ok && FcCharSetAddChar(charset, (FcChar32)codepoints[i]);
        }
        ok = ok && FcPatternAddCharSet(pattern, FC_CHARSET, charset);
        FcCharSetDestroy(charset);
        if (!ok) {
            FcPatternDestroy(pattern);
            return NULL;
        }
    }

    FcConfigSubstitute(NULL, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);

    FcResult result = FcResultNoMatch;
    FcFontSet *set = FcFontSort(NULL, pattern, FcTrue, NULL, &result);
    FcPatternDestroy(pattern);
    return set;
}

static inline unsigned int keywork_fontconfig_sort_count(const FcFontSet *set) {
    return set ? (unsigned int)set->nfont : 0;
}

/// 1 when the candidate's fontconfig charset claims every codepoint.
/// Cheap pre-filter so callers only load fonts worth verifying.
static inline int keywork_fontconfig_sort_covers(FcFontSet *set, unsigned int index, const uint32_t *codepoints, unsigned int count) {
    if (!set || index >= (unsigned int)set->nfont) return 0;
    FcCharSet *charset = NULL;
    if (FcPatternGetCharSet(set->fonts[index], FC_CHARSET, 0, &charset) != FcResultMatch || !charset) return 0;
    for (unsigned int i = 0; i < count; i += 1) {
        if (!FcCharSetHasChar(charset, (FcChar32)codepoints[i])) return 0;
    }
    return 1;
}

static inline int keywork_fontconfig_sort_path(FcFontSet *set, unsigned int index, char *out, size_t out_len) {
    if (!set || index >= (unsigned int)set->nfont || out_len == 0) return 0;
    out[0] = '\0';

    FcChar8 *file = NULL;
    if (FcPatternGetString(set->fonts[index], FC_FILE, 0, &file) != FcResultMatch || file == NULL) return 0;
    int written = snprintf(out, out_len, "%s", (const char *)file);
    return written > 0 && (size_t)written < out_len;
}

static inline void keywork_fontconfig_sort_destroy(FcFontSet *set) {
    if (set) FcFontSetDestroy(set);
}

static inline unsigned int keywork_ft_get_char_index(FT_Face face, uint32_t codepoint) {
    return FT_Get_Char_Index(face, (FT_ULong)codepoint);
}

/// Bitmap-strike fonts reject exact FT_Set_Pixel_Sizes; select the
/// nearest fixed strike instead.
static inline int keywork_ft_select_size(FT_Face face, unsigned int pixel_size) {
    if (FT_Set_Pixel_Sizes(face, 0, pixel_size) == 0) return 1;
    if (face->num_fixed_sizes <= 0) return 0;
    int best = 0;
    long best_delta = -1;
    for (int i = 0; i < face->num_fixed_sizes; i++) {
        long height = face->available_sizes[i].height;
        long delta = height > (long)pixel_size ? height - (long)pixel_size : (long)pixel_size - height;
        if (best_delta < 0 || delta < best_delta) {
            best_delta = delta;
            best = i;
        }
    }
    return FT_Select_Size(face, best) == 0;
}

static inline int keywork_ft_set_pixel_size(FT_Face face, unsigned int pixels) {
    return keywork_ft_select_size(face, pixels);
}

/// Loads and rasterizes a glyph, shifting the outline right by
/// subpixel_x (26.6 fixed point) before rendering so fractional pen
/// positions are baked into the coverage. Bitmap strikes cannot shift
/// and render at their integer position.
static inline int keywork_ft_load_render_glyph(FT_Face face, unsigned int glyph_index, long subpixel_x) {
    if (FT_Load_Glyph(face, glyph_index, FT_LOAD_COLOR) != 0) return 0;
    if (face->glyph->format == FT_GLYPH_FORMAT_BITMAP) return 1;
    if (subpixel_x != 0 && face->glyph->format == FT_GLYPH_FORMAT_OUTLINE) {
        FT_Outline_Translate(&face->glyph->outline, subpixel_x, 0);
    }
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

/// 1 when the loaded glyph is a premultiplied BGRA color bitmap.
static inline int keywork_ft_bitmap_is_color(FT_Face face) {
    return face->glyph->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
}

/// The strike size actually selected for bitmap fonts; equals the
/// requested pixel size for scalable fonts.
static inline unsigned int keywork_ft_y_ppem(FT_Face face) {
    return face->size->metrics.y_ppem;
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

// Cap height at the current pixel size, or 0 when the font has no OS/2
// table (callers approximate with ~0.7em).
static inline int keywork_ft_cap_height(FT_Face face) {
    TT_OS2 *os2 = (TT_OS2 *)FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
    if (!os2 || os2->sCapHeight <= 0) return 0;
    return (int)(FT_MulFix(os2->sCapHeight, face->size->metrics.y_scale) >> 6);
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
