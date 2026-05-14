#include <Arduino.h>
#include <ArduinoJson.h>
#include <M5Unified.h>
#include <pgmspace.h>
#include "ble.h"
#include "codex_app_icon.h"
#include "data.h"
#include "sukuna_pet.h"

static UsageData usage = {};
static int screen = 0;
static ble_state_t last_ble_state = BLE_STATE_INIT;
static char serial_buf[512];
static size_t serial_len = 0;
static int pet_frame = 0;
static uint8_t selected_pet = 0;
static uint32_t last_pet_frame = 0;
static uint8_t pet_message_idx = 0;
static uint32_t last_pet_message = 0;
static M5Canvas screen_canvas(&M5.Display);
static M5Canvas pet_canvas(&M5.Display);
static M5Canvas message_canvas(&M5.Display);
static bool screen_canvas_ready = false;
static bool pet_canvas_ready = false;
static bool message_canvas_ready = false;

static constexpr uint8_t ATOM_BRIGHTNESS = 72;
static constexpr uint16_t ATOM_BG = 0x0000;
static constexpr uint16_t ATOM_TEXT = 0xD69A;
static constexpr uint16_t ATOM_DIM = 0x8C71;
static constexpr uint16_t ATOM_RULE = 0x2965;
static constexpr uint8_t SCREEN_COUNT = 4;
static constexpr uint16_t PET_MESSAGE_MS = 4000;
static constexpr uint16_t PET_FRAME_MS = 240;
static constexpr int PET_CANVAS_W = 128;
static constexpr int PET_CANVAS_H = 104;
static constexpr int MESSAGE_CANVAS_W = 128;
static constexpr int MESSAGE_CANVAS_H = 24;

enum PetKind : uint8_t {
    PET_KIND_SUKUNA,
    PET_KIND_SHAPE,
};

struct PetDefinition {
    const char* name;
    uint16_t accent;
    PetKind kind;
    uint8_t shape;
};

static const PetDefinition pets[] = {
    {"Sakuna", 0xD69A, PET_KIND_SUKUNA, 0},
    {"Orb", 0xD69A, PET_KIND_SHAPE, 0},
    {"Spark", 0xFD20, PET_KIND_SHAPE, 1},
    {"Pixel", 0x07FF, PET_KIND_SHAPE, 2},
    {"Bloom", 0xF81F, PET_KIND_SHAPE, 3},
};
static constexpr uint8_t PET_COUNT = sizeof(pets) / sizeof(pets[0]);

static const char* const pet_messages[] = {
    "Accomplishing", "Elucidating", "Perusing",
    "Actioning", "Enchanting", "Philosophising",
    "Actualizing", "Envisioning", "Pondering",
    "Baking", "Finagling", "Pontificating",
    "Booping", "Flibbertigibbeting", "Processing",
    "Brewing", "Forging", "Puttering",
    "Calculating", "Forming", "Puzzling",
    "Cerebrating", "Frolicking", "Reticulating",
    "Channelling", "Generating", "Ruminating",
    "Churning", "Germinating", "Scheming",
    "Clauding", "Hatching", "Schlepping",
    "Coalescing", "Herding", "Shimmying",
    "Cogitating", "Honking", "Shucking",
    "Combobulating", "Hustling", "Simmering",
    "Computing", "Ideating", "Smooshing",
    "Concocting", "Imagining", "Spelunking",
    "Conjuring", "Incubating", "Spinning",
    "Considering", "Inferring", "Stewing",
    "Contemplating", "Jiving", "Sussing",
    "Cooking", "Manifesting", "Synthesizing",
    "Crafting", "Marinating", "Thinking",
    "Creating", "Meandering", "Tinkering",
    "Crunching", "Moseying", "Transmuting",
    "Deciphering", "Mulling", "Unfurling",
    "Deliberating", "Mustering", "Unravelling",
    "Determining", "Musing", "Vibing",
    "Discombobulating", "Noodling", "Wandering",
    "Divining", "Percolating", "Whirring",
    "Doing", "Wibbling",
    "Effecting", "Wizarding",
    "Working", "Wrangling",
};
static constexpr uint8_t PET_MESSAGE_COUNT = sizeof(pet_messages) / sizeof(pet_messages[0]);

static void present_canvas() {
    if (screen_canvas_ready) {
        screen_canvas.pushSprite(0, 0);
    }
}

static void present_pet_canvas(int y) {
    if (pet_canvas_ready) {
        pet_canvas.pushSprite(0, y);
    }
}

static void draw_message_strip(const char* message, uint16_t color = ATOM_DIM) {
    if (!message_canvas_ready) return;
    message_canvas.fillScreen(ATOM_BG);
    message_canvas.setTextDatum(top_center);
    message_canvas.setTextColor(color, ATOM_BG);
    message_canvas.setTextSize(1);
    message_canvas.drawString(message, 64, 5);
    message_canvas.drawFastHLine(22, 18, 84, ATOM_RULE);
    message_canvas.pushSprite(0, 0);
}

static uint16_t remaining_color(float pct) {
    if (pct <= 20.0f) return RED;
    if (pct <= 50.0f) return ORANGE;
    return GREEN;
}

static void draw_bar(int x, int y, int w, int h, int pct, uint16_t color) {
    pct = constrain(pct, 0, 100);
    screen_canvas.drawRoundRect(x, y, w, h, 3, 0x5AEB);
    screen_canvas.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, 0x2124);
    int fill = ((w - 2) * pct) / 100;
    if (fill > 0) {
        screen_canvas.fillRoundRect(x + 1, y + 1, fill, h - 2, 2, color);
    }
}

static void draw_codex_icon(int x, int y) {
    for (int iy = 0; iy < CODEX_APP_ICON_H; iy++) {
        for (int ix = 0; ix < CODEX_APP_ICON_W; ix++) {
            int idx = iy * CODEX_APP_ICON_W + ix;
            uint8_t a = codex_app_icon_alpha[idx];
            if (a < 16) continue;
            screen_canvas.drawPixel(x + ix, y + iy, codex_app_icon_rgb565[idx]);
        }
    }
}

static void draw_header() {
    draw_codex_icon(4, 2);
    screen_canvas.setTextDatum(top_left);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(2);
    screen_canvas.drawString("Codex", 40, 4);
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("usage", 42, 23);
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
    screen_canvas.fillScreen(ATOM_BG);
    draw_header();

    if (!usage.valid) {
        screen_canvas.setTextDatum(middle_center);
        screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
        screen_canvas.drawString("waiting for host", 64, 76);
        return;
    }

    char reset[16];
    int s = (int)(usage.session_pct + 0.5f);
    int w = (int)(usage.weekly_pct + 0.5f);
    bool has_percent = usage.ok;

    screen_canvas.setTextDatum(top_left);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString(has_percent ? "5H LEFT" : "TODAY", 6, 38);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(2);
    screen_canvas.drawString(has_percent ? String(s) + "%" : "--", 6, 50);
    draw_bar(6, 73, 116, 11, has_percent ? s : 0, has_percent ? remaining_color(usage.session_pct) : 0x5AEB);
    fmt_reset(usage.session_reset_mins, reset, sizeof(reset));
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString(has_percent ? String("reset ") + reset : usage.status, 6, 87);

    screen_canvas.drawString(has_percent ? "WK LEFT" : "WEEK", 6, 100);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(2);
    screen_canvas.drawString(has_percent ? String(w) + "%" : "--", 6, 111);
    draw_bar(62, 116, 60, 9, has_percent ? w : 0, has_percent ? remaining_color(usage.weekly_pct) : 0x5AEB);
    if (!has_percent) {
        screen_canvas.setTextSize(1);
        screen_canvas.setTextColor(ORANGE, ATOM_BG);
        screen_canvas.drawString("needs login", 62, 112);
    }
}

static void draw_ble() {
    screen_canvas.fillScreen(ATOM_BG);
    screen_canvas.setTextDatum(top_center);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(1);
    screen_canvas.drawString("Bluetooth", 64, 6);

    const char* state = "Init";
    uint16_t color = ATOM_DIM;
    switch (ble_get_state()) {
        case BLE_STATE_CONNECTED: state = "Connected"; color = GREEN; break;
        case BLE_STATE_ADVERTISING: state = "Advertising"; color = ORANGE; break;
        case BLE_STATE_DISCONNECTED: state = "Disconnected"; color = RED; break;
        default: break;
    }

    screen_canvas.setTextDatum(middle_center);
    screen_canvas.setTextColor(color, ATOM_BG);
    screen_canvas.setTextSize(2);
    screen_canvas.drawString(state, 64, 50);

    screen_canvas.setTextDatum(top_center);
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString(ble_get_device_name(), 64, 84);
    screen_canvas.drawString(ble_get_mac_address(), 64, 100);
}

static void reset_pet_animation() {
    pet_frame = 0;
    pet_message_idx = 0;
    last_pet_frame = millis();
    last_pet_message = last_pet_frame;
}

static uint8_t current_pet_frame_count() {
    return pets[selected_pet].kind == PET_KIND_SUKUNA ? SUKUNA_PET_FRAMES : 24;
}

static uint16_t current_pet_frame_ms() {
    if (pets[selected_pet].kind == PET_KIND_SUKUNA) {
        return pgm_read_word(&sukuna_pet_frame_ms[pet_frame % SUKUNA_PET_FRAMES]);
    }
    return PET_FRAME_MS;
}

static void draw_pet_orb(M5Canvas& canvas, int cx, int cy, int pulse, uint16_t accent) {
    canvas.drawCircle(cx, cy, 24 + pulse / 3, ATOM_DIM);
    canvas.drawCircle(cx, cy, 16 + pulse / 4, accent);
    canvas.fillCircle(cx, cy, 6 + pulse / 3, accent);
    canvas.drawFastHLine(cx - 34, cy, 20, ATOM_RULE);
    canvas.drawFastHLine(cx + 14, cy, 20, ATOM_RULE);
    canvas.drawFastVLine(cx, cy - 34, 20, ATOM_RULE);
    canvas.drawFastVLine(cx, cy + 14, 20, ATOM_RULE);
}

static void draw_pet_spark(M5Canvas& canvas, int cx, int cy, int pulse, uint16_t accent) {
    int r = 18 + pulse / 2;
    canvas.drawLine(cx, cy - r - 8, cx, cy + r + 8, accent);
    canvas.drawLine(cx - r - 8, cy, cx + r + 8, cy, accent);
    canvas.drawLine(cx - r, cy - r, cx + r, cy + r, ATOM_DIM);
    canvas.drawLine(cx + r, cy - r, cx - r, cy + r, ATOM_DIM);
    canvas.fillCircle(cx, cy, 5 + pulse / 4, accent);
}

static void draw_pet_pixel(M5Canvas& canvas, int cx, int cy, int pulse, uint16_t accent) {
    int offset = pulse / 2;
    canvas.drawRect(cx - 24, cy - 22 + offset, 48, 42, accent);
    canvas.drawRect(cx - 18, cy - 16 + offset, 36, 30, ATOM_DIM);
    canvas.fillRect(cx - 11, cy - 6 + offset, 6, 6, accent);
    canvas.fillRect(cx + 5, cy - 6 + offset, 6, 6, accent);
    canvas.drawFastHLine(cx - 8, cy + 8 + offset, 16, accent);
    canvas.drawFastVLine(cx - 30, cy - 6 + offset, 12, ATOM_RULE);
    canvas.drawFastVLine(cx + 30, cy - 6 + offset, 12, ATOM_RULE);
}

static void draw_pet_bloom(M5Canvas& canvas, int cx, int cy, int pulse, uint16_t accent) {
    int r = 12 + pulse / 3;
    canvas.fillCircle(cx, cy - r, 9, ATOM_DIM);
    canvas.fillCircle(cx + r, cy, 9, ATOM_DIM);
    canvas.fillCircle(cx, cy + r, 9, ATOM_DIM);
    canvas.fillCircle(cx - r, cy, 9, ATOM_DIM);
    canvas.drawCircle(cx, cy - r, 9, accent);
    canvas.drawCircle(cx + r, cy, 9, accent);
    canvas.drawCircle(cx, cy + r, 9, accent);
    canvas.drawCircle(cx - r, cy, 9, accent);
    canvas.fillCircle(cx, cy, 7 + pulse / 4, accent);
}

static void draw_pet_sukuna(M5Canvas& canvas, int x0, int y0, uint8_t frame) {
    frame %= SUKUNA_PET_FRAMES;
    for (int y = 0; y < SUKUNA_PET_H; y++) {
        for (int x = 0; x < SUKUNA_PET_W; x++) {
            int idx = y * SUKUNA_PET_W + x;
            if (pgm_read_byte(&sukuna_pet_alpha[frame][idx]) < 16) continue;
            uint16_t color = pgm_read_word(&sukuna_pet_rgb565[frame][idx]);
            canvas.drawPixel(x0 + x, y0 + y, color);
        }
    }
}

static void draw_pet_preview(M5Canvas& canvas, int cx, int cy, int pulse, uint8_t pet_idx) {
    const PetDefinition& pet = pets[pet_idx % PET_COUNT];
    if (pet.kind == PET_KIND_SUKUNA) {
        draw_pet_sukuna(canvas, (PET_CANVAS_W - SUKUNA_PET_W) / 2, 0, pet_frame);
        return;
    }

    switch (pet.shape) {
        case 1: draw_pet_spark(canvas, cx, cy, pulse, pet.accent); break;
        case 2: draw_pet_pixel(canvas, cx, cy, pulse, pet.accent); break;
        case 3: draw_pet_bloom(canvas, cx, cy, pulse, pet.accent); break;
        default: draw_pet_orb(canvas, cx, cy, pulse, pet.accent); break;
    }
}

static void draw_pet_frame_region(int y, int cy, int pulse) {
    if (!pet_canvas_ready) return;
    pet_canvas.fillScreen(ATOM_BG);
    draw_pet_preview(pet_canvas, 64, cy, pulse, selected_pet);
    present_pet_canvas(y);
}

static void draw_pet(bool force = false) {
    uint32_t now = millis();
    int next_frame = pet_frame;
    bool redraw = force;
    bool redraw_shell = force;
    if (force) {
        next_frame = 0;
        last_pet_frame = now;
        last_pet_message = now;
    } else if (now - last_pet_frame >= current_pet_frame_ms()) {
        next_frame = (pet_frame + 1) % current_pet_frame_count();
        last_pet_frame = now;
        redraw = true;
    }

    if (!force && now - last_pet_message >= PET_MESSAGE_MS) {
        pet_message_idx = (pet_message_idx + 1) % PET_MESSAGE_COUNT;
        last_pet_message = now;
        redraw = true;
        redraw_shell = true;
    }

    if (!redraw) {
        return;
    }

    if (force) {
        pet_message_idx = 0;
    }

    if (redraw_shell) {
        screen_canvas.fillScreen(ATOM_BG);
        present_canvas();
    }

    pet_frame = next_frame;

    int pulse = next_frame < 12 ? next_frame : 24 - next_frame;
    draw_pet_frame_region(24, pets[selected_pet].kind == PET_KIND_SUKUNA ? 48 : 44, pulse);
    draw_message_strip(pet_messages[pet_message_idx]);
}

static void draw_pet_select(bool force = false) {
    uint32_t now = millis();
    if (now - last_pet_frame >= current_pet_frame_ms()) {
        pet_frame = (pet_frame + 1) % current_pet_frame_count();
        last_pet_frame = now;
    } else if (!force) {
        return;
    }

    if (force) {
        screen_canvas.fillScreen(ATOM_BG);
        present_canvas();
    }

    int pulse = pet_frame < 12 ? pet_frame : 24 - pet_frame;
    draw_pet_frame_region(22, pets[selected_pet].kind == PET_KIND_SUKUNA ? 48 : 37, pulse);
    String label = String(pets[selected_pet].name) + " " + String(selected_pet + 1) + "/" + String(PET_COUNT);
    draw_message_strip(label.c_str(), pets[selected_pet].accent);
}

static void select_next_pet() {
    selected_pet = (selected_pet + 1) % PET_COUNT;
    reset_pet_animation();
    draw_pet_select(true);
}

static void draw_screen(bool force = false) {
    if (screen == 2) {
        draw_pet(force);
        return;
    }
    if (screen == 3) {
        draw_pet_select(force);
        return;
    }
    if (!force) return;
    if (screen == 0) draw_usage();
    else if (screen == 1) draw_ble();
    present_canvas();
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
    M5.Display.setBrightness(ATOM_BRIGHTNESS);
    M5.Display.fillScreen(ATOM_BG);
    screen_canvas.setColorDepth(16);
    screen_canvas_ready = screen_canvas.createSprite(128, 128) != nullptr;
    pet_canvas.setColorDepth(16);
    pet_canvas_ready = pet_canvas.createSprite(PET_CANVAS_W, PET_CANVAS_H) != nullptr;
    message_canvas.setColorDepth(16);
    message_canvas_ready = message_canvas.createSprite(MESSAGE_CANVAS_W, MESSAGE_CANVAS_H) != nullptr;

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
        screen = (screen + 1) % SCREEN_COUNT;
        draw_screen(true);
    }

    if (M5.BtnA.wasHold()) {
        if (screen == 3) {
            select_next_pet();
        } else if (screen == 1) {
            ble_clear_bonds();
            draw_screen(true);
        }
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

    if (screen == 2 || screen == 3) {
        draw_screen();
    }
    delay(10);
}
