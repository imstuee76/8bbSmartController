let token = "";
const TOKEN_KEY = "8bb_flasher_auth_token_v1";
const DRAFT_KEY = "8bb_flasher_profile_workflow_v1";

const authSetup = document.getElementById("authSetup");
const authLogin = document.getElementById("authLogin");
const appPanel = document.getElementById("appPanel");

const scanOut = document.getElementById("scanOut");
const actionOut = document.getElementById("actionOut");
const staticIpFields = document.getElementById("staticIpFields");
const deviceTypeOptions = document.getElementById("deviceTypeOptions");

const profileDeviceType = document.getElementById("profileDeviceType");
const ipMode = document.getElementById("ipMode");
const firmwareSelect = document.getElementById("firmwareSelect");
const flashOut = document.getElementById("flashOut");
const monitorOut = document.getElementById("monitorOut");
const diagOut = document.getElementById("diagOut");
const flasherVersionLabel = document.getElementById("flasherVersionLabel");

const DEFAULT_BAUDS = [115200, 230400, 460800, 921600, 1000000, 1500000, 2000000];
const DEFAULT_RELAY_GPIOS = [16, 17, 18, 19, -1, -1, -1, -1];
let flashPollTimer = null;
let monitorPollTimer = null;
let monitorSessionId = "";
let activeFlashJobId = "";
let comCooldownUntil = 0;

function stopBackgroundPolling() {
  if (flashPollTimer) {
    clearInterval(flashPollTimer);
    flashPollTimer = null;
  }
  activeFlashJobId = "";
  comCooldownUntil = 0;
  if (monitorPollTimer) {
    clearInterval(monitorPollTimer);
    monitorPollTimer = null;
  }
}

function handleAuthExpired() {
  token = "";
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch {
    // Best effort only.
  }
  monitorSessionId = "";
  stopBackgroundPolling();
  hide(appPanel);
  hide(authSetup);
  show(authLogin);
}

function getEl(id) {
  return document.getElementById(id);
}

async function api(path, opts = {}) {
  const headers = { "Content-Type": "application/json", ...(opts.headers || {}) };
  if (token) {
    headers["X-Auth-Token"] = token;
  }
  const res = await fetch(path, { ...opts, headers });
  const text = await res.text();
  let body = {};
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { raw: text };
  }
  if (!res.ok) {
    if (res.status === 401) {
      handleAuthExpired();
      throw new Error("Authentication expired. Please login again.");
    }
    let message = text || `HTTP ${res.status}`;
    if (body && body.detail) {
      if (typeof body.detail === "string") {
        message = body.detail;
      } else if (typeof body.detail === "object") {
        message = body.detail.message || JSON.stringify(body.detail, null, 2);
      }
    }
    throw new Error(message);
  }
  return body;
}

function show(el) {
  el.classList.remove("hidden");
}

function hide(el) {
  el.classList.add("hidden");
}

function print(out, label, payload) {
  const lines = [label, ""]; 
  if (typeof payload === "string") {
    lines.push(payload);
  } else {
    lines.push(JSON.stringify(payload, null, 2));
  }
  out.textContent = lines.join("\n");
}

function showError(err) {
  const message = err instanceof Error ? err.message : String(err);
  print(actionOut, "Error", message);
}

function clampInt(value, min, max, fallback) {
  const num = parseInt(String(value || ""), 10);
  if (Number.isNaN(num)) return fallback;
  return Math.max(min, Math.min(max, num));
}

function defaultRelayGpioForIndex(idx) {
  if (idx < 1 || idx > 8) {
    return -1;
  }
  return DEFAULT_RELAY_GPIOS[idx - 1];
}

function parseRelayGpioValue(rawValue, idx) {
  const fallback = defaultRelayGpioForIndex(idx);
  const text = String(rawValue == null ? "" : rawValue).trim();
  if (!text) {
    return fallback;
  }
  const num = parseInt(text, 10);
  if (Number.isNaN(num)) {
    return fallback;
  }
  if (num === -1) {
    return -1;
  }
  return Math.max(0, Math.min(39, num));
}

function requireLoggedIn() {
  if (!token) {
    throw new Error("Login required. Please login first.");
  }
}

function requireNoActiveFlash(actionLabel) {
  if (activeFlashJobId) {
    throw new Error(`Cannot ${actionLabel} while flash job ${activeFlashJobId} is running.`);
  }
  const now = Date.now();
  if (comCooldownUntil > now) {
    const waitSec = Math.max(1, Math.ceil((comCooldownUntil - now) / 1000));
    throw new Error(`Please wait ${waitSec}s before ${actionLabel}. Releasing COM port...`);
  }
}

function setupBaudSelect(selectId, fallback = 921600) {
  const select = getEl(selectId);
  if (!select) {
    return;
  }
  if (!select.options.length) {
    DEFAULT_BAUDS.forEach((baud) => {
      const opt = document.createElement("option");
      opt.value = String(baud);
      opt.textContent = String(baud);
      select.appendChild(opt);
    });
  }
  const current = parseInt(select.value || "", 10);
  if (Number.isNaN(current)) {
    select.value = String(fallback);
  }
}

function escapeAttr(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function captureFormState() {
  const state = {};
  document.querySelectorAll("#appPanel input, #appPanel select, #appPanel textarea").forEach((el) => {
    if (!el.id || el.type === "file") {
      return;
    }
    if (el.type === "checkbox") {
      state[el.id] = el.checked;
      return;
    }
    state[el.id] = el.value;
  });
  return state;
}

function applyFormState(state) {
  if (!state || typeof state !== "object") {
    return;
  }
  Object.entries(state).forEach(([id, value]) => {
    const el = getEl(id);
    if (!el || el.type === "file") {
      return;
    }
    if (el.type === "checkbox") {
      el.checked = Boolean(value);
      return;
    }
    el.value = value == null ? "" : String(value);
  });
}

function saveDraft() {
  try {
    const state = captureFormState();
    localStorage.setItem(DRAFT_KEY, JSON.stringify(state));
  } catch {
    // Best effort only.
  }
}

function loadDraft() {
  try {
    const raw = localStorage.getItem(DRAFT_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === "object") {
      return parsed;
    }
  } catch {
    // Best effort only.
  }
  return {};
}

function toggleStaticIpFields() {
  if (ipMode.value === "static") {
    show(staticIpFields);
  } else {
    hide(staticIpFields);
  }
}

function renderRelayRows(state = {}) {
  const relayCount = clampInt(getEl("relayCount")?.value, 1, 8, 1);
  const matrix = getEl("relayMatrix");
  if (!matrix) {
    return;
  }
  const rows = [];
  rows.push('<div class="head">Relay Name</div><div class="head">GPIO</div><div class="head">Invert</div>');
  for (let idx = 1; idx <= relayCount; idx += 1) {
    const nameId = `relayName${idx}`;
    const gpioId = `relayGpio${idx}`;
    const invertId = `relayInvert${idx}`;
    const nameValue = state[nameId] || `Relay ${idx}`;
    const gpioValue =
      state[gpioId] == null || String(state[gpioId]).trim() === ""
        ? String(defaultRelayGpioForIndex(idx))
        : String(state[gpioId]);
    const invertChecked = state[invertId] ? "checked" : "";

    rows.push(`<input id="${nameId}" value="${escapeAttr(nameValue)}" />`);
    rows.push(`<input id="${gpioId}" type="number" min="-1" max="39" value="${escapeAttr(gpioValue)}" />`);
    rows.push(`<input id="${invertId}" type="checkbox" ${invertChecked} />`);
  }
  matrix.innerHTML = rows.join("");
}

function renderFanRows(state = {}) {
  const speedCount = clampInt(getEl("fanSpeedCount")?.value, 2, 8, 3);
  const matrix = getEl("fanMatrix");
  if (!matrix) {
    return;
  }
  const rows = [];
  rows.push('<div class="head">Speed Label</div><div class="head">Percent</div><div class="head">Reserved</div>');
  for (let idx = 1; idx <= speedCount; idx += 1) {
    const labelId = `fanSpeedLabel${idx}`;
    const pctId = `fanSpeedPct${idx}`;
    const labelValue = state[labelId] || `Speed ${idx}`;
    const pctDefault = Math.round((idx / speedCount) * 100);
    const pctValue = state[pctId] || String(pctDefault);

    rows.push(`<input id="${labelId}" value="${escapeAttr(labelValue)}" />`);
    rows.push(`<input id="${pctId}" type="number" min="1" max="100" value="${escapeAttr(pctValue)}" />`);
    rows.push('<input disabled value="-" />');
  }
  matrix.innerHTML = rows.join("");
}

function renderDeviceTypeOptions() {
  const snapshot = captureFormState();
  const type = profileDeviceType.value;

  if (type === "relay_switch") {
    deviceTypeOptions.innerHTML = `
      <div class="grid two-col">
        <label>Relay Count
          <input id="relayCount" type="number" min="1" max="8" value="2" />
        </label>
        <label>Button Count
          <input id="buttonCount" type="number" min="0" max="8" value="2" />
        </label>
        <label>Boot State
          <select id="relayBootState">
            <option value="off">All Off</option>
            <option value="on">All On</option>
            <option value="restore">Restore Last</option>
          </select>
        </label>
      </div>
      <div id="relayMatrix" class="dynamic-grid"></div>
    `;
    applyFormState(snapshot);
    renderRelayRows(snapshot);
    getEl("relayCount")?.addEventListener("change", () => {
      const current = captureFormState();
      renderRelayRows(current);
      saveDraft();
    });
    return;
  }

  if (type === "fan") {
    deviceTypeOptions.innerHTML = `
      <div class="grid two-col">
        <label>Speed Levels
          <input id="fanSpeedCount" type="number" min="2" max="8" value="3" />
        </label>
        <label>PWM GPIO
          <input id="fanPwmGpio" type="number" min="0" max="39" value="18" />
        </label>
        <label>Enable GPIO
          <input id="fanEnableGpio" type="number" min="0" max="39" value="19" />
        </label>
        <label>Oscillation Support
          <input id="fanOscillation" type="checkbox" />
        </label>
      </div>
      <div id="fanMatrix" class="dynamic-grid"></div>
    `;
    applyFormState(snapshot);
    renderFanRows(snapshot);
    getEl("fanSpeedCount")?.addEventListener("change", () => {
      const current = captureFormState();
      renderFanRows(current);
      saveDraft();
    });
    return;
  }

  if (type === "light_single") {
    deviceTypeOptions.innerHTML = `
      <div class="grid two-col">
        <label>Light GPIO
          <input id="singleLightGpio" type="number" min="0" max="39" value="23" />
        </label>
        <label>Default State
          <select id="singleLightDefaultState">
            <option value="off">Off</option>
            <option value="on">On</option>
            <option value="restore">Restore Last</option>
          </select>
        </label>
      </div>
    `;
    applyFormState(snapshot);
    return;
  }

  if (type === "light_dimmer") {
    deviceTypeOptions.innerHTML = `
      <div class="grid two-col">
        <label>Dimmer PWM GPIO
          <input id="dimmerPwmGpio" type="number" min="0" max="39" value="23" />
        </label>
        <label>Dimming Curve
          <select id="dimmerCurve">
            <option value="linear">Linear</option>
            <option value="gamma22">Gamma 2.2</option>
          </select>
        </label>
        <label>Min Brightness (%)
          <input id="dimmerMin" type="number" min="1" max="100" value="5" />
        </label>
        <label>Max Brightness (%)
          <input id="dimmerMax" type="number" min="1" max="100" value="100" />
        </label>
      </div>
    `;
    applyFormState(snapshot);
    return;
  }

  if (type === "light_rgb") {
    deviceTypeOptions.innerHTML = `
      <div class="grid three-col">
        <label>GPIO Red
          <input id="rgbPinR" type="number" min="0" max="39" value="25" />
        </label>
        <label>GPIO Green
          <input id="rgbPinG" type="number" min="0" max="39" value="26" />
        </label>
        <label>GPIO Blue
          <input id="rgbPinB" type="number" min="0" max="39" value="27" />
        </label>
      </div>
      <div class="grid two-col">
        <label>Color Order
          <select id="rgbOrder">
            <option value="RGB">RGB</option>
            <option value="GRB">GRB</option>
            <option value="BRG">BRG</option>
          </select>
        </label>
        <label>Enable Effects
          <input id="rgbEffects" type="checkbox" checked />
        </label>
      </div>
    `;
    applyFormState(snapshot);
    return;
  }

  if (type === "light_rgbw") {
    deviceTypeOptions.innerHTML = `
      <div class="grid three-col">
        <label>GPIO Red
          <input id="rgbwPinR" type="number" min="0" max="39" value="25" />
        </label>
        <label>GPIO Green
          <input id="rgbwPinG" type="number" min="0" max="39" value="26" />
        </label>
        <label>GPIO Blue
          <input id="rgbwPinB" type="number" min="0" max="39" value="27" />
        </label>
        <label>GPIO White
          <input id="rgbwPinW" type="number" min="0" max="39" value="14" />
        </label>
      </div>
      <div class="grid two-col">
        <label>Color Order
          <select id="rgbwOrder">
            <option value="RGBW">RGBW</option>
            <option value="GRBW">GRBW</option>
            <option value="BRGW">BRGW</option>
          </select>
        </label>
        <label>Enable Color Temperature Blend
          <input id="rgbwColorTempBlend" type="checkbox" checked />
        </label>
      </div>
    `;
    applyFormState(snapshot);
    return;
  }

  deviceTypeOptions.innerHTML = "";
}

function collectRelaySettings() {
  const count = clampInt(getEl("relayCount")?.value, 1, 8, 1);
  const relays = [];
  const relayGpio = [];
  for (let idx = 1; idx <= count; idx += 1) {
    const gpio = parseRelayGpioValue(getEl(`relayGpio${idx}`)?.value, idx);
    relayGpio.push(gpio);
    relays.push({
      index: idx,
      name: getEl(`relayName${idx}`)?.value?.trim() || `Relay ${idx}`,
      gpio,
      invert: Boolean(getEl(`relayInvert${idx}`)?.checked),
    });
  }
  for (let idx = count + 1; idx <= 8; idx += 1) {
    relayGpio.push(-1);
  }
  return {
    relay_count: count,
    button_count: clampInt(getEl("buttonCount")?.value, 0, 8, 0),
    boot_state: getEl("relayBootState")?.value || "off",
    relays,
    relay_gpio: relayGpio,
  };
}

function collectFanSettings() {
  const speedCount = clampInt(getEl("fanSpeedCount")?.value, 2, 8, 3);
  const speeds = [];
  for (let idx = 1; idx <= speedCount; idx += 1) {
    speeds.push({
      index: idx,
      label: getEl(`fanSpeedLabel${idx}`)?.value?.trim() || `Speed ${idx}`,
      percent: clampInt(getEl(`fanSpeedPct${idx}`)?.value, 1, 100, Math.round((idx / speedCount) * 100)),
    });
  }
  return {
    speed_count: speedCount,
    pwm_gpio: clampInt(getEl("fanPwmGpio")?.value, 0, 39, 18),
    enable_gpio: clampInt(getEl("fanEnableGpio")?.value, 0, 39, 19),
    oscillation: Boolean(getEl("fanOscillation")?.checked),
    speeds,
  };
}

function collectLightSingleSettings() {
  return {
    gpio: clampInt(getEl("singleLightGpio")?.value, 0, 39, 23),
    default_state: getEl("singleLightDefaultState")?.value || "off",
  };
}

function collectLightDimmerSettings() {
  const min = clampInt(getEl("dimmerMin")?.value, 1, 100, 5);
  const max = clampInt(getEl("dimmerMax")?.value, min, 100, 100);
  return {
    pwm_gpio: clampInt(getEl("dimmerPwmGpio")?.value, 0, 39, 23),
    curve: getEl("dimmerCurve")?.value || "linear",
    min_brightness_pct: min,
    max_brightness_pct: max,
  };
}

function collectLightRgbSettings() {
  return {
    pin_r: clampInt(getEl("rgbPinR")?.value, 0, 39, 25),
    pin_g: clampInt(getEl("rgbPinG")?.value, 0, 39, 26),
    pin_b: clampInt(getEl("rgbPinB")?.value, 0, 39, 27),
    color_order: getEl("rgbOrder")?.value || "RGB",
    effects_enabled: Boolean(getEl("rgbEffects")?.checked),
  };
}

function collectLightRgbwSettings() {
  return {
    pin_r: clampInt(getEl("rgbwPinR")?.value, 0, 39, 25),
    pin_g: clampInt(getEl("rgbwPinG")?.value, 0, 39, 26),
    pin_b: clampInt(getEl("rgbwPinB")?.value, 0, 39, 27),
    pin_w: clampInt(getEl("rgbwPinW")?.value, 0, 39, 14),
    color_order: getEl("rgbwOrder")?.value || "RGBW",
    color_temp_blend: Boolean(getEl("rgbwColorTempBlend")?.checked),
  };
}

function collectTypeSettings(type) {
  if (type === "relay_switch") return collectRelaySettings();
  if (type === "fan") return collectFanSettings();
  if (type === "light_single") return collectLightSingleSettings();
  if (type === "light_dimmer") return collectLightDimmerSettings();
  if (type === "light_rgb") return collectLightRgbSettings();
  if (type === "light_rgbw") return collectLightRgbwSettings();
  return {};
}

function collectNetworkSettings() {
  return {
    wifi: {
      ssid: getEl("wifiSsid").value.trim(),
      password: getEl("wifiPassword").value,
    },
    fallback_ap: {
      ssid: getEl("fallbackApSsid").value.trim(),
      password: getEl("fallbackApPassword").value,
      timeout_sec: clampInt(getEl("fallbackApTimeout").value, 30, 3600, 300),
    },
    ip: {
      mode: getEl("ipMode").value,
      static_ip: getEl("staticIp").value.trim(),
      gateway: getEl("gatewayIp").value.trim(),
      subnet_mask: getEl("subnetMask").value.trim(),
      dns1: getEl("dns1").value.trim(),
      dns2: getEl("dns2").value.trim(),
    },
  };
}

function syncDynamicRowsFromState(state = {}) {
  const type = profileDeviceType.value;
  if (type === "relay_switch") {
    renderRelayRows(state);
  } else if (type === "fan") {
    renderFanRows(state);
  }
}

function collectWorkflowPayload() {
  const profileName = getEl("profileName").value.trim();
  const version = getEl("profileVersion").value.trim();
  const firmware = getEl("firmwareSelect").value;
  const deviceType = getEl("profileDeviceType").value;

  if (!profileName) {
    throw new Error("Profile name is required.");
  }
  if (!version) {
    throw new Error("Version is required.");
  }
  if (!firmware) {
    throw new Error("Firmware is missing. Click Build Firmware first.");
  }

  const network = collectNetworkSettings();
  if (!network.wifi.ssid) {
    throw new Error("Wi-Fi SSID is required.");
  }
  if (network.ip.mode === "static" && (!network.ip.static_ip || !network.ip.gateway || !network.ip.subnet_mask)) {
    throw new Error("Static IP mode requires static IP, gateway, and subnet mask.");
  }

  return {
    profile_name: profileName,
    firmware_filename: firmware,
    version,
    device_type: deviceType,
    settings: {
      general: {
        device_name: getEl("deviceName").value.trim(),
        device_passcode: getEl("devicePasscode").value,
        mdns_hostname: getEl("deviceHostname").value.trim(),
        ota_channel: getEl("otaChannel").value,
      },
      network,
      device: collectTypeSettings(deviceType),
    },
    notes: getEl("profileNotes").value.trim(),
  };
}

async function bootAuth() {
  await loadSystemVersion();
  const status = await api("/api/auth/status");
  if (!status.configured) {
    show(authSetup);
    hide(authLogin);
    hide(appPanel);
  } else {
    hide(authSetup);
    hide(appPanel);
    const savedToken = (() => {
      try {
        return localStorage.getItem(TOKEN_KEY) || "";
      } catch {
        return "";
      }
    })();
    token = savedToken;
    if (savedToken) {
      try {
        await api("/api/auth/validate");
        hide(authLogin);
        show(appPanel);
        await initAfterLogin();
        return;
      } catch {
        token = "";
        try {
          localStorage.removeItem(TOKEN_KEY);
        } catch {
          // Best effort only.
        }
      }
    }
    show(authLogin);
  }
}

async function loadSystemVersion() {
  try {
    const result = await api("/api/system/version");
    const flasher = result.flasher || {};
    const version = `${flasher.version || "0.0.0"}+${flasher.build || 0}`;
    const updated = result.updated_at || "";
    if (flasherVersionLabel) {
      flasherVersionLabel.textContent = `Version: ${version}${updated ? ` | Updated: ${updated}` : ""}`;
    }
  } catch (err) {
    if (flasherVersionLabel) {
      flasherVersionLabel.textContent = "Version: unavailable";
    }
  }
}

async function loadFirmware() {
  const current = getEl("firmwareSelect").value;
  const files = await api("/api/files/firmware");
  const select = getEl("firmwareSelect");
  select.innerHTML = "";
  files.forEach((name) => {
    const opt = document.createElement("option");
    opt.value = name;
    opt.textContent = name;
    select.appendChild(opt);
  });
  if (current && files.includes(current)) {
    select.value = current;
  }
}

async function buildFirmwareFromSource() {
  requireLoggedIn();
  const profileName = getEl("profileName").value.trim() || "profile";
  const version = getEl("profileVersion").value.trim() || "1.0.0";
  const deviceType = getEl("profileDeviceType").value;
  const typeSettings = collectTypeSettings(deviceType);
  const ipModeVal = getEl("ipMode").value;
  const defaults = {
    name: getEl("deviceName").value.trim() || profileName,
    type: deviceType,
    passcode: getEl("devicePasscode").value || "1234",
    wifi_ssid: getEl("wifiSsid").value.trim(),
    wifi_pass: getEl("wifiPassword").value,
    ap_ssid: getEl("fallbackApSsid").value.trim() || "8bb-device-setup",
    ap_pass: getEl("fallbackApPassword").value || "12345678",
    use_static_ip: ipModeVal === "static",
    static_ip: getEl("staticIp").value.trim(),
    gateway: getEl("gatewayIp").value.trim(),
    subnet_mask: getEl("subnetMask").value.trim(),
    type_settings: typeSettings,
  };
  if (deviceType === "relay_switch" && typeSettings && typeof typeSettings === "object") {
    defaults.relay_count = clampInt(typeSettings.relay_count, 1, 8, 1);
    defaults.relay_gpio = Array.isArray(typeSettings.relay_gpio) ? typeSettings.relay_gpio.slice(0, 8) : [];
  }
  const startedAt = Date.now();
  print(actionOut, "Build Firmware", "Compiling firmware from esp32-firmware...\nThis can take a few minutes.");
  const timer = setInterval(() => {
    const sec = Math.floor((Date.now() - startedAt) / 1000);
    print(actionOut, "Build Firmware", `Working...\nElapsed: ${sec}s`);
  }, 1000);
  let result = null;
  try {
    result = await api("/api/firmware/build", {
      method: "POST",
      body: JSON.stringify({
        profile_name: profileName,
        version,
        device_type: deviceType,
        defaults,
      }),
    });
  } finally {
    clearInterval(timer);
  }
  await loadFirmware();
  const preferred = result.ota_firmware_filename || "";
  if (preferred) {
    firmwareSelect.value = preferred;
  }
  if (result.version) {
    getEl("profileVersion").value = String(result.version);
  }
  saveDraft();
  print(actionOut, "Build Firmware", {
    build_id: result.build_id,
    version: result.version,
    log_file: result.log_file,
    ota_firmware_filename: result.ota_firmware_filename,
    serial_firmware_filename: result.serial_firmware_filename,
    build_log_tail: result.build_log,
    merge_log_tail: result.merge_log,
  });
  return result;
}

function setSelectedFirmware(name) {
  if (!name) {
    return;
  }
  const options = Array.from(firmwareSelect.options).map((o) => o.value);
  if (options.includes(name)) {
    firmwareSelect.value = name;
  }
}

async function ensureFirmwareForAction(actionKind) {
  const selected = firmwareSelect.value.trim();
  if (selected) {
    return selected;
  }
  const built = await buildFirmwareFromSource();
  if (actionKind === "serial" && !built.serial_firmware_filename) {
    throw new Error(
      "Serial merged firmware was not generated. Check Build Firmware output log and ESP-IDF merge-bin support.",
    );
  }
  const preferred =
    actionKind === "serial"
      ? (built.serial_firmware_filename || "")
      : (built.ota_firmware_filename || built.serial_firmware_filename || "");
  setSelectedFirmware(preferred);
  return firmwareSelect.value.trim();
}

async function loadPorts() {
  const currentFlash = getEl("portSelect").value;
  const currentMonitor = getEl("monitorPortSelect").value;
  const ports = await api("/api/flash/ports");
  const flashSelect = getEl("portSelect");
  const monitorSelect = getEl("monitorPortSelect");
  flashSelect.innerHTML = "";
  monitorSelect.innerHTML = "";
  ports.forEach((item) => {
    const opt = document.createElement("option");
    opt.value = item.device;
    opt.textContent = `${item.device} - ${item.description || "serial"}`;
    flashSelect.appendChild(opt);
    monitorSelect.appendChild(opt.cloneNode(true));
  });
  if (!ports.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "No ports detected";
    flashSelect.appendChild(opt);
    monitorSelect.appendChild(opt.cloneNode(true));
  }
  if (currentFlash) {
    flashSelect.value = currentFlash;
  }
  if (currentMonitor) {
    monitorSelect.value = currentMonitor;
  }
}

async function loadProfiles() {
  const current = getEl("profileSelect").value;
  const result = await api("/api/firmware/profiles");
  const profiles = result.profiles || [];
  const select = getEl("profileSelect");
  select.innerHTML = "";
  profiles.forEach((p) => {
    const opt = document.createElement("option");
    opt.value = p.profile_id;
    opt.textContent = `${p.profile_name} | ${p.device_type} | ${p.version} | ${p.created_at}`;
    select.appendChild(opt);
  });
  if (!profiles.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "No profiles yet";
    select.appendChild(opt);
  }
  if (current) {
    select.value = current;
  }
}

async function loadDevices() {
  const current = getEl("otaDeviceSelect").value;
  const devices = await api("/api/devices");
  const select = getEl("otaDeviceSelect");
  select.innerHTML = "";

  devices.forEach((d) => {
    const opt = document.createElement("option");
    opt.value = d.id;
    const host = d.host || "no-host";
    opt.textContent = `${d.name} | ${d.type} | ${host}`;
    select.appendChild(opt);
  });

  if (!devices.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "No devices registered";
    select.appendChild(opt);
  }
  if (current) {
    select.value = current;
  }
}

async function uploadFirmware() {
  const fileInput = getEl("firmwareFile");
  const file = fileInput.files[0];
  if (!file) {
    throw new Error("Select a .bin file first.");
  }

  const form = new FormData();
  form.append("file", file);
  const headers = {};
  if (token) {
    headers["X-Auth-Token"] = token;
  }

  const res = await fetch("/api/files/firmware/upload", {
    method: "POST",
    headers,
    body: form,
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(text || `HTTP ${res.status}`);
  }

  await loadFirmware();
  print(actionOut, "Firmware Upload", text || "Upload complete");
}

async function scanNetwork() {
  const result = await api("/api/discovery/scan", {
    method: "POST",
    body: JSON.stringify({ subnet_hint: "" }),
  });
  print(scanOut, "Scan Results", result.results || []);
}

async function flashToPort() {
  requireNoActiveFlash("start another COM action");
  if (monitorSessionId) {
    await stopSerialMonitor();
  }
  flashOut.textContent = "Building fresh firmware from current form values before flash...";
  const built = await buildFirmwareFromSource();
  const firmware = (built && built.serial_firmware_filename ? String(built.serial_firmware_filename) : "").trim();
  const port = getEl("portSelect").value.trim();
  const baud = clampInt(getEl("baudSelect").value, 115200, 3000000, 921600);

  if (!firmware) {
    throw new Error("Fresh build did not produce a serial *_full.bin firmware.");
  }
  setSelectedFirmware(firmware);
  if (!port) {
    throw new Error("Select a serial port first.");
  }

  flashOut.textContent = `Starting serial flash with fresh build: ${firmware}`;
  const job = await api("/api/flash/jobs", {
    method: "POST",
    body: JSON.stringify({ port, baud, firmware_filename: firmware }),
  });

  const jobId = job.job_id;
  activeFlashJobId = jobId;
  flashOut.textContent = `Job ${jobId}\nStatus: queued\n`;
  if (flashPollTimer) {
    clearInterval(flashPollTimer);
  }
  flashPollTimer = setInterval(async () => {
    try {
      const status = await api(`/api/flash/jobs/${jobId}`);
      const state = status.status || "unknown";
      const body = status.output || "";
      flashOut.textContent = [
        `Job ${jobId}`,
        `Status: ${state}`,
        `Port: ${status.port || port}`,
        `Baud: ${status.baud || baud}`,
        "",
        body,
      ].join("\n");
      if (status.status === "success" || status.status === "failed") {
        clearInterval(flashPollTimer);
        flashPollTimer = null;
        activeFlashJobId = "";
        comCooldownUntil = Date.now() + 3500;
      }
    } catch (err) {
      clearInterval(flashPollTimer);
      flashPollTimer = null;
      activeFlashJobId = "";
      comCooldownUntil = Date.now() + 2000;
      showError(err);
    }
  }, 1500);
}

async function buildProfilePackage() {
  await ensureFirmwareForAction("ota");
  const payload = collectWorkflowPayload();
  print(actionOut, "Build OTA File", "Creating profile package...");
  const result = await api("/api/firmware/profiles", {
    method: "POST",
    body: JSON.stringify(payload),
  });

  await loadProfiles();
  getEl("profileSelect").value = result.profile_id || "";
  print(actionOut, "Build OTA File", {
    profile_id: result.profile_id,
    profile_name: result.profile_name,
    profile_folder: result.profile_folder,
    saved_under: `data/firmware_profiles/${result.profile_folder}`,
    files: result.files,
  });
}

async function flashOta() {
  const profileId = getEl("profileSelect").value.trim();
  const deviceId = getEl("otaDeviceSelect").value.trim();
  if (!profileId) {
    throw new Error("Select a saved profile first.");
  }
  if (!deviceId) {
    throw new Error("Select a target device first.");
  }

  print(actionOut, "Flash OTA", "Pushing profile OTA to device...");
  const result = await api(`/api/firmware/profiles/${encodeURIComponent(profileId)}/push/${encodeURIComponent(deviceId)}`, {
    method: "POST",
    body: JSON.stringify({}),
  });
  print(actionOut, "Flash OTA", result);
}

async function pollSerialMonitor() {
  if (!monitorSessionId) {
    return;
  }
  const data = await api(`/api/serial/monitor/${encodeURIComponent(monitorSessionId)}`);
  monitorOut.textContent = [
    `Session: ${data.session_id}`,
    `Status: ${data.status}`,
    `Port: ${data.port}`,
    `Baud: ${data.baud}`,
    data.error ? `Error: ${data.error}` : "",
    "",
    data.output || "",
  ]
    .filter((line) => line !== "")
    .join("\n");
  if (data.status === "stopped" || data.status === "error") {
    if (monitorPollTimer) {
      clearInterval(monitorPollTimer);
      monitorPollTimer = null;
    }
  }
}

async function startSerialMonitor() {
  requireNoActiveFlash("start serial monitor");
  const port = getEl("monitorPortSelect").value.trim();
  const baud = clampInt(getEl("monitorBaudSelect").value, 115200, 3000000, 115200);
  if (!port) {
    throw new Error("Select a monitor serial port first.");
  }

  if (monitorSessionId) {
    await stopSerialMonitor();
  }
  monitorOut.textContent = `Starting monitor on ${port} @ ${baud}...`;
  const started = await api("/api/serial/monitor/start", {
    method: "POST",
    body: JSON.stringify({ port, baud }),
  });
  monitorSessionId = started.session_id || "";
  await pollSerialMonitor();
  if (monitorPollTimer) {
    clearInterval(monitorPollTimer);
  }
  monitorPollTimer = setInterval(() => {
    guarded(pollSerialMonitor);
  }, 1000);
}

async function stopSerialMonitor() {
  if (!monitorSessionId) {
    monitorOut.textContent = "[monitor] no active session";
    return;
  }
  const sessionId = monitorSessionId;
  monitorSessionId = "";
  const result = await api(`/api/serial/monitor/${encodeURIComponent(sessionId)}/stop`, {
    method: "POST",
    body: JSON.stringify({}),
  });
  monitorOut.textContent = [
    `Session: ${result.session_id}`,
    `Status: ${result.status}`,
    `Port: ${result.port}`,
    `Baud: ${result.baud}`,
    "",
    result.output || "",
  ].join("\n");
  if (monitorPollTimer) {
    clearInterval(monitorPollTimer);
    monitorPollTimer = null;
  }
}

async function probeSerialPort() {
  requireLoggedIn();
  requireNoActiveFlash("probe serial port");
  if (monitorSessionId) {
    await stopSerialMonitor();
  }
  const port = getEl("monitorPortSelect").value.trim();
  const baud = clampInt(getEl("monitorBaudSelect").value, 115200, 3000000, 115200);
  if (!port) {
    throw new Error("Select a monitor serial port first.");
  }
  monitorOut.textContent = `Probing ${port} @ ${baud}...`;
  const result = await api("/api/serial/probe", {
    method: "POST",
    body: JSON.stringify({ port, baud }),
  });
  monitorOut.textContent = [
    `Probe Port: ${result.port || port}`,
    `Baud: ${result.baud || baud}`,
    `OK: ${Boolean(result.ok)}`,
    result.probe_mode ? `Probe Mode: ${result.probe_mode}` : "",
    result.reset_attempted ? `Reset Pulse Attempted: true` : "",
    result.reset_attempted ? `Reset Pulse OK: ${Boolean(result.reset_ok)}` : "",
    result.reset_error ? `Reset Pulse Error: ${result.reset_error}` : "",
    result.runtime_summary && result.runtime_summary.mode
      ? `Runtime Mode: ${result.runtime_summary.mode}`
      : "",
    result.runtime_summary && result.runtime_summary.ip ? `IP: ${result.runtime_summary.ip}` : "",
    result.runtime_summary && result.runtime_summary.ap_ssid ? `AP SSID: ${result.runtime_summary.ap_ssid}` : "",
    result.runtime_summary && result.runtime_summary.hostname ? `Hostname: ${result.runtime_summary.hostname}` : "",
    result.runtime_summary && result.runtime_summary.last_wifi_reason != null
      ? `Last Wi-Fi Reason: ${result.runtime_summary.last_wifi_reason}`
      : "",
    result.return_code != null ? `Return Code: ${result.return_code}` : "",
    result.tool_source ? `Tool: ${result.tool_source}` : "",
    result.hint ? `Hint: ${result.hint}` : "",
    result.error ? `Error: ${result.error}` : "",
    result.runtime_capture_ok === false ? `Runtime Capture Error: ${result.runtime_capture_error || "unknown"}` : "",
    result.runtime_retry_errors && result.runtime_retry_errors.length
      ? `Runtime Retry Errors: ${result.runtime_retry_errors.join(" | ")}`
      : "",
    "",
    result.output || "",
    result.runtime_log_tail ? "\n--- runtime serial tail ---\n" + result.runtime_log_tail : "",
  ]
    .filter((line) => line !== "")
    .join("\n");
}

async function ensureDiagHostFromSerial() {
  const existing = getEl("diagHost").value.trim();
  if (existing) {
    return existing;
  }

  const expectedHostname = getEl("diagExpectedHostname").value.trim() || getEl("deviceHostname").value.trim();
  const passcode = getEl("diagPasscode").value;
  printDiag("Auto Discover", "No host/IP entered. Discovering from serial and LAN...");
  const result = await api("/api/diagnostics/auto-discover", {
    method: "POST",
    body: JSON.stringify({
      session_id: monitorSessionId || "",
      expected_hostname: expectedHostname,
      passcode,
      text: monitorOut.textContent || "",
    }),
  });
  if (result && result.detected_host) {
    const host = String(result.detected_host);
    getEl("diagHost").value = host;
    saveDraft();
    return host;
  }
  throw new Error(
    "Could not auto-discover device host. Start Serial Monitor, reboot device, then try again.",
  );
}

function printDiag(label, payload) {
  print(diagOut, label, payload);
}

async function detectIpFromSerial() {
  const payload = {
    session_id: monitorSessionId || "",
    text: monitorOut.textContent || "",
  };
  const result = await api("/api/diagnostics/extract-ip", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  const ips = result.ips || [];
  if (ips.length) {
    getEl("diagHost").value = ips[0];
    saveDraft();
  }
  printDiag("Detect IP", {
    found: ips.length,
    ips,
    selected_host: getEl("diagHost").value.trim(),
  });
}

async function parseSerialDetails() {
  const pasted = getEl("diagSerialText").value || "";
  const payload = {
    session_id: monitorSessionId || "",
    text: pasted || monitorOut.textContent || "",
  };
  const result = await api("/api/diagnostics/parse-serial", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  if (result && result.ip) {
    getEl("diagHost").value = String(result.ip);
    saveDraft();
  }
  printDiag("Parse Serial Log", result);
}

async function runPingTest() {
  const host = await ensureDiagHostFromSerial();
  const result = await api("/api/diagnostics/ping", {
    method: "POST",
    body: JSON.stringify({ host }),
  });
  printDiag("Ping Test", result);
}

async function runStatusTest() {
  const host = await ensureDiagHostFromSerial();
  const result = await api("/api/diagnostics/status", {
    method: "POST",
    body: JSON.stringify({ host }),
  });
  printDiag("Web API Test", result);
}

async function runPairTest() {
  const host = await ensureDiagHostFromSerial();
  const passcode = getEl("diagPasscode").value;
  if (!passcode) {
    throw new Error("Enter device passcode for pair test.");
  }
  const result = await api("/api/diagnostics/pair", {
    method: "POST",
    body: JSON.stringify({ host, passcode }),
  });
  printDiag("Pair Test", result);
}

async function runAllTests() {
  const host = await ensureDiagHostFromSerial();
  const passcode = getEl("diagPasscode").value;
  const result = await api("/api/diagnostics/run-all", {
    method: "POST",
    body: JSON.stringify({ host, passcode }),
  });
  printDiag("Bring-Up Tests", result);
}

async function autoDiscoverDevice() {
  const expectedHostname = getEl("diagExpectedHostname").value.trim() || getEl("deviceHostname").value.trim();
  const passcode = getEl("diagPasscode").value;
  const result = await api("/api/diagnostics/auto-discover", {
    method: "POST",
    body: JSON.stringify({
      session_id: monitorSessionId || "",
      expected_hostname: expectedHostname,
      passcode,
      text: monitorOut.textContent || "",
    }),
  });
  if (result && result.detected_host) {
    getEl("diagHost").value = String(result.detected_host);
    saveDraft();
  }
  printDiag("Auto Discover", result);
}

async function initAfterLogin() {
  setupBaudSelect("baudSelect", 921600);
  setupBaudSelect("monitorBaudSelect", 115200);
  await Promise.all([loadFirmware(), loadPorts(), loadProfiles(), loadDevices()]);

  const draft = loadDraft();
  applyFormState(draft);
  renderDeviceTypeOptions();
  applyFormState(draft);
  syncDynamicRowsFromState(draft);
  applyFormState(draft);
  setupBaudSelect("baudSelect", 921600);
  setupBaudSelect("monitorBaudSelect", 115200);
  toggleStaticIpFields();
  if (!getEl("diagExpectedHostname").value.trim()) {
    getEl("diagExpectedHostname").value = getEl("deviceHostname").value.trim();
  }
  saveDraft();
  activeFlashJobId = "";
  comCooldownUntil = 0;
  monitorOut.textContent = "[monitor] stopped";
  diagOut.textContent = "[diagnostics] ready";
}

async function guarded(action) {
  try {
    await action();
  } catch (err) {
    showError(err);
  }
}

document.getElementById("setupBtn").addEventListener("click", () => guarded(async () => {
  const username = document.getElementById("setupUser").value.trim();
  const password = document.getElementById("setupPass").value.trim();
  await api("/api/auth/setup", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });
  await bootAuth();
}));

document.getElementById("loginBtn").addEventListener("click", () => guarded(async () => {
  const username = document.getElementById("loginUser").value.trim();
  const password = document.getElementById("loginPass").value.trim();
  const result = await api("/api/auth/login", {
    method: "POST",
    body: JSON.stringify({ username, password }),
  });

  token = result.token || "";
  try {
    localStorage.setItem(TOKEN_KEY, token);
  } catch {
    // Best effort only.
  }
  hide(authSetup);
  hide(authLogin);
  show(appPanel);
  await initAfterLogin();
}));

profileDeviceType.addEventListener("change", () => {
  renderDeviceTypeOptions();
  saveDraft();
});

ipMode.addEventListener("change", () => {
  toggleStaticIpFields();
  saveDraft();
});

appPanel.addEventListener("input", () => saveDraft());
appPanel.addEventListener("change", () => saveDraft());

getEl("scanBtn").addEventListener("click", () => guarded(scanNetwork));
getEl("firmwareBtn").addEventListener("click", () => guarded(loadFirmware));
getEl("portsBtn").addEventListener("click", () => guarded(loadPorts));
getEl("profilesBtn").addEventListener("click", () => guarded(loadProfiles));
getEl("devicesBtn").addEventListener("click", () => guarded(loadDevices));
getEl("uploadFirmwareBtn").addEventListener("click", () => guarded(uploadFirmware));
getEl("buildFirmwareBtn").addEventListener("click", () => guarded(buildFirmwareFromSource));
getEl("flashBtn").addEventListener("click", () => guarded(flashToPort));
getEl("monitorStartBtn").addEventListener("click", () => guarded(startSerialMonitor));
getEl("monitorStopBtn").addEventListener("click", () => guarded(stopSerialMonitor));
getEl("monitorProbeBtn").addEventListener("click", () => guarded(probeSerialPort));
getEl("diagParseSerialBtn").addEventListener("click", () => guarded(parseSerialDetails));
getEl("diagDetectIpBtn").addEventListener("click", () => guarded(detectIpFromSerial));
getEl("diagAutoDiscoverBtn").addEventListener("click", () => guarded(autoDiscoverDevice));
getEl("diagPingBtn").addEventListener("click", () => guarded(runPingTest));
getEl("diagStatusBtn").addEventListener("click", () => guarded(runStatusTest));
getEl("diagPairBtn").addEventListener("click", () => guarded(runPairTest));
getEl("diagAllBtn").addEventListener("click", () => guarded(runAllTests));
getEl("buildProfileBtn").addEventListener("click", () => guarded(buildProfilePackage));
getEl("flashOtaBtn").addEventListener("click", () => guarded(flashOta));

bootAuth().catch((err) => {
  showError(err);
});
