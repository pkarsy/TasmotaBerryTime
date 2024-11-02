# GNSSTIME

Tasmota berry driver to use a GNSS module (UBLOX etc) as a time source when accurate
time keeping is needed but no WIFI network is available. Also when the AP is not in our control, and at any time can disappear or change SSID/password.

## Note : Tasmota already has support for UBLOX GNSS modules using a custom image

If you already use a custom image and your GNSS receiver is UBLOX just #include the support in this image. This driver allows to use GNSS modules with stock ESP32(or s2 c2 c3 etc) tasmota images, By using the standard NMEA protocol, potentially supports more GNSS receivers. Some of the information in this README may be relevant even if you are going to use the native tasmota driver.

## GNSS modules support

The driver reads the $--RMC sentence, so it should be compatible with many (probably most. The RMC sentence in standard) GNSS modules.
However it is only tested with UBLOX NEO 6M , 7C and M8N (Factory settings). All these modules emit such sentences via serial line :

```sh
# GPS only
"$GPRMC,123519,A,4417.128,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
# More satellite constellations
"$GNRMC,121134.00,A,3321.31523,N,02201.41432,E,0.019,,030624,,,A*66"
```

It is only tested with the default 9600 baud, and there is no real advantage using higher baudrates.

## GNSS module selection and satellite signal

The obvious consideration with GNSS receivers is that we need to put them in a place with good satellite signal. HDOP and similar is not important here, but SNR is.

Generally speaking, it is much easier for a receiver to get the time (even 1 satellite is enough) than to get a position. However even with this bonus, we need to be very careful about the installation site.

Ideally we want it to be outdoors, but this option is not always possible (long distances from the controlled device) or safe (ie bad weather conditions, lightnings etc). The type of the building is crucial and light constructions without metal and thin walls/floor to be usually acceptable (barns, wooden houses etc). The location (mountains, height, terrain) and the weather can have a crucial effect on the available satellites and SNR.

The available receivers also differ significantly. For example the NEO-Μ8N seems to be better than 7 and 6 series (more satellite constellations). Even the best GNSS receivers will have problems if they are away from windows or the walls are thick etc. In this case you will probably need:

- An external antenna.
- Longer serial cables. There are dedicated tutorials if you are in this category (noise reduction, isolation etc.)
- The ESP32 & GNSS modules are inside the same project box enclosure, and in a place with good signal, and if applicable, longer cables are used to control the target device.
- Use a more sensitive GNSS receiver. However this is expensive and not a panacea. If the signal is bad, easily the GNSS will not work at all with unfavorable weather conditions an unforeseen obstacle etc, or simply by the variation of the satellites in view.

You can find some methods to ensure that the signal is OK, in the dedicated section below.

## Connection with the MCU

3 pins are needed GND VCC (3.3V but some modules have a regulator and accept 5V check the documentation) and the TX pin to any free ESP32 pin. Every GNSS module I have, is using 3.3V logic for the TX pin, but check the data sheet anyway. Do NOT set the pin as serial line (tasmota configuration menu). Just make sure
it is unused. Check the manufacturer of the breakout, LOLIN, WEMOS, etc for the available PINs (Be careful, almost all ESP32 boards have some pins you rather avoid).

## Software installation

- paste this to Berry Scripting Console
```berry
do
  var fn = 'gnsstime.be'
  var cl = webclient()
  var url = 'https://raw.githubusercontent.com/pkarsy/TasmotaBerryTime/refs/heads/main/gnsstime/' + fn
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
Or upload the file "gnsstime.be" to the tasmota filesystem.

Put this to "autoexec.be", but first test in berry console :

```berry
load('gnsstime')
# here is the TX-pin of GNSS to the GPIO-4 of ESP32(s2)(c3) baud is 9600
# The factory default for at least UBLOX NEO 6 7 8 series
gnsstime.start(4, 9600)
# This is for test, no need to be in autoexec
gnsstime.update()
# if update() is working OK
gnsstime.update_every(3600)
# for testing you can use a very short update period, for example update_every(30) minimum is 5 sec
# From now on the system time is updated periodically
# there is no performance impact and
# you can load any other berry code you use.
```

and check the console. If you preffer MQTT, enable messages :
> mqttlog 2


## Test the module without Internet time (NTP)

To be sure it is working you can completely disable Wifi and see what happens.
Connect the ESP32 to the computer with USB. Open a serial terminal.

```sh
> WiFi 0 + Ctrl-J # disables the Wifi
> restart 1 + Ctrl-J # The module restarts without NTP (and no Internet at all)
```

And check the log messages. Hopefully you will see the time from GNSS.

```sh
> Wifi 1 + Ctrl-J # to re-enable Wifi if needed.
```

## GNSS satellite time vs stored RTC time

At least NEO 6 7 8 modules ship with a rechargeable battery cell, and once they get the first data from satellites, they keep the time in their internal RTC. If there is no satellite signal the $--RMC sentence contains this time. If we make the mistake to put the module in a place without satellite signal, the time will start to drift. Gnsstime prints a warning if the time is RTC based.

## How to check if the installation site has adequate satellite signal

Needless to say the following tests must be done in the exact location we want to install the receiver. Even if we install it outdoors, there can still be problems with the terrain, an antenna malfunction etc, so the first test is necessary.

- Check the messages this driver prints (If there is no wifi, use your mobile phone as AP, or connect your laptop with a USB cable).
As long as the GNSS does not have a fix, a warning message is printed. If you have a relatively quick fix after power up, probably you are OK.
If the receiver does not get a fix, or gets it intermittently you cannot trust this installation point.
A very important information is the SNR values printed (and the number of satellites of course). If enough satellites have a good SNR you are probably OK. What a good SNR is, it depends on the sensitivity of the receiver. Move the receiver to various places to learn how is functioning. Some sources consider for example 35 a weak signal, however at least NEO M8N seems to work way below that.

- You can also additionally use an identical GNSS receiver connected to a PC and a GNSS viewer application.
For example you can do a cold boot to see how fast you get a fix, etc.

### Important design considerations

- On power up, the GNSS may need from a few seconds up to a few minutes to get the time. If the module has a battery backed RTC (like NEO 6 7 8 mentioned earlier) the RTC time it is becoming quickly available (about after 5 seconds, when the driver reads the GNSS for the first time).
If however the module does not have a battery(or it is depleted), the system time will be wrong for a while.

- Be careful to only start programmed actions if the system time is correct. An easy and relatively reliable way to do this (in berry code) is to ensure epoch>1700000000 or year>2023 or something similar.

- For the usage gnsstime is designed, the power can also be unreliable, so

    ```sh
    SetOption65 1
    ```

    to avoid unwelcome factory defaults. Read the documentation for this setting, to be sure you want to use it.

- As the wifi is most likely unavailable, configure tasmota SSID1 or 2 to be the AP of your mobile phone. Optionally, configure an MQTT server to be able to control it easily.
