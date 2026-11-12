#ifndef CNIKONMAID_H
#define CNIKONMAID_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t id;
    char name[64];
    char version[64];
    int available;
    uint32_t connected_pid;
} AFDeviceInfo;

/* Lifecycle */
int af_load(const char* module_path);
int af_init(void);
int af_free(void);

/* Devices */
int af_pump(int ms);
int af_refresh_devices(void);
int af_device_count(void);
int af_device_at(int index, AFDeviceInfo* out);
int af_devices_json(char* out, int out_len);
int af_caps_json(char* out, int out_len);
int af_connect(int index);
int af_disconnect(void);

/* Capabilities */
int af_cap_count(void);
int af_cap_info(int index, uint32_t* id, uint32_t* type, uint32_t* ops,
                char* desc, int desc_len);
int af_cap_get_u32(const char* name, uint32_t* out);
int af_cap_set_u32(const char* name, uint32_t value);
int af_cap_get_enum(const char* name, char* out, int out_len);
int af_cap_set_enum(const char* name, const char* value);
int af_cap_list_enum(const char* name, char* out, int out_len);

/* Live view */
int af_lv_start(void);
int af_lv_stop(void);
int af_lv_status(int* out);
int af_lv_get(uint8_t* buf, int cap, int* out_len, int* out_w, int* out_h,
              uint64_t* out_seq);
uint64_t af_lv_frames(void);

/* Capture */
int af_set_save_path(const char* dir);
int af_shoot_single(const char* dir, int autofocus);
int af_shoot_bulb(const char* dir, int seconds);
int af_wait_capture(int timeout_ms);
int af_shoot_status(int* out);
int af_cancel_shoot(void);
int af_focus(int direction, int steps);

/* Diagnostics */
const char* af_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
