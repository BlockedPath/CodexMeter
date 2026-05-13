#include <Arduino.h>
#include <M5Unified.h>

static void set_led(uint8_t r, uint8_t g, uint8_t b) {
#if defined(RGB_BUILTIN)
    rgbLedWrite(RGB_BUILTIN, r, g, b);
#endif
}

void setup() {
    Serial.begin(115200);
    delay(1200);
    Serial.println("AtomS3 smoke setup start");
    Serial.flush();

    set_led(48, 0, 0);
    delay(300);
    set_led(0, 48, 0);
    delay(300);
    set_led(0, 0, 48);

    auto cfg = M5.config();
    cfg.serial_baudrate = 115200;
    cfg.fallback_board = m5::board_t::board_M5AtomS3;
    M5.begin(cfg);

    Serial.printf("M5 board=%d display=%dx%d\n",
                  (int)M5.getBoard(),
                  M5.Display.width(),
                  M5.Display.height());
    Serial.flush();

    M5.Display.setRotation(0);
    M5.Display.setBrightness(255);
    M5.Display.fillScreen(RED);
    delay(700);
    M5.Display.fillScreen(GREEN);
    delay(700);
    M5.Display.fillScreen(BLUE);
    delay(700);
    M5.Display.fillScreen(BLACK);
    M5.Display.setTextDatum(middle_center);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(2);
    M5.Display.drawString("AtomS3", 64, 48);
    M5.Display.setTextSize(1);
    M5.Display.drawString("CodexMeter", 64, 78);
    Serial.println("AtomS3 smoke ready");
    Serial.flush();
}

void loop() {
    static uint32_t last = 0;
    static uint8_t phase = 0;
    if (millis() - last >= 500) {
        last = millis();
        phase = (phase + 1) % 3;
        if (phase == 0) set_led(48, 0, 0);
        if (phase == 1) set_led(0, 48, 0);
        if (phase == 2) set_led(0, 0, 48);
        Serial.printf("smoke tick %u\n", phase);
        Serial.flush();
    }
}
