#include "CNikonMAID.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <strings.h>
#include <unistd.h>
#include <vector>

#include "Maid3.h"
#include "Maid3d1.h"

namespace {

void* g_module = nullptr;
LPNkMAIDEnumDevices g_devices = nullptr;
LPNkMAIDEnumCapInfo g_caps = nullptr;
bool g_connected = false;

LPMAIDInitializeSDKProc pInitializeSDK = nullptr;
LPMAIDFreeSDKProc pFreeSDK = nullptr;
LPMAIDConnectDeviceProc pConnectDevice = nullptr;
LPMAIDDisconnectDeviceProc pDisconnectDevice = nullptr;
LPMAIDStartLiveView pStartLiveView = nullptr;
LPMAIDStopLiveView pStopLiveView = nullptr;
LPMAIDGetLiveViewStatus pGetLiveViewStatus = nullptr;
LPMAIDStartShooting pStartShooting = nullptr;
LPMAIDCancelShooting pCancelShooting = nullptr;
LPMAIDGetShootingStatus pGetShootingStatus = nullptr;
LPMAIDGetCapability pGetCapability = nullptr;
LPMAIDSetCapability pSetCapability = nullptr;
LPMAIDEnumCapabilities pEnumCapabilities = nullptr;
LPMAIDEnumDevices pEnumDevices = nullptr;
LPMAIDStartOperation pStartOperation = nullptr;
LPMAIDSetLoggingLevel pSetLoggingLevel = nullptr;
LPMAIDSetImageVideoSavePath pSetImageVideoSavePath = nullptr;

std::mutex g_lv_mutex;
std::vector<uint8_t> g_lv_jpeg;
int g_lv_w = 0;
int g_lv_h = 0;
uint64_t g_lv_seq = 0;

std::atomic<bool> g_capture_saved{false};
std::atomic<int> g_async_result{9999};
std::atomic<uint32_t> g_last_event{0};
std::string g_last_error = "none";
int g_last_code = 0;

void set_error(const char* msg, int code = -1) {
    g_last_error = msg ? msg : "unknown";
    g_last_code = code;
}

void* alloc_mem(size_t n) { return std::malloc(n); }
void free_mem(void* p) { std::free(p); }

void event_proc(NKREF, ULONG ev, NKPARAM) {
    g_last_event.store(ev);
    if (ev == kNkMAIDEvent_ImageSaved || ev == kNkMAIDEvent_ImageSavedInCard ||
        ev == kNkMAIDEvent_CaptureComplete) {
        g_capture_saved.store(true);
    }
}

ULONG ui_req_proc(NKREF, LPNkMAIDUIRequestInfo) { return 0; }
void progress_proc(ULONG, ULONG, NKREF, ULONG, ULONG) {}
NKERROR data_proc(NKREF, LPVOID, LPVOID) { return kNkMAIDResult_NoError; }

void async_complete(NKREF, NKERROR result) {
    g_async_result.store(static_cast<int>(result));
}

void lv_data_proc(NKREF, LPNkMAIDLiveViewData data) {
    if (!data) return;
    if (data->pImageData && data->ulLvImageSize > 0) {
        std::lock_guard<std::mutex> lock(g_lv_mutex);
        const auto* p = static_cast<const uint8_t*>(data->pImageData);
        g_lv_jpeg.assign(p, p + data->ulLvImageSize);
        g_lv_w = static_cast<int>(data->stLiveViewHeader.m_JpegW.uiSize);
        g_lv_h = static_cast<int>(data->stLiveViewHeader.m_JpegH.uiSize);
        g_lv_seq++;
    }
    // Ownership is handed to the client by the SDK; the sample frees both.
    if (data->pImageData) std::free(data->pImageData);
    std::free(data);
}

struct CapName {
    const char* name;
    ULONG id;
};

const CapName kCaps[] = {
    {"name", kNkMAIDCapability_Name},
    {"isalive", kNkMAIDCapability_IsAlive},
    {"batterylevel", kNkMAIDCapability_BatteryLevel},
    {"shutterspeed", kNkMAIDCapability_ShutterSpeed},
    {"aperture", kNkMAIDCapability_Aperture},
    {"sensitivity", kNkMAIDCapability_Sensitivity},
    {"exposuremode", kNkMAIDCapability_ExposureMode},
    {"exposurecomp", kNkMAIDCapability_ExposureComp},
    {"savemedia", kNkMAIDCapability_SaveMedia},
    {"liveviewsize", kNkMAIDCapability_LiveViewImageSize},
    {"liveviewselector", kNkMAIDCapability_LiveViewSelector},
    {"liveviewstatus", kNkMAIDCapability_LiveViewStatus},
    {"liveviewprohibit", kNkMAIDCapability_LiveViewProhibit},
    {"mfdrive", kNkMAIDCapability_MFDrive},
    {"monitoroff", kNkMAIDCapability_ChangeMonitorOffStatus},
    {"compressionlevel", kNkMAIDCapability_CompressionLevel},
    {"compressrawex", kNkMAIDCapability_CompressRAWEx},
    {"lensinfo", kNkMAIDCapability_LensInfo},
    {"focallength", kNkMAIDCapability_FocalLength},
    {"shootingmode", kNkMAIDCapability_ShootingMode},
    {"lockcamera", kNkMAIDCapability_LockCamera},
};

ULONG cap_id(const char* name) {
    if (!name) return 0;
    for (const auto& c : kCaps) {
        if (std::strcmp(c.name, name) == 0) return c.id;
    }
    return 0;
}

void free_cap(void* p, eNkMAIDDataType type) {
    if (!p) return;
    if (type == kNkMAIDDataType_EnumPtr) {
        std::free(static_cast<LPNkMAIDEnum>(p)->pData);
    } else if (type == kNkMAIDDataType_ArrayPtr) {
        std::free(static_cast<LPNkMAIDArray>(p)->pData);
    }
    std::free(p);
}

std::string enum_element(const NkMAIDEnum& e, ULONG index) {
    if (!e.pData || index >= e.ulElements) return {};
    if (e.ulType == kNkMAIDArrayType_PackedString) {
        const size_t stride = e.wPhysicalBytes;
        const char* s = static_cast<const char*>(e.pData) + index * stride;
        return std::string(s);
    }
    if (e.ulType == kNkMAIDArrayType_Unsigned) {
        const uint32_t v = static_cast<const uint32_t*>(e.pData)[index];
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%u", v);
        return std::string(buf);
    }
    return {};
}

int get_enum_struct(ULONG id, eNkSDKGetSettingRequestType req, NkMAIDEnum* out,
                    eNkMAIDDataType* outType) {
    void* p = nullptr;
    eNkMAIDDataType type = kNkMAIDDataType_Null;
    NKERROR err = pGetCapability(id, req, p, type);
    if (err != kNkMAIDResult_NoError || !p) {
        set_error("GetCapability failed", err);
        if (p) free_cap(p, type);
        return -1;
    }
    if (type != kNkMAIDDataType_EnumPtr) {
        set_error("capability is not an enum", -3);
        free_cap(p, type);
        return -3;
    }
    *out = *static_cast<LPNkMAIDEnum>(p);
    // Deep copy pData so the caller can free the wrapper.
    if (out->pData && out->ulElements > 0) {
        size_t bytes = static_cast<size_t>(out->wPhysicalBytes) * out->ulElements;
        void* copy = std::malloc(bytes);
        if (copy) std::memcpy(copy, out->pData, bytes);
        out->pData = copy;
    }
    *outType = type;
    free_cap(p, type);
    return 0;
}

}  // namespace

extern "C" {

int af_load(const char* module_path) {
    if (g_module) return 0;
    if (!module_path) {
        set_error("module path is null");
        return -1;
    }
    g_module = dlopen(module_path, RTLD_NOW | RTLD_LOCAL);
    if (!g_module) {
        set_error(dlerror());
        return -2;
    }
    pInitializeSDK = reinterpret_cast<LPMAIDInitializeSDKProc>(dlsym(g_module, "InitializeSDK"));
    pFreeSDK = reinterpret_cast<LPMAIDFreeSDKProc>(dlsym(g_module, "FreeSDK"));
    pConnectDevice = reinterpret_cast<LPMAIDConnectDeviceProc>(dlsym(g_module, "ConnectDevice"));
    pDisconnectDevice = reinterpret_cast<LPMAIDDisconnectDeviceProc>(dlsym(g_module, "DisconnectDevice"));
    pStartLiveView = reinterpret_cast<LPMAIDStartLiveView>(dlsym(g_module, "StartLiveView"));
    pStopLiveView = reinterpret_cast<LPMAIDStopLiveView>(dlsym(g_module, "StopLiveView"));
    pGetLiveViewStatus = reinterpret_cast<LPMAIDGetLiveViewStatus>(dlsym(g_module, "GetLiveViewStatus"));
    pStartShooting = reinterpret_cast<LPMAIDStartShooting>(dlsym(g_module, "StartShooting"));
    pCancelShooting = reinterpret_cast<LPMAIDCancelShooting>(dlsym(g_module, "CancelShooting"));
    pGetShootingStatus = reinterpret_cast<LPMAIDGetShootingStatus>(dlsym(g_module, "GetShootingStatus"));
    pGetCapability = reinterpret_cast<LPMAIDGetCapability>(dlsym(g_module, "GetCapability"));
    pSetCapability = reinterpret_cast<LPMAIDSetCapability>(dlsym(g_module, "SetCapability"));
    pEnumCapabilities = reinterpret_cast<LPMAIDEnumCapabilities>(dlsym(g_module, "EnumCapabilities"));
    pEnumDevices = reinterpret_cast<LPMAIDEnumDevices>(dlsym(g_module, "EnumDevices"));
    pStartOperation = reinterpret_cast<LPMAIDStartOperation>(dlsym(g_module, "StartOperation"));
    pSetLoggingLevel = reinterpret_cast<LPMAIDSetLoggingLevel>(dlsym(g_module, "SetLoggingLevel"));
    pSetImageVideoSavePath = reinterpret_cast<LPMAIDSetImageVideoSavePath>(dlsym(g_module, "SetImageVideoSavePath"));
    if (!pInitializeSDK || !pFreeSDK || !pConnectDevice || !pGetCapability ||
        !pSetCapability || !pStartLiveView || !pStopLiveView || !pStartShooting) {
        set_error("required SDK symbols missing");
        return -3;
    }
    if (pSetLoggingLevel) pSetLoggingLevel(kkNkSDKLogLevel_Error);
    return 0;
}

int af_init(void) {
    if (!pInitializeSDK) {
        set_error("af_load not called");
        return -1;
    }
    NkMAIDCSCallback cb{};
    cb.pUIReqProc = (LPNKFUNC)ui_req_proc;
    cb.pfnEventProc = (LPNKFUNC)event_proc;
    cb.pProgressProc = (LPNKFUNC)progress_proc;
    cb.pDataProc = (LPNKFUNC)data_proc;
    cb.pLiveViewDataProc = (LPNKFUNC)lv_data_proc;
    cb.refProc = nullptr;
    NKERROR err = pInitializeSDK((LPMAIDAllocateMemory)alloc_mem,
                                  (LPMAIDFreeMemory)free_mem, &cb, &g_devices,
                                  nullptr);
    if (err != kNkMAIDResult_NoError) {
        set_error("InitializeSDK failed", err);
        return err;
    }
    // Device enumeration is asynchronous; give the SDK a moment and a run loop.
    af_pump(600);
    if (pEnumDevices) {
        LPNkMAIDEnumDevices list = nullptr;
        if (pEnumDevices(list, nullptr, nullptr) == kNkMAIDResult_NoError && list) {
            if (g_devices) {
                std::free(g_devices->pDeviceData);
                std::free(g_devices);
            }
            g_devices = list;
        }
        af_pump(300);
    }
    return 0;
}

int af_free(void) {
    if (g_connected) af_disconnect();
    if (pFreeSDK) pFreeSDK();
    if (g_devices) {
        std::free(g_devices->pDeviceData);
        std::free(g_devices);
        g_devices = nullptr;
    }
    if (g_module) {
        dlclose(g_module);
        g_module = nullptr;
    }
    return 0;
}

int af_pump(int ms) {
    int waited = 0;
    while (waited < ms) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        waited += 50;
    }
    return 0;
}

int af_refresh_devices(void) {
    if (!pEnumDevices) return -1;
    LPNkMAIDEnumDevices list = nullptr;
    NKERROR err = pEnumDevices(list, nullptr, nullptr);
    af_pump(500);
    if (err == kNkMAIDResult_NoError && list) {
        if (g_devices) {
            std::free(g_devices->pDeviceData);
            std::free(g_devices);
        }
        g_devices = list;
    }
    return err;
}

int af_device_count(void) {
    return g_devices ? static_cast<int>(g_devices->ulElements) : 0;
}

int af_device_at(int index, AFDeviceInfo* out) {
    if (!g_devices || index < 0 || static_cast<ULONG>(index) >= g_devices->ulElements ||
        !out) {
        return -1;
    }
    const auto& d = g_devices->pDeviceData[index];
    std::memset(out, 0, sizeof(*out));
    out->id = d.ID;
    std::strncpy(out->name, d.Name, sizeof(out->name) - 1);
    std::strncpy(out->version, d.Version, sizeof(out->version) - 1);
    out->available = d.Availability ? 1 : 0;
    out->connected_pid = d.ulConnectedPID;
    return 0;
}

int af_devices_json(char* out, int out_len) {
    if (!out || out_len <= 0) return -1;
    std::string s = "[";
    const int n = af_device_count();
    for (int i = 0; i < n; i++) {
        AFDeviceInfo d{};
        if (af_device_at(i, &d) != 0) continue;
        if (i) s += ",";
        char escName[128] = {0};
        char escVer[128] = {0};
        std::snprintf(escName, sizeof(escName), "%s", d.name);
        std::snprintf(escVer, sizeof(escVer), "%s", d.version);
        char item[512];
        std::snprintf(item, sizeof(item),
                      "{\"id\":%u,\"name\":\"%s\",\"version\":\"%s\",\"available\":%s,\"pid\":%u}",
                      d.id, escName, escVer, d.available ? "true" : "false", d.connected_pid);
        s += item;
    }
    s += "]";
    std::snprintf(out, static_cast<size_t>(out_len), "%s", s.c_str());
    return 0;
}

int af_caps_json(char* out, int out_len) {
    if (!out || out_len <= 0) return -1;
    std::string s = "[";
    const int n = af_cap_count();
    for (int i = 0; i < n; i++) {
        uint32_t id = 0, type = 0, ops = 0;
        char desc[256] = {0};
        if (af_cap_info(i, &id, &type, &ops, desc, sizeof(desc)) != 0) continue;
        if (i) s += ",";
        char item[512];
        std::snprintf(item, sizeof(item),
                      "{\"id\":%u,\"type\":%u,\"ops\":%u,\"desc\":\"%s\"}",
                      id, type, ops, desc);
        s += item;
    }
    s += "]";
    std::snprintf(out, static_cast<size_t>(out_len), "%s", s.c_str());
    return 0;
}

int af_connect(int index) {
    if (!g_devices || index < 0 || static_cast<ULONG>(index) >= g_devices->ulElements) {
        set_error("device index out of range");
        return -1;
    }
    const auto& d = g_devices->pDeviceData[index];
    if (!d.Availability) {
        set_error("device not available");
        return -2;
    }
    NKERROR err = pConnectDevice(d.ID, &g_caps);
    if (err != kNkMAIDResult_NoError) {
        set_error("ConnectDevice failed", err);
        return err;
    }
    g_connected = true;
    return 0;
}

int af_disconnect(void) {
    if (!g_connected) return 0;
    HRESULT hr = pDisconnectDevice ? pDisconnectDevice() : 0;
    g_connected = false;
    if (g_caps) {
        std::free(g_caps->pCapArray);
        std::free(g_caps);
        g_caps = nullptr;
    }
    return hr == 0 ? 0 : -1;
}

int af_cap_count(void) { return g_caps ? static_cast<int>(g_caps->ulCapCount) : 0; }

int af_cap_info(int index, uint32_t* id, uint32_t* type, uint32_t* ops,
                char* desc, int desc_len) {
    if (!g_caps || index < 0 || static_cast<ULONG>(index) >= g_caps->ulCapCount) {
        return -1;
    }
    const auto& c = g_caps->pCapArray[index];
    if (id) *id = c.ulID;
    if (type) *type = c.ulType;
    if (ops) *ops = c.ulOperations;
    if (desc && desc_len > 0) {
        std::strncpy(desc, reinterpret_cast<const char*>(c.szDescription), static_cast<size_t>(desc_len) - 1);
        desc[desc_len - 1] = '\0';
    }
    return 0;
}

int af_cap_get_u32(const char* name, uint32_t* out) {
    ULONG id = cap_id(name);
    if (!id || !out || !g_connected) {
        set_error("capability name/connection invalid");
        return -1;
    }
    void* p = nullptr;
    eNkMAIDDataType type = kNkMAIDDataType_Null;
    NKERROR err = pGetCapability(id, kNkSDKGetSettingValue, p, type);
    if (err != kNkMAIDResult_NoError || !p) {
        set_error("GetCapability failed", err);
        if (p) free_cap(p, type);
        return err;
    }
    int rc = 0;
    if (type == kNkMAIDDataType_UnsignedPtr || type == kNkMAIDDataType_IntegerPtr) {
        *out = *static_cast<uint32_t*>(p);
    } else if (type == kNkMAIDDataType_Unsigned || type == kNkMAIDDataType_Integer) {
        *out = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(p));
    } else {
        set_error("capability is not scalar", -3);
        rc = -3;
    }
    free_cap(p, type);
    return rc;
}

int af_cap_set_u32(const char* name, uint32_t value) {
    ULONG id = cap_id(name);
    if (!id || !g_connected) {
        set_error("capability name/connection invalid");
        return -1;
    }
    ULONG v = value;
    NKERROR err = pSetCapability(id, &v, kNkMAIDDataType_UnsignedPtr);
    if (err != kNkMAIDResult_NoError) {
        set_error("SetCapability failed", err);
        return err;
    }
    return 0;
}

int af_cap_get_enum(const char* name, char* out, int out_len) {
    ULONG id = cap_id(name);
    if (!id || !out || out_len <= 0 || !g_connected) return -1;
    NkMAIDEnum current{};
    eNkMAIDDataType type;
    if (get_enum_struct(id, kNkSDKGetSettingValue, &current, &type) != 0) return -2;
    std::string s;
    if (current.pData) {
        s = enum_element(current, current.ulValue);
    } else {
        // Current value may come back as index only; map it through the supported array.
        NkMAIDEnum supported{};
        if (get_enum_struct(id, kNkSDKGetSettingSupportedValueArray, &supported, &type) == 0) {
            s = enum_element(supported, current.ulValue);
            std::free(supported.pData);
        }
        if (s.empty()) s = std::to_string(current.ulValue);
    }
    std::free(current.pData);
    std::snprintf(out, static_cast<size_t>(out_len), "%s", s.c_str());
    return 0;
}

int af_cap_list_enum(const char* name, char* out, int out_len) {
    ULONG id = cap_id(name);
    if (!id || !out || out_len <= 0 || !g_connected) return -1;
    NkMAIDEnum e{};
    eNkMAIDDataType type;
    if (get_enum_struct(id, kNkSDKGetSettingSupportedValueArray, &e, &type) != 0)
        return -2;
    std::string s;
    for (ULONG i = 0; i < e.ulElements; i++) {
        std::string v = enum_element(e, i);
        if (v.empty()) continue;
        if (!s.empty()) s += "\n";
        s += v;
    }
    std::free(e.pData);
    std::snprintf(out, static_cast<size_t>(out_len), "%s", s.c_str());
    return 0;
}

int af_cap_set_enum(const char* name, const char* value) {
    ULONG id = cap_id(name);
    if (!id || !value || !g_connected) return -1;
    NkMAIDEnum supported{};
    eNkMAIDDataType type;
    if (get_enum_struct(id, kNkSDKGetSettingSupportedValueArray, &supported, &type) != 0)
        return -2;
    int found = -1;
    for (ULONG i = 0; i < supported.ulElements; i++) {
        std::string v = enum_element(supported, i);
        if (strcasecmp(v.c_str(), value) == 0) {
            found = static_cast<int>(i);
            break;
        }
    }
    std::free(supported.pData);
    if (found < 0) {
        set_error("value not found in enum");
        return -3;
    }
    NkMAIDEnum current{};
    if (get_enum_struct(id, kNkSDKGetSettingValue, &current, &type) != 0) return -4;
    current.ulValue = static_cast<ULONG>(found);
    current.pData = nullptr;
    NKERROR err = pSetCapability(id, &current, kNkMAIDDataType_EnumPtr);
    if (err != kNkMAIDResult_NoError) {
        set_error("SetCapability enum failed", err);
        return err;
    }
    return 0;
}

int af_lv_start(void) {
    if (!g_connected) return -1;
    // If live view is already running (camera or remote), stop it first so the
    // SDK can take over the session.
    int current = -1;
    if (af_lv_status(&current) == 0 && current != eNkMAIDLVStatus_OFF) {
        pStopLiveView(nullptr, nullptr);
        af_pump(400);
    }
    NKERROR err = pStartLiveView(nullptr, nullptr);
    af_pump(700);
    if (err == kNkMAIDAPIResult_LiveViewAlreadyStarted) return 0;
    if (err != kNkMAIDResult_NoError) {
        set_error("StartLiveView failed", err);
        return err;
    }
    return 0;
}

int af_lv_stop(void) {
    if (!pStopLiveView) return -1;
    NKERROR err = pStopLiveView(nullptr, nullptr);
    if (err != kNkMAIDResult_NoError) {
        set_error("StopLiveView failed", err);
        return err;
    }
    return 0;
}

int af_lv_status(int* out) {
    if (!pGetLiveViewStatus || !out) return -1;
    eNkMAIDLVStatus s = eNkMAIDLVStatus_OFF;
    NKERROR err = pGetLiveViewStatus(s);
    if (err != kNkMAIDResult_NoError) {
        set_error("GetLiveViewStatus failed", err);
        return err;
    }
    *out = static_cast<int>(s);
    return 0;
}

int af_lv_get(uint8_t* buf, int cap, int* out_len, int* out_w, int* out_h,
              uint64_t* out_seq) {
    std::lock_guard<std::mutex> lock(g_lv_mutex);
    if (g_lv_jpeg.empty()) {
        if (out_len) *out_len = 0;
        return 1;
    }
    int n = static_cast<int>(g_lv_jpeg.size());
    if (n > cap) n = cap;
    if (buf) std::memcpy(buf, g_lv_jpeg.data(), static_cast<size_t>(n));
    if (out_len) *out_len = n;
    if (out_w) *out_w = g_lv_w;
    if (out_h) *out_h = g_lv_h;
    if (out_seq) *out_seq = g_lv_seq;
    return 0;
}

uint64_t af_lv_frames(void) {
    std::lock_guard<std::mutex> lock(g_lv_mutex);
    return g_lv_seq;
}

int af_set_save_path(const char* dir) {
    if (!dir || !g_connected) return -1;
    if (pSetImageVideoSavePath) {
        NKERROR err = pSetImageVideoSavePath(dir, dir);
        if (err != kNkMAIDResult_NoError) {
            set_error("SetImageVideoSavePath failed", err);
            return err;
        }
    }
    return 0;
}

static int shoot(const char* dir, int type, int seconds, int autofocus) {
    if (!g_connected || !pStartShooting) return -1;
    af_set_save_path(dir);
    // SDRAM transfer avoids the "card does not notify" behaviour.
    af_cap_set_u32("savemedia", 1);

    MAIDShootingStructure s{};
    s.ShootingType = static_cast<eNkMAIDShootingType>(type);
    s.bAutoFocus = autofocus ? true : false;
    s.ulBULBExposureDuration = static_cast<ULONG>(seconds);
    if (dir) std::strncpy(s.ImageSavePath, dir, sizeof(s.ImageSavePath) - 1);

    g_capture_saved.store(false);
    g_async_result.store(9999);
    NKERROR err = pStartShooting(s, async_complete, nullptr);
    if (err == kNkMAIDResult_Waiting_2ndRelease) {
        set_error("waiting for second release", err);
        return err;
    }
    if (err == kNkMAIDResult_Pending) return 0;
    if (err != kNkMAIDResult_NoError) {
        set_error("StartShooting failed", err);
        return err;
    }
    return 0;
}

int af_shoot_single(const char* dir, int autofocus) {
    return shoot(dir, kNkSDKShootingTypeSingle, 0, autofocus);
}

int af_shoot_bulb(const char* dir, int seconds) {
    return shoot(dir, kNkSDKShootingTypeBULB, seconds, 0);
}

int af_wait_capture(int timeout_ms) {
    int waited = 0;
    while (waited < timeout_ms) {
        if (g_capture_saved.load()) return 0;
        const int ar = g_async_result.load();
        if (ar != 9999 && ar != kNkMAIDResult_Pending) {
            if (ar == kNkMAIDResult_NoError) return 0;
            set_error("capture failed", ar);
            return ar;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        waited += 50;
    }
    return g_capture_saved.load() ? 0 : -2;
}

int af_shoot_status(int* out) {
    if (!pGetShootingStatus || !out) return -1;
    eNkMAIDShootingStatus s = kNkSDKShootingFinishedOrNotStarted;
    HRESULT hr = pGetShootingStatus(s);
    if (hr != 0) return -1;
    *out = static_cast<int>(s);
    return 0;
}

int af_cancel_shoot(void) {
    if (!pCancelShooting) return -1;
    NKERROR err = pCancelShooting(nullptr, nullptr);
    return err == kNkMAIDResult_NoError ? 0 : err;
}

int af_focus(int direction, int steps) {
    if (!g_connected) return -1;
    if (steps < 0) steps = 0;
    if (steps > 200) steps = 200;
    ULONG dir = direction ? 1 : 0;  // 0: infinity->closest, 1: closest->infinity
    for (int i = 0; i < steps; i++) {
        NKERROR err = pSetCapability(kNkMAIDCapability_MFDrive, &dir,
                                     kNkMAIDDataType_UnsignedPtr);
        if (err != kNkMAIDResult_NoError) {
            set_error("MFDrive failed", err);
            return err;
        }
        usleep(30 * 1000);
    }
    return 0;
}

const char* af_last_error(void) { return g_last_error.c_str(); }

}  // extern "C"
