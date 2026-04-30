# DS3231 Driver — Logic Walkthrough

The driver implements a **bidirectional time sync** between the DS3231 RTC chip and the Tasmota system, using I2C communication with BCD-encoded registers.

## Two Helper Functions (Free-Standing)

**`bcd2int(x)`** — converts a BCD byte to a 2-character string. BCD stores each decimal digit in a nibble, so `0x59` → `"59"`. It uses string concatenation rather than arithmetic for convenience (the result is fed into `strptime()` later).

**`int2bcd(x)`** — reverse: decimal integer `59` → BCD byte `0x59 = 89`.

**`system2bcd()`** — reads the Tasmota system time via `tasmota.rtc_utc()` (epoch seconds), decomposes it with `tasmota.time_dump()` into a field map, reorders to DS3231 register order `[sec, min, hour, weekday, day, month, year%100]`, then encodes each field to BCD and packs into a 7-byte `bytes()` buffer ready to write to the chip.

## Class `DS3231` — Three Methods + Lifecycle

### `init()` — runs automatically on instantiation (`global.ds3231 = DS3231()`)

1. Checks if a global `DS3231_ADDR` override exists; otherwise uses `0x68` (the standard DS3231 I2C address).
2. Scans the I2C bus with `tasmota.wire_scan(self.addr)`. If no chip found → print error, exit. No rule is registered (harmless).
3. If chip found:
   - If system time < `1775000000` (epoch for Apr 2026) → it's definitely wrong (NTP hasn't run yet). Calls `self.rtc2system()` to pull time from the DS3231 immediately.
   - If system time ≥ cutoff → might be correct, might not. Prints a warning telling the user to force a sync manually.
   - Registers a **rule** on `Time#Set`: every time the system time gets set (including NTP updates ~hourly), `system2rtc()` fires. This keeps the DS3231 continuously accurate as long as NTP occasionally succeeds.

### `rtc2system()` — **RTC → System** direction

1. Guards: if `self.w == nil` (no chip), abort.
2. Reads 7 registers (addr 0–6) from DS3231 via I2C: `[sec, min, hour, weekday, day, month, year]` in BCD.
3. Converts each BCD byte to decimal string via `bcd2int()`.
4. Pops the weekday field (3rd element, index 3 — not needed for epoch calculation).
5. Reverses the list so the order becomes `[year, month, day, hour, min, sec]` — matching `strptime` format `"%Y %m %d %H %M %S"`.
6. Prepends `"20"` to the 2-digit year (`24` → `"2024"`).
7. Uses `tasmota.strptime()` to parse the concatenated string into an epoch timestamp.
8. **Safety floor**: if the computed epoch is < `1775000000`, it's clamped to that value. This prevents setting time to year 1900 if the chip's battery died, while still firing the `Time#Set` rule.
9. Sets system time with `tasmota.cmd('time ' .. t+1, true)` — **the `+1` is a crude I2C read-delay compensation** (the read took non-zero time).
10. **Critical**: immediately calls `tasmota.cmd('time 0', true)` to re-enable NTP. Without this, the manual `time` command would permanently disable NTP updates.

### `system2rtc()` — **System → RTC** direction

1. Guards against missing chip.
2. Calls the helper `system2bcd()` to get the current system time as a 7-byte BCD buffer.
3. Writes the buffer to DS3231 registers 0–6 via `write_bytes()`.
4. This fires on every `Time#Set` rule trigger (NTP update ≈ hourly).

## Lifecycle: The Whole Story

```
Boot (load 'ds3231')
  │
  ├─ I2C scan → chip found?
  │   ├─ No  → print error, exit (no rule registered)
  │   └─ Yes →
  │        ├─ System time < Apr 2026? → rtc2system() (pull from chip)
  │        └─ System time ≥ Apr 2026? → print "seems set, force manually"
  │        └─ Register rule: Time#Set → system2rtc()
  │
  └─ NTP fires (~hourly)
       │
       └─ Time#Set rule triggers → system2rtc() → updates DS3231 registers
             │
             └─ Keeps RTC accurate for when NTP is unavailable
```

## Why Both Directions?

The DS3231 has a backup battery (CR2032) and keeps accurate time even when the ESP is powered off. At **boot**, the driver pulls the battery-backed time from the chip into Tasmota. Then **whenever NTP succeeds**, it pushes the precise internet time back to the chip, compensating for the DS3231's ~2ppm drift (~1 min/year). This means even if the device loses internet for weeks, the RTC will have been updated the last time NTP was available, minimizing drift.

## Non-Obvious Details

- **The `+1` second** in `rtc2system()` is **not a bug** — it compensates for the time lost during I2C reading. Removing it would make the system time consistently ~100ms+ behind the RTC.
- **`tasmota.cmd('time 0', true)`** after `rtc2system()` is mandatory. Tasmota treats `time <epoch>` as a manual override that disables NTP. Calling `time 0` re-enables it.
- **The `Time#Set` rule** fires on *any* time set operation, including the one from `rtc2system()`. This means at boot, after `rtc2system()` sets the time, `system2rtc()` fires writing the system time back to the DS3231 — which is fine since both sources agree (or are at least near each other).
- **`do/end` block** prevents the helper functions and class from leaking into global scope. Only `global.ds3231` escapes.
- **Reload guard** — if `global.ds3231` already exists, the old instance is stopped and nilled before creating a new one. This is essential during development when the file is reloaded via the Berry console.
