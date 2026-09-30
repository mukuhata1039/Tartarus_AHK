import importlib.util
import json
import py_compile
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FAIL = []
WARN = []
OK = []


def ok(msg):
    OK.append(msg)


def fail(msg):
    FAIL.append(msg)


def warn(msg):
    WARN.append(msg)


def load_settings_module():
    path = ROOT / "Tartarus_Settings_Server.py"
    spec = importlib.util.spec_from_file_location("tartarus_settings_selftest", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_python_syntax():
    for name in ("Tartarus_Settings_Server.py", "Tartarus_LED_Daemon.py", "Tartarus_Analog_Daemon.py"):
        try:
            py_compile.compile(str(ROOT / name), doraise=True)
            ok(f"Python syntax: {name}")
        except Exception as e:
            fail(f"Python syntax: {name}: {e}")


def test_config():
    mod = load_settings_module()
    maps, mappings = mod.parse_config(mod.CONFIG)
    names = [x["name"] for x in maps]
    if not names:
        fail("No Keymap definitions")
        return
    ok(f"Keymaps: {', '.join(names)}")

    bad = [(k, a) for k, a in mappings.items() if not mod.valid_action(a, names)]
    if bad:
        fail(f"Invalid mappings: {bad[:5]}")
    else:
        ok(f"Mappings valid: {len(mappings)} entries")

    current = mod.current_map(names)
    if current:
        ok(f"Current map is valid: {current}")
    else:
        warn("Current map file is empty or refers to a missing Keymap")

    # Raw duplicate detection. Silent duplicates are dangerous because the last
    # line wins and the UI can hide the earlier one.
    seen_maps = set()
    seen_ids = set()
    for no, raw in enumerate(mod.CONFIG.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if parts[0] == "@map" and len(parts) in (5, 8):
            name = parts[1].casefold()
            if name in seen_maps:
                fail(f"Duplicate Keymap definition at line {no}: {parts[1]}")
            seen_maps.add(name)
        elif len(parts) == 4 and not parts[0].startswith("@"):
            key = tuple(parts[:3])
            if key in seen_ids:
                fail(f"Duplicate mapping at line {no}: {' / '.join(key)}")
            seen_ids.add(key)

    cfg = json.loads((ROOT / "Tartarus_Analog_Config.json").read_text(encoding="utf-8-sig"))
    keys = cfg.get("keys", {})
    if len(keys) != 20:
        fail(f"Analog config must contain 20 keys, found {len(keys)}")
    for i in range(1, 21):
        k = f"{i:02d}"
        v = keys.get(k)
        if not isinstance(v, dict):
            fail(f"Analog config missing key {k}")
            continue
        ton, toff = v.get("t_on"), v.get("t_off")
        if not isinstance(ton, int) or not isinstance(toff, int) or not (1 <= ton <= 255 and 0 <= toff < ton):
            fail(f"Invalid analog thresholds {k}: {v}")
    if not any(x.startswith("Invalid analog") for x in FAIL):
        ok("Analog thresholds valid")


def test_ahk_guards():
    src = (ROOT / "Tartarus_Main.ahk").read_text(encoding="utf-8-sig")
    hotkeys = []
    for no, line in enumerate(src.splitlines(), 1):
        stripped = line.strip()
        if not stripped.startswith(";") and "::" in stripped:
            hotkeys.append((no, stripped))
    if hotkeys:
        fail(f"Global AHK hotkeys can self-trigger from Tartarus output: {hotkeys}")
    else:
        ok("No global AHK hotkeys")

    required = {
        "modifier repeat guard": src.count("if IsModifierKey(mainKey)") >= 2,
        "multi-HyperShift tracking": "global HyperTokens := Map()" in src and "SetHyperToken(token" in src,
        "mouse output refcount": "global MouseOutputCounts := Map()" in src,
        "analog remap recovery": "CloseAnalogMapping()" in src and "AnalogMapOpenedTick" in src,
        "hot-path logging disabled by default": "ENABLE_VERBOSE_LOGGING.txt" in src,
        "SOCD last-input-wins core": "SocdDirectionDown(token, key)" in src and "SocdReconcilePair(key)" in src,
        "SOCD limited to WASD cluster": '"08", "w"' in src and '"12", "a"' in src and '"13", "s"' in src and '"14", "d"' in src,
        "SOCD analog token transfer": "SocdHeldTokens[newToken]" in src,
        "SOCD winner keeps typematic": "SocdSyncRepeatForPair(key, other, winnerToken)" in src and "StartSoftwareRepeat(token)" in src,
        "SOCD loser repeat stops": "StopSoftwareRepeat(token)" in src and "winnerToken" in src,
    }
    for label, present in required.items():
        (ok if present else fail)(label)


def test_daemon_guards():
    analog = (ROOT / "Tartarus_Analog_Daemon.py").read_text(encoding="utf-8")
    led = (ROOT / "Tartarus_LED_Daemon.py").read_text(encoding="utf-8")
    checks = {
        "analog single-instance mutex": "TartarusAnalogDaemon" in analog,
        "LED single-instance mutex": "TartarusLedDaemon" in led,
        "analog drops unreadable collections": "DROPPED unreadable collection" in analog,
        "analog log cap": "MAX_LOG_BYTES" in analog,
        "LED log cap": "MAX_LOG_BYTES" in led,
        "LED can restore streaming mode": "enable_streaming_mode(h)" in led,
    }
    for label, present in checks.items():
        (ok if present else fail)(label)



def test_startup_guards():
    setup = (ROOT / "SETUP_PORTABLE.ps1").read_text(encoding="utf-8-sig")
    runtime = (ROOT / "Tartarus_Runtime.ps1").read_text(encoding="utf-8-sig")
    auto_ps1 = ROOT / "Tartarus_Autostart.ps1"
    auto_vbs = ROOT / "Tartarus_Autostart.vbs"
    register_bat = ROOT / "REGISTER_AUTOSTART.bat"
    checks = {
        "delayed autostart launcher present": auto_ps1.exists() and auto_vbs.exists(),
        "setup registers delayed launcher": "Tartarus_Autostart.vbs" in setup and "$AutostartVbs" in setup,
        "runtime retries mapper during logon race": "Start-MapperWithRetry" in runtime,
        "one-click autostart repair present": register_bat.exists(),
    }
    for label, present in checks.items():
        (ok if present else fail)(label)


def test_log_sizes():
    logdir = ROOT / "Logs"
    for path in logdir.glob("*"):
        if path.is_file() and path.stat().st_size > 10 * 1024 * 1024:
            warn(f"Large log file: {path.name} = {path.stat().st_size / (1024*1024):.1f} MiB")


def main():
    test_python_syntax()
    test_config()
    test_ahk_guards()
    test_daemon_guards()
    test_startup_guards()
    test_log_sizes()

    print("============================================================")
    print(" Tartarus SOCD + STARTUP self-test")
    print("============================================================")
    for x in OK:
        print("[OK]  " + x)
    for x in WARN:
        print("[WARN] " + x)
    for x in FAIL:
        print("[FAIL] " + x)
    print("------------------------------------------------------------")
    print(f"OK={len(OK)} WARN={len(WARN)} FAIL={len(FAIL)}")
    if FAIL:
        return 1
    print("Static/config checks passed. Real hardware input still requires an on-device test.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
