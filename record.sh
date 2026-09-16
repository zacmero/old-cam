#!/usr/bin/env bash
set -euo pipefail

# DarkHorse USB 2.0 Web Camera (1b17:6101) All-in-One Recording Pipeline
# Captures 636x476 YUYV video + analog microphone with real-time 8 kHz whine filtering.

VIDEO_DEV="/dev/video0"
AUDIO_SRC="alsa_input.pci-0000_00_1b.0.analog-stereo"

# Steep FIR brick-wall notch filter eliminating 8,000 Hz USB microframe clock crosstalk + highpass + denoise
AUDIO_FILTER="highpass=f=100,firequalizer=gain_entry='entry(0,0);entry(7000,0);entry(7500,-80);entry(24000,-80)',afftdn=nf=-20"

usage() {
    cat << 'EOF'
DarkHorse Webcam Recording Tool

Usage:
  ./record.sh [output.mp4]                   Record video + whine-filtered audio to file
  ./record.sh --preview [output.mp4]         Record while viewing live on-screen preview (mpv)
  ./record.sh --clean <input.mp4> <out.mp4>  Post-process an existing video to remove 8 kHz whine

Options:
  -p, --preview          Show live video preview window on screen during recording
  -c, --clean, --filter  Filter an existing recording without re-capturing
  -h, --help             Show this help message

Controls during recording:
  Press 'q' (in the terminal or preview window) or Ctrl+C to stop recording.
EOF
    exit 0
}

ensure_audio_profile() {
    pactl set-card-profile alsa_card.pci-0000_00_1b.0 input:analog-stereo 2>/dev/null || true
}

PREVIEW=false
CLEAN_MODE=false
INPUT_FILE=""
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--preview)
            PREVIEW=true
            shift
            ;;
        -c|--clean|--filter)
            CLEAN_MODE=true
            if [ $# -lt 3 ]; then
                echo "[!] Error: --clean requires <input.mp4> and <output.mp4>"
                exit 1
            fi
            INPUT_FILE="$2"
            OUTPUT_FILE="$3"
            shift 3
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE="$1"
            else
                echo "[!] Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Optical black calibration strip removal + standard 640x480 VGA scaling
VIDEO_FILTER="crop=460:476:176:0,scale=640:480"

# Mode 1: Post-process existing file
if [ "$CLEAN_MODE" = true ]; then
    if [ ! -f "$INPUT_FILE" ]; then
        echo "[!] Error: Input file $INPUT_FILE not found."
        exit 1
    fi
    echo "[*] Post-processing existing file: $INPUT_FILE -> $OUTPUT_FILE"
    IN_RES=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$INPUT_FILE" 2>/dev/null || true)
    if [ "$IN_RES" = "636x476" ]; then
        echo "[*] Detected raw 636x476 video: removing left glitch strip & scaling to 640x480..."
        ffmpeg -y -i "$INPUT_FILE" \
            -vf "$VIDEO_FILTER" \
            -c:v libx264 -pix_fmt yuv420p \
            -af "$AUDIO_FILTER" \
            -c:a aac -b:a 192k \
            "$OUTPUT_FILE"
    else
        ffmpeg -y -i "$INPUT_FILE" \
            -c:v copy \
            -af "$AUDIO_FILTER" \
            -c:a aac -b:a 192k \
            "$OUTPUT_FILE"
    fi
    echo "[+] Cleaned file saved to: $OUTPUT_FILE"
    exit 0
fi

# Mode 2: Live recording (with or without preview)
OUTPUT_FILE="${OUTPUT_FILE:-$HOME/webcam_recording.mp4}"

if [ ! -e "$VIDEO_DEV" ]; then
    echo "[!] Error: Video device $VIDEO_DEV not found."
    echo "    Check USB connection or load driver: sudo modprobe vc032x_custom"
    exit 1
fi

ensure_audio_profile

echo "=================================================="
echo " Starting Webcam Recording Pipeline"
echo " Destination: $OUTPUT_FILE"
echo " Video:       $VIDEO_DEV (636x476 YUYV -> 640x480 H.264, strip removed)"
echo " Audio:       Rear Mic (PipeWire) + 8 kHz Notch Filter"
echo " Preview:     $PREVIEW"
echo " Stop:        Press 'q' or Ctrl+C"
echo "=================================================="

if [ "$PREVIEW" = true ]; then
    ffmpeg -y \
        -thread_queue_size 1024 -f v4l2 -input_format yuyv422 -video_size 636x476 -i "$VIDEO_DEV" \
        -thread_queue_size 1024 -f pulse -i "$AUDIO_SRC" \
        -vf "$VIDEO_FILTER" \
        -c:v libx264 -pix_fmt yuv420p \
        -af "$AUDIO_FILTER" \
        -c:a aac -b:a 192k "$OUTPUT_FILE" \
        -f matroska -c:v copy -an - | mpv --title="Webcam Recording Preview" -
else
    ffmpeg -y \
        -thread_queue_size 1024 -f v4l2 -input_format yuyv422 -video_size 636x476 -i "$VIDEO_DEV" \
        -thread_queue_size 1024 -f pulse -i "$AUDIO_SRC" \
        -vf "$VIDEO_FILTER" \
        -c:v libx264 -pix_fmt yuv420p \
        -af "$AUDIO_FILTER" \
        -c:a aac -b:a 192k "$OUTPUT_FILE"
fi

echo ""
echo "[+] Recording successfully saved to: $OUTPUT_FILE"
