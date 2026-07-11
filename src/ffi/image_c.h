#pragma once

#include <resvg.h>
#include <stb_image.h>
#include <stb_image_resize2.h>
#include <stb_image_write.h>

#if RESVG_MAJOR_VERSION == 0 && RESVG_MINOR_VERSION < 47
#error "keywork requires resvg >= 0.47.0"
#endif
