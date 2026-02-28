#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "generated_defaults.h"
#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "lwip/inet.h"
#include "lwip/ip4_addr.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"
#include "nvs.h"
#include "nvs_flash.h"

#define TAG "8BB_FW"

#define MAX_STR 96
#define OTA_BUFFER_MAX 8192
#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT BIT1

/* GPIO and PWM mapping for default reference board. */
#define RELAY1_PIN GPIO_NUM_16
#define RELAY2_PIN GPIO_NUM_17
#define RELAY3_PIN GPIO_NUM_18
#define RELAY4_PIN GPIO_NUM_19
#define LIGHT_SINGLE_PIN GPIO_NUM_23
#define FAN_POWER_PIN GPIO_NUM_32

#define DIMMER_PIN GPIO_NUM_21
#define RGB_R_PIN GPIO_NUM_25
#define RGB_G_PIN GPIO_NUM_26
#define RGB_B_PIN GPIO_NUM_27
#define RGB_W_PIN GPIO_NUM_14
#define FAN_SPEED_PIN GPIO_NUM_33

typedef struct {
    char name[MAX_STR];
    char type[MAX_STR];
    char passcode[MAX_STR];
    int relay_gpio[4];
    char wifi_ssid[MAX_STR];
    char wifi_pass[MAX_STR];
    char ap_ssid[MAX_STR];
    char ap_pass[MAX_STR];
    bool use_static_ip;
    char static_ip[MAX_STR];
    char gateway[MAX_STR];
    char subnet_mask[MAX_STR];
    char ota_key[MAX_STR];
} device_config_t;

typedef struct {
    bool relay[4];
    bool light_single;
    int dimmer_pct;
    int rgb[4];
    bool fan_power;
    int fan_speed_pct;
} output_state_t;

static device_config_t g_cfg = {
    .name = FW_DEFAULT_NAME,
    .type = FW_DEFAULT_TYPE,
    .passcode = FW_DEFAULT_PASSCODE,
    .relay_gpio = {RELAY1_PIN, RELAY2_PIN, RELAY3_PIN, RELAY4_PIN},
    .wifi_ssid = FW_DEFAULT_WIFI_SSID,
    .wifi_pass = FW_DEFAULT_WIFI_PASS,
    .ap_ssid = FW_DEFAULT_AP_SSID,
    .ap_pass = FW_DEFAULT_AP_PASS,
    .use_static_ip = FW_DEFAULT_USE_STATIC_IP,
    .static_ip = FW_DEFAULT_STATIC_IP,
    .gateway = FW_DEFAULT_GATEWAY,
    .subnet_mask = FW_DEFAULT_SUBNET_MASK,
    .ota_key = FW_DEFAULT_OTA_KEY,
};

static output_state_t g_state = {0};
static httpd_handle_t g_server = NULL;
static EventGroupHandle_t g_wifi_events;
static int g_sta_fail_count = 0;
static esp_netif_t *g_sta_netif = NULL;
static esp_netif_t *g_ap_netif = NULL;

/* LEDC channel allocation for dimmer/RGB/fan. */
static const ledc_channel_t CH_DIMMER = LEDC_CHANNEL_0;
static const ledc_channel_t CH_RGB_R = LEDC_CHANNEL_1;
static const ledc_channel_t CH_RGB_G = LEDC_CHANNEL_2;
static const ledc_channel_t CH_RGB_B = LEDC_CHANNEL_3;
static const ledc_channel_t CH_RGB_W = LEDC_CHANNEL_4;
static const ledc_channel_t CH_FAN = LEDC_CHANNEL_5;
static const int DEFAULT_RELAY_GPIOS[4] = {RELAY1_PIN, RELAY2_PIN, RELAY3_PIN, RELAY4_PIN};

static void safe_strcpy(char *dst, const char *src, size_t dst_size) {
    if (!dst || !src || dst_size == 0) return;
    snprintf(dst, dst_size, "%s", src);
}

static void sanitize_wifi_field(char *value) {
    if (!value) return;
    size_t read_idx = 0;
    size_t write_idx = 0;
    while (value[read_idx] != '\0') {
        char c = value[read_idx++];
        if (c == '\r' || c == '\n' || c == '\t') {
            continue;
        }
        value[write_idx++] = c;
    }
    value[write_idx] = '\0';

    while (write_idx > 0 && (value[write_idx - 1] == ' ')) {
        value[--write_idx] = '\0';
    }
    size_t start = 0;
    while (value[start] == ' ') {
        start++;
    }
    if (start > 0) {
        memmove(value, value + start, strlen(value + start) + 1);
    }
}

static size_t copy_wifi_field(uint8_t *dst, size_t dst_size, const char *src) {
    if (!dst || dst_size == 0 || !src) return 0;
    memset(dst, 0, dst_size);
    size_t len = strnlen(src, dst_size - 1);
    memcpy(dst, src, len);
    dst[len] = '\0';
    return len;
}

static int clamp_int(int value, int min_val, int max_val) {
    if (value < min_val) return min_val;
    if (value > max_val) return max_val;
    return value;
}

static bool valid_output_gpio_int(int pin) {
    return pin >= 0 && pin <= 39 && GPIO_IS_VALID_OUTPUT_GPIO(pin);
}

static void sanitize_relay_gpio_map(void) {
    for (int i = 0; i < 4; i++) {
        if (!valid_output_gpio_int(g_cfg.relay_gpio[i])) {
            g_cfg.relay_gpio[i] = DEFAULT_RELAY_GPIOS[i];
        }
    }
}

static void configure_relay_gpio_outputs(void) {
    sanitize_relay_gpio_map();
    for (int i = 0; i < 4; i++) {
        gpio_num_t pin = (gpio_num_t)g_cfg.relay_gpio[i];
        gpio_reset_pin(pin);
        gpio_set_direction(pin, GPIO_MODE_OUTPUT);
    }
}

static void hex_encode(const unsigned char *input, size_t len, char *out, size_t out_size) {
    const char *hex = "0123456789abcdef";
    size_t need = len * 2 + 1;
    if (out_size < need) return;
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = hex[(input[i] >> 4) & 0xF];
        out[i * 2 + 1] = hex[input[i] & 0xF];
    }
    out[len * 2] = '\0';
}

static void load_config_from_nvs(void) {
    nvs_handle_t nvs;
    if (nvs_open("cfg", NVS_READONLY, &nvs) != ESP_OK) {
        ESP_LOGW(TAG, "NVS cfg not found, using defaults");
        sanitize_relay_gpio_map();
        return;
    }
    size_t len = sizeof(g_cfg);
    esp_err_t err = nvs_get_blob(nvs, "device", &g_cfg, &len);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "Loaded config from NVS");
    } else {
        ESP_LOGW(TAG, "Config read failed, using defaults");
    }
    nvs_close(nvs);
    sanitize_relay_gpio_map();
    sanitize_wifi_field(g_cfg.wifi_ssid);
    sanitize_wifi_field(g_cfg.wifi_pass);
    sanitize_wifi_field(g_cfg.ap_ssid);
    sanitize_wifi_field(g_cfg.ap_pass);
}

static void save_config_to_nvs(void) {
    nvs_handle_t nvs;
    if (nvs_open("cfg", NVS_READWRITE, &nvs) != ESP_OK) {
        ESP_LOGE(TAG, "NVS open failed");
        return;
    }
    nvs_set_blob(nvs, "device", &g_cfg, sizeof(g_cfg));
    nvs_commit(nvs);
    nvs_close(nvs);
    ESP_LOGI(TAG, "Config saved");
}

static esp_err_t send_json(httpd_req_t *req, cJSON *root) {
    char *body = cJSON_PrintUnformatted(root);
    if (!body) return ESP_FAIL;
    httpd_resp_set_type(req, "application/json");
    esp_err_t err = httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
    cJSON_free(body);
    return err;
}

static bool check_passcode(cJSON *root) {
    cJSON *pass = cJSON_GetObjectItem(root, "passcode");
    return cJSON_IsString(pass) && strcmp(pass->valuestring, g_cfg.passcode) == 0;
}

static void ledc_set_percent(ledc_channel_t channel, int pct) {
    int val = clamp_int(pct, 0, 100);
    uint32_t duty = (uint32_t)((val * 255) / 100);
    ledc_set_duty(LEDC_LOW_SPEED_MODE, channel, duty);
    ledc_update_duty(LEDC_LOW_SPEED_MODE, channel);
}

static void apply_relay(int idx, bool on) {
    if (idx < 0 || idx > 3) return;
    sanitize_relay_gpio_map();
    int pin = g_cfg.relay_gpio[idx];
    if (!valid_output_gpio_int(pin)) return;
    gpio_set_level((gpio_num_t)pin, on ? 1 : 0);
    g_state.relay[idx] = on;
}

static void apply_light_single(bool on) {
    gpio_set_level(LIGHT_SINGLE_PIN, on ? 1 : 0);
    g_state.light_single = on;
}

static void apply_dimmer(int pct) {
    g_state.dimmer_pct = clamp_int(pct, 0, 100);
    ledc_set_percent(CH_DIMMER, g_state.dimmer_pct);
}

static void apply_rgb(int r, int g, int b, int w) {
    g_state.rgb[0] = clamp_int(r, 0, 100);
    g_state.rgb[1] = clamp_int(g, 0, 100);
    g_state.rgb[2] = clamp_int(b, 0, 100);
    g_state.rgb[3] = clamp_int(w, 0, 100);
    ledc_set_percent(CH_RGB_R, g_state.rgb[0]);
    ledc_set_percent(CH_RGB_G, g_state.rgb[1]);
    ledc_set_percent(CH_RGB_B, g_state.rgb[2]);
    ledc_set_percent(CH_RGB_W, g_state.rgb[3]);
}

static void apply_fan(bool power, int speed_pct) {
    g_state.fan_power = power;
    g_state.fan_speed_pct = clamp_int(speed_pct, 0, 100);
    gpio_set_level(FAN_POWER_PIN, g_state.fan_power ? 1 : 0);
    ledc_set_percent(CH_FAN, g_state.fan_power ? g_state.fan_speed_pct : 0);
}

static bool parse_on_off_toggle(const char *state, bool current) {
    if (!state) return current;
    if (strcmp(state, "toggle") == 0) return !current;
    if (strcmp(state, "on") == 0) return true;
    if (strcmp(state, "off") == 0) return false;
    return current;
}

static bool handle_control(cJSON *root) {
    cJSON *channel = cJSON_GetObjectItem(root, "channel");
    cJSON *state = cJSON_GetObjectItem(root, "state");
    cJSON *value = cJSON_GetObjectItem(root, "value");
    if (!cJSON_IsString(channel)) return false;

    const char *ch = channel->valuestring;
    const char *st = cJSON_IsString(state) ? state->valuestring : "toggle";
    int val = cJSON_IsNumber(value) ? value->valueint : 0;

    if (strncmp(ch, "relay", 5) == 0) {
        int idx = atoi(ch + 5) - 1;
        bool target = parse_on_off_toggle(st, (idx >= 0 && idx < 4) ? g_state.relay[idx] : false);
        apply_relay(idx, target);
        return true;
    }

    if (strcmp(ch, "light") == 0) {
        bool target = parse_on_off_toggle(st, g_state.light_single);
        apply_light_single(target);
        return true;
    }

    if (strcmp(ch, "dimmer") == 0) {
        int pct = (strcmp(st, "set") == 0) ? val : (parse_on_off_toggle(st, g_state.dimmer_pct > 0) ? 100 : 0);
        apply_dimmer(pct);
        return true;
    }

    if (strcmp(ch, "rgb") == 0 || strcmp(ch, "rgbw") == 0) {
        cJSON *r = cJSON_GetObjectItem(root, "r");
        cJSON *g = cJSON_GetObjectItem(root, "g");
        cJSON *b = cJSON_GetObjectItem(root, "b");
        cJSON *w = cJSON_GetObjectItem(root, "w");
        if (strcmp(st, "off") == 0) {
            apply_rgb(0, 0, 0, 0);
        } else if (strcmp(st, "on") == 0) {
            apply_rgb(100, 100, 100, strcmp(ch, "rgbw") == 0 ? 100 : 0);
        } else {
            apply_rgb(cJSON_IsNumber(r) ? r->valueint : g_state.rgb[0],
                      cJSON_IsNumber(g) ? g->valueint : g_state.rgb[1],
                      cJSON_IsNumber(b) ? b->valueint : g_state.rgb[2],
                      cJSON_IsNumber(w) ? w->valueint : g_state.rgb[3]);
        }
        return true;
    }

    if (strcmp(ch, "fan") == 0 || strcmp(ch, "fan_power") == 0) {
        bool power = g_state.fan_power;
        int speed = g_state.fan_speed_pct;
        if (strcmp(ch, "fan_power") == 0) {
            power = parse_on_off_toggle(st, g_state.fan_power);
        } else if (strcmp(st, "set") == 0) {
            speed = val;
            power = speed > 0;
        } else {
            power = parse_on_off_toggle(st, g_state.fan_power);
            if (!power) speed = 0;
            if (power && speed == 0) speed = 50;
        }
        apply_fan(power, speed);
        return true;
    }

    return false;
}

static void init_outputs(void) {
    gpio_config_t io_conf = {
        .intr_type = GPIO_INTR_DISABLE,
        .mode = GPIO_MODE_OUTPUT,
        .pin_bit_mask = (1ULL << LIGHT_SINGLE_PIN) | (1ULL << FAN_POWER_PIN),
        .pull_down_en = 0,
        .pull_up_en = 0,
    };
    gpio_config(&io_conf);
    configure_relay_gpio_outputs();

    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .timer_num = LEDC_TIMER_0,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&timer);

    ledc_channel_config_t channels[] = {
        {.gpio_num = DIMMER_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_DIMMER, .timer_sel = LEDC_TIMER_0, .duty = 0},
        {.gpio_num = RGB_R_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_RGB_R, .timer_sel = LEDC_TIMER_0, .duty = 0},
        {.gpio_num = RGB_G_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_RGB_G, .timer_sel = LEDC_TIMER_0, .duty = 0},
        {.gpio_num = RGB_B_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_RGB_B, .timer_sel = LEDC_TIMER_0, .duty = 0},
        {.gpio_num = RGB_W_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_RGB_W, .timer_sel = LEDC_TIMER_0, .duty = 0},
        {.gpio_num = FAN_SPEED_PIN, .speed_mode = LEDC_LOW_SPEED_MODE, .channel = CH_FAN, .timer_sel = LEDC_TIMER_0, .duty = 0},
    };
    for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); i++) {
        ledc_channel_config(&channels[i]);
    }

    for (int i = 0; i < 4; i++) apply_relay(i, false);
    apply_light_single(false);
    apply_dimmer(0);
    apply_rgb(0, 0, 0, 0);
    apply_fan(false, 0);
}

static esp_err_t status_handler(httpd_req_t *req) {
    sanitize_relay_gpio_map();
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "name", g_cfg.name);
    cJSON_AddStringToObject(root, "type", g_cfg.type);
    cJSON_AddBoolToObject(root, "static_ip_enabled", g_cfg.use_static_ip);
    cJSON_AddStringToObject(root, "static_ip", g_cfg.static_ip);
    cJSON_AddStringToObject(root, "gateway", g_cfg.gateway);
    cJSON_AddStringToObject(root, "subnet_mask", g_cfg.subnet_mask);
    cJSON_AddStringToObject(root, "fw_version", "0.2.0");
    cJSON_AddStringToObject(root, "ota_mode", "signed-hmac");

    cJSON *outputs = cJSON_CreateObject();
    cJSON_AddBoolToObject(outputs, "relay1", g_state.relay[0]);
    cJSON_AddBoolToObject(outputs, "relay2", g_state.relay[1]);
    cJSON_AddBoolToObject(outputs, "relay3", g_state.relay[2]);
    cJSON_AddBoolToObject(outputs, "relay4", g_state.relay[3]);
    cJSON_AddBoolToObject(outputs, "light", g_state.light_single);
    cJSON_AddNumberToObject(outputs, "dimmer", g_state.dimmer_pct);
    cJSON_AddNumberToObject(outputs, "rgb_r", g_state.rgb[0]);
    cJSON_AddNumberToObject(outputs, "rgb_g", g_state.rgb[1]);
    cJSON_AddNumberToObject(outputs, "rgb_b", g_state.rgb[2]);
    cJSON_AddNumberToObject(outputs, "rgb_w", g_state.rgb[3]);
    cJSON_AddBoolToObject(outputs, "fan_power", g_state.fan_power);
    cJSON_AddNumberToObject(outputs, "fan_speed", g_state.fan_speed_pct);
    cJSON_AddItemToObject(root, "outputs", outputs);
    cJSON *relay_gpio = cJSON_CreateArray();
    for (int i = 0; i < 4; i++) {
        cJSON_AddItemToArray(relay_gpio, cJSON_CreateNumber(g_cfg.relay_gpio[i]));
    }
    cJSON_AddItemToObject(root, "relay_gpio", relay_gpio);

    esp_err_t err = send_json(req, root);
    cJSON_Delete(root);
    return err;
}

static esp_err_t web_root_handler(httpd_req_t *req) {
    const char *html =
        "<!doctype html>"
        "<html><head><meta charset='utf-8'/>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'/>"
        "<title>8bb ESP32</title>"
        "<style>"
        "body{font-family:Arial,sans-serif;margin:16px;background:#10161c;color:#e9eef4}"
        "h1{margin:0 0 10px 0;font-size:22px}h2{font-size:16px;margin:14px 0 8px}"
        ".grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}"
        ".card{border:1px solid #2a3a4a;border-radius:10px;padding:12px;background:#131c24;margin-bottom:12px}"
        "label{display:block;font-size:12px;color:#a8bacd;margin-bottom:6px}"
        "input,select,button{width:100%;padding:10px;border-radius:8px;border:1px solid #324657;background:#0f151c;color:#e9eef4;box-sizing:border-box}"
        "button{cursor:pointer;background:#1f3345;border-color:#4a6a85}"
        ".row{display:grid;grid-template-columns:1fr 1fr;gap:8px}"
        ".row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}"
        "pre{background:#0b1016;border:1px solid #2a3a4a;padding:10px;border-radius:8px;overflow:auto;max-height:220px}"
        ".small{font-size:12px;color:#9cb0c3}"
        "</style></head><body>"
        "<h1>8bb ESP32 Device</h1>"
        "<div class='card'>"
        "<h2>Session</h2>"
        "<div class='row'>"
        "<div><label>Passcode</label><input id='pass' type='password' placeholder='required for write actions'/></div>"
        "<div><label>Pair Test</label><button id='pairBtn'>Pair</button></div>"
        "</div>"
        "<div class='row'>"
        "<button id='refreshBtn'>Refresh Status</button>"
        "<button id='applyCfgBtn'>Save Config</button>"
        "</div>"
        "<div class='small'>Manual UI for test/control/config. API root: /api/status</div>"
        "</div>"

        "<div class='card'>"
        "<h2>Outputs</h2>"
        "<div class='row3'>"
        "<button data-relay='relay1' class='relayBtn'>Toggle Relay 1</button>"
        "<button data-relay='relay2' class='relayBtn'>Toggle Relay 2</button>"
        "<button data-relay='relay3' class='relayBtn'>Toggle Relay 3</button>"
        "<button data-relay='relay4' class='relayBtn'>Toggle Relay 4</button>"
        "<button id='lightBtn'>Toggle Light</button>"
        "<button id='fanPowerBtn'>Toggle Fan Power</button>"
        "</div>"
        "<div class='row'>"
        "<div><label>Dimmer %</label><input id='dimmerVal' type='number' min='0' max='100' value='50'/></div>"
        "<div><label>Fan Speed %</label><input id='fanVal' type='number' min='0' max='100' value='50'/></div>"
        "</div>"
        "<div class='row'>"
        "<button id='setDimmerBtn'>Set Dimmer</button>"
        "<button id='setFanBtn'>Set Fan Speed</button>"
        "</div>"
        "</div>"

        "<div class='card'>"
        "<h2>GPIO Test</h2>"
        "<div class='row3'>"
        "<div><label>GPIO</label><input id='gpioPin' type='number' min='0' max='39' value='16'/></div>"
        "<div><label>Level</label><select id='gpioLevel'><option value='1'>ON (1)</option><option value='0'>OFF (0)</option></select></div>"
        "<div><label>Apply</label><button id='gpioSetBtn'>Set GPIO</button></div>"
        "</div>"
        "<div class='small'>For temporary manual test only. Does not change saved relay mapping.</div>"
        "</div>"

        "<div class='card'>"
        "<h2>Config</h2>"
        "<div class='grid'>"
        "<div><label>Device Name</label><input id='cfgName' placeholder='8bb-esp32'/></div>"
        "<div><label>Device Type</label><input id='cfgType' placeholder='relay_switch'/></div>"
        "<div><label>New Device Passcode</label><input id='cfgNewPass' type='password'/></div>"
        "<div><label>Wi-Fi SSID</label><input id='cfgWifiSsid'/></div>"
        "<div><label>Wi-Fi Password</label><input id='cfgWifiPass' type='password'/></div>"
        "<div><label>Fallback AP SSID</label><input id='cfgApSsid'/></div>"
        "<div><label>Fallback AP Password</label><input id='cfgApPass' type='password'/></div>"
        "<div><label>Relay1 GPIO</label><input id='cfgRelay1' type='number' min='0' max='39' value='16'/></div>"
        "<div><label>Relay2 GPIO</label><input id='cfgRelay2' type='number' min='0' max='39' value='17'/></div>"
        "<div><label>Relay3 GPIO</label><input id='cfgRelay3' type='number' min='0' max='39' value='18'/></div>"
        "<div><label>Relay4 GPIO</label><input id='cfgRelay4' type='number' min='0' max='39' value='19'/></div>"
        "<div><label>Use Static IP</label><select id='cfgStaticUse'><option value='0'>No (DHCP)</option><option value='1'>Yes</option></select></div>"
        "<div><label>Static IP</label><input id='cfgStaticIp' placeholder='192.168.1.50'/></div>"
        "<div><label>Gateway</label><input id='cfgGateway' placeholder='192.168.1.1'/></div>"
        "<div><label>Subnet Mask</label><input id='cfgMask' placeholder='255.255.255.0'/></div>"
        "<div><label>OTA Key</label><input id='cfgOtaKey' type='password'/></div>"
        "</div>"
        "</div>"

        "<div class='card'><h2>Status</h2><pre id='statusOut'>Loading...</pre></div>"
        "<div class='card'><h2>Log</h2><pre id='logOut'></pre></div>"
        "<script>"
        "const $=id=>document.getElementById(id);"
        "let S={};"
        "const log=m=>{$('logOut').textContent=(new Date().toISOString()+' '+m+'\\n'+$('logOut').textContent).slice(0,6000);};"
        "const pass=()=>$('pass').value||'';"
        "async function api(path,payload){"
        "const o=payload?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}:{};"
        "const r=await fetch(path,o);const t=await r.text();let j={};try{j=t?JSON.parse(t):{}}catch(_){j={raw:t}}"
        "if(!r.ok){throw new Error((j&&j.detail)||t||('HTTP '+r.status));}return j;}"
        "function setCfgFromStatus(s){$('cfgName').value=s.name||$('cfgName').value;$('cfgType').value=s.type||$('cfgType').value;$('cfgStaticUse').value=s.static_ip_enabled?'1':'0';$('cfgStaticIp').value=s.static_ip||'';$('cfgGateway').value=s.gateway||'';$('cfgMask').value=s.subnet_mask||'';const rg=Array.isArray(s.relay_gpio)?s.relay_gpio:[];$('cfgRelay1').value=(rg[0]??$('cfgRelay1').value);$('cfgRelay2').value=(rg[1]??$('cfgRelay2').value);$('cfgRelay3').value=(rg[2]??$('cfgRelay3').value);$('cfgRelay4').value=(rg[3]??$('cfgRelay4').value);}"
        "async function refresh(){try{S=await api('/api/status');$('statusOut').textContent=JSON.stringify(S,null,2);setCfgFromStatus(S);log('status refreshed');}catch(e){log('status error: '+e.message);}}"
        "async function doControl(channel,state,value){const p={passcode:pass(),channel:channel,state:state};if(value!==undefined)p.value=value;const r=await api('/api/control',p);log('control '+channel+' '+state+' ok');await refresh();return r;}"
        "document.querySelectorAll('.relayBtn').forEach(b=>b.onclick=()=>doControl(b.getAttribute('data-relay'),'toggle'));"
        "$('lightBtn').onclick=()=>doControl('light','toggle');"
        "$('fanPowerBtn').onclick=()=>doControl('fan_power','toggle');"
        "$('setDimmerBtn').onclick=()=>doControl('dimmer','set',parseInt($('dimmerVal').value||'0',10));"
        "$('setFanBtn').onclick=()=>doControl('fan_speed','set',parseInt($('fanVal').value||'0',10));"
        "$('gpioSetBtn').onclick=async()=>{try{const p={passcode:pass(),gpio:parseInt($('gpioPin').value||'0',10),value:parseInt($('gpioLevel').value||'0',10)};const r=await api('/api/test/gpio',p);log('gpio test ok '+JSON.stringify(r));}catch(e){log('gpio test error: '+e.message);}};"
        "$('pairBtn').onclick=async()=>{try{const r=await api('/api/pair',{passcode:pass()});log('pair ok '+JSON.stringify(r));}catch(e){log('pair error: '+e.message);}};"
        "$('refreshBtn').onclick=()=>refresh();"
        "$('applyCfgBtn').onclick=async()=>{"
        "try{const p={passcode:pass(),use_static_ip:$('cfgStaticUse').value==='1'};"
        "const setIf=(k,v)=>{if(v!==undefined&&v!==null&&String(v).length>0)p[k]=v;};"
        "setIf('name',$('cfgName').value.trim());setIf('type',$('cfgType').value.trim());setIf('new_passcode',$('cfgNewPass').value);"
        "setIf('wifi_ssid',$('cfgWifiSsid').value);setIf('wifi_pass',$('cfgWifiPass').value);"
        "const rg=[parseInt($('cfgRelay1').value||'-1',10),parseInt($('cfgRelay2').value||'-1',10),parseInt($('cfgRelay3').value||'-1',10),parseInt($('cfgRelay4').value||'-1',10)];if(rg.every(v=>Number.isInteger(v)&&v>=0&&v<=39)){p.relay_gpio=rg;}"
        "setIf('ap_ssid',$('cfgApSsid').value);setIf('ap_pass',$('cfgApPass').value);"
        "setIf('static_ip',$('cfgStaticIp').value.trim());setIf('gateway',$('cfgGateway').value.trim());setIf('subnet_mask',$('cfgMask').value.trim());"
        "setIf('ota_key',$('cfgOtaKey').value);"
        "await api('/api/config',p);log('config saved, reboot device for Wi-Fi mode changes if needed');await refresh();"
        "}catch(e){log('config error: '+e.message);}};"
        "refresh();"
        "</script>"
        "</body></html>";
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_sendstr(req, html);
}

static esp_err_t favicon_handler(httpd_req_t *req) {
    httpd_resp_set_status(req, "204 No Content");
    return httpd_resp_send(req, NULL, 0);
}

static esp_err_t pair_handler(httpd_req_t *req) {
    char buf[256] = {0};
    int len = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (len <= 0) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad payload");
    cJSON *root = cJSON_Parse(buf);
    if (!root) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "json parse failed");
    bool ok = check_passcode(root);
    cJSON_Delete(root);
    if (!ok) return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "invalid passcode");
    return httpd_resp_sendstr(req, "{\"paired\":true}");
}

static esp_err_t config_handler(httpd_req_t *req) {
    char buf[1024] = {0};
    int len = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (len <= 0) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad payload");
    cJSON *root = cJSON_Parse(buf);
    if (!root) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "json parse failed");
    if (!check_passcode(root)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "invalid passcode");
    }

    cJSON *name = cJSON_GetObjectItem(root, "name");
    cJSON *type = cJSON_GetObjectItem(root, "type");
    cJSON *passcode = cJSON_GetObjectItem(root, "new_passcode");
    cJSON *wifi_ssid = cJSON_GetObjectItem(root, "wifi_ssid");
    cJSON *wifi_pass = cJSON_GetObjectItem(root, "wifi_pass");
    cJSON *ap_ssid = cJSON_GetObjectItem(root, "ap_ssid");
    cJSON *ap_pass = cJSON_GetObjectItem(root, "ap_pass");
    cJSON *relay_gpio = cJSON_GetObjectItem(root, "relay_gpio");
    cJSON *ota_key = cJSON_GetObjectItem(root, "ota_key");
    cJSON *static_ip_enabled = cJSON_GetObjectItem(root, "use_static_ip");
    cJSON *static_ip = cJSON_GetObjectItem(root, "static_ip");
    cJSON *gateway = cJSON_GetObjectItem(root, "gateway");
    cJSON *subnet_mask = cJSON_GetObjectItem(root, "subnet_mask");

    if (cJSON_IsString(name)) safe_strcpy(g_cfg.name, name->valuestring, sizeof(g_cfg.name));
    if (cJSON_IsString(type)) safe_strcpy(g_cfg.type, type->valuestring, sizeof(g_cfg.type));
    if (cJSON_IsString(passcode)) safe_strcpy(g_cfg.passcode, passcode->valuestring, sizeof(g_cfg.passcode));
    if (cJSON_IsString(wifi_ssid)) safe_strcpy(g_cfg.wifi_ssid, wifi_ssid->valuestring, sizeof(g_cfg.wifi_ssid));
    if (cJSON_IsString(wifi_pass)) safe_strcpy(g_cfg.wifi_pass, wifi_pass->valuestring, sizeof(g_cfg.wifi_pass));
    if (cJSON_IsString(ap_ssid)) safe_strcpy(g_cfg.ap_ssid, ap_ssid->valuestring, sizeof(g_cfg.ap_ssid));
    if (cJSON_IsString(ap_pass)) safe_strcpy(g_cfg.ap_pass, ap_pass->valuestring, sizeof(g_cfg.ap_pass));
    if (cJSON_IsArray(relay_gpio)) {
        for (int i = 0; i < 4; i++) {
            cJSON *it = cJSON_GetArrayItem(relay_gpio, i);
            if (cJSON_IsNumber(it)) g_cfg.relay_gpio[i] = it->valueint;
        }
    }
    if (cJSON_IsString(ota_key)) safe_strcpy(g_cfg.ota_key, ota_key->valuestring, sizeof(g_cfg.ota_key));
    if (cJSON_IsBool(static_ip_enabled)) g_cfg.use_static_ip = cJSON_IsTrue(static_ip_enabled);
    if (cJSON_IsString(static_ip)) safe_strcpy(g_cfg.static_ip, static_ip->valuestring, sizeof(g_cfg.static_ip));
    if (cJSON_IsString(gateway)) safe_strcpy(g_cfg.gateway, gateway->valuestring, sizeof(g_cfg.gateway));
    if (cJSON_IsString(subnet_mask)) safe_strcpy(g_cfg.subnet_mask, subnet_mask->valuestring, sizeof(g_cfg.subnet_mask));
    sanitize_wifi_field(g_cfg.wifi_ssid);
    sanitize_wifi_field(g_cfg.wifi_pass);
    sanitize_wifi_field(g_cfg.ap_ssid);
    sanitize_wifi_field(g_cfg.ap_pass);
    sanitize_relay_gpio_map();
    configure_relay_gpio_outputs();
    for (int i = 0; i < 4; i++) {
        apply_relay(i, g_state.relay[i]);
    }

    save_config_to_nvs();
    cJSON_Delete(root);
    return httpd_resp_sendstr(req, "{\"saved\":true}");
}

static esp_err_t control_handler(httpd_req_t *req) {
    char buf[1024] = {0};
    int len = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (len <= 0) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad payload");
    cJSON *root = cJSON_Parse(buf);
    if (!root) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "json parse failed");
    if (!check_passcode(root)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "invalid passcode");
    }

    bool ok = handle_control(root);
    cJSON_Delete(root);
    if (!ok) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "unsupported channel/state");
    return httpd_resp_sendstr(req, "{\"ok\":true}");
}

static esp_err_t gpio_test_handler(httpd_req_t *req) {
    char buf[256] = {0};
    int len = httpd_req_recv(req, buf, sizeof(buf) - 1);
    if (len <= 0) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad payload");
    cJSON *root = cJSON_Parse(buf);
    if (!root) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "json parse failed");
    if (!check_passcode(root)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "invalid passcode");
    }

    cJSON *gpio = cJSON_GetObjectItem(root, "gpio");
    cJSON *value = cJSON_GetObjectItem(root, "value");
    if (!cJSON_IsNumber(gpio) || !cJSON_IsNumber(value)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "gpio and value are required numbers");
    }
    int pin = gpio->valueint;
    int level = value->valueint ? 1 : 0;
    if (pin < 0 || pin > 39 || !GPIO_IS_VALID_OUTPUT_GPIO(pin)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid output gpio");
    }

    gpio_reset_pin((gpio_num_t)pin);
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_OUTPUT);
    gpio_set_level((gpio_num_t)pin, level);
    cJSON_Delete(root);

    cJSON *out = cJSON_CreateObject();
    cJSON_AddBoolToObject(out, "ok", true);
    cJSON_AddNumberToObject(out, "gpio", pin);
    cJSON_AddNumberToObject(out, "level", level);
    esp_err_t err = send_json(req, out);
    cJSON_Delete(out);
    return err;
}

static bool compute_manifest_signature(const char *sha256, const char *version, const char *device_type, char *out, size_t out_size) {
    if (!sha256 || !version || !device_type || !out) return false;
    char msg[256] = {0};
    snprintf(msg, sizeof(msg), "%s:%s:%s", sha256, version, device_type);
    unsigned char hmac[32] = {0};
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!info) return false;
    if (mbedtls_md_hmac(info, (const unsigned char *)g_cfg.ota_key, strlen(g_cfg.ota_key), (const unsigned char *)msg, strlen(msg), hmac) != 0) {
        return false;
    }
    hex_encode(hmac, sizeof(hmac), out, out_size);
    return true;
}

static bool http_get_to_buffer(const char *url, char *buf, size_t buf_size) {
    if (!url || !buf || buf_size < 2) return false;
    esp_http_client_config_t cfg = {.url = url, .timeout_ms = 15000};
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client) return false;
    if (esp_http_client_open(client, 0) != ESP_OK) {
        esp_http_client_cleanup(client);
        return false;
    }

    int read_total = 0;
    while (read_total < (int)(buf_size - 1)) {
        int r = esp_http_client_read(client, buf + read_total, buf_size - 1 - read_total);
        if (r <= 0) break;
        read_total += r;
    }
    buf[read_total] = '\0';
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return read_total > 0;
}

static bool verify_manifest(const char *manifest_json, char *sha_out, size_t sha_out_size) {
    cJSON *root = cJSON_Parse(manifest_json);
    if (!root) return false;

    cJSON *algo = cJSON_GetObjectItem(root, "algorithm");
    cJSON *sha = cJSON_GetObjectItem(root, "sha256");
    cJSON *version = cJSON_GetObjectItem(root, "version");
    cJSON *device_type = cJSON_GetObjectItem(root, "device_type");
    cJSON *signature = cJSON_GetObjectItem(root, "signature");
    if (!cJSON_IsString(algo) || !cJSON_IsString(sha) || !cJSON_IsString(version) || !cJSON_IsString(device_type) || !cJSON_IsString(signature)) {
        cJSON_Delete(root);
        return false;
    }
    if (strcmp(algo->valuestring, "hmac-sha256") != 0) {
        cJSON_Delete(root);
        return false;
    }
    if (strcmp(device_type->valuestring, g_cfg.type) != 0 && strcmp(device_type->valuestring, "any") != 0) {
        cJSON_Delete(root);
        return false;
    }

    char expected_sig[65] = {0};
    bool sig_ok = compute_manifest_signature(sha->valuestring, version->valuestring, device_type->valuestring, expected_sig, sizeof(expected_sig));
    bool ok = sig_ok && strcmp(expected_sig, signature->valuestring) == 0;
    if (ok) safe_strcpy(sha_out, sha->valuestring, sha_out_size);
    cJSON_Delete(root);
    return ok;
}

static bool ota_download_and_apply(const char *firmware_url, const char *expected_sha) {
    const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
    if (!update_partition) {
        ESP_LOGE(TAG, "No OTA partition available");
        return false;
    }

    esp_ota_handle_t ota_handle = 0;
    if (esp_ota_begin(update_partition, OTA_SIZE_UNKNOWN, &ota_handle) != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_begin failed");
        return false;
    }

    esp_http_client_config_t cfg = {.url = firmware_url, .timeout_ms = 30000};
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    if (!client || esp_http_client_open(client, 0) != ESP_OK) {
        esp_ota_end(ota_handle);
        if (client) esp_http_client_cleanup(client);
        ESP_LOGE(TAG, "HTTP open failed");
        return false;
    }

    unsigned char sha_bin[32] = {0};
    char sha_hex[65] = {0};
    unsigned char buf[1024];
    mbedtls_sha256_context sha_ctx;
    mbedtls_sha256_init(&sha_ctx);
    mbedtls_sha256_starts(&sha_ctx, 0);

    while (1) {
        int r = esp_http_client_read(client, (char *)buf, sizeof(buf));
        if (r < 0) {
            ESP_LOGE(TAG, "HTTP read failed");
            esp_http_client_close(client);
            esp_http_client_cleanup(client);
            mbedtls_sha256_free(&sha_ctx);
            esp_ota_end(ota_handle);
            return false;
        }
        if (r == 0) break;

        mbedtls_sha256_update(&sha_ctx, buf, r);
        if (esp_ota_write(ota_handle, buf, r) != ESP_OK) {
            ESP_LOGE(TAG, "esp_ota_write failed");
            esp_http_client_close(client);
            esp_http_client_cleanup(client);
            mbedtls_sha256_free(&sha_ctx);
            esp_ota_end(ota_handle);
            return false;
        }
    }

    mbedtls_sha256_finish(&sha_ctx, sha_bin);
    mbedtls_sha256_free(&sha_ctx);
    hex_encode(sha_bin, sizeof(sha_bin), sha_hex, sizeof(sha_hex));

    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (strcmp(sha_hex, expected_sha) != 0) {
        ESP_LOGE(TAG, "SHA mismatch expected=%s got=%s", expected_sha, sha_hex);
        esp_ota_end(ota_handle);
        return false;
    }

    if (esp_ota_end(ota_handle) != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end failed");
        return false;
    }
    if (esp_ota_set_boot_partition(update_partition) != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_set_boot_partition failed");
        return false;
    }
    ESP_LOGI(TAG, "OTA ready; rebooting");
    vTaskDelay(pdMS_TO_TICKS(400));
    esp_restart();
    return true;
}

static esp_err_t ota_apply_handler(httpd_req_t *req) {
    char body[512] = {0};
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad payload");
    cJSON *root = cJSON_Parse(body);
    if (!root) return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "json parse failed");
    if (!check_passcode(root)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "invalid passcode");
    }

    cJSON *firmware_url = cJSON_GetObjectItem(root, "firmware_url");
    cJSON *manifest_url = cJSON_GetObjectItem(root, "manifest_url");
    if (!cJSON_IsString(firmware_url) || !cJSON_IsString(manifest_url)) {
        cJSON_Delete(root);
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "firmware_url and manifest_url required");
    }
    char firmware_url_copy[256] = {0};
    char manifest_url_copy[256] = {0};
    safe_strcpy(firmware_url_copy, firmware_url->valuestring, sizeof(firmware_url_copy));
    safe_strcpy(manifest_url_copy, manifest_url->valuestring, sizeof(manifest_url_copy));
    cJSON_Delete(root);

    char manifest_buf[OTA_BUFFER_MAX] = {0};
    if (!http_get_to_buffer(manifest_url_copy, manifest_buf, sizeof(manifest_buf))) {
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "manifest download failed");
    }

    char expected_sha[65] = {0};
    if (!verify_manifest(manifest_buf, expected_sha, sizeof(expected_sha))) {
        return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "manifest signature verification failed");
    }

    bool ok = ota_download_and_apply(firmware_url_copy, expected_sha);
    if (!ok) {
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "ota apply failed");
    }
    return httpd_resp_sendstr(req, "{\"ok\":true}");
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {
    (void)arg;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        ESP_LOGI(TAG, "Wi-Fi STA start ssid=%s", g_cfg.wifi_ssid);
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *disc = (wifi_event_sta_disconnected_t *)event_data;
        ESP_LOGW(TAG, "Wi-Fi disconnected reason=%d retry=%d", disc ? disc->reason : -1, g_sta_fail_count + 1);
        g_sta_fail_count++;
        if (g_sta_fail_count < 5) {
            esp_wifi_connect();
        } else {
            xEventGroupSetBits(g_wifi_events, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
        if (evt) {
            ESP_LOGI(TAG, "NET_OK name=%s host=%s.local ip=" IPSTR " gw=" IPSTR " mask=" IPSTR,
                     g_cfg.name, g_cfg.name, IP2STR(&evt->ip_info.ip), IP2STR(&evt->ip_info.gw), IP2STR(&evt->ip_info.netmask));
        }
        g_sta_fail_count = 0;
        xEventGroupSetBits(g_wifi_events, WIFI_CONNECTED_BIT);
    }
}

static void start_wifi_ap_fallback(void) {
    ESP_LOGW(TAG, "Starting fallback AP ssid=%s", g_cfg.ap_ssid);
    wifi_config_t ap_cfg = {
        .ap = {
            .ssid_len = 0,
            .channel = 1,
            .max_connection = 4,
            .authmode = WIFI_AUTH_WPA2_PSK,
        }
    };
    sanitize_wifi_field(g_cfg.ap_ssid);
    sanitize_wifi_field(g_cfg.ap_pass);
    size_t ssid_len = copy_wifi_field(ap_cfg.ap.ssid, sizeof(ap_cfg.ap.ssid), g_cfg.ap_ssid);
    size_t pass_len = copy_wifi_field(ap_cfg.ap.password, sizeof(ap_cfg.ap.password), g_cfg.ap_pass);
    ap_cfg.ap.ssid_len = ssid_len;
    if (pass_len < 8) ap_cfg.ap.authmode = WIFI_AUTH_OPEN;
    ESP_LOGI(TAG, "AP cfg ssid=%s auth=%s pass_len=%d",
             (char *)ap_cfg.ap.ssid,
             ap_cfg.ap.authmode == WIFI_AUTH_OPEN ? "open" : "wpa2",
             (int)pass_len);
    esp_wifi_set_mode(WIFI_MODE_AP);
    esp_wifi_set_config(WIFI_IF_AP, &ap_cfg);
    esp_wifi_start();
    if (g_ap_netif) {
        esp_netif_ip_info_t ap_ip = {0};
        if (esp_netif_get_ip_info(g_ap_netif, &ap_ip) == ESP_OK) {
            ESP_LOGI(TAG, "NET_AP name=%s ap_ssid=%s ip=" IPSTR " gw=" IPSTR " mask=" IPSTR,
                     g_cfg.name, g_cfg.ap_ssid, IP2STR(&ap_ip.ip), IP2STR(&ap_ip.gw), IP2STR(&ap_ip.netmask));
        }
    }
}

static void apply_static_ip_if_needed(void) {
    if (!g_cfg.use_static_ip || !g_sta_netif) return;
    if (strlen(g_cfg.static_ip) == 0 || strlen(g_cfg.gateway) == 0 || strlen(g_cfg.subnet_mask) == 0) return;

    esp_netif_ip_info_t ip_info = {0};
    if (!ip4addr_aton(g_cfg.static_ip, (ip4_addr_t *)&ip_info.ip) ||
        !ip4addr_aton(g_cfg.gateway, (ip4_addr_t *)&ip_info.gw) ||
        !ip4addr_aton(g_cfg.subnet_mask, (ip4_addr_t *)&ip_info.netmask)) {
        ESP_LOGE(TAG, "Invalid static IP settings");
        return;
    }

    esp_netif_dhcpc_stop(g_sta_netif);
    esp_netif_set_ip_info(g_sta_netif, &ip_info);
    ESP_LOGI(TAG, "Static IP configured");
}

static void start_wifi_station_or_ap(void) {
    g_wifi_events = xEventGroupCreate();
    esp_netif_init();
    esp_event_loop_create_default();
    g_sta_netif = esp_netif_create_default_wifi_sta();
    g_ap_netif = esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL);

    if (strlen(g_cfg.wifi_ssid) == 0) {
        start_wifi_ap_fallback();
        return;
    }

    wifi_config_t sta_cfg = {0};
    sanitize_wifi_field(g_cfg.wifi_ssid);
    sanitize_wifi_field(g_cfg.wifi_pass);
    size_t sta_ssid_len = copy_wifi_field(sta_cfg.sta.ssid, sizeof(sta_cfg.sta.ssid), g_cfg.wifi_ssid);
    size_t sta_pass_len = copy_wifi_field(sta_cfg.sta.password, sizeof(sta_cfg.sta.password), g_cfg.wifi_pass);
    ESP_LOGI(TAG, "STA cfg ssid=%s ssid_len=%d pass_len=%d", (char *)sta_cfg.sta.ssid, (int)sta_ssid_len, (int)sta_pass_len);

    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &sta_cfg);
    apply_static_ip_if_needed();
    esp_wifi_start();

    EventBits_t bits = xEventGroupWaitBits(g_wifi_events, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(15000));
    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(TAG, "Wi-Fi connected");
    } else {
        ESP_LOGW(TAG, "Wi-Fi STA failed, switching to AP fallback");
        esp_wifi_stop();
        start_wifi_ap_fallback();
    }
}

static void start_http_server(void) {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    if (httpd_start(&g_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "HTTP server start failed");
        return;
    }

    httpd_uri_t root_uri = {.uri = "/", .method = HTTP_GET, .handler = web_root_handler};
    httpd_uri_t favicon_uri = {.uri = "/favicon.ico", .method = HTTP_GET, .handler = favicon_handler};
    httpd_uri_t status_uri = {.uri = "/api/status", .method = HTTP_GET, .handler = status_handler};
    httpd_uri_t pair_uri = {.uri = "/api/pair", .method = HTTP_POST, .handler = pair_handler};
    httpd_uri_t config_uri = {.uri = "/api/config", .method = HTTP_POST, .handler = config_handler};
    httpd_uri_t control_uri = {.uri = "/api/control", .method = HTTP_POST, .handler = control_handler};
    httpd_uri_t gpio_test_uri = {.uri = "/api/test/gpio", .method = HTTP_POST, .handler = gpio_test_handler};
    httpd_uri_t ota_uri = {.uri = "/api/ota/apply", .method = HTTP_POST, .handler = ota_apply_handler};

    httpd_register_uri_handler(g_server, &root_uri);
    httpd_register_uri_handler(g_server, &favicon_uri);
    httpd_register_uri_handler(g_server, &status_uri);
    httpd_register_uri_handler(g_server, &pair_uri);
    httpd_register_uri_handler(g_server, &config_uri);
    httpd_register_uri_handler(g_server, &control_uri);
    httpd_register_uri_handler(g_server, &gpio_test_uri);
    httpd_register_uri_handler(g_server, &ota_uri);
    ESP_LOGI(TAG, "HTTP API ready");
}

void app_main(void) {
    nvs_flash_init();
    load_config_from_nvs();
    init_outputs();
    start_wifi_station_or_ap();
    start_http_server();
}
