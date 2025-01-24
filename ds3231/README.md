# DS3231 driver for tasmota, written in the Berry scripting language.

## Purpose

The tasmota system already contains support for DS3231, but only on custom builds. This driver offers this functionality for stock Tasmota esp32xx images. If your node needs a custom image anyway or if you
use esp8266 (Berry cannot run there), use the builtin feature.

## Characteristics

- Does not try to implement all the features of DS3231, only time get and time set (No alarms or other DS3231 chip features)
- The blue breakout found on online stores, also contains an EEPROM chip which is not handled here
- The code is event driven (as it should in berry). The ESP is free to do all usual tasmota tasks and can also run other berry code.
- *probably* works with DS3232 (not tested)

## Installation
- paste this to Berry Scripting Console
```berry
do
  var fn = 'ds3231.be'
  var cl = webclient()
  var url = 'https://raw.githubusercontent.com/pkarsy/TasmotaBerryTime/refs/heads/main/ds3231/' + fn
  cl.begin(url)
  if cl.GET() != 200 print('Error getting', fn) return end
  var s = cl.get_string()
  cl.close()
  var f = open('/'+fn, 'w')
  f.write(s)
  f.close()
  print('Installed', fn)
end
```
Or upload the "ds3231.be" to the tasmota filesystem

# Coonecting the DS3231 breakout board

The DS3231 breakout board has 6 pins but we will use 4 : GND VCC SDA SCL
Now we configure Tasmota ESP32 :
TasmotaMain -> Configuration -> Module

- Choose the most convenient PINs for you project.
for example the ESP32 devkit and similar boards can be configured as:
```sh
GND (Onboard)
GPIO 19 -> OutputHi (acts as VCC)
GPIO 18 -> SDA
GPIO 5 -> SCL
```

the Luatos Esp32-C3 can be configured as : 

```sh
GND (onboard)
VCC 3.3 (onboard)
GPIO 5 -> SDA
GPIO 4 -> SCL
```

For the ESP32-C3 32S Ai-thinker
```sh
GND (onboard) TODO
VCC 3.3 (onboard) TODO
GPIO 5 -> SDA
GPIO 4 -> SCL
```

so the pins are in the same order as DS3231 (including GND and 3.3V), and can be directly connected to the ESP board.

- Go to berry scripting console and type
```
load('ds3231')
```
You will see a message hopefully reporting success.
- If all is OK put this in "autoexec.be". The line should be the first in autoexec if you have other modules to load. This way the time will be correct when those moudules are loaded.

## Breakout battery problem

![DS3231 breakout](ds3231.jpg)

**For the impatient, when using 3.3V for VCC (ESP32, STM32 etc) just put a CR2032 and you are ready to go.**

More details now :
The most popular (on online stores) breakout, has a weird design choice. In particular it has a primitive charging circuitry (a diode and a resistor in series) and is trying to charge a rechargeable battery (LIR2032). Most of the time however the breakout is sold with a normal (CR2032) or no battery at all. The use of a rechargeable battery is a somewhat problematic choice anyway :

- The LIR2032 is no nearly as common, and it is more expensive than CR2032.
- It has a very low capacity and higher shelf discharge rate than CR2032.
- With ESP(or any other 3.3V MCU) we want the DS3231-VCC to be 3.3V and the LIR2032 cannot be charged with this voltage.
- It seems the chemistry of LIR does not allow for deep discharge, so it is destroyed if fully discharged. Not sure about this.

For the above reasons use the very common CR2032. It can last 10 years according to data sheets.
**If you are using 5V (Arduino Uno for example) for the VCC, you must de-solder the diode (or the resistor), to avoid damaging the non rechargeable CR2032 cell**
Of course it does not hurt to desolder the diode on 3.3V systems, but it is not necessary.

Finally, do not trust the coin cell (if came) with the module, use a new one.

## Unreliable power
- If your power source is unreliable
  ```
  SetOption65 1
  ```
  in tasmota console, to avoid unexplained resets to factory defaults. Battery power can easily lead to this problem. Read the documentation however before setting this option.

## How the driver works

The DS3231 has 7 registers containing year month etc. At boot the module reads all those registers and assembles the "epoch" time and sets the system time. When(if) the internet becomes available the oposite operation is done.
I don't know if the native tasmota DS3231 code does it, but this module updates the RTC clock periodically (on every NTP update, about every hour). This way the RTC clock remains always accurate, unless of course the ESP is without internet connection for extended periods of time.

## Limitations

Although very accurate(2ppm), the DS3231 can be off by 1min per year. If the module is going to be used standalone (without internet) and you need such accuracy, you might consider using a GNSS module. The tasmota system have support for UBLOX modules (again a custom build is needed). This repository contains also "gnsstime" which serves the same purpose as ds3231 and does not require a custom build.
