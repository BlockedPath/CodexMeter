#include <Arduino.h>
#include <ArduinoJson.h>
#include <M5Unified.h>
#include <Preferences.h>
#include "ble.h"
#include "color_utils.h"
#include "text_utils.h"
#include "data.h"
#include "codex_icon.h"
#include "boba_sprite.h"
#include "gojo_sprite.h"
#include "itachi_sprite.h"
#include "sukuna_sprite.h"

static UsageData usage = {};
static int screen = 0;
static uint8_t active_pet = 0;
static ble_state_t last_ble_state = BLE_STATE_INIT;
static char serial_buf[512];
static size_t serial_len = 0;
static int pet_frame = 0;
static uint8_t pet_anim_state = 0;
static uint32_t last_pet_frame = 0;
static uint8_t pet_message_idx = 0;
static uint32_t last_pet_message = 0;
static M5Canvas screen_canvas(&M5.Display);
static bool screen_canvas_ready = false;
static Preferences preferences;

static constexpr uint8_t ATOM_BRIGHTNESS = 72;
static constexpr uint8_t SCREEN_COUNT = 5;
static constexpr uint16_t ATOM_BG = 0x0000;
static constexpr uint16_t ATOM_TEXT = 0xD69A;
static constexpr uint16_t ATOM_DIM = 0x8C71;
static constexpr uint16_t ATOM_RULE = 0x2965;
static constexpr uint16_t ATOM_CARD = 0x0841;
static constexpr uint16_t CODEX_WHITE = 0xF7BE;
static constexpr uint16_t PET_ACCENT = 0xF6C7;
static constexpr uint16_t PET_MESSAGE_MS = 4000;
static constexpr uint16_t PET_SPRITE_W = 52;
static constexpr uint16_t PET_SPRITE_H = 80;
static constexpr uint16_t PET_SPRITE_PIXELS = PET_SPRITE_W * PET_SPRITE_H;

struct PetStyle {
    const char* name;
    uint16_t accent;
    uint16_t card;
    uint8_t state_count;
    const uint16_t* state_offset;
    const uint8_t* state_count_frames;
    const uint16_t* frame_ms;
    const uint16_t (*rgb565)[PET_SPRITE_PIXELS];
    const uint8_t (*alpha)[PET_SPRITE_PIXELS];
};

static const PetStyle pet_styles[] = {
    {"Sukuna", PET_ACCENT, ATOM_CARD, PET_SUKUNA_STATE_COUNT, pet_sukuna_state_offset, pet_sukuna_state_count, pet_sukuna_frame_ms, pet_sukuna_rgb565, pet_sukuna_alpha},
    {"Boba",  0x8EFD, 0x1008, PET_BOBA_STATE_COUNT, pet_boba_state_offset, pet_boba_state_count, pet_boba_frame_ms, pet_boba_rgb565, pet_boba_alpha},
    {"Gojo",  0xC6FF, 0x0844, PET_GOJO_STATE_COUNT, pet_gojo_state_offset, pet_gojo_state_count, pet_gojo_frame_ms, pet_gojo_rgb565, pet_gojo_alpha},
    {"Itachi",0xE8E4, 0x1804, PET_ITACHI_STATE_COUNT, pet_itachi_state_offset, pet_itachi_state_count, pet_itachi_frame_ms, pet_itachi_rgb565, pet_itachi_alpha},
};
static constexpr uint8_t PET_STYLE_COUNT = sizeof(pet_styles) / sizeof(pet_styles[0]);

static_assert(PET_SPRITE_W == PET_BOBA_W && PET_SPRITE_H == PET_BOBA_H, "BOBA sprite dimensions mismatch");
static_assert(PET_SPRITE_W == PET_GOJO_W && PET_SPRITE_H == PET_GOJO_H, "GOJO sprite dimensions mismatch");
static_assert(PET_SPRITE_W == PET_ITACHI_W && PET_SPRITE_H == PET_ITACHI_H, "ITACHI sprite dimensions mismatch");
static_assert(PET_SPRITE_W == PET_SUKUNA_W && PET_SPRITE_H == PET_SUKUNA_H, "SUKUNA sprite dimensions mismatch");

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

static bool is_generic_pet_message(const char* message) {
    return strcmp(message, "Thinking") == 0 || strcmp(message, "Ready") == 0;
}

static const char* current_pet_message() {
    if (usage.pet_message[0] != '\0' && !is_generic_pet_message(usage.pet_message)) {
        return usage.pet_message;
    }
    return pet_messages[pet_message_idx];
}

static const char* current_pet_title() {
    if (usage.pet_title[0] != '\0') {
        return usage.pet_title;
    }
    return "Codex";
}

static const char* current_project_name() {
    if (usage.project[0] != '\0') {
        return usage.project;
    }
    return "project";
}

static const char* current_completed_text() {
    if (usage.completed[0] != '\0') {
        return usage.completed;
    }
    return "waiting";
}

static const char* current_action_text() {
    if (usage.pet_message[0] != '\0') {
        return usage.pet_message;
    }
    return "Ready";
}

static const PetStyle& current_pet_style() {
    return pet_styles[active_pet % PET_STYLE_COUNT];
}

static void present_canvas() {
    if (screen_canvas_ready) {
        screen_canvas.pushSprite(0, 0);
    }
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

static void draw_codex_mark(int x, int y) {
    for (int iy = 0; iy < CODEX_ICON_H; iy++) {
        for (int ix = 0; ix < CODEX_ICON_W; ix++) {
            uint16_t color = pgm_read_word(&CODEX_ICON[iy * CODEX_ICON_W + ix]);
            if (color != CODEX_ICON_TRANSPARENT) {
                screen_canvas.drawPixel(x + ix, y + iy, color);
            }
        }
    }
}

static void draw_header() {
    draw_codex_mark(4, 2);
    screen_canvas.setTextDatum(top_left);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(2);
    screen_canvas.drawString("Codex", 40, 4);
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("usage", 42, 23);
}

static void draw_fit_string(const char* text, int x, int y, int max_w) {
    char buf[48];
    strlcpy(buf, text, sizeof(buf));
    size_t len = strlen(buf);
    while (len > 3 && screen_canvas.textWidth(buf) > max_w) {
        len--;
        buf[len] = '\0';
        if (len > 3) {
            buf[len - 3] = '.';
            buf[len - 2] = '.';
            buf[len - 1] = '.';
        }
    }
    screen_canvas.drawString(buf, x, y);
}

static uint16_t current_pet_frame_index(const PetStyle& pet, uint8_t state, uint8_t frame) {
    state %= pet.state_count;
    uint8_t count = pet.state_count_frames[state];
    return pet.state_offset[state] + (frame % count);
}

static void draw_current_pet_sprite(int x, int y, uint8_t state, uint8_t frame) {
    const PetStyle& pet = current_pet_style();
    uint16_t sprite_frame = current_pet_frame_index(pet, state, frame);
    for (int sy = 0; sy < PET_SPRITE_H; sy++) {
        for (int sx = 0; sx < PET_SPRITE_W; sx++) {
            int idx = sy * PET_SPRITE_W + sx;
            uint8_t alpha = pgm_read_byte(&pet.alpha[sprite_frame][idx]);
            if (alpha > 8) {
                uint16_t color = pgm_read_word(&pet.rgb565[sprite_frame][idx]);
                if (alpha < 250) {
                    color = blend_rgb565(ATOM_BG, color, alpha);
                }
                screen_canvas.drawPixel(x + sx, y + sy, color);
            }
        }
    }
}

static void draw_usage() {
    if (screen_canvas_ready) {
        screen_canvas.fillScreen(ATOM_BG);
        draw_header();
    } else {
        M5.Display.fillScreen(ATOM_BG);
    }

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
    char pct_str[8];
    snprintf(pct_str, sizeof(pct_str), "%d%%", s);
    screen_canvas.drawString(has_percent ? pct_str : "--", 6, 50);
    draw_bar(6, 73, 116, 11, has_percent ? s : 0, has_percent ? remaining_color(usage.session_pct) : 0x5AEB);
    fmt_reset(usage.session_reset_mins, reset, sizeof(reset));
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    char reset_label[24];
    snprintf(reset_label, sizeof(reset_label), "reset %s", reset);
    screen_canvas.drawString(has_percent ? reset_label : usage.status, 6, 87);

    screen_canvas.drawString(has_percent ? "WK LEFT" : "WEEK", 6, 100);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    screen_canvas.setTextSize(2);
    snprintf(pct_str, sizeof(pct_str), "%d%%", w);
    screen_canvas.drawString(has_percent ? pct_str : "--", 6, 111);
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

static void draw_pet(bool force = false) {
    uint32_t now = millis();
    int next_frame = pet_frame;
    bool redraw = force;
    const PetStyle& pet = current_pet_style();
    uint8_t state = pet_anim_state % pet.state_count;
    uint8_t frame_count = pet.state_count_frames[state];
    uint16_t frame_index = current_pet_frame_index(pet, state, pet_frame);
    if (force) {
        next_frame = 0;
        pet_anim_state = 0;
        last_pet_frame = now;
        last_pet_message = now;
    } else if (now - last_pet_frame >= pet.frame_ms[frame_index]) {
        next_frame = (pet_frame + 1) % frame_count;
        last_pet_frame = now;
        redraw = true;
    }

    if (!force && now - last_pet_message >= PET_MESSAGE_MS) {
        pet_message_idx = (pet_message_idx + 1) % PET_MESSAGE_COUNT;
        pet_anim_state = (pet_anim_state + 1) % pet.state_count;
        next_frame = 0;
        last_pet_message = now;
        redraw = true;
    }

    if (!redraw) {
        return;
    }

    if (force) {
        pet_message_idx = 0;
    }

    screen_canvas.fillScreen(ATOM_BG);
    screen_canvas.fillRoundRect(3, 3, 122, 42, 7, current_pet_style().card);
    screen_canvas.drawRoundRect(3, 3, 122, 42, 7, ATOM_RULE);
    screen_canvas.setTextDatum(top_left);
    screen_canvas.setTextColor(ATOM_TEXT, current_pet_style().card);
    screen_canvas.setTextSize(1);
    draw_fit_string("Codex", 9, 7, 108);
    screen_canvas.drawFastHLine(9, 20, 108, ATOM_RULE);
    screen_canvas.setTextColor(CODEX_WHITE, current_pet_style().card);
    draw_fit_string(pet_messages[pet_message_idx], 9, 26, 108);

    int pulse = next_frame < 6 ? next_frame : 12 - next_frame;
    int bob = max(0, pulse / 3);
    draw_current_pet_sprite((128 - PET_SPRITE_W) / 2, 48 - bob, pet_anim_state, next_frame);

    present_canvas();

    pet_frame = next_frame;
}

static void draw_pet_selector() {
    screen_canvas.fillScreen(ATOM_BG);
    screen_canvas.setTextDatum(top_center);
    screen_canvas.setTextColor(current_pet_style().accent, ATOM_BG);
    screen_canvas.setTextSize(1);
    screen_canvas.drawString(current_pet_style().name, 64, 7);
    screen_canvas.drawFastHLine(34, 21, 60, ATOM_RULE);

    draw_current_pet_sprite((128 - PET_SPRITE_W) / 2, 30, 0, 0);

    int dot_start = 64 - ((PET_STYLE_COUNT - 1) * 12) / 2;
    for (uint8_t i = 0; i < PET_STYLE_COUNT; i++) {
        uint16_t color = i == active_pet ? pet_styles[i].accent : ATOM_RULE;
        screen_canvas.fillCircle(dot_start + i * 12, 113, i == active_pet ? 3 : 2, color);
    }

    screen_canvas.setTextDatum(bottom_center);
    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("hold for next", 64, 126);
    present_canvas();
}

static void draw_working() {
    screen_canvas.fillScreen(ATOM_BG);
    screen_canvas.setTextDatum(top_left);
    screen_canvas.setTextSize(1);
    screen_canvas.setTextColor(current_pet_style().accent, ATOM_BG);
    screen_canvas.drawString("NOW WORKING", 6, 5);
    screen_canvas.drawFastHLine(6, 18, 116, ATOM_RULE);

    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("project", 6, 25);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    draw_fit_string(current_project_name(), 54, 25, 68);

    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("task", 6, 45);
    screen_canvas.setTextColor(CODEX_WHITE, ATOM_BG);
    draw_fit_string(current_pet_title(), 6, 57, 116);

    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("action", 6, 76);
    screen_canvas.setTextColor(current_pet_style().accent, ATOM_BG);
    draw_fit_string(current_action_text(), 54, 76, 68);

    screen_canvas.setTextColor(ATOM_DIM, ATOM_BG);
    screen_canvas.drawString("last done", 6, 96);
    screen_canvas.setTextColor(ATOM_TEXT, ATOM_BG);
    draw_fit_string(current_completed_text(), 6, 108, 116);
    present_canvas();
}

static void select_next_pet() {
    active_pet = (active_pet + 1) % PET_STYLE_COUNT;
    preferences.putUChar("pet_v2", active_pet);
    pet_frame = 0;
    pet_anim_state = 0;
    last_pet_frame = millis();
    draw_pet_selector();
}

static void draw_screen(bool force = false) {
    if (screen == 2) {
        draw_pet(force);
        return;
    }
    if (!force) return;
    if (screen == 0) draw_usage();
    else if (screen == 1) draw_ble();
    else if (screen == 3) draw_pet_selector();
    else if (screen == 4) draw_working();
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
    strlcpy(out->pet_title, doc["pt"] | "", sizeof(out->pet_title));
    strlcpy(out->pet_message, doc["m"] | "", sizeof(out->pet_message));
    strlcpy(out->project, doc["pr"] | "", sizeof(out->project));
    strlcpy(out->completed, doc["lc"] | "", sizeof(out->completed));
    out->ok = doc["ok"] | false;
    out->valid = true;
    return true;
}

static void handle_payload(const char* data) {
    Serial.printf("RX: %s\n", data);
    if (parse_json(data, &usage)) {
        ble_send_ack();
        if (screen == 0 || screen == 4) {
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
            Serial.println("serial JSON overflow, discarding buffer");
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
    preferences.begin("codexmeter", false);
    active_pet = preferences.getUChar("pet_v2", 0) % PET_STYLE_COUNT;

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
        } else {
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

    if (screen == 2) {
        draw_screen();
    }
    delay(10);
}
