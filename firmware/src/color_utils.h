#pragma once
#include <stdint.h>

// Decompose an RGB565 pixel into 8-bit channels (0-255).
inline uint8_t rgb565_r(uint16_t color) {
    return ((color >> 11) & 0x1F) * 255 / 31;
}

inline uint8_t rgb565_g(uint16_t color) {
    return ((color >> 5) & 0x3F) * 255 / 63;
}

inline uint8_t rgb565_b(uint16_t color) {
    return (color & 0x1F) * 255 / 31;
}

// Pack 8-bit RGB channels into an RGB565 pixel.
inline uint16_t make_rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}

// Alpha-blend a tint over a base color.  amount=0 → base, amount=255 → tint.
inline uint16_t blend_rgb565(uint16_t base, uint16_t tint, uint8_t amount) {
    uint8_t inverse = 255 - amount;
    uint8_t r = (rgb565_r(base) * inverse + rgb565_r(tint) * amount) / 255;
    uint8_t g = (rgb565_g(base) * inverse + rgb565_g(tint) * amount) / 255;
    uint8_t b = (rgb565_b(base) * inverse + rgb565_b(tint) * amount) / 255;
    return make_rgb565(r, g, b);
}
