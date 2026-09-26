import ctypes
import os
import json
import mmap
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CFG = ROOT / "Tartarus_Analog_Config.json"
LOG = ROOT / "Logs" / "Tartarus_Analog_Debug.log"
LOG.parent.mkdir(exist_ok=True)

MMAP_NAME = r"Local\TartarusAnalogState"
MMAP_SIZE = 64
VID, PID = 0x1532, 0x0244
DEFAULT_ON = 106
DEFAULT_OFF = 86
ANALOG_REPORT_ID = 0x06
NUM_KEYS = 20
MAX_LOG_BYTES = 2 * 1024 * 1024

# Shared-memory layout (64 bytes)
#   [0]      magic: 0xA7 only after a real report-id 0x06 has been received
#   [1]      sequence: increments for each valid analog report
#   [2:22]   raw depths for keys 01..20
#   [22:42]  thresholded key states for keys 01..20
#   [42]     daemon heartbeat while the selected HID path is still present
#   [43]     opened Interface-1 collection count (diagnostic)

_last_log = {}
_last_rotate_check = 0.0


def _rotate_log_if_needed():
    global _last_rotate_check
    now = time.monotonic()
    if now - _last_rotate_check < 10.0:
        return
    _last_rotate_check = now
    try:
        if LOG.exists() and LOG.stat().st_size > MAX_LOG_BYTES:
            old = LOG.with_suffix(LOG.suffix + ".1")
            try:
                old.unlink()
            except FileNotFoundError:
                pass
            LOG.replace(old)
    except Exception:
        pass


def log(msg):
    try:
        _rotate_log_if_needed()
        with LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass


def log_limited(key, msg, interval=5.0):
    now = time.monotonic()
    if now - _last_log.get(key, -1e9) < interval:
        return
    _last_log[key] = now
    log(msg)


def load_cfg():
    out = {
        "enabled": True,
        "keys": {
            f"{i:02d}": {"t_on": DEFAULT_ON, "t_off": DEFAULT_OFF}
            for i in range(1, NUM_KEYS + 1)
        },
    }
    try:
        if CFG.exists():
            raw = json.loads(CFG.read_text(encoding="utf-8-sig"))
            out["enabled"] = bool(raw.get("enabled", True))
            keys = raw.get("keys", {})
            if isinstance(keys, dict):
                for k in out["keys"]:
                    v = keys.get(k, {})
                    try:
                        ton = int(v.get("t_on", DEFAULT_ON))
                        toff = int(v.get("t_off", DEFAULT_OFF))
                    except Exception:
                        continue
                    ton = max(1, min(255, ton))
                    toff = max(0, min(254, toff))
                    if toff >= ton:
                        toff = max(0, ton - 20)
                    out["keys"][k] = {"t_on": ton, "t_off": toff}
    except Exception as e:
        log("CONFIG ERROR " + repr(e))
    return out


def build_razer_cmd(txn, cls, cmd, args):
    b = bytearray(91)
    b[2] = txn
    b[6] = len(args)
    b[7] = cls
    b[8] = cmd
    b[9 : 9 + len(args)] = bytes(args)
    crc = 0
    for x in b[3:89]:
        crc ^= x
    b[89] = crc
    return bytes(b)


def enumerate_paths(hid, verbose=False):
    items = hid.enumerate(VID, PID)
    analog = []
    controls = []
    for x in items:
        iface = x.get("interface_number")
        usage_page = x.get("usage_page")
        usage = x.get("usage")
        path = x.get("path")
        if verbose:
            log(
                "ENUM "
                f"iface={iface} usage_page={usage_page!r} usage={usage!r} path={path!r}"
            )
        if not path:
            continue

        if iface == 1:
            # This top-level collection is Windows' keyboard collection on the
            # user's Tartarus and ReadFile fails continuously. It never carries
            # report-id 0x06, so do not put it in the hot polling loop.
            if usage_page == 0x0001 and usage == 0x0006:
                continue
            analog.append(path)

        if iface == 2:
            score = 0 if (usage_page == 0x0001 and usage == 0x0002) else 1
            controls.append((score, path))

    analog = list(dict.fromkeys(analog))
    controls.sort(key=lambda z: z[0])
    controls = list(dict.fromkeys(path for _, path in controls))
    return analog, controls


def open_analog_devices(hid, paths):
    devices = []
    for path in paths:
        d = hid.device()
        try:
            d.open_path(path)
            d.set_nonblocking(1)
            devices.append({"path": path, "dev": d, "errors": 0})
            log(f"ANALOG collection OPEN path={path!r}")
        except Exception as e:
            log_limited(
                ("open", repr(path)),
                f"ANALOG collection OPEN FAILED path={path!r} error={e!r}",
            )
            try:
                d.close()
            except Exception:
                pass
    return devices


def close_devices(devices, except_dev=None):
    for item in devices:
        d = item["dev"]
        if d is except_dev:
            continue
        try:
            d.close()
        except Exception:
            pass


def send_streaming_unlock(hid, control_paths):
    cmd = build_razer_cmd(0x01, 0x00, 0x04, [0x03, 0x00])
    last = None
    for path in control_paths:
        d = hid.device()
        try:
            d.open_path(path)
            n = d.send_feature_report(cmd)
            log(f"STREAM enable sent bytes={n} path={path!r}")
            return True
        except Exception as e:
            last = e
            log_limited(
                ("ctrl", repr(path)),
                f"CONTROL OPEN/SEND FAILED path={path!r} error={e!r}",
            )
        finally:
            try:
                d.close()
            except Exception:
                pass
    log_limited("unlock_failed", f"STREAM enable unavailable: {last!r}", 2.0)
    return False


def normalize_report(data):
    if not data:
        return None
    b = list(data)
    if len(b) >= 1 + NUM_KEYS and b[0] == ANALOG_REPORT_ID:
        return b[1 : 1 + NUM_KEYS]
    return None


def clear_state(mm):
    mm[0] = 0
    mm[1] = 0
    mm[2:42] = bytes(40)
    mm[42] = 0
    mm[43] = 0


def selected_path_still_present(hid, path):
    try:
        analog_paths, _ = enumerate_paths(hid, verbose=False)
        return path in analog_paths
    except Exception:
        # Enumeration failing transiently is not proof of disconnect.
        return True


def run_connected_session(hid, mm, cfg, cfg_mtime, analog_paths, control_paths):
    devices = open_analog_devices(hid, analog_paths)
    if not devices:
        clear_state(mm)
        return cfg, cfg_mtime, False

    mm[43] = min(255, len(devices))

    try:
        # Best effort. If the LED daemon already owns Interface 2, it now sends
        # the exact same mode-3 unlock itself; therefore a busy control handle
        # is no longer a reason to discard a perfectly readable analog path.
        send_streaming_unlock(hid, control_paths)

        pressed = [False] * NUM_KEYS
        selected = None
        got_valid_report = False
        started = time.monotonic()
        last_presence_check = started
        last_heartbeat = started

        while True:
            try:
                mt = CFG.stat().st_mtime_ns if CFG.exists() else 0
                if mt != cfg_mtime:
                    cfg = load_cfg()
                    cfg_mtime = mt
                    if not cfg.get("enabled", True):
                        clear_state(mm)
                        return cfg, cfg_mtime, True
            except Exception:
                pass

            found_report = False
            survivors = []
            for item in devices:
                path, d = item["path"], item["dev"]
                try:
                    data = d.read(64)
                    item["errors"] = 0
                except Exception as e:
                    item["errors"] += 1
                    log_limited(
                        ("read", repr(path)),
                        f"READ ERROR path={path!r} count={item['errors']} error={e!r}",
                        5.0,
                    )
                    if item["errors"] >= 3:
                        try:
                            d.close()
                        except Exception:
                            pass
                        log(f"DROPPED unreadable collection path={path!r}")
                        continue
                    survivors.append(item)
                    continue

                vals = normalize_report(data)
                if vals is not None:
                    found_report = True
                    if selected is None:
                        selected = item
                        got_valid_report = True
                        mm[0] = 0xA7
                        log(
                            "ANALOG ONLINE: selected report-id 0x06 path="
                            f"{path!r}, initially_opened={len(devices)}"
                        )

                        # Report ID 0x06 belongs to one top-level collection.
                        # Once identified, stop polling every other collection.
                        close_devices(devices, except_dev=d)
                        survivors = [item]

                    if selected is item:
                        for i, v in enumerate(vals):
                            th = cfg["keys"][f"{i + 1:02d}"]
                            if not pressed[i] and v >= th["t_on"]:
                                pressed[i] = True
                            elif pressed[i] and v <= th["t_off"]:
                                pressed[i] = False

                        mm[2:22] = bytes(vals)
                        mm[22:42] = bytes(1 if x else 0 for x in pressed)
                        mm[1] = (mm[1] + 1) & 0xFF
                        mm[0] = 0xA7
                survivors.append(item)

                if selected is item:
                    # No other device needs polling once the correct report is found.
                    break

            # De-duplicate in case selected was appended before/after selection.
            dedup = []
            seen = set()
            for item in survivors:
                ident = id(item["dev"])
                if ident not in seen:
                    seen.add(ident)
                    dedup.append(item)
            devices = dedup

            if selected is not None:
                devices = [selected] if selected in devices else []

            if not devices:
                raise RuntimeError("all Interface-1 collections became unreadable")

            now = time.monotonic()
            if selected is None:
                # Without a real report, stay OFFLINE so AHK uses digital fallback.
                mm[0] = 0
                if now - started > 3.0:
                    raise RuntimeError("no report-id 0x06 after unlock")
            else:
                if now - last_presence_check >= 1.0:
                    last_presence_check = now
                    if not selected_path_still_present(hid, selected["path"]):
                        raise RuntimeError("selected analog HID path disappeared")

                if now - last_heartbeat >= 0.05:
                    mm[42] = (mm[42] + 1) & 0xFF
                    last_heartbeat = now

            if not found_report:
                time.sleep(0.001)

    finally:
        close_devices(devices)



def acquire_single_instance():
    if os.name != "nt":
        return object()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = kernel32.CreateMutexW(None, False, 'Local\\TartarusAnalogDaemon')
    if not handle:
        return None
    if ctypes.get_last_error() == 183:  # ERROR_ALREADY_EXISTS
        kernel32.CloseHandle(handle)
        return None
    return handle

def main():
    try:
        import hid
    except Exception as e:
        log("FATAL: Python package hidapi missing: " + repr(e))
        return 2

    try:
        LOG.write_text("", encoding="utf-8")
    except Exception:
        pass
    instance_mutex = acquire_single_instance()
    if instance_mutex is None:
        log("Second daemon instance refused; existing instance is still active")
        return 0

    log("Analog daemon AUDIT FIX1 start")

    mm = mmap.mmap(-1, MMAP_SIZE, tagname=MMAP_NAME, access=mmap.ACCESS_WRITE)
    clear_state(mm)

    cfg = load_cfg()
    cfg_mtime = CFG.stat().st_mtime_ns if CFG.exists() else 0
    first_enum = True

    while True:
        if not cfg.get("enabled", True):
            clear_state(mm)
            time.sleep(0.25)
            try:
                mt = CFG.stat().st_mtime_ns if CFG.exists() else 0
                if mt != cfg_mtime:
                    cfg = load_cfg()
                    cfg_mtime = mt
            except Exception:
                pass
            continue

        try:
            analog_paths, control_paths = enumerate_paths(hid, verbose=first_enum)
            first_enum = False
            if not analog_paths:
                clear_state(mm)
                log_limited("no_analog", "Interface-1 analog HID path not found; retrying", 5.0)
                time.sleep(1.0)
                continue

            cfg, cfg_mtime, disabled = run_connected_session(
                hid, mm, cfg, cfg_mtime, analog_paths, control_paths
            )
            if disabled:
                continue
        except Exception as e:
            clear_state(mm)
            log_limited(
                "session_error",
                "HID SESSION RESET " + repr(e) + "\n" + traceback.format_exc(limit=3),
                2.0,
            )
            time.sleep(0.5)


if __name__ == "__main__":
    raise SystemExit(main())
