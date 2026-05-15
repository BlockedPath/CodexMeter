#pragma once
#include <stdint.h>

// Format a reset-time in minutes as a compact string ("--", "5m", "2h30", "1d05h").
// Passes through snprintf, never overflows.
inline void fmt_reset(int mins, char* buf, size_t len) {
    if (mins < 0) {
        snprintf(buf, len, "--");
    } else if (mins < 60) {
        snprintf(buf, len, "%dm", mins);
    } else if (mins < 1440) {
        snprintf(buf, len, "%dh%02d", mins / 60, mins % 60);
    } else {
        snprintf(buf, len, "%dd%02dh", mins / 1440, (mins % 1440) / 60);
    }
}
