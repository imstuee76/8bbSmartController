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
#define MAX_RELAYS 8
#define WEB_STATUS_LED_PIN GPIO_NUM_2

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
    int relay_count;
    int relay_gpio[MAX_RELAYS];
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
    bool relay[MAX_RELAYS];
    bool light_single;
    int dimmer_pct;
    int rgb[4];
    bool fan_power;
    int fan_speed_pct;
} output_state_t;

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
} legacy_device_config_v1_t;

static device_config_t g_cfg = {
    .name = FW_DEFAULT_NAME,
    .type = FW_DEFAULT_TYPE,
    .passcode = FW_DEFAULT_PASSCODE,
    .relay_count = 4,
    .relay_gpio = {RELAY1_PIN, RELAY2_PIN, RELAY3_PIN, RELAY4_PIN, -1, -1, -1, -1},
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
static int g_last_wifi_disc_reason = 0;
static bool g_web_led_enabled = false;
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
static const int SAFE_SCAN_GPIOS[] = {2, 4, 5, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33};

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

static void sanitize_relay_count(void) {
    g_cfg.relay_count = clamp_int(g_cfg.relay_count, 1, MAX_RELAYS);
}

static bool valid_output_gpio_int(int pin) {
    return pin >= 0 && pin <= 39 && GPIO_IS_VALID_OUTPUT_GPIO(pin);
}

static bool is_safe_scan_gpio_int(int pin) {
    for (size_t i = 0; i < sizeof(SAFE_SCAN_GPIOS) / sizeof(SAFE_SCAN_GPIOS[0]); i++) {
        if (SAFE_SCAN_GPIOS[i] == pin) return true;
    }
    return false;
}

static bool valid_relay_gpio_int(int pin) {
    return valid_output_gpio_int(pin) && is_safe_scan_gpio_int(pin);
}

static bool relay_pin_in_use(int pin) {
    sanitize_relay_count();
    for (int i = 0; i < g_cfg.relay_count; i++) {
        if (g_cfg.relay_gpio[i] == pin) return true;
    }
    return false;
}

static bool aux_pin_available(int pin) {
    return valid_output_gpio_int(pin) && !relay_pin_in_use(pin);
}

static void set_web_status_led(bool on) {
    if (!g_web_led_enabled) return;
    gpio_set_level(WEB_STATUS_LED_PIN, on ? 1 : 0);
}

static void setup_web_status_led(void) {
    if (!valid_output_gpio_int(WEB_STATUS_LED_PIN)) {
        g_web_led_enabled = false;
        return;
    }
    if (relay_pin_in_use(WEB_STATUS_LED_PIN)) {
        ESP_LOGW(TAG, "Web status LED disabled, pin %d is assigned to relay", WEB_STATUS_LED_PIN);
        g_web_led_enabled = false;
        return;
    }
    gpio_reset_pin(WEB_STATUS_LED_PIN);
    gpio_set_direction(WEB_STATUS_LED_PIN, GPIO_MODE_OUTPUT);
    gpio_set_level(WEB_STATUS_LED_PIN, 0);
    g_web_led_enabled = true;
}

static void sanitize_relay_gpio_map(void) {
    sanitize_relay_count();
    for (int i = 0; i < MAX_RELAYS; i++) {
        if (valid_relay_gpio_int(g_cfg.relay_gpio[i])) continue;
        if (i < 4) {
            g_cfg.relay_gpio[i] = DEFAULT_RELAY_GPIOS[i];
        } else {
            g_cfg.relay_gpio[i] = -1;
        }
    }
}

static void configure_relay_gpio_outputs(void) {
    sanitize_relay_gpio_map();
    for (int i = 0; i < MAX_RELAYS; i++) {
        if (!valid_relay_gpio_int(g_cfg.relay_gpio[i])) continue;
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

static void save_config_to_nvs(void);

static void load_config_from_nvs(void) {
    nvs_handle_t nvs;
    if (nvs_open("cfg", NVS_READONLY, &nvs) != ESP_OK) {
        ESP_LOGW(TAG, "NVS cfg not found, using defaults");
        sanitize_relay_count();
        sanitize_relay_gpio_map();
        return;
    }
    size_t len = sizeof(g_cfg);
    esp_err_t err = nvs_get_blob(nvs, "device", &g_cfg, &len);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "Loaded config from NVS");
    } else {
        legacy_device_config_v1_t legacy = {0};
        len = sizeof(legacy);
        err = nvs_get_blob(nvs, "device", &legacy, &len);
        if (err == ESP_OK) {
            ESP_LOGW(TAG, "Loaded legacy config from NVS, migrating");
            safe_strcpy(g_cfg.name, legacy.name, sizeof(g_cfg.name));
            safe_strcpy(g_cfg.type, legacy.type, sizeof(g_cfg.type));
            safe_strcpy(g_cfg.passcode, legacy.passcode, sizeof(g_cfg.passcode));
            g_cfg.relay_count = 4;
            for (int i = 0; i < 4; i++) g_cfg.relay_gpio[i] = legacy.relay_gpio[i];
            for (int i = 4; i < MAX_RELAYS; i++) g_cfg.relay_gpio[i] = -1;
            safe_strcpy(g_cfg.wifi_ssid, legacy.wifi_ssid, sizeof(g_cfg.wifi_ssid));
            safe_strcpy(g_cfg.wifi_pass, legacy.wifi_pass, sizeof(g_cfg.wifi_pass));
            safe_strcpy(g_cfg.ap_ssid, legacy.ap_ssid, sizeof(g_cfg.ap_ssid));
            safe_strcpy(g_cfg.ap_pass, legacy.ap_pass, sizeof(g_cfg.ap_pass));
            g_cfg.use_static_ip = legacy.use_static_ip;
            safe_strcpy(g_cfg.static_ip, legacy.static_ip, sizeof(g_cfg.static_ip));
            safe_strcpy(g_cfg.gateway, legacy.gateway, sizeof(g_cfg.gateway));
            safe_strcpy(g_cfg.subnet_mask, legacy.subnet_mask, sizeof(g_cfg.subnet_mask));
            safe_strcpy(g_cfg.ota_key, legacy.ota_key, sizeof(g_cfg.ota_key));
            save_config_to_nvs();
        } else {
            ESP_LOGW(TAG, "Config read failed, using defaults");
        }
    }
    nvs_close(nvs);
    sanitize_relay_count();
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
    if (idx < 0 || idx >= MAX_RELAYS) return;
    if (idx >= g_cfg.relay_count) return;
    sanitize_relay_gpio_map();
    int pin = g_cfg.relay_gpio[idx];
    if (!valid_relay_gpio_int(pin)) return;
    gpio_set_level((gpio_num_t)pin, on ? 1 : 0);
    g_state.relay[idx] = on;
}

static void apply_light_single(bool on) {
    if (aux_pin_available(LIGHT_SINGLE_PIN)) {
        gpio_set_level(LIGHT_SINGLE_PIN, on ? 1 : 0);
    }
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
    if (aux_pin_available(FAN_POWER_PIN)) {
        gpio_set_level(FAN_POWER_PIN, g_state.fan_power ? 1 : 0);
    }
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
        if (idx < 0 || idx >= g_cfg.relay_count) return false;
        bool target = parse_on_off_toggle(st, (idx >= 0 && idx < MAX_RELAYS) ? g_state.relay[idx] : false);
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

    if (strcmp(ch, "fan") == 0 || strcmp(ch, "fan_power") == 0 || strcmp(ch, "fan_speed") == 0) {
        bool power = g_state.fan_power;
        int speed = g_state.fan_speed_pct;
        if (strcmp(ch, "fan_power") == 0) {
            power = parse_on_off_toggle(st, g_state.fan_power);
        } else if (strcmp(ch, "fan_speed") == 0) {
            speed = val;
            power = speed > 0;
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

static void configure_output_pins_only(void) {
    configure_relay_gpio_outputs();
    if (aux_pin_available(LIGHT_SINGLE_PIN)) {
        gpio_reset_pin(LIGHT_SINGLE_PIN);
        gpio_set_direction(LIGHT_SINGLE_PIN, GPIO_MODE_OUTPUT);
    } else {
        ESP_LOGW(TAG, "LIGHT_SINGLE pin %d conflicts with relay mapping; feature disabled", LIGHT_SINGLE_PIN);
    }
    if (aux_pin_available(FAN_POWER_PIN)) {
        gpio_reset_pin(FAN_POWER_PIN);
        gpio_set_direction(FAN_POWER_PIN, GPIO_MODE_OUTPUT);
    } else {
        ESP_LOGW(TAG, "FAN_POWER pin %d conflicts with relay mapping; feature disabled", FAN_POWER_PIN);
    }

    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_8_BIT,
        .timer_num = LEDC_TIMER_0,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&timer);

    typedef struct {
        int gpio;
        ledc_channel_t channel;
        const char *name;
    } pwm_chan_t;
    pwm_chan_t chans[] = {
        {.gpio = DIMMER_PIN, .channel = CH_DIMMER, .name = "DIMMER"},
        {.gpio = RGB_R_PIN, .channel = CH_RGB_R, .name = "RGB_R"},
        {.gpio = RGB_G_PIN, .channel = CH_RGB_G, .name = "RGB_G"},
        {.gpio = RGB_B_PIN, .channel = CH_RGB_B, .name = "RGB_B"},
        {.gpio = RGB_W_PIN, .channel = CH_RGB_W, .name = "RGB_W"},
        {.gpio = FAN_SPEED_PIN, .channel = CH_FAN, .name = "FAN_SPEED"},
    };
    for (size_t i = 0; i < sizeof(chans) / sizeof(chans[0]); i++) {
        ledc_stop(LEDC_LOW_SPEED_MODE, chans[i].channel, 0);
        if (!aux_pin_available(chans[i].gpio)) {
            ESP_LOGW(TAG, "%s PWM pin %d conflicts with relay mapping; channel disabled", chans[i].name, chans[i].gpio);
            continue;
        }
        ledc_channel_config_t cfg = {
            .gpio_num = chans[i].gpio,
            .speed_mode = LEDC_LOW_SPEED_MODE,
            .channel = chans[i].channel,
            .timer_sel = LEDC_TIMER_0,
            .duty = 0,
        };
        ledc_channel_config(&cfg);
    }
}

static void init_outputs(void) {
    configure_output_pins_only();

    for (int i = 0; i < MAX_RELAYS; i++) apply_relay(i, false);
    for (int i = g_cfg.relay_count; i < MAX_RELAYS; i++) {
        if (valid_output_gpio_int(g_cfg.relay_gpio[i])) {
            gpio_set_level((gpio_num_t)g_cfg.relay_gpio[i], 0);
        }
        g_state.relay[i] = false;
    }
    apply_light_single(false);
    apply_dimmer(0);
    apply_rgb(0, 0, 0, 0);
    apply_fan(false, 0);
}

static void add_ip_info_to_json(cJSON *obj, const char *prefix, esp_netif_t *netif) {
    if (!obj || !prefix || !netif) return;
    esp_netif_ip_info_t info = {0};
    if (esp_netif_get_ip_info(netif, &info) != ESP_OK) return;
    char ip[20] = {0};
    char gw[20] = {0};
    char mask[20] = {0};
    snprintf(ip, sizeof(ip), IPSTR, IP2STR(&info.ip));
    snprintf(gw, sizeof(gw), IPSTR, IP2STR(&info.gw));
    snprintf(mask, sizeof(mask), IPSTR, IP2STR(&info.netmask));

    char key_ip[32] = {0};
    char key_gw[32] = {0};
    char key_mask[32] = {0};
    snprintf(key_ip, sizeof(key_ip), "%s_ip", prefix);
    snprintf(key_gw, sizeof(key_gw), "%s_gw", prefix);
    snprintf(key_mask, sizeof(key_mask), "%s_mask", prefix);
    cJSON_AddStringToObject(obj, key_ip, ip);
    cJSON_AddStringToObject(obj, key_gw, gw);
    cJSON_AddStringToObject(obj, key_mask, mask);
}

static void add_network_status(cJSON *root) {
    cJSON *net = cJSON_CreateObject();
    wifi_mode_t mode = WIFI_MODE_NULL;
    esp_err_t mode_err = esp_wifi_get_mode(&mode);
    if (mode_err != ESP_OK) {
        cJSON_AddStringToObject(net, "mode", "unknown");
    } else if (mode == WIFI_MODE_STA) {
        cJSON_AddStringToObject(net, "mode", "sta");
    } else if (mode == WIFI_MODE_AP) {
        cJSON_AddStringToObject(net, "mode", "ap");
    } else if (mode == WIFI_MODE_APSTA) {
        cJSON_AddStringToObject(net, "mode", "apsta");
    } else {
        cJSON_AddStringToObject(net, "mode", "unknown");
    }

    bool sta_connected = false;
    if (g_wifi_events) {
        EventBits_t bits = xEventGroupGetBits(g_wifi_events);
        sta_connected = (bits & WIFI_CONNECTED_BIT) != 0;
    }
    cJSON_AddBoolToObject(net, "sta_connected", sta_connected);
    cJSON_AddNumberToObject(net, "last_disconnect_reason", g_last_wifi_disc_reason);
    cJSON_AddStringToObject(net, "configured_ssid", g_cfg.wifi_ssid);
    cJSON_AddStringToObject(net, "fallback_ap_ssid", g_cfg.ap_ssid);
    cJSON_AddBoolToObject(net, "static_ip_enabled", g_cfg.use_static_ip);

    wifi_ap_record_t ap_info = {0};
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        cJSON_AddStringToObject(net, "connected_ssid", (const char *)ap_info.ssid);
        cJSON_AddNumberToObject(net, "rssi", ap_info.rssi);
    } else {
        cJSON_AddStringToObject(net, "connected_ssid", "");
    }

    add_ip_info_to_json(net, "sta", g_sta_netif);
    add_ip_info_to_json(net, "ap", g_ap_netif);
    cJSON_AddItemToObject(root, "network", net);
}

static esp_err_t status_handler(httpd_req_t *req) {
    sanitize_relay_gpio_map();
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "name", g_cfg.name);
    cJSON_AddStringToObject(root, "type", g_cfg.type);
    cJSON_AddNumberToObject(root, "relay_count", g_cfg.relay_count);
    cJSON_AddBoolToObject(root, "static_ip_enabled", g_cfg.use_static_ip);
    cJSON_AddStringToObject(root, "static_ip", g_cfg.static_ip);
    cJSON_AddStringToObject(root, "gateway", g_cfg.gateway);
    cJSON_AddStringToObject(root, "subnet_mask", g_cfg.subnet_mask);
    cJSON_AddStringToObject(root, "fw_version", "0.3.0");
    cJSON_AddStringToObject(root, "ota_mode", "signed-hmac");

    cJSON *outputs = cJSON_CreateObject();
    for (int i = 0; i < g_cfg.relay_count; i++) {
        char key[16] = {0};
        snprintf(key, sizeof(key), "relay%d", i + 1);
        cJSON_AddBoolToObject(outputs, key, g_state.relay[i]);
    }
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
    for (int i = 0; i < MAX_RELAYS; i++) {
        cJSON_AddItemToArray(relay_gpio, cJSON_CreateNumber(g_cfg.relay_gpio[i]));
    }
    cJSON_AddItemToObject(root, "relay_gpio", relay_gpio);
    cJSON *gpio_candidates = cJSON_CreateArray();
    for (size_t i = 0; i < sizeof(SAFE_SCAN_GPIOS) / sizeof(SAFE_SCAN_GPIOS[0]); i++) {
        int pin = SAFE_SCAN_GPIOS[i];
        if (g_web_led_enabled && pin == WEB_STATUS_LED_PIN) continue;
        if (GPIO_IS_VALID_OUTPUT_GPIO(pin) && is_safe_scan_gpio_int(pin)) {
            cJSON_AddItemToArray(gpio_candidates, cJSON_CreateNumber(pin));
        }
    }
    cJSON_AddItemToObject(root, "gpio_candidates", gpio_candidates);
    cJSON_AddBoolToObject(root, "web_ui_running", g_server != NULL);
    cJSON_AddBoolToObject(root, "web_led_enabled", g_web_led_enabled);
    cJSON_AddNumberToObject(root, "web_led_pin", WEB_STATUS_LED_PIN);
    add_network_status(root);

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
        "h1{margin:0 0 10px 0;font-size:22px}h2{font-size:16px;margin:8px 0}"
        ".card{border:1px solid #2a3a4a;border-radius:10px;padding:12px;background:#131c24;margin-bottom:12px}"
        ".row{display:grid;grid-template-columns:1fr 1fr;gap:8px}"
        ".row3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}"
        ".row4{display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:8px}"
        "label{display:block;font-size:12px;color:#a8bacd;margin-bottom:6px}"
        "input,select,button,textarea{width:100%;padding:10px;border-radius:8px;border:1px solid #324657;background:#0f151c;color:#e9eef4;box-sizing:border-box}"
        "button{cursor:pointer;background:#1f3345;border-color:#4a6a85}"
        "button.secondary{background:#132332}"
        ".small{font-size:12px;color:#9cb0c3}"
        ".tabs{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0 14px}"
        ".tab{width:auto;padding:8px 12px}"
        ".tab.active{background:#2f5576}"
        ".panel{display:none}"
        ".panel.active{display:block}"
        ".relay-grid{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:8px}"
        ".relay-config-grid{display:grid;grid-template-columns:repeat(3,minmax(120px,1fr));gap:8px}"
        ".kpi{display:grid;grid-template-columns:repeat(4,minmax(130px,1fr));gap:8px}"
        "pre{background:#0b1016;border:1px solid #2a3a4a;padding:10px;border-radius:8px;overflow:auto;max-height:260px}"
        "</style></head><body>"
        "<h1>8bb ESP32 Device</h1>"
        "<div class='card'>"
        "<h2>Session</h2>"
        "<div class='row'>"
        "<div><label>Passcode</label><input id='pass' type='password' placeholder='required for write actions'/></div>"
        "<div><label>Pair Test</label><button id='pairBtn'>Pair</button></div>"
        "</div>"
        "<div class='row'>"
        "<div><label><input id='rememberPass' type='checkbox' style='width:auto;margin-right:8px'/>Remember passcode on this browser</label></div>"
        "<div><label>Saved Passcode</label><button id='clearSavedPassBtn' class='secondary'>Clear Saved Passcode</button></div>"
        "</div>"
        "<div class='row'>"
        "<button id='refreshBtn'>Refresh Status</button>"
        "<button id='applyCfgBtn'>Save Config</button>"
        "</div>"
        "<div id='actionOut' class='small'>Ready.</div>"
        "<div class='small'>Tabbed local UI. API root: /api/status</div>"
        "</div>"

        "<div class='tabs'>"
        "<button class='tab active' data-tab='overviewPanel'>Overview</button>"
        "<button class='tab' data-tab='controlsPanel'>Controls</button>"
        "<button class='tab' data-tab='gpioPanel'>GPIO Scanner</button>"
        "<button class='tab' data-tab='configPanel'>Config</button>"
        "<button class='tab' data-tab='rawPanel'>Raw Status</button>"
        "</div>"

        "<div id='overviewPanel' class='panel active'>"
        "<div class='card'>"
        "<h2>Network Connection</h2>"
        "<div class='kpi'>"
        "<div><label>Mode</label><input id='netMode' readonly/></div>"
        "<div><label>Connected SSID</label><input id='netSsid' readonly/></div>"
        "<div><label>STA IP</label><input id='netStaIp' readonly/></div>"
        "<div><label>AP IP</label><input id='netApIp' readonly/></div>"
        "</div>"
        "<div class='kpi'>"
        "<div><label>Configured SSID</label><input id='netCfgSsid' readonly/></div>"
        "<div><label>Fallback AP SSID</label><input id='netApSsid' readonly/></div>"
        "<div><label>Last Wi-Fi Reason</label><input id='netReason' readonly/></div>"
        "<div><label>Relay Ports</label><input id='relayCountView' readonly/></div>"
        "</div>"
        "</div>"
        "</div>"

        "<div id='controlsPanel' class='panel'>"
        "<div class='card'>"
        "<h2>Outputs</h2>"
        "<div id='relayButtons' class='relay-grid'></div>"
        "<div class='row3' style='margin-top:8px'>"
        "<button id='lightBtn'>Toggle Light</button>"
        "<button id='fanPowerBtn'>Toggle Fan Power</button>"
        "<button id='refreshControlBtn' class='secondary'>Reload Controls</button>"
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
        "</div>"

        "<div id='gpioPanel' class='panel'>"
        "<div class='card'>"
        "<h2>GPIO Test</h2>"
        "<div class='row3'>"
        "<div><label>GPIO</label><input id='gpioPin' type='number' min='0' max='39' value='16'/></div>"
        "<div><label>Level</label><select id='gpioLevel'><option value='1'>ON (1)</option><option value='0'>OFF (0)</option></select></div>"
        "<div><label>Apply</label><button id='gpioSetBtn'>Set GPIO</button></div>"
        "</div>"
        "<div class='small'>Temporary test only. Does not change saved relay mapping.</div>"
        "</div>"

        "<div class='card'>"
        "<h2>GPIO Scanner</h2>"
        "<div class='row4'>"
        "<button id='scanStartBtn'>Start Scan (1.5s)</button>"
        "<button id='scanPauseBtn' class='secondary'>Pause</button>"
        "<button id='scanContinueBtn' class='secondary'>Continue</button>"
        "<button id='scanStopBtn' class='secondary'>Stop</button>"
        "</div>"
        "<div class='row3' style='margin-top:8px'>"
        "<button id='scanTestOnBtn'>Test ON Current GPIO</button>"
        "<button id='scanTestOffBtn'>Test OFF Current GPIO</button>"
        "<button id='scanNextBtn' class='secondary'>Next GPIO</button>"
        "</div>"
        "<div class='row3' style='margin-top:8px'>"
        "<div><label>Start From GPIO</label><input id='scanStartPin' type='number' min='2' max='33' value='16'/></div>"
        "<div><label>Current Scan GPIO</label><input id='scanCurrentPin' readonly/></div>"
        "<div><label>Scan State</label><input id='scanState' readonly value='stopped'/></div>"
        "</div>"
        "<div class='small'>Scans only safe ESP32 output GPIOs. Use Pause instantly when relay clicks, test ON/OFF, then Continue.</div>"
        "</div>"
        "</div>"

        "<div id='configPanel' class='panel'>"
        "<div class='card'>"
        "<h2>Config</h2>"
        "<div class='row'>"
        "<div><label>Device Name</label><input id='cfgName' placeholder='8bb-esp32'/></div>"
        "<div><label>Device Type</label><input id='cfgType' placeholder='relay_switch'/></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>New Device Passcode</label><input id='cfgNewPass' type='password'/></div>"
        "<div><label>Wi-Fi SSID</label><input id='cfgWifiSsid'/></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>Wi-Fi Password</label><input id='cfgWifiPass' type='password'/></div>"
        "<div><label>Fallback AP SSID</label><input id='cfgApSsid'/></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>Fallback AP Password</label><input id='cfgApPass' type='password'/></div>"
        "<div><label>Use Static IP</label><select id='cfgStaticUse'><option value='0'>No (DHCP)</option><option value='1'>Yes</option></select></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>Static IP</label><input id='cfgStaticIp' placeholder='192.168.1.50'/></div>"
        "<div><label>Gateway</label><input id='cfgGateway' placeholder='192.168.1.1'/></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>Subnet Mask</label><input id='cfgMask' placeholder='255.255.255.0'/></div>"
        "<div><label>OTA Key</label><input id='cfgOtaKey' type='password'/></div>"
        "</div>"
        "<div class='row'>"
        "<div><label>Relay Port Count (1-8)</label><input id='cfgRelayCount' type='number' min='1' max='8' value='4'/></div>"
        "<div><label>Apply Port Count</label><button id='cfgRelayCountApply' class='secondary'>Update Relay Rows</button></div>"
        "</div>"
        "<div id='relayConfigRows' class='relay-config-grid' style='margin-top:8px'></div>"
        "</div>"
        "</div>"

        "<div id='rawPanel' class='panel'>"
        "<div class='card'><h2>Status</h2><pre id='statusOut'>Loading...</pre></div>"
        "<div class='card'><h2>Log</h2><pre id='logOut'></pre></div>"
        "</div>"
        "<script>"
        "const $=id=>document.getElementById(id);"
        "const MAX_RELAYS=8;"
        "const SAFE_GPIO=[2,4,5,12,13,14,15,16,17,18,19,21,22,23,25,26,27,32,33];"
        "const PASS_LOCAL_KEY='8bb_device_passcode_v1';"
        "const PASS_SESSION_KEY='8bb_device_passcode_session_v1';"
        "let S={};"
        "let scanner={running:false,paused:false,pins:[],idx:0,currentPin:null,timer:null};"
        "const log=m=>{const line=(new Date().toISOString()+' '+m);$('logOut').textContent=(line+'\\n'+$('logOut').textContent).slice(0,6000);$('actionOut').textContent=line;};"
        "function loadPassFromStorage(){let p='';try{p=sessionStorage.getItem(PASS_SESSION_KEY)||'';}catch(_){}if(!p){try{p=localStorage.getItem(PASS_LOCAL_KEY)||'';}catch(_){}}if(p){$('pass').value=p;}try{$('rememberPass').checked=!!localStorage.getItem(PASS_LOCAL_KEY);}catch(_){$('rememberPass').checked=false;}}"
        "function savePassToStorage(){const p=$('pass').value||'';try{if(p){sessionStorage.setItem(PASS_SESSION_KEY,p);}else{sessionStorage.removeItem(PASS_SESSION_KEY);}}catch(_){}try{if($('rememberPass').checked&&p){localStorage.setItem(PASS_LOCAL_KEY,p);}else{localStorage.removeItem(PASS_LOCAL_KEY);}}catch(_){}}"
        "const pass=()=>{const p=$('pass').value||'';savePassToStorage();return p;};"
        "function requirePass(){const p=pass();if(!p){log('enter passcode first');throw new Error('passcode required');}return p;}"
        "function setTab(name){document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));const p=$(name);if(p)p.classList.add('active');document.querySelectorAll('.tab').forEach(t=>{if(t.getAttribute('data-tab')===name)t.classList.add('active');});}"
        "document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>setTab(t.getAttribute('data-tab')));"
        "async function api(path,payload){"
        "const o=payload?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}:{};"
        "const r=await fetch(path,o);const t=await r.text();let j={};try{j=t?JSON.parse(t):{}}catch(_){j={raw:t}}"
        "if(!r.ok){throw new Error((j&&j.detail)||t||('HTTP '+r.status));}return j;}"
        "function buildRelayConfigRows(){const c=Math.min(MAX_RELAYS,Math.max(1,parseInt($('cfgRelayCount').value||'4',10)));const rg=Array.isArray(S.relay_gpio)?S.relay_gpio:[];const out=(S&&S.outputs)?S.outputs:{};let h='';for(let i=0;i<c;i++){const idx=i+1;const relayKey='relay'+idx;const v=(Number.isInteger(rg[i])?rg[i]:(i<4?[16,17,18,19][i]:-1));const st=out[relayKey]?'on':'off';h+='<div><label>Relay '+idx+' GPIO (safe only)</label><input id=\\'cfgRelay'+idx+'\\' type=\\'number\\' min=\\'-1\\' max=\\'33\\' value=\\''+v+'\\'/></div>';h+='<div><label>Relay '+idx+' Toggle</label><button type=\\'button\\' class=\\'cfgRelayToggle\\' data-relay-index=\\''+idx+'\\'>Toggle</button></div>';h+='<div><label>Current State</label><input id=\\'cfgRelayState'+idx+'\\' readonly value=\\''+st+'\\'/></div>';}$('relayConfigRows').innerHTML=h;document.querySelectorAll('.cfgRelayToggle').forEach(b=>b.onclick=()=>{const idx=b.getAttribute('data-relay-index');doControl('relay'+idx,'toggle');});}"
        "function buildRelayButtons(){const c=Math.min(MAX_RELAYS,Math.max(1,parseInt(S.relay_count||'4',10)));let h='';for(let i=1;i<=c;i++){h+='<button type=\\'button\\' class=\\'relayBtn\\' data-relay=\\'relay'+i+'\\'>Toggle Relay '+i+'</button>';}$('relayButtons').innerHTML=h;document.querySelectorAll('.relayBtn').forEach(b=>b.onclick=()=>doControl(b.getAttribute('data-relay'),'toggle'));}"
        "function setOverview(s){const n=s.network||{};$('netMode').value=n.mode||'';$('netSsid').value=n.connected_ssid||'';$('netStaIp').value=n.sta_ip||'';$('netApIp').value=n.ap_ip||'';$('netCfgSsid').value=n.configured_ssid||'';$('netApSsid').value=n.fallback_ap_ssid||'';$('netReason').value=((n.last_disconnect_reason==null)?'':n.last_disconnect_reason).toString();$('relayCountView').value=((s.relay_count==null)?'':s.relay_count).toString();}"
        "function setCfgFromStatus(s){const n=s.network||{};$('cfgName').value=s.name||$('cfgName').value;$('cfgType').value=s.type||$('cfgType').value;$('cfgStaticUse').value=s.static_ip_enabled?'1':'0';$('cfgStaticIp').value=s.static_ip||'';$('cfgGateway').value=s.gateway||'';$('cfgMask').value=s.subnet_mask||'';$('cfgWifiSsid').value=n.configured_ssid||$('cfgWifiSsid').value;$('cfgApSsid').value=n.fallback_ap_ssid||$('cfgApSsid').value;$('cfgRelayCount').value=(s.relay_count||4);buildRelayConfigRows();setOverview(s);buildRelayButtons();}"
        "async function refresh(){try{S=await api('/api/status');$('statusOut').textContent=JSON.stringify(S,null,2);setCfgFromStatus(S);log('status refreshed');}catch(e){log('status error: '+e.message);}}"
        "async function doControl(channel,state,value){try{const p={passcode:requirePass(),channel:channel,state:state};if(value!==undefined)p.value=value;const r=await api('/api/control',p);log('control '+channel+' '+state+' ok');await refresh();return r;}catch(e){log('control error: '+e.message);return null;}}"
        "$('lightBtn').onclick=()=>doControl('light','toggle');"
        "$('fanPowerBtn').onclick=()=>doControl('fan_power','toggle');"
        "$('refreshControlBtn').onclick=()=>refresh();"
        "$('setDimmerBtn').onclick=()=>doControl('dimmer','set',parseInt($('dimmerVal').value||'0',10));"
        "$('setFanBtn').onclick=()=>doControl('fan_speed','set',parseInt($('fanVal').value||'0',10));"
        "$('gpioSetBtn').onclick=async()=>{try{const p={passcode:pass(),gpio:parseInt($('gpioPin').value||'0',10),value:parseInt($('gpioLevel').value||'0',10)};const r=await api('/api/test/gpio',p);log('gpio test ok '+JSON.stringify(r));}catch(e){log('gpio test error: '+e.message);}};"
        "$('pairBtn').onclick=async()=>{try{const r=await api('/api/pair',{passcode:requirePass()});log('pair ok '+JSON.stringify(r));}catch(e){log('pair error: '+e.message);}};"
        "$('cfgRelayCountApply').onclick=()=>buildRelayConfigRows();"
        "$('refreshBtn').onclick=()=>refresh();"
        "async function scannerSet(pin,level){await api('/api/test/gpio',{passcode:requirePass(),gpio:pin,value:level});}"
        "function scannerUpdateState(t){$('scanState').value=t;}"
        "function scannerClearTimer(){if(scanner.timer){clearTimeout(scanner.timer);scanner.timer=null;}}"
        "async function scannerStep(){if(!scanner.running||scanner.paused)return;if(!scanner.pins.length){scannerUpdateState('error');log('scanner error: no safe GPIO candidates');scanner.running=false;return;}if(scanner.currentPin!==null){try{await scannerSet(scanner.currentPin,0);}catch(e){log('scanner clear gpio '+scanner.currentPin+' failed: '+e.message);}}let attempts=0;scanner.currentPin=null;while(attempts<scanner.pins.length&&scanner.currentPin===null){if(scanner.idx>=scanner.pins.length)scanner.idx=0;const pin=scanner.pins[scanner.idx++];attempts+=1;$('scanCurrentPin').value=String(pin);$('gpioPin').value=String(pin);try{await scannerSet(pin,1);scanner.currentPin=pin;scannerUpdateState('running');log('scanner gpio '+pin+' ON');}catch(e){log('scanner skip gpio '+pin+': '+e.message);}}if(scanner.currentPin===null){scannerUpdateState('error');log('scanner error: all GPIO candidates failed');scanner.running=false;return;}if(!scanner.running||scanner.paused){scannerUpdateState(scanner.paused?'paused':'stopped');return;}scanner.timer=setTimeout(()=>{scannerStep().catch(e=>log('scanner error: '+e.message));},1500);}"
        "function scannerPins(){const fromStatus=Array.isArray(S.gpio_candidates)?S.gpio_candidates:[];const base=fromStatus.length?fromStatus:SAFE_GPIO;const pins=base.map(x=>parseInt(x,10)).filter(v=>Number.isInteger(v)&&SAFE_GPIO.includes(v));return Array.from(new Set(pins));}"
        "$('scanStartBtn').onclick=async()=>{try{scanner.running=true;scanner.paused=false;scanner.pins=scannerPins();scannerClearTimer();if(scanner.currentPin!==null){try{await scannerSet(scanner.currentPin,0);}catch(_){}}scanner.currentPin=null;const startRaw=parseInt($('scanStartPin').value||'',10);if(Number.isInteger(startRaw)){const exact=scanner.pins.indexOf(startRaw);if(exact>=0){scanner.idx=exact;}else{const next=scanner.pins.findIndex(v=>v>=startRaw);scanner.idx=(next>=0?next:0);}}else{scanner.idx=0;}if(scanner.pins.length){$('scanStartPin').value=String(scanner.pins[scanner.idx]);}scannerUpdateState('starting');await scannerStep();}catch(e){log('scan start error: '+e.message);}};"
        "$('scanPauseBtn').onclick=()=>{scanner.paused=true;scannerClearTimer();scannerUpdateState('paused');log('scanner paused at gpio '+((scanner.currentPin==null)?'none':scanner.currentPin));};"
        "$('scanContinueBtn').onclick=()=>{if(!scanner.running)return;scanner.paused=false;scannerUpdateState('running');scannerStep().catch(e=>log('scanner continue error: '+e.message));};"
        "$('scanStopBtn').onclick=async()=>{scanner.running=false;scanner.paused=false;scannerClearTimer();if(scanner.currentPin!==null){try{await scannerSet(scanner.currentPin,0);}catch(_){}}scanner.currentPin=null;$('scanCurrentPin').value='';scannerUpdateState('stopped');log('scanner stopped');};"
        "$('scanNextBtn').onclick=()=>{if(!scanner.running)return;if(scanner.paused){scanner.paused=false;scannerStep().catch(e=>log('scanner next error: '+e.message));}};"
        "$('scanTestOnBtn').onclick=async()=>{try{const p=scanner.currentPin!==null?scanner.currentPin:parseInt($('gpioPin').value||'0',10);await scannerSet(p,1);$('scanCurrentPin').value=String(p);scanner.currentPin=p;log('manual test ON gpio '+p);}catch(e){log('manual test ON error: '+e.message);}};"
        "$('scanTestOffBtn').onclick=async()=>{try{const p=scanner.currentPin!==null?scanner.currentPin:parseInt($('gpioPin').value||'0',10);await scannerSet(p,0);$('scanCurrentPin').value=String(p);scanner.currentPin=p;log('manual test OFF gpio '+p);}catch(e){log('manual test OFF error: '+e.message);}};"
        "$('pass').addEventListener('input',()=>savePassToStorage());"
        "$('rememberPass').addEventListener('change',()=>savePassToStorage());"
        "$('clearSavedPassBtn').onclick=()=>{try{localStorage.removeItem(PASS_LOCAL_KEY);}catch(_){}try{sessionStorage.removeItem(PASS_SESSION_KEY);}catch(_){}$('pass').value='';$('rememberPass').checked=false;log('saved passcode cleared');};"
        "$('applyCfgBtn').onclick=async()=>{"
        "try{const p={passcode:pass(),use_static_ip:$('cfgStaticUse').value==='1'};"
        "const setIf=(k,v)=>{if(v!==undefined&&v!==null&&String(v).length>0)p[k]=v;};"
        "setIf('name',$('cfgName').value.trim());setIf('type',$('cfgType').value.trim());setIf('new_passcode',$('cfgNewPass').value);"
        "setIf('wifi_ssid',$('cfgWifiSsid').value);setIf('wifi_pass',$('cfgWifiPass').value);"
        "const c=Math.min(MAX_RELAYS,Math.max(1,parseInt($('cfgRelayCount').value||'4',10)));p.relay_count=c;const rg=[];for(let i=1;i<=MAX_RELAYS;i++){const el=$('cfgRelay'+i);if(!el){rg.push(-1);continue;}const raw=parseInt(el.value||'-1',10);if(raw===-1){rg.push(-1);}else if(Number.isInteger(raw)&&SAFE_GPIO.includes(raw)){rg.push(raw);}else{rg.push(-1);log('relay '+i+' gpio '+el.value+' not safe, set to -1');}}p.relay_gpio=rg;"
        "setIf('ap_ssid',$('cfgApSsid').value);setIf('ap_pass',$('cfgApPass').value);"
        "setIf('static_ip',$('cfgStaticIp').value.trim());setIf('gateway',$('cfgGateway').value.trim());setIf('subnet_mask',$('cfgMask').value.trim());"
        "setIf('ota_key',$('cfgOtaKey').value);"
        "await api('/api/config',p);log('config saved, reboot device for Wi-Fi mode changes if needed');await refresh();"
        "}catch(e){log('config error: '+e.message);}};"
        "loadPassFromStorage();"
        "scannerUpdateState('stopped');"
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
    char buf[2048] = {0};
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
    cJSON *relay_count = cJSON_GetObjectItem(root, "relay_count");
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
    if (cJSON_IsNumber(relay_count)) g_cfg.relay_count = relay_count->valueint;
    if (cJSON_IsArray(relay_gpio)) {
        for (int i = 0; i < MAX_RELAYS; i++) {
            cJSON *it = cJSON_GetArrayItem(relay_gpio, i);
            if (cJSON_IsNumber(it)) {
                int pin = it->valueint;
                if (pin == -1 || valid_relay_gpio_int(pin)) {
                    g_cfg.relay_gpio[i] = pin;
                }
            }
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
    sanitize_relay_count();
    sanitize_relay_gpio_map();
    configure_output_pins_only();
    setup_web_status_led();
    set_web_status_led(g_server != NULL);
    for (int i = 0; i < MAX_RELAYS; i++) {
        if (i < g_cfg.relay_count) {
            apply_relay(i, g_state.relay[i]);
        } else {
            if (valid_relay_gpio_int(g_cfg.relay_gpio[i])) {
                gpio_set_level((gpio_num_t)g_cfg.relay_gpio[i], 0);
            }
            g_state.relay[i] = false;
        }
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
        g_last_wifi_disc_reason = disc ? disc->reason : -1;
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
        g_last_wifi_disc_reason = 0;
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
        set_web_status_led(false);
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
    setup_web_status_led();
    set_web_status_led(true);
    ESP_LOGI(TAG, "HTTP API ready");
}

void app_main(void) {
    nvs_flash_init();
    load_config_from_nvs();
    init_outputs();
    start_wifi_station_or_ap();
    start_http_server();
}
