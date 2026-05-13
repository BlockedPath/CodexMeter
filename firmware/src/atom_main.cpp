#include <Arduino.h>
#include <ArduinoJson.h>
#include <M5Unified.h>
#include "ble.h"
#include "codex_app_icon.h"
#include "data.h"
#include "pixel_art_screen.h"

static UsageData usage = {};
static int screen = 0;
static ble_state_t last_ble_state = BLE_STATE_INIT;
static char serial_buf[512];
static size_t serial_len = 0;
static int pixel_art_frame = 0;
static uint32_t last_pixel_art = 0;
static M5Canvas pixel_art_canvas(&M5.Display);
static bool pixel_art_canvas_ready = false;

static uint16_t remaining_color(float pct) {
    if (pct <= 20.0f) return RED;
    if (pct <= 50.0f) return ORANGE;
    return GREEN;
}

static void draw_bar(int x, int y, int w, int h, int pct, uint16_t color) {
    pct = constrain(pct, 0, 100);
    M5.Display.drawRoundRect(x, y, w, h, 3, 0x5AEB);
    M5.Display.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, 0x2124);
    int fill = ((w - 2) * pct) / 100;
    if (fill > 0) {
        M5.Display.fillRoundRect(x + 1, y + 1, fill, h - 2, 2, color);
    }
}

static void draw_codex_icon(int x, int y) {
    for (int iy = 0; iy < CODEX_APP_ICON_H; iy++) {
        for (int ix = 0; ix < CODEX_APP_ICON_W; ix++) {
            int idx = iy * CODEX_APP_ICON_W + ix;
            uint8_t a = codex_app_icon_alpha[idx];
            if (a < 16) continue;
            M5.Display.drawPixel(x + ix, y + iy, codex_app_icon_rgb565[idx]);
        }
    }
}

static void draw_header() {
    draw_codex_icon(4, 2);
    M5.Display.setTextDatum(top_left);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(2);
    M5.Display.drawString("Codex", 40, 4);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(0xC618, BLACK);
    M5.Display.drawString("usage", 42, 23);
}

static void fmt_reset(int mins, char* buf, size_t len) {
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

static void draw_usage() {
    M5.Display.fillScreen(BLACK);
    draw_header();

    if (!usage.valid) {
        M5.Display.setTextDatum(middle_center);
        M5.Display.setTextColor(0xC618, BLACK);
        M5.Display.drawString("waiting for host", 64, 76);
        return;
    }

    char reset[16];
    int s = (int)(usage.session_pct + 0.5f);
    int w = (int)(usage.weekly_pct + 0.5f);
    bool has_percent = usage.ok;

    M5.Display.setTextDatum(top_left);
    M5.Display.setTextColor(0xC618, BLACK);
    M5.Display.drawString(has_percent ? "5H LEFT" : "TODAY", 6, 38);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(2);
    M5.Display.drawString(has_percent ? String(s) + "%" : "--", 6, 50);
    draw_bar(6, 73, 116, 11, has_percent ? s : 0, has_percent ? remaining_color(usage.session_pct) : 0x5AEB);
    fmt_reset(usage.session_reset_mins, reset, sizeof(reset));
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(0xC618, BLACK);
    M5.Display.drawString(has_percent ? String("reset ") + reset : usage.status, 6, 87);

    M5.Display.drawString(has_percent ? "WK LEFT" : "WEEK", 6, 100);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(2);
    M5.Display.drawString(has_percent ? String(w) + "%" : "--", 6, 111);
    draw_bar(62, 116, 60, 9, has_percent ? w : 0, has_percent ? remaining_color(usage.weekly_pct) : 0x5AEB);
    if (!has_percent) {
        M5.Display.setTextSize(1);
        M5.Display.setTextColor(ORANGE, BLACK);
        M5.Display.drawString("needs login", 62, 112);
    }
}

static void draw_ble() {
    M5.Display.fillScreen(BLACK);
    M5.Display.setTextDatum(top_center);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(1);
    M5.Display.drawString("Bluetooth", 64, 6);

    const char* state = "Init";
    uint16_t color = 0xC618;
    switch (ble_get_state()) {
        case BLE_STATE_CONNECTED: state = "Connected"; color = GREEN; break;
        case BLE_STATE_ADVERTISING: state = "Advertising"; color = ORANGE; break;
        case BLE_STATE_DISCONNECTED: state = "Disconnected"; color = RED; break;
        default: break;
    }

    M5.Display.setTextDatum(middle_center);
    M5.Display.setTextColor(color, BLACK);
    M5.Display.setTextSize(2);
    M5.Display.drawString(state, 64, 50);

    M5.Display.setTextDatum(top_center);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(0xC618, BLACK);
    M5.Display.drawString(ble_get_device_name(), 64, 84);
    M5.Display.drawString(ble_get_mac_address(), 64, 100);
}

static void draw_pixel_art(bool force = false) {
    uint32_t now = millis();
    int next_frame = pixel_art_frame;
    if (force) {
        next_frame = 0;
        last_pixel_art = now;
    } else if (now - last_pixel_art >= pixel_art_frame_ms[pixel_art_frame]) {
        next_frame = (pixel_art_frame + 1) % PIXEL_ART_FRAMES;
        last_pixel_art = now;
    } else {
        return;
    }

    if (pixel_art_canvas_ready) {
        pixel_art_canvas.fillScreen(BLACK);
    } else {
        M5.Display.fillScreen(BLACK);
    }

    int x0 = (128 - PIXEL_ART_W) / 2;
    int y0 = (128 - PIXEL_ART_H) / 2;
    for (int y = 0; y < PIXEL_ART_H; y++) {
        for (int x = 0; x < PIXEL_ART_W; x++) {
            int idx = y * PIXEL_ART_W + x;
            if (pixel_art_alpha[next_frame][idx] < 16) continue;
            uint16_t color = pixel_art_rgb565[next_frame][idx];
            if (pixel_art_canvas_ready) {
                pixel_art_canvas.drawPixel(x0 + x, y0 + y, color);
            } else {
                M5.Display.drawPixel(x0 + x, y0 + y, color);
            }
        }
    }

    if (pixel_art_canvas_ready) {
        pixel_art_canvas.pushSprite(0, 0);
    }

    pixel_art_frame = next_frame;
}

static void draw_screen(bool force = false) {
    if (screen == 2) {
        draw_pixel_art(force);
        return;
    }
    if (!force) return;
    if (screen == 0) draw_usage();
    else if (screen == 1) draw_ble();
}

static bool parse_json(const char* json, UsageData* out) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    if (err) {
        Serial.printf("JSON parse error: %s\n", err.c_str());
        return false;
    }

    out->session_pct = doc["s"] | 0.0f;
    out->session_reset_mins = doc["sr"] | -1;
    out->weekly_pct = doc["w"] | 0.0f;
    out->weekly_reset_mins = doc["wr"] | -1;
    strlcpy(out->status, doc["st"] | "unknown", sizeof(out->status));
    out->ok = doc["ok"] | false;
    out->valid = true;
    return true;
}

static void handle_payload(const char* data) {
    Serial.printf("RX: %s\n", data);
    if (parse_json(data, &usage)) {
        ble_send_ack();
        if (screen == 0) {
            draw_screen(true);
        }
    } else {
        ble_send_nack();
    }
}

static void poll_serial_json() {
    while (Serial.available() > 0) {
        char c = (char)Serial.read();
        if (c == '\r') continue;
        if (c == '\n') {
            serial_buf[serial_len] = '\0';
            if (serial_len > 0) {
                handle_payload(serial_buf);
            }
            serial_len = 0;
            continue;
        }
        if (serial_len < sizeof(serial_buf) - 1) {
            serial_buf[serial_len++] = c;
        } else {
            serial_len = 0;
        }
    }
}

void setup() {
    Serial.begin(115200);
    delay(1200);
    Serial.println("{\"ready\":true,\"target\":\"AtomS3\"}");
    Serial.flush();

    auto cfg = M5.config();
    cfg.serial_baudrate = 115200;
    cfg.fallback_board = m5::board_t::board_M5AtomS3;
    Serial.println("M5.begin starting");
    Serial.flush();
    M5.begin(cfg);
    Serial.printf("M5.begin done, board=%d, display=%dx%d\n",
                  (int)M5.getBoard(),
                  M5.Display.width(),
                  M5.Display.height());
    Serial.flush();
    M5.Display.setRotation(0);
    M5.Display.setBrightness(160);
    M5.Display.fillScreen(BLACK);
    pixel_art_canvas.setColorDepth(16);
    pixel_art_canvas_ready = pixel_art_canvas.createSprite(128, 128) != nullptr;

    draw_screen(true);
    Serial.println("BLE init starting");
    Serial.flush();
    ble_init();
    Serial.println("BLE init done");
    Serial.flush();
    draw_screen(true);
    Serial.println("AtomS3 dashboard ready, waiting for data on BLE...");
    Serial.flush();
}

void loop() {
    M5.update();
    ble_tick();
    poll_serial_json();

    if (M5.BtnA.wasClicked()) {
        screen = (screen + 1) % 3;
        draw_screen(true);
    }

    if (M5.BtnA.wasHold()) {
        ble_clear_bonds();
        draw_screen(true);
    }

    if (ble_has_data()) {
        handle_payload(ble_get_data());
    }

    ble_state_t state = ble_get_state();
    if (state != last_ble_state) {
        last_ble_state = state;
        if (screen == 1) {
            draw_screen(true);
        }
    }

    if (screen == 2) {
        draw_screen();
    }
    delay(10);
}
