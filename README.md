# DarkHorse USB 2.0 Web Camera (1b17:6101) Linux Driver

This repository contains the customized Linux kernel driver, hardware reverse-engineering tools, and setup scripts for the **DarkHorse USB 2.0 Web Camera** (USB ID `1b17:6101`).

---

## 1. Hardware Specifications

| Component | Specification |
|---|---|
| **Device Name** | DarkHorse USB 2.0 Web Camera |
| **USB Vendor ID / Product ID** | `1b17:6101` |
| **USB Bus Architecture** | USB 2.0 High-Speed (480 Mbps) |
| **Bridge Controller** | Vimicro VC0321 (Z-Star / Vimicro) |
| **Optical Image Sensor** | OmniVision OV7660 (VGA CMOS sensor, SCCB / I2C `0x21` / `0xa1`) |
| **Native Resolutions** | 636x476, 640x480 (VGA), 320x240 (QVGA) |
| **Pixel Format** | YUYV 4:2:2 (native uncompressed) |
| **Frame Rate** | Up to 12.55 FPS |
| **Audio Interface** | Integrated microphone routed through an external 3.5mm (P2) analog audio jack |

---

## 2. Root Cause Analysis: Why It Did Not Work Out of the Box

Modern Linux distributions failed to recognize or stream from this camera due to four interconnected hardware/firmware incompatibilities:

1. **Unrecognized OEM Identifiers:**
   The bridge chip is a Vimicro VC0321, but the OEM flashed custom vendor and product IDs (`1b17:6101`). The in-tree `gspca_vc032x` driver only bound to standard Vimicro (`0ac8:*`) and Logitech (`046d:*`) IDs.
2. **I2C Sensor Probe Failure:**
   When manually forced via sysfs dynamic IDs (`new_id`), `gspca_vc032x` attempted automatic I2C sensor probing for unknown VIDs. The VC0321 I2C interface timed out during generic probing, causing the driver probe routine to abort with `-EINVAL`.
3. **USB Isochronous Buffer Overrun (`-EOVERFLOW` / `-75`):**
   The VC0321 hardware bursts packets up to 3,072 bytes per microframe (USB Alternate Setting 7). The upstream driver's bandwidth calculation logic selected Alternate Setting 6 (max 2,688 bytes/microframe). This caused continuous `-75` (`-EOVERFLOW`) packet errors, and `gspca_main` discarded 100% of all incoming video frames.
4. **Proprietary Frame Sync Header:**
   Upstream `vc032x.c` expected standard JPEG start-of-image markers (`0xff 0xd8`). The DarkHorse firmware instead transmits a proprietary 46-byte frame boundary delimiter starting with `0xff 0xd9 0xff 0xd8` followed by the ASCII sequence `Dark2Horse`. Because `data[0..1] == 0xff 0xd8` never matched at offset 0, the driver never marked `FIRST_PACKET` or `LAST_PACKET`.
5. **Pixel Format Incompatibility:**
   Upstream declared `V4L2_PIX_FMT_YVYU`, which is unsupported or deprecated by modern video capture applications (FFmpeg, Chromium, OBS, mpv).

---

## 3. Reverse-Engineering Methodology

The device was diagnosed and characterized using direct USB register probing via PyUSB before modifying kernel code:

1. **Bridge Identification ([`diagnostics/dump_regs.py`](diagnostics/dump_regs.py)):**
   Sending a vendor control read request to register `0xbfcf` returned `0x2c` (`44`), confirming the Vimicro VC0321 register map.
2. **Sensor Identification ([`diagnostics/probe_sensors.py`](diagnostics/probe_sensors.py)):**
   By executing raw SCCB/I2C read transactions through VC0321 bridge registers `0xa0` and `0x88`, reading register `0x0a` on I2C address `0xa1` returned `0x7660`, identifying the sensor as an OmniVision OV7660.
3. **Stream Boundary Delineation:**
   Capturing raw isochronous stream buffers revealed repeated delimiters spaced exactly 605,538 bytes apart:
   ```
   ff d9 ff d8 44 61 72 6b 32 48 6f 72 73 65  ....Dark2Horse
   ```
   - Header size: 46 bytes
   - Payload per frame: 605,492 bytes = 636 × 476 pixels × 2 bytes/pixel (YUYV) + 20 trailer bytes.

---

## 4. Kernel Driver Modifications

The driver source ([`vc032x.c`](vc032x.c)) incorporates the following fixes:

1. **Device ID Registration:**
   ```c
   static const struct usb_device_id device_table[] = {
       {USB_DEVICE(0x1b17, 0x6101), BF(VC0321, 0)},
       ...
   ```
2. **Automatic OV7660 Sensor Binding:**
   ```c
   if (force_sensor >= 0)
       sd->sensor = force_sensor;
   else if (id->idVendor == 0x1b17 && id->idProduct == 0x6101)
       sd->sensor = SENSOR_OV7660;
   ```
3. **Bandwidth & Alternate Setting Selection:**
   Implemented `sd_isoc_init` to force USB Alternate Setting 7 (3 packets × 1024 bytes = 3,072 bytes per microframe), matching the maximum packet burst of the VC0321 controller and eliminating `-EOVERFLOW`.
4. **Dark2Horse Header Synchronization:**
   Updated `sd_pkt_scan`:
   ```c
   if (len >= 4 &&
       ((data[0] == 0xff && data[1] == 0xd9 && data[2] == 0xff && data[3] == 0xd8) ||
        (data[0] == 0xff && data[1] == 0xd8))) {
       gspca_frame_add(gspca_dev, LAST_PACKET, NULL, 0);
       if (len > sd->image_offset) {
           data += sd->image_offset;
           len -= sd->image_offset;
           gspca_frame_add(gspca_dev, FIRST_PACKET, data, len);
       } else {
           gspca_frame_add(gspca_dev, FIRST_PACKET, NULL, 0);
       }
       return;
   }
   ```
5. **Pixel Format & Resolution Table:**
   Switched format to standard `V4L2_PIX_FMT_YUYV` and added the native geometry `636x476` alongside `640x480` and `320x240`.

---

## 5. Quick Installation

### Prerequisites (Arch Linux)
```bash
sudo pacman -S --needed linux-headers base-devel zstd v4l-utils ffmpeg
```

### Build and Install
Run the automated installer script:
```bash
sudo ./install.sh
```

The script will:
1. Compile `vc032x_custom.ko` against your running kernel headers.
2. Compress the module with `zstd` and install it to `/usr/lib/modules/$(uname -r)/updates/`.
3. Update module dependencies via `depmod -a`.
4. Register the module for auto-loading on boot in `/etc/modules-load.d/webcam-1b17.conf`.
5. Install udev rules in `/etc/udev/rules.d/99-webcam-1b17.rules` for automatic hotplug detection and proper permissions.

---

## 6. Verification and Testing

### 1. Verify Video Device Node
```bash
v4l2-ctl --list-devices
```
Expected output:
```text
USB2.0 Web Camera (usb-0000:00:14.0-12):
	/dev/video0
```

### 2. Verify Supported Formats
```bash
v4l2-ctl --list-formats-ext
```
Expected output:
```text
ioctl: VIDIOC_ENUM_FMT
	Type: Video Capture

	[0]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 320x240
		Size: Discrete 640x480
		Size: Discrete 636x476
```

### 3. Test Frame Capture & Streaming
Stream 30 frames with zero frame drops:
```bash
v4l2-ctl --device=/dev/video0 --stream-mmap --stream-count=30
```

### 4. Record Video with FFmpeg
```bash
ffmpeg -f v4l2 -input_format yuyv422 -video_size 640x480 -i /dev/video0 -t 5 -c:v libx264 test.mp4
```

### 5. Live Preview
View the live camera stream with `mpv`:
```bash
mpv --demuxer-lavf-format=video4linux2 --demuxer-lavf-o-set=input_format=yuyv422,video_size=640x480 av://v4l2:/dev/video0
```
Or with `ffplay`:
```bash
ffplay -f v4l2 -input_format yuyv422 -video_size 640x480 /dev/video0
```

---

## 7. Camera Controls & Tuning

The OmniVision OV7660 incorporates built-in Automatic Gain Control (AGC) and Automatic Exposure Control (AEC).
When the camera is first opened or exposed to low light, it takes several frames for the exposure loop to stabilize.

You can inspect and adjust hardware controls via `v4l2-ctl`:
```bash
# List all adjustable controls
v4l2-ctl -d /dev/video0 -l

# Adjust brightness (range 0 to 255)
v4l2-ctl -d /dev/video0 --set-ctrl=brightness=160

# Adjust contrast (range 0 to 255)
v4l2-ctl -d /dev/video0 --set-ctrl=contrast=60
```

---

## 8. Integrated Microphone (3.5mm P2 Audio Jack)

The webcam features an integrated analog electret microphone exposed via a separate 3.5mm (P2) audio jack rather than USB audio.

### Audio Configuration (ALSA)
When connected to the front panel audio jack of the motherboard (Intel PCH / ALC887):
1. **Input Selection:** Route the input to the front microphone:
   ```bash
   amixer -c 0 sset 'Input Source',0 'Front Mic'
   ```
2. **Microphone Boost & Gain:**
   Electret capsules output low-voltage analog signals. Enable pre-amp boost (+20dB) and set capture volume:
   ```bash
   amixer -c 0 sset 'Front Mic Boost' 2
   amixer -c 0 sset 'Capture' 100%
   ```
3. **Audio-Only Recording Test:**
   ```bash
   arecord -D hw:0,0 -f S16_LE -r 44100 -c 2 -d 5 test_mic.wav
   ```
4. **Simultaneous Video + Audio Capture (FFmpeg):**
   ```bash
   ffmpeg -f v4l2 -input_format yuyv422 -video_size 640x480 -i /dev/video0 \
          -f alsa -i hw:0,0 -t 10 -c:v libx264 -c:a aac output.mp4
   ```

---

## 9. Hardware Activity LED

The webcam body includes an integrated red indicator LED.
- **Hardware Architecture:** On Vimicro VC0321/VC0323 controller boards, the activity LED is typically connected to one of the bridge GPIO output pins controlled via register `0x89`.
- **Behavior:** In Logitech QuickCam OEM implementations, the driver asserts `0x89 = 0xfdff` to drive the LED low during streaming. In this DarkHorse OEM variant, the LED is unmapped by default and remains off during operation.

