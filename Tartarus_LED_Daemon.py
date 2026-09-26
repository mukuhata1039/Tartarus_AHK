import ctypes
import os
import sys
import time
from pathlib import Path

VID = 0x1532
PID = 0x0244
ROOT = Path(__file__).resolve().parent
LOG_DIR = ROOT / "Logs"
LOG_DIR.mkdir(exist_ok=True)
STATE_FILE = ROOT / "Tartarus_LED_State.txt"
CONFIG_FILE = ROOT / "Tartarus_Config.tsv"
LOG_FILE = LOG_DIR / "Tartarus_LED_Debug.log"
MAX_LOG_BYTES = 2 * 1024 * 1024
_last_rotate_check = 0.0

DEFAULT_COLORS = {
    "Base":        ((255,  77,   0), (255,  77,   0)),
    "Keymap 1":    ((255,   0,   0), (255,   0,   0)),
    "Controller":  ((  0, 255,   0), (  0, 255,   0)),
    "clip_studio": ((  0,   0, 255), (  0,   0, 255)),
    "aseprite":    ((180,   0, 255), (180,   0, 255)),
    "blender":     ((  0, 220, 255), (  0, 220, 255)),
}

def load_colors():
    colors = {}
    try:
        for raw in CONFIG_FILE.read_text(encoding="utf-8-sig").splitlines():
            parts = raw.split("\t")
            if parts[0] != "@map" or len(parts) not in (5, 8):
                continue
            try:
                top_rgb = tuple(int(x) for x in parts[2:5])
                bottom_rgb = tuple(int(x) for x in parts[5:8]) if len(parts) == 8 else top_rgb
            except ValueError:
                continue
            if (parts[1] and all(0 <= x <= 255 for x in top_rgb)
                    and all(0 <= x <= 255 for x in bottom_rgb)):
                colors[parts[1]] = (top_rgb, bottom_rgb)
    except Exception as e:
        log(f"COLOR CONFIG ERROR: {e!r}")
    return colors or dict(DEFAULT_COLORS)

def load_indicators():
    indicators = {}
    try:
        for raw in CONFIG_FILE.read_text(encoding="utf-8-sig").splitlines():
            parts = raw.split("\t")
            if len(parts) != 6 or parts[0] != "@indicator":
                continue
            name, layer = parts[1], parts[2]
            bits = parts[3:6]
            if name and layer in ("N", "H") and all(x in ("0", "1") for x in bits):
                indicators[(name, layer)] = tuple(x == "1" for x in bits)
    except Exception as e:
        log(f"INDICATOR CONFIG ERROR: {e!r}")
    return indicators


def log(msg):
    global _last_rotate_check
    try:
        now = time.monotonic()
        if now - _last_rotate_check >= 10.0:
            _last_rotate_check = now
            if LOG_FILE.exists() and LOG_FILE.stat().st_size > MAX_LOG_BYTES:
                old = LOG_FILE.with_suffix(LOG_FILE.suffix + ".1")
                try:
                    old.unlink()
                except FileNotFoundError:
                    pass
                LOG_FILE.replace(old)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass

try:
    import hid
except Exception as e:
    log(f"IMPORT ERROR hid: {e!r}")
    sys.exit(2)

def build_razer_cmd(txn, cls, cmd, args, data_size=None):
    # 91-byte Razer feature report including leading report-ID 0.
    b = bytearray(91)
    b[2] = txn
    b[6] = len(args) if data_size is None else data_size
    b[7] = cls
    b[8] = cmd
    b[9:9 + len(args)] = bytes(args)

    crc = 0
    for x in b[3:89]:
        crc ^= x
    b[89] = crc
    return bytes(b)

def open_control():
    rows = hid.enumerate(VID, PID)
    preferred = [
        d for d in rows
        if d.get("usage_page") == 0x0001 and d.get("usage") == 0x0002
    ]
    preferred.sort(key=lambda d: 0 if d.get("interface_number") == 2 else 1)

    last = None
    for d in preferred:
        h = hid.device()
        try:
            h.open_path(d["path"])
            log(f"OPEN if={d.get('interface_number')} usage=0x{(d.get('usage') or 0):04X}")
            return h
        except Exception as e:
            last = e
            try:
                h.close()
            except Exception:
                pass

    raise RuntimeError(f"control interface open failed: {last!r}")

def send_report(h, data, label):
    n = h.send_feature_report(data)
    log(f"{label}: {n}")
    return n

def enable_streaming_mode(h):
    # Same mode-3 command Synapse sends before Interface 1 starts emitting
    # report-id 0x06. The LED daemon already owns Interface 2, so sending it
    # here also makes analog recovery robust if the analog daemon restarts
    # while this control handle is open.
    args = [0x03, 0x00]
    data = build_razer_cmd(0x01, 0x00, 0x04, args)
    send_report(h, data, "STREAM MODE 3")


def enable_custom_mode(h):
    # Extended-matrix CUSTOM effect.
    # class 0x0F / cmd 0x02 / effect 0x08
    # 12-byte payload used by Razer's extended custom-frame command.
    args = [0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    data = build_razer_cmd(0x1F, 0x0F, 0x02, args)
    send_report(h, data, "CUSTOM MODE")


def set_keymap_indicator(h, lamps):
    # Captured directly from Synapse on a real Tartarus Pro (VID:PID 1532:0244).
    # The three physical indicator lamps are controlled through LED ID 0x0B.
    # Synapse sends Extended Matrix STATIC:
    #   class 0x0F / cmd 0x02
    #   args: 01 0B 01 00 01 01 RR GG BB
    # Treat RR/GG/BB as the ON/OFF channels of the red/green/blue indicator lamps.
    red, green, blue = (bool(x) for x in lamps)
    rgb = (0xFF if red else 0x00, 0xFF if green else 0x00, 0xFF if blue else 0x00)
    args = [0x01, 0x0B, 0x01, 0x00, 0x01, 0x01, *rgb]
    data = build_razer_cmd(0x1F, 0x0F, 0x02, args)
    send_report(
        h, data,
        f"KEYMAP INDICATOR R={int(red)} G={int(green)} B={int(blue)}"
    )

def set_split_custom_frame(h, top_rgb, bottom_rgb):
    # Tartarus Pro exposes its main lighting as a 1x21 matrix.
    # Custom-frame command:
    #   class 0x0F / cmd 0x03
    #   arguments[2] = row
    #   arguments[3] = start column
    #   arguments[4] = stop column (inclusive)
    #   arguments[5..] = RGB triplets
    #
    # OpenRazer uses data_size 0x47 for this command even though the actual
    # populated payload is shorter; the remaining report bytes stay zero.
    args = [0x00, 0x00, 0x00, 0x00, 0x14]  # row 0, cols 0..20
    # Tartarus Pro reports 21 lighting columns in physical key order.
    # Keys 01..10 are the upper half; keys 11..20 plus the final segment are
    # the lower half.
    for index in range(21):
        r, g, b = top_rgb if index < 10 else bottom_rgb
        args.extend([r, g, b])

    data = build_razer_cmd(0x1F, 0x0F, 0x03, args, data_size=0x47)
    send_report(
        h, data,
        "FRAME TOP #{:02X}{:02X}{:02X} BOTTOM #{:02X}{:02X}{:02X}".format(
            *top_rgb, *bottom_rgb
        ),
    )

def restore_spectrum(h):
    args = [0x01, 0x05, 0x03, 0x00, 0x00, 0x00]
    data = build_razer_cmd(0x1F, 0x0F, 0x02, args)
    send_report(h, data, "SPECTRUM")

def fallback_static(h, rgb):
    # If custom-frame is rejected on a particular firmware, fall back to
    # the already-tested static command.
    r, g, b = rgb
    args = [0x01, 0x05, 0x01, 0x00, 0x00, 0x01, r, g, b]
    data = build_razer_cmd(0x1F, 0x0F, 0x02, args)
    send_report(h, data, f"STATIC-FALLBACK #{r:02X}{g:02X}{b:02X}")

def read_state():
    try:
        text = STATE_FILE.read_text(encoding="utf-8-sig").strip()
    except Exception:
        return "", "N"
    parts = text.split("\t")
    name = parts[0].strip() if parts else ""
    layer = parts[1].strip() if len(parts) >= 2 and parts[1].strip() in ("N", "H") else "N"
    return name, layer

def apply_colors(h, top_rgb, bottom_rgb):
    # Instant path: upload a full custom RGB frame. No firmware fade.
    try:
        set_split_custom_frame(h, top_rgb, bottom_rgb)
        return
    except Exception as e:
        log(f"CUSTOM FRAME ERROR: {e!r}")
        fallback_static(h, top_rgb)


def acquire_single_instance():
    if os.name != "nt":
        return object()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = kernel32.CreateMutexW(None, False, 'Local\\TartarusLedDaemon')
    if not handle:
        return None
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        kernel32.CloseHandle(handle)
        return None
    return handle

def main():
    LOG_FILE.write_text("", encoding="utf-8")
    instance_mutex = acquire_single_instance()
    if instance_mutex is None:
        log("Second daemon instance refused; existing instance is still active")
        return 0

    log("LED daemon v10.1.5 AUDIT FIX1 start")

    h = open_control()
    colors = load_colors()
    indicators = load_indicators()
    last_state_mtime = None
    last_config_mtime = None

    try:
        # Own both control-channel responsibilities from this persistent handle:
        # keep analog streaming unlocked, then put lighting in custom mode.
        enable_streaming_mode(h)
        enable_custom_mode(h)

        while True:
            try:
                state_mtime = STATE_FILE.stat().st_mtime_ns
            except FileNotFoundError:
                state_mtime = None
            try:
                config_mtime = CONFIG_FILE.stat().st_mtime_ns
            except FileNotFoundError:
                config_mtime = None

            state_changed = state_mtime != last_state_mtime
            config_changed = config_mtime != last_config_mtime

            if config_changed:
                last_config_mtime = config_mtime
                colors = load_colors()
                indicators = load_indicators()
                log(f"CONFIG loaded colors={len(colors)} indicators={len(indicators)}")

            if state_changed:
                last_state_mtime = state_mtime

            if state_changed or config_changed:
                state_map, state_layer = read_state()
                if state_map == "__EXIT__":
                    log("EXIT requested")
                    restore_spectrum(h)
                    break

                # Re-apply on either a map/layer switch, manual resync, or config edit.
                if state_map in colors:
                    try:
                        top_rgb, bottom_rgb = colors[state_map]
                        lamps = indicators.get((state_map, state_layer), (False, False, False))
                        apply_colors(h, top_rgb, bottom_rgb)
                        set_keymap_indicator(h, lamps)
                        log(
                            "MAP {} LAYER {} TOP #{:02X}{:02X}{:02X} BOTTOM #{:02X}{:02X}{:02X} IND={}{}{}".format(
                                state_map, state_layer, *top_rgb, *bottom_rgb,
                                int(lamps[0]), int(lamps[1]), int(lamps[2])
                            )
                        )
                    except Exception as e:
                        log(f"SEND ERROR: {e!r}; reopening")
                        try:
                            h.close()
                        except Exception:
                            pass
                        time.sleep(0.05)
                        h = open_control()
                        enable_streaming_mode(h)
                        enable_custom_mode(h)
                        top_rgb, bottom_rgb = colors[state_map]
                        lamps = indicators.get((state_map, state_layer), (False, False, False))
                        apply_colors(h, top_rgb, bottom_rgb)
                        set_keymap_indicator(h, lamps)

            # 10 ms polling: map-color changes feel immediate.
            time.sleep(0.01)

    finally:
        try:
            h.close()
        except Exception:
            pass
        log("LED daemon v10.1.5 AUDIT FIX1 stop")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"FATAL: {e!r}")
        raise
