# TasmotaBerryTime — Agent Guide

## What This Project Is

A collection of **Berry scripting language drivers** for [Tasmota](https://tasmota.github.io/) (ESP32 firmware). These drivers provide real-time-clock functionality for stock (non-custom) Tasmota builds, targeting scenarios where WiFi/NTP is unreliable or unavailable.

- **ds3231** — I2C driver for the DS3231 RTC chip. Reads time from the chip at boot, writes NTP time back to the chip on every NTP sync.
- **gnsstime** — Serial (UART) driver for GNSS modules (UBLOX NEO 6/7/8 series, others via standard NMEA). Parses `$--RMC` and `$--GSV` sentences, extracts time, updates system clock periodically.

Both drivers are single-file `.be` scripts meant to be `load()`-ed into the Tasmota Berry runtime.

## Language & Runtime

- **Berry** — a lightweight scripting language embedded in Tasmota firmware. Syntax resembles Lua/Python. Uses `def` for functions, `class/end` for classes, `do/end` for blocks.
- Tasmota-specific APIs used: `tasmota.rtc_utc()`, `tasmota.time_dump()`, `tasmota.wire_scan()`, `tasmota.add_rule()`, `tasmota.add_fast_loop()`, `tasmota.remove_fast_loop()`, `tasmota.set_timer()`, `tasmota.remove_timer()`, `tasmota.cmd()`, `tasmota.strptime()`, `tasmota.millis()`, `tasmota.gc()` — these are Tasmota Berry built-ins, not defined in this repo. See the [Tasmota Berry docs](https://tasmota.github.io/docs/Berry/).
- Run target: **ESP32, ESP32-S2, ESP32-C3** (not ESP8266 — it cannot run Berry).
- No build step, no tests, no CI, no formatter/linter — scripts are loaded directly onto a Tasmota device via the Berry Scripting Console or filesystem upload.

## Repository Structure

```
TasmotaBerryTime/
├── README.md             # Top-level overview
├── LICENSE               # MIT License (2024 Panagiotis Karagiannis)
├── AGENTS.md             # This file
├── ds3231/
│   ├── README.md         # DS3231 doc: wiring, installation, gotchas
│   ├── ds3231.be         # The driver (Berry source)
│   └── ds3231.png        # Wiring diagram
└── gnsstime/
    ├── README.md         # GNSS doc: module selection, wiring, testing
    └── gnsstime.be       # The driver (Berry source)
```

No build system, no package manager, no test files, no CI config, no `.cursor` or `.github` directory.

## Key Code Patterns & Conventions

**1. Namespace isolation via `do/end` or function scope** — each driver wraps its code in a block to avoid polluting the Berry global namespace. The class is assigned to a single global variable (`global.ds3231` / `global.gnsstime`).

**2. Graceful reload** — at the top of each file, the driver checks if a prior instance exists, calls its `stop()` method, and nils the global before reloading. This allows re-`load()`-ing the script during development without restarting Tasmota.

**3. Event-driven / non-blocking** — drivers use `tasmota.add_fast_loop()` / `tasmota.set_timer()` / `tasmota.add_rule()` to avoid blocking the main Tasmota loop. No `while` busy-waits.

**4. Single instance per driver** — the class is instantiated once at the bottom of the file. The constructor variable/function is then set to `nil` to prevent accidental re-instantiation (gnsstime pattern).

**5. Error handling** — prints error messages via `print()` to the Tasmota console/log. No exceptions/`try`-`catch` thrown (Berry lacks robust exception handling). Guard conditions check `self.w == nil` / `self.ser == nil` to skip operations when hardware is absent.

**6. BCD encoding** — DS3231 uses BCD (Binary-Coded Decimal) for register values. Helper functions `bcd2int()` and `int2bcd()` handle the conversion as strings.

**7. Global config override** — DS3231 checks `global.DS3231_ADDR` to allow runtime override of the I2C address (defaults to `0x68`). This is a documented extension point.

**8. NTP re-enable** — after setting time manually via `tasmota.cmd('time <epoch>', true)`, both drivers call `tasmota.cmd('time 0', true)` to re-enable NTP time updates.

**9. Minimum epoch guards** — a hardcoded minimum epoch (`1775000000` ~ Apr 2026 in ds3231, `1700000000` in gnsstime) prevents setting the system time to clearly-wrong values.

**10. No project-wide conventions file** — naming is consistent within each driver but the two drivers have slightly different styles (ds3231 uses `do/end` encapsulation, gnsstime uses function encapsulation). Follow the pattern of whichever driver you're editing.

## DS3231 Driver (`ds3231.be`)

### Architecture

- Class `DS3231` encapsulates all I2C communication with the DS3231 chip (addr `0x68`).
- `init()` scans I2C bus for the chip, calls `rtc2system()` if system time is clearly wrong (< Apr 2026), otherwise warns.
- Registers a rule on `Time#Set` via `tasmota.add_rule()` so `system2rtc()` fires every time NTP updates the system time (roughly hourly).
- `stop()` removes the rule — no cleanup needed beyond that.

### Data Flow

```
DS3231 chip (I2C 0x68)  ←→  driver  ←→  Tasmota system time
   ↑ 7 BCD registers          |              ↑
   └──────────────────────────┘              NTP (approx hourly)
   (rtc2system at boot)       (system2rtc on Time#Set rule)
```

- Read: 7 registers → BCD to decimal → build epoch string → `tasmota.strptime()` → `tasmota.cmd('time ...')`
- Write: `tasmota.rtc_utc()` → `tasmota.time_dump()` → reorder to DS3231 register order → `int2bcd()` → `bytes()` → `write_bytes()`

### Gotchas

- The `+1` second workaround on line ~107 compensates for I2C read delay. Do not remove.
- After setting time, `tasmota.cmd('time 0', true)` is called to re-enable NTP. This is critical.
- The `rtc2system()` always calls `tasmota.cmd()` even if the RTC time appears wrong (epoch < cutoff) — this forces the `Time#Set` rule to fire, which is needed for the initial boot sequence. The time floor of `ctime` prevents setting an obviously-zero epoch.
- The `Time#Set` rule is never removed if I2C scan fails at init — but it's harmless because `system2rtc()` guards with `self.w == nil`.

## GNSSTIME Driver (`gnsstime.be`)

### Architecture

- Class `GnssTime` encapsulates serial communication with a GNSS module.
- **Two-phase lifecycle**: `start(pin, baud)` opens the serial port, `update_every(sec)` kicks off periodic updates.
- `update()` initiates a one-shot NMEA read via fast loop (`tasmota.add_fast_loop`).
- `update_every(sec)` sets up a recurring timer (`tasmota.set_timer`).
- NMEA parsing handles `$--RMC` (time) and `$--GSV` (SNR data) sentences.
- Uses a state machine in `_fast_loop()` (states 1→2→3) to find sentence boundaries by detecting serial silence (>50ms gaps).

### Data Flow

```
GNSS module (UART TX→ESP32 RX)  →  serial port  →  fast loop → NMEA parser
                                                       ↓
                                              tasmota.cmd('time <epoch>')
                                                       ↓
                                              Tasmota system time
```

- Fast loop runs at Berry VM's maximum frequency — it does NOT block the system.
- After collecting all NMEA sentences (detected by >50ms serial silence), the fast loop self-terminates.

### Gotchas

- `start(pin, baud)` must be called before `update()` or `update_every()`. Missing it prints an error message (not an exception).
- `update()` sets `self.working = true` to prevent concurrent updates. There is only one serial port.
- The minimum update interval is **5 seconds** (enforced in `update_every()`).
- The maximum update interval is **86400 seconds** (1 day).
- If `self.gottime` is false (no valid time has ever been received), the retry interval is shortened to 15 seconds.
- Boot protection: `_update()` waits 5 seconds after boot before attempting GNSS read, to let Tasmota initialize.
- Buffer cap: if `self.buf` exceeds 2500 bytes, the fast loop terminates with a "PROGRAM ERROR" message (memory protection).
- The timeout in `_fast_loop()` is 4 seconds — if exceeded, it's treated as a program logic error and the loop terminates.
- `stop()` closes the serial port and re-enables NTP. After `stop()`, the instance is dead (`self.ser = nil`).
- `deinit()` is called by Berry garbage collector — it calls `stop()` if serial is still open.

### Testing GNSS Without NTP

From the README — to verify GNSS time works independently of internet:
```
> WiFi 0   # disables WiFi
> restart 1  # reboots without NTP
```

## Installation Flow (User-Facing)

1. Upload `.be` file to Tasmota filesystem or `tasmota.urlfetch()` from GitHub.
2. Wire the hardware per the README schematics.
3. Test in Berry Console: `load('ds3231')` or `load('gnsstime')`.
4. For automation, add `load('driver_name')` to `autoexec.be` on the Tasmota filesystem.

## Key Tasmota Berry API Surface (Not Defined In Repo)

These are Tasmota built-ins used extensively:

| API | Used By | Purpose |
|-----|---------|---------|
| `tasmota.wire_scan(addr)` | ds3231 | I2C bus scan |
| `tasmota.rtc_utc()` | ds3231 | Get system epoch time |
| `tasmota.time_dump(epoch)` | ds3231 | Convert epoch to map of fields |
| `tasmota.strptime(str, fmt)` | both | Parse time string to map |
| `tasmota.cmd(cmd, silent)` | both | Execute Tasmota command |
| `tasmota.add_rule(event, closure, id)` | ds3231 | Register event-triggered callback |
| `tasmota.remove_rule(event, id)` | ds3231 | Remove registered rule |
| `tasmota.add_fast_loop(closure)` | gnsstime | Register high-frequency callback |
| `tasmota.remove_fast_loop(closure)` | gnsstime | Remove fast loop callback |
| `tasmota.set_timer(ms, closure, id)` | gnsstime | Schedule one-shot/repeating timer |
| `tasmota.remove_timer(id)` | gnsstime | Cancel scheduled timer |
| `tasmota.millis()` | gnsstime | Uptime in milliseconds |
| `tasmota.gc()` | ds3231 | Trigger garbage collection |
| `serial(pin, -1, baud)` | gnsstime | Open serial port (RX only: pin, -1, baud) |

## Conventions to Follow When Contributing

- Each driver is a single `.be` file — no splitting into modules.
- Use `do/end` or function scope to isolate globals. Assign exactly one global name matching the driver name.
- Add a reload guard at the top of the file.
- All user-facing output via `print()` (goes to Tasmota console/log).
- Methods: `init()`, `stop()`, `deinit()` are the lifecycle trio. `deinit()` is called by the Berry VM on garbage collection — implement it.
- Comment style: `#` prefixed, occasionally `# TODO` for known incomplete functionality.
- String/byte manipulation uses Berry's `bytes()` type and `string.split()`, `string.find()`, etc.
- Event-driven paradigms only — never block with busy loops. Use fast_loop/set_timer/add_rule.
- Print a status message on success. Print an error message on failure. No silent failures.
- `true`/`false` are Berry keywords — use lowercase.
- `nil` is Berry's null.
- String concatenation uses `..` operator.
- Lambda syntax: `/->expression` or `def (args) body end`.
- Global variable access: use `global.varname`.

## Common Pitfalls for Agents

- **Berry is NOT Python or Lua** — syntax looks similar but `def` creates functions, `class/end` creates classes, `var` declares local variables. No `try/catch`. No `import` beyond `import strict` and `import string`.
- **These files are loaded at runtime on a Tasmota device** — there is no local development environment, test runner, or simulator. You cannot `run` or `test` these files on the host machine.
- **I2C address 0x68 is hardcoded** in ds3231, with a global override (`global.DS3231_ADDR`). Change the default carefully.
- **The `+1` second in ds3231 `rtc2system()`** is intentional — the I2C read takes non-zero time. Do not "fix" it.
- **Minimum epoch values** (`1775000000` in ds3231, `1700000000` in gnsstime) are hardcoded and should be updated if the project becomes significantly outdated (they represent "now-ish" as of Apr 2026).
- **`tasmota.cmd('time 0', true)` after setting time** — always do this to re-enable NTP. Omitting it will prevent NTP from ever updating the time again.
- **gnsstime's `self.working` flag** prevents concurrent `update()` calls. If a previous `update()` hangs (e.g., hardware failure), no new update can start until the 4-second timeout fires.
- **The `_stop_fast_loop()` method** in gnsstime sets `self.snr = ''` (string) instead of `self.snr = []` (list). This is existing behavior — do not change without testing on device.
