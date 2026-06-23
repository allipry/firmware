# MAGK Portable Node — MM6108 (Wio‑WM6180 XIAO HaLow) → Raspberry Pi SPI Wiring

**Source of truth:** the OpenMANet kernel device‑tree overlay
`arch/arm/boot/dts/overlays/mm610x-spi-overlay.dts`
(added by `target/linux/bcm27xx/patches-6.6/991-0003-dt-overlays-morse-add-spi-overlay-fragment.patch`).
This overlay is applied by the `mm610x-spi` distro config, which is what the
`bcm2710_mm6108-spi` (Pi Zero 2 W / Pi 3) and `bcm2711_mm6108-spi` (Pi 4 / GW1)
device profiles select.

> The overlay's `compatible` list covers bcm2708/2709/2710/2711/2835/2836/2837,
> so **the Pi Zero 2 W uses the identical pinout to GW1** (Pi 4). Any Pi with the
> standard 40‑pin header wires the same way.

The HaLow module **must be powered at 3.3 V** (per the Seeed Wio‑WM6180 spec).
Driver: `morse,mm610x-spi`, on **SPI0, chip‑select CE0**, **50 MHz** max.

---

## Pin map (what the firmware expects)

| Morse signal | BCM GPIO | Pi 40‑pin **physical** pin | DT role | Direction / pull (pinctrl) |
|---|---|---|---|---|
| SPI MOSI | GPIO10 | **19** | `spi0_pins` (ALT0) | SPI0, pull‑up |
| SPI MISO | GPIO9  | **21** | `spi0_pins` (ALT0) | SPI0, pull‑up |
| SPI SCLK | GPIO11 | **23** | `spi0_pins` (ALT0) | SPI0, pull‑up |
| SPI CS (CE0) | GPIO8 | **24** | `cs-gpios=<&gpio 8 1>`, `reg=<0>` | output, active‑low |
| Reset | GPIO17 | **11** | `reset-gpios=<&gpio 17 0>` | output (pinctrl: in, pull‑up) |
| IRQ | GPIO5 | **29** | `spi-irq-gpios=<&gpio 5 0>` | input, pull‑up |
| Wake / power[0] | GPIO23 | **16** | `power-gpios[0]` / `morse_wake` | input, pull‑up |
| Busy / power[1] | GPIO24 | **18** | `power-gpios[1]` / `morse_busy` | input, pull‑down |
| Power | 3V3 | **1** (or 17) | — | 3.3 V supply |
| Ground | GND | **6** (or 9,14,20,25,30,34,39) | — | common ground |

`power-gpios = <&gpio 23 0>, <&gpio 24 0>` — the morse driver claims **GPIO23 and
GPIO24** for power/enable sequencing; the pinctrl also names them `morse_wake`
(23) and `morse_busy` (24). Wire both.

### Header view (signals on the left/right rails)

```
        3V3  (1) (2)  5V
      GPIO2  (3) (4)  5V
      GPIO3  (5) (6)  GND ─── GND
      GPIO4  (7) (8)  GPIO14
        GND  (9) (10) GPIO15
 RESET►GPIO17(11)(12) GPIO18
     GPIO27 (13)(14) GND
     GPIO22 (15)(16) GPIO23 ◄WAKE/PWR
        3V3 (17)(18) GPIO24 ◄BUSY/PWR
 MOSI►GPIO10(19)(20) GND
 MISO► GPIO9(21)(22) GPIO25
 SCLK►GPIO11(23)(24) GPIO8 ◄CS/CE0
        GND (25)(26) GPIO7
      GPIO0 (27)(28) GPIO1
  IRQ►GPIO5 (29)(30) GND
     GPIO6 (31)(32) GPIO12
```
(Standard 40‑pin Raspberry Pi header; Pi Zero 2 W shares this layout. ◄ = wire to the module.)

---

## Minimum connection list (XIAO Wio‑WM6180 → Pi Zero 2 W)

Map the module's edge signals to these Pi header **physical** pins:

- Module **MOSI** → pin **19** (GPIO10)
- Module **MISO** → pin **21** (GPIO9)
- Module **SCK/SCLK** → pin **23** (GPIO11)
- Module **CS/SS** → pin **24** (GPIO8 / CE0)
- Module **RESET / RST** → pin **11** (GPIO17)
- Module **IRQ / INT** → pin **29** (GPIO5)
- Module **WAKE** (or enable/PWR) → pin **16** (GPIO23)
- Module **BUSY** (or 2nd enable) → pin **18** (GPIO24)
- Module **3V3** → pin **1** (3.3 V)
- Module **GND** → pin **6** (GND)

> The Seeed wiki for this module documents it on a **XIAO ESP32S3 socket**, not a
> Pi. You are adapting the XIAO edge connector to the Pi GPIO above. Confirm the
> module's silk/pinout for which edge pad is MOSI/MISO/SCLK/CS/IRQ/RESET/WAKE/BUSY
> and translate to the Pi physical pins listed here. If the module exposes
> different control‑line names, match by function (reset / interrupt / power‑enable).

---

## Verify after flashing `bcm2710_mm6108-spi`

On the node:
```sh
dmesg | grep -i morse                 # expect morse SPI probe + chip ID, no -ENODEV
logread | grep -iE "morse|mm610"      # driver bring-up
ls /sys/bus/spi/devices/              # spi0.0 present
morse_cli -i wlan0 channel            # radio responds (operating freq / BW)
iw dev                                 # wlan0 should exist (the S1G mesh iface)
```
If `dmesg` shows the morse driver loading but failing to probe (timeout / no
response), it's almost always a **wiring mismatch** on CS (GPIO8), IRQ (GPIO5),
RESET (GPIO17), or the power lines (GPIO23/24) — recheck those four against the
table above before suspecting the image.

## If your wiring can't match this pinout
The pins above are fixed in the stock overlay. If your MANet‑radio carrier board
routes the XIAO module to **different** GPIOs, we build a **custom overlay**
(copy `mm610x-spi-overlay.dts`, change the `cs-gpios`, `reset-gpios`,
`power-gpios`, `spi-irq-gpios`, and the matching pinctrl `brcm,pins`) and ship it
in the image. Send me the carrier‑board pin assignments and I'll generate it.
