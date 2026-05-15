#pragma once
#include <Arduino.h>

struct UsageData {
    float session_pct;       // 5-hour window utilization (0-100)
    int session_reset_mins;  // minutes until session resets
    float weekly_pct;        // 7-day window utilization (0-100)
    int weekly_reset_mins;   // minutes until weekly resets
    char status[24];         // short status line
    char pet_title[28];      // active Codex chat title
    char pet_message[44];    // current Codex activity/pet overlay line
    char project[22];        // current repo/project name
    char completed[44];      // last completed action
    bool ok;                 // data parse succeeded
    bool valid;              // false until first successful parse
};
