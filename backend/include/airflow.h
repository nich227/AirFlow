// The C interface of AirFlow's Rust backend. backend/src/ffi.rs defines these functions and
// structures, and backend/src/protocol.rs defines the same names for the helper. A test in
// the backend fails if this file and the Rust source disagree.

#ifndef AIRFLOW_H
#define AIRFLOW_H

#include <stdbool.h>
#include <stdint.h>

// The helper: its Mach service, and the keys of the XPC dictionaries the app sends it.
#define AIRFLOW_HELPER_SERVICE "com.kevster.airflow.helper"
#define AIRFLOW_HELPER_PROTOCOL_VERSION "1"
#define AIRFLOW_KEY_OPERATION "op"
#define AIRFLOW_KEY_FAN "fan"
#define AIRFLOW_KEY_RPM "rpm"
#define AIRFLOW_KEY_OK "ok"
#define AIRFLOW_KEY_ERROR "error"
#define AIRFLOW_KEY_VERSION "version"
#define AIRFLOW_OP_VERSION "version"
#define AIRFLOW_OP_SET_FAN "set_fan"
#define AIRFLOW_OP_SET_AUTOMATIC "set_automatic"
#define AIRFLOW_OP_RESET_ALL "reset_all"
#define AIRFLOW_OP_KEEP_ALIVE "keep_alive"

// One fan as the SMC reports it.
typedef struct AirflowFan {
    int32_t index;
    double minimum_rpm;
    double maximum_rpm;
    double current_rpm;
    double target_rpm;
    // True while something other than the system holds the fan's speed.
    bool is_manual;
} AirflowFan;

// The part of the Mac a sensor belongs to, in the order the app lists them.
enum {
    AIRFLOW_GROUP_CPU = 0,
    AIRFLOW_GROUP_GPU = 1,
    AIRFLOW_GROUP_MEMORY = 2,
    AIRFLOW_GROUP_STORAGE = 3,
    AIRFLOW_GROUP_BATTERY = 4,
    AIRFLOW_GROUP_ENCLOSURE = 5,
    AIRFLOW_GROUP_POWER = 6,
    AIRFLOW_GROUP_WIRELESS = 7,
    AIRFLOW_GROUP_OTHER = 8,
};

// One temperature sensor. The key and the name are NUL-terminated UTF-8. `is_known` is false
// for a key whose meaning is not known: its name is its group's, with a number.
typedef struct AirflowSensor {
    char key[8];
    char name[56];
    uint8_t group;
    bool is_known;
    double celsius;
} AirflowSensor;

typedef struct AirflowReader AirflowReader;

// Opens the SMC for reading, which needs no privilege. Returns NULL when the Mac has no SMC
// that can be opened. Use one reader from one thread at a time.
AirflowReader *airflow_reader_open(void);

// A reader over made-up values, two fans and a few sensors, for tests of the bridge.
AirflowReader *airflow_reader_open_sample(void);

void airflow_reader_close(AirflowReader *reader);

// Each call fills at most `capacity` entries and returns how many it filled.
int32_t airflow_reader_read_fans(AirflowReader *reader, AirflowFan *fans, int32_t capacity);
int32_t airflow_reader_read_sensors(AirflowReader *reader, AirflowSensor *sensors, int32_t capacity);

// The same sensors, but only those of the groups in `groups` are read now: bit n is the group
// numbered n above. Each other sensor has its last reading. One key takes about a tenth of a
// millisecond to read, so a caller reads often only the groups it acts on.
int32_t airflow_reader_read_sensors_in(AirflowReader *reader, AirflowSensor *sensors, int32_t capacity, uint32_t groups);

// The power the whole Mac draws, in watts, or a negative number where the SMC does not report it.
double airflow_reader_read_system_power(AirflowReader *reader);

// 1 when the Mac runs on its battery, and 0 when it is plugged in or has no battery.
int32_t airflow_power_source_is_battery(void);

// The code signing requirement the app must set on its connection to the helper: the helper's
// identifier, signed by the same team as the running program. Writes a NUL-terminated string
// and returns its length, or returns 0 when the running program has no team's signature.
int32_t airflow_helper_requirement(char *buffer, int32_t capacity);

#endif
