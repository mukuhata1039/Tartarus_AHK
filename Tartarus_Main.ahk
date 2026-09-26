#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
#Include Lib\AutoHotInterception.ahk

; ============================================================
; Tartarus Pro replacement mapper - v10.1.5 AUDIT FIX1
;
; v5:
; 1) Keeps v4 input behavior unchanged.
; 2) Adds keymap-dependent Tartarus main backlight colors through a tiny
;    background HID helper (Python).
; 3) Restores Spectrum lighting when the mapper exits normally.
; ============================================================

global AHI := AutoHotInterception()

global Kbd1 := AHI.GetKeyboardId(0x1532, 0x0244, 1)
global Kbd2 := AHI.GetKeyboardId(0x1532, 0x0244, 2)
global TartarusMouse := AHI.GetMouseId(0x1532, 0x0244, 1)

global OutputKeyboard := FindOutputKeyboard()
global OutputMouse := FindOutputMouse()

if (!OutputKeyboard) {
    MsgBox("Tartarus以外の出力用キーボードを取得できませんでした。")
    ExitApp()
}

global CurrentMap := "clip_studio"
global HyperShift := false

global Mappings := Map()
global MapOrder := []
global MapColors := Map()
global RuntimeReady := false
global AnalogMapHandle := 0
global AnalogView := 0
global AnalogOnline := false
global AnalogPrev := Map()
global AnalogHeartbeat := -1
global AnalogHeartbeatTick := 0
global AnalogMapOpenedTick := 0
global Pressed := Map()
global ActiveActions := Map()
global OutputCounts := Map()
global MouseOutputCounts := Map()
global HyperTokens := Map()

global DpadGeneration := Map()
global ThumbGeneration := Map()

; Software typematic timers, indexed by physical token (device:scan-code)
global RepeatTimers := Map()
global RepeatDelayMs := 500
global RepeatIntervalMs := 31

global LogDir := A_ScriptDir "\\Logs"
DirCreate(LogDir)
global DebugFile := LogDir "\\Tartarus_AHK_Debug.log"
global LedStateFile := A_ScriptDir "\\Tartarus_LED_State.txt"
global ConfigFile := A_ScriptDir "\\Tartarus_Config.tsv"
global ConfigBackupFile := A_ScriptDir "\\Tartarus_Config.backup.tsv"
global CommandFile := A_ScriptDir "\\Tartarus_Command.txt"
global CurrentMapFile := A_ScriptDir "\\Tartarus_CurrentMap.txt"
global VerboseLogFlag := A_ScriptDir "\\ENABLE_VERBOSE_LOGGING.txt"
global VerboseLogging := FileExist(VerboseLogFlag)
try FileDelete(DebugFile)
Log("START v10.1.5 AUDIT FIX1  Kbd1=" Kbd1 " Kbd2=" Kbd2 " TartarusMouse=" TartarusMouse " OutputKeyboard=" OutputKeyboard " OutputMouse=" OutputMouse)

LoadMappingsFromConfig()
RestoreCurrentMapFromFile()

AHI.SubscribeKeyboard(Kbd1, true, OnKeyboard.Bind(Kbd1))
AHI.SubscribeKeyboard(Kbd2, true, OnKeyboard.Bind(Kbd2))
AHI.SubscribeMouseButtons(TartarusMouse, true, OnMouse.Bind(TartarusMouse))

OnExit(Cleanup)
UpdateTray()
ShowMapStatus()
SendLedState(CurrentMap)
WriteCurrentMap()
RuntimeReady := true
SetTimer(ReloadMappingsIfChanged, 300)
SetTimer(CheckRuntimeCommand, 300)
SetTimer(PollAnalogState, 5)

FindOutputKeyboard() {
    global AHI, Kbd1, Kbd2
    devices := AHI.GetDeviceList()

    for id, dev in devices {
        if dev.IsMouse
            continue
        if (id = Kbd1 || id = Kbd2)
            continue
        return id
    }
    return 0
}

FindOutputMouse() {
    global AHI, TartarusMouse
    devices := AHI.GetDeviceList()

    for id, dev in devices {
        if !dev.IsMouse
            continue
        if (id = TartarusMouse)
            continue
        return id
    }
    return 0
}

OnKeyboard(source, code, state) {
    phys := PhysicalFromScanCode(code)
    Log("RAW K id=" source " code=" code " state=" state " phys=" phys)

    if (phys = "")
        return

    ; When the analog HID helper is alive, keys 01-20 are driven by raw depth
    ; instead of Tartarus' built-in digital threshold. Keep D-pad/thumb on AHI.
    if (AnalogOnline && IsAnalogPhys(phys))
        return

    token := source . ":" . code

    if (phys = "ALTBTN") {
        HandleThumb(token, phys, state)
        return
    }

    if IsDpad(phys) {
        HandleDpad(token, phys, state)
        return
    }

    HandlePhysical(token, phys, state)
}


IsAnalogPhys(phys) {
    if (StrLen(phys) != 2)
        return false
    n := phys + 0
    return n >= 1 && n <= 20
}

PollAnalogState() {
    global AnalogMapHandle, AnalogView, AnalogOnline, AnalogPrev, AnalogHeartbeat, AnalogHeartbeatTick, AnalogMapOpenedTick

    if (!AnalogView) {
        h := DllCall("OpenFileMappingW", "UInt", 0x0004, "Int", 0, "WStr", "Local\TartarusAnalogState", "Ptr")
        if (!h) {
            SetAnalogOffline()
            return
        }
        view := DllCall("MapViewOfFile", "Ptr", h, "UInt", 0x0004, "UInt", 0, "UInt", 0, "UPtr", 64, "Ptr")
        if (!view) {
            DllCall("CloseHandle", "Ptr", h)
            SetAnalogOffline()
            return
        }
        AnalogMapHandle := h
        AnalogView := view
        AnalogMapOpenedTick := A_TickCount
    }

    magic := NumGet(AnalogView, 0, "UChar")
    if (magic != 0xA7) {
        if AnalogOnline {
            SetAnalogOffline(true)
        } else if (AnalogMapOpenedTick && A_TickCount - AnalogMapOpenedTick > 250) {
            ; If the daemon restarted, our old named-mapping handle would keep
            ; the old object alive forever. Drop it periodically while offline
            ; so the next poll can attach to the daemon's new mapping object.
            CloseAnalogMapping()
        }
        return
    }

    hb := NumGet(AnalogView, 42, "UChar")
    if (hb != AnalogHeartbeat) {
        AnalogHeartbeat := hb
        AnalogHeartbeatTick := A_TickCount
    } else if (AnalogHeartbeatTick && A_TickCount - AnalogHeartbeatTick > 600) {
        SetAnalogOffline(true)
        return
    }

    if (!AnalogOnline) {
        SynchronizeAnalogTakeover()
        Log("ANALOG ONLINE")
    }
    AnalogOnline := true
    Loop 20 {
        idx := A_Index
        phys := Format("{:02}", idx)
        down := NumGet(AnalogView, 21 + idx, "UChar") != 0
        prev := AnalogPrev.Has(phys) ? AnalogPrev[phys] : false
        if (down != prev) {
            AnalogPrev[phys] := down
            HandlePhysical("AN:" . phys, phys, down ? 1 : 0)
        }
    }
}


TransferPressedToken(oldToken, newToken, phys) {
    global Pressed, ActiveActions, RepeatTimers, HyperTokens

    if (oldToken = newToken || !Pressed.Has(oldToken))
        return

    action := ActiveActions.Has(oldToken) ? ActiveActions[oldToken] : ""
    hadRepeat := RepeatTimers.Has(oldToken)
    if hadRepeat
        StopSoftwareRepeat(oldToken)

    Pressed.Delete(oldToken)
    Pressed[newToken] := phys

    if ActiveActions.Has(oldToken)
        ActiveActions.Delete(oldToken)
    ActiveActions[newToken] := action

    if HyperTokens.Has(oldToken) {
        HyperTokens.Delete(oldToken)
        HyperTokens[newToken] := true
    }

    if hadRepeat
        StartSoftwareRepeat(newToken)
}

SynchronizeAnalogTakeover() {
    global AnalogView, AnalogPrev, Pressed

    ; Switch token ownership from AHI's digital source to the analog source
    ; WITHOUT re-firing the action. This matters for held shortcuts, MAP keys,
    ; media actions and HyperShift when the analog daemon reconnects mid-hold.
    Loop 20 {
        idx := A_Index
        phys := Format("{:02}", idx)
        analogToken := "AN:" . phys
        down := NumGet(AnalogView, 21 + idx, "UChar") != 0
        digitalTokens := []

        for token, heldPhys in Pressed {
            if (heldPhys = phys && SubStr(token, 1, 3) != "AN:")
                digitalTokens.Push(token)
        }

        if down {
            if !Pressed.Has(analogToken) {
                if (digitalTokens.Length > 0) {
                    TransferPressedToken(digitalTokens[1], analogToken, phys)
                    if (digitalTokens.Length > 1) {
                        Loop digitalTokens.Length - 1
                            HandlePhysical(digitalTokens[A_Index + 1], phys, 0)
                    }
                } else {
                    HandlePhysical(analogToken, phys, 1)
                }
            } else {
                for token in digitalTokens
                    HandlePhysical(token, phys, 0)
            }
            AnalogPrev[phys] := true
        } else {
            for token in digitalTokens
                HandlePhysical(token, phys, 0)
            if Pressed.Has(analogToken)
                HandlePhysical(analogToken, phys, 0)
            AnalogPrev[phys] := false
        }
    }
}

CloseAnalogMapping() {
    global AnalogView, AnalogMapHandle, AnalogHeartbeat, AnalogHeartbeatTick, AnalogMapOpenedTick

    try {
        if AnalogView
            DllCall("UnmapViewOfFile", "Ptr", AnalogView)
    }
    try {
        if AnalogMapHandle
            DllCall("CloseHandle", "Ptr", AnalogMapHandle)
    }

    AnalogView := 0
    AnalogMapHandle := 0
    AnalogHeartbeat := -1
    AnalogHeartbeatTick := 0
    AnalogMapOpenedTick := 0
}

SetAnalogOffline(closeMapping := false) {
    global AnalogOnline, AnalogPrev

    wasOnline := AnalogOnline
    AnalogOnline := false

    for phys, wasDown in AnalogPrev {
        if (wasDown)
            HandlePhysical("AN:" . phys, phys, 0)
        AnalogPrev[phys] := false
    }

    if closeMapping
        CloseAnalogMapping()

    if wasOnline
        Log("ANALOG OFFLINE -> digital fallback")
}

OnMouse(source, code, state) {
    Log("RAW M id=" source " code=" code " state=" state)

    if (code != 5)
        return

    if (state = 1)
        phys := "ScrollUp"
    else if (state = -1)
        phys := "ScrollDown"
    else
        return

    action := ResolveAction(phys)
    Log("ACTION " phys " -> " action)
    ExecuteInstant(action)
}

PhysicalFromScanCode(code) {
    static Codes := Map(
        2,   "01",
        3,   "02",
        4,   "03",
        5,   "04",
        6,   "05",
        15,  "06",
        16,  "07",
        17,  "08",
        18,  "09",
        19,  "10",
        58,  "11",
        30,  "12",
        31,  "13",
        32,  "14",
        33,  "15",
        42,  "16",
        44,  "17",
        45,  "18",
        46,  "19",
        57,  "20",

        56,  "ALTBTN",

        328, "DUp",
        333, "DRight",
        336, "DDown",
        331, "DLeft"
    )

    return Codes.Has(code) ? Codes[code] : ""
}

IsDpad(phys) {
    return (
        phys = "DUp"
        || phys = "DRight"
        || phys = "DDown"
        || phys = "DLeft"
    )
}

; ------------------------------------------------------------
; Debounce
; ------------------------------------------------------------

; D-pad:
; release must stay released for 30 ms.
HandleDpad(token, phys, state) {
    global DpadGeneration, Pressed

    gen := DpadGeneration.Has(token) ? DpadGeneration[token] + 1 : 1
    DpadGeneration[token] := gen

    if (state = 1) {
        if Pressed.Has(token)
            return
        HandlePhysical(token, phys, 1)
        return
    }

    SetTimer(FinalizeDpadRelease.Bind(token, phys, gen), -30)
}

FinalizeDpadRelease(token, phys, generation) {
    global DpadGeneration

    if !DpadGeneration.Has(token)
        return
    if (DpadGeneration[token] != generation)
        return

    HandlePhysical(token, phys, 0)
}

; Thumb button:
; Short stable-release debounce. 30 ms is long enough to swallow the observed
; bounce, but short enough that intentional rapid tapping is not merged.
HandleThumb(token, phys, state) {
    global ThumbGeneration, Pressed

    gen := ThumbGeneration.Has(token) ? ThumbGeneration[token] + 1 : 1
    ThumbGeneration[token] := gen

    if (state = 1) {
        ; A fresh DOWN during the release-delay cancels the pending release.
        if Pressed.Has(token)
            return

        HandlePhysical(token, phys, 1)
        return
    }

    SetTimer(FinalizeThumbRelease.Bind(token, phys, gen), -30)
}

FinalizeThumbRelease(token, phys, generation) {
    global ThumbGeneration

    if !ThumbGeneration.Has(token)
        return
    if (ThumbGeneration[token] != generation)
        return

    HandlePhysical(token, phys, 0)
}

; ------------------------------------------------------------
; Main physical state
; ------------------------------------------------------------

HandlePhysical(token, phys, state) {
    global Pressed, ActiveActions
    global HyperShift, CurrentMap

    if (state = 1) {
        ; Ignore Tartarus' own repeated RAW DOWN events.
        ; v4 generates its own steady repeat so HyperShift cannot interrupt it.
        if Pressed.Has(token)
            return

        Pressed[token] := phys
        action := ResolveAction(phys)
        ActiveActions[token] := action

        Log("DOWN " phys " -> " action)

        if (action = "HYPER") {
            SetHyperToken(token, true)
            return
        }

        if (SubStr(action, 1, 4) = "MAP|") {
            SwitchMap(SubStr(action, 5))
            return
        }

        if (action = "DISABLE" || action = "DEFAULT")
            return

        if (SubStr(action, 1, 2) = "K|") {
            HoldKeyboardAction(action)
            StartSoftwareRepeat(token)
            return
        }

        if (SubStr(action, 1, 6) = "MOUSE|") {
            HoldMouseAction(action)
            return
        }

        if (SubStr(action, 1, 6) = "MEDIA|"
            || SubStr(action, 1, 6) = "WHEEL|") {
            ExecuteInstant(action)
            return
        }

        return
    }

    if !Pressed.Has(token)
        return

    Pressed.Delete(token)

    action := ActiveActions.Has(token) ? ActiveActions[token] : ""
    if ActiveActions.Has(token)
        ActiveActions.Delete(token)

    Log("UP " phys " -> " action)

    ; Release EXACTLY what this physical key started on its DOWN event.
    ; Layer/keymap changes never cause already-held keys to be re-resolved.
    if (action = "HYPER") {
        SetHyperToken(token, false)
        return
    }

    if (SubStr(action, 1, 2) = "K|") {
        StopSoftwareRepeat(token)
        ReleaseKeyboardAction(action)
        return
    }

    if (SubStr(action, 1, 6) = "MOUSE|") {
        ReleaseMouseAction(action)
        return
    }
}

SetHyperToken(token, isDown) {
    global HyperTokens, HyperShift, CurrentMap

    if isDown {
        HyperTokens[token] := true
    } else if HyperTokens.Has(token) {
        HyperTokens.Delete(token)
    }

    newState := HyperTokens.Count > 0
    if (newState = HyperShift)
        return

    HyperShift := newState
    Log("HYPER " . (HyperShift ? "ON" : "OFF"))
    SendLedState(CurrentMap)
    UpdateTray()
}

; ------------------------------------------------------------
; Software typematic
; ------------------------------------------------------------

IsModifierKey(key) {
    return (
        key = "LControl" || key = "RControl"
        || key = "LShift" || key = "RShift"
        || key = "LAlt" || key = "RAlt"
        || key = "LWin" || key = "RWin"
    )
}

StartSoftwareRepeat(token) {
    global RepeatTimers, RepeatDelayMs, ActiveActions

    if RepeatTimers.Has(token)
        return
    if !ActiveActions.Has(token)
        return

    ; Pure modifier assignments (Ctrl/Shift/Alt/Win) must be held, not
    ; typematic-repeated. Repeated modifier DOWN packets cause erratic
    ; behaviour in games/apps and were especially visible on Controller 16.
    action := ActiveActions[token]
    if (SubStr(action, 1, 2) != "K|")
        return

    keys := StrSplit(SubStr(action, 3), "+")
    if (keys.Length < 1)
        return

    mainKey := keys[keys.Length]
    if IsModifierKey(mainKey)
        return

    fn := SoftwareRepeatStart.Bind(token)
    RepeatTimers[token] := fn
    SetTimer(fn, -RepeatDelayMs)
}

SoftwareRepeatStart(token) {
    global RepeatTimers, RepeatIntervalMs

    if !RepeatTimers.Has(token)
        return

    RepeatCurrentAction(token)

    ; The same timer object becomes periodic after the first delayed repeat.
    if RepeatTimers.Has(token)
        SetTimer(RepeatTimers[token], RepeatIntervalMs)
}

RepeatCurrentAction(token) {
    global Pressed, ActiveActions, AHI, OutputKeyboard

    if !Pressed.Has(token)
        return
    if !ActiveActions.Has(token)
        return

    action := ActiveActions[token]
    if (SubStr(action, 1, 2) != "K|")
        return

    keys := StrSplit(SubStr(action, 3), "+")
    if (keys.Length < 1)
        return

    mainKey := keys[keys.Length]
    if IsModifierKey(mainKey)
        return

    sc := GetKeySC(mainKey)

    if (!sc)
        return

    Log("REPEAT_SW " mainKey " sc=" sc)
    AHI.SendKeyEvent(OutputKeyboard, sc, 1)
}

StopSoftwareRepeat(token) {
    global RepeatTimers

    if !RepeatTimers.Has(token)
        return

    try SetTimer(RepeatTimers[token], 0)
    RepeatTimers.Delete(token)
}

; ------------------------------------------------------------
; Mapping
; ------------------------------------------------------------

ResolveAction(phys) {
    global CurrentMap, HyperShift, Mappings

    layer := HyperShift ? "H" : "N"
    id := CurrentMap . "|" . layer . "|" . phys

    if Mappings.Has(id)
        return Mappings[id]

    return DefaultAction(phys)
}

DefaultAction(phys) {
    static Defaults := Map(
        "01", "K|1",
        "02", "K|2",
        "03", "K|3",
        "04", "K|4",
        "05", "K|5",
        "06", "K|Tab",
        "07", "K|q",
        "08", "K|w",
        "09", "K|e",
        "10", "K|r",
        "11", "K|CapsLock",
        "12", "K|a",
        "13", "K|s",
        "14", "K|d",
        "15", "K|f",
        "16", "K|LShift",
        "17", "K|z",
        "18", "K|x",
        "19", "K|c",
        "20", "K|Space",
        "ALTBTN", "K|LAlt",
        "DUp", "K|Up",
        "DRight", "K|Right",
        "DDown", "K|Down",
        "DLeft", "K|Left",
        "ScrollUp", "WHEEL|1",
        "ScrollDown", "WHEEL|-1"
    )

    return Defaults.Has(phys) ? Defaults[phys] : "DISABLE"
}

LoadMappingsFromConfig() {
    global ConfigFile, ConfigBackupFile, Mappings, MapOrder

    if !FileExist(ConfigFile) {
        Mappings := Map()
        InitMapDefinitions()
        InitMappings()
        Log("CONFIG missing -> built-in mappings")
        return
    }

    try {
        text := FileRead(ConfigFile, "UTF-8")
        LoadMappingsFromText(text)
        return
    } catch Error as e {
        Log("CONFIG LOAD ERROR: " e.Message)
    }

    ; A damaged/half-edited config must never silently turn missing entries
    ; into unrelated default keys. Prefer the last known-good UI backup.
    if FileExist(ConfigBackupFile) {
        try {
            backupText := FileRead(ConfigBackupFile, "UTF-8")
            LoadMappingsFromText(backupText)
            Log("CONFIG recovered from backup")
            return
        } catch Error as e {
            Log("CONFIG BACKUP ERROR: " e.Message)
        }
    }

    Mappings := Map()
    InitMapDefinitions()
    InitMappings()
    Log("CONFIG unrecoverable -> built-in mappings")
}

IsKnownPhysical(phys) {
    static Known := Map(
        "01",1,"02",1,"03",1,"04",1,"05",1,
        "06",1,"07",1,"08",1,"09",1,"10",1,
        "11",1,"12",1,"13",1,"14",1,"15",1,
        "16",1,"17",1,"18",1,"19",1,"20",1,
        "ALTBTN",1,"DUp",1,"DRight",1,"DDown",1,"DLeft",1,
        "ScrollUp",1,"ScrollDown",1
    )
    return Known.Has(phys)
}

ValidateActionSyntax(action, declaredMaps) {
    if (action = "DISABLE" || action = "HYPER")
        return

    if (SubStr(action, 1, 4) = "MAP|") {
        target := SubStr(action, 5)
        if !declaredMaps.Has(target)
            throw Error("unknown Keymap target: " target)
        return
    }

    if (SubStr(action, 1, 6) = "MOUSE|") {
        if (MouseButtonCode(SubStr(action, 7)) < 0)
            throw Error("invalid mouse action: " action)
        return
    }

    if (SubStr(action, 1, 6) = "MEDIA|") {
        key := SubStr(action, 7)
        if !(key = "Volume_Up" || key = "Volume_Down" || key = "Volume_Mute"
            || key = "Media_Play_Pause" || key = "Media_Next"
            || key = "Media_Prev" || key = "Media_Stop")
            throw Error("invalid media action: " action)
        return
    }

    if (action = "WHEEL|1" || action = "WHEEL|-1")
        return

    if (SubStr(action, 1, 2) = "K|") {
        body := SubStr(action, 3)
        if (body = "")
            throw Error("empty keyboard action")
        for key in StrSplit(body, "+") {
            if (key = "" || !GetKeySC(key))
                throw Error("invalid keyboard key: " key)
        }
        return
    }

    throw Error("invalid action: " action)
}

LoadMappingsFromText(text) {
    global Mappings, MapOrder, MapColors, RuntimeReady, CurrentMap

    fresh := Map()
    freshOrder := []
    freshColors := Map()
    declaredMaps := Map()
    pendingMappings := []
    lineNo := 0

    for rawLine in StrSplit(text, "`n") {
        lineNo += 1
        line := Trim(rawLine, "`r`n")
        if (line = "" || SubStr(line, 1, 1) = "#")
            continue

        parts := StrSplit(line, "`t")

        if (parts[1] = "@map") {
            if !(parts.Length = 5 || parts.Length = 8)
                throw Error("invalid @map line " lineNo)
            name := parts[2]
            if (name = "" || declaredMaps.Has(name))
                throw Error("invalid/duplicate Keymap on line " lineNo ": " name)

            rgbIdx := [3,4,5]
            if (parts.Length = 8) {
                rgbIdx.Push(6)
                rgbIdx.Push(7)
                rgbIdx.Push(8)
            }
            for idx in rgbIdx {
                if !RegExMatch(parts[idx], "^\d{1,3}$")
                    throw Error("invalid RGB on line " lineNo)
                n := parts[idx] + 0
                if (n < 0 || n > 255)
                    throw Error("RGB out of range on line " lineNo)
            }

            freshOrder.Push(name)
            freshColors[name] := [parts[3] + 0, parts[4] + 0, parts[5] + 0]
            declaredMaps[name] := true
            continue
        }

        if (parts[1] = "@indicator") {
            if (parts.Length != 6)
                throw Error("invalid @indicator line " lineNo)
            continue
        }

        if (parts.Length != 4)
            throw Error("invalid config line " lineNo)

        pendingMappings.Push([parts[1], parts[2], parts[3], parts[4], lineNo])
    }

    if (freshOrder.Length = 0)
        throw Error("config contains no Keymap definitions")

    for item in pendingMappings {
        mapName := item[1]
        layer := item[2]
        phys := item[3]
        action := item[4]
        sourceLine := item[5]

        if !declaredMaps.Has(mapName)
            throw Error("mapping references unknown Keymap on line " sourceLine ": " mapName)
        if !(layer = "N" || layer = "H")
            throw Error("invalid layer on line " sourceLine)
        if !IsKnownPhysical(phys)
            throw Error("invalid physical input on line " sourceLine ": " phys)

        ValidateActionSyntax(action, declaredMaps)
        fresh[mapName . "|" . layer . "|" . phys] := action
    }

    ; Swap only after the entire file has passed validation.
    Mappings := fresh
    MapOrder := freshOrder
    MapColors := freshColors
    Log("CONFIG loaded maps=" freshOrder.Length " entries=" fresh.Count)

    if RuntimeReady {
        RestoreCurrentMapFromFile()
        if !MapExists(CurrentMap)
            CurrentMap := MapOrder[1]
        WriteCurrentMap()
        SendLedState(CurrentMap)
        UpdateTray()
        ShowMapStatus()
    }
}

DefaultMapDefinitions() {
    order := ["Keymap 1", "Controller", "clip_studio", "aseprite", "blender"]
    colors := Map(
        "Keymap 1", [255, 0, 0],
        "Controller", [0, 255, 0],
        "clip_studio", [0, 0, 255],
        "aseprite", [180, 0, 255],
        "blender", [0, 220, 255]
    )
    return [order, colors]
}

InitMapDefinitions() {
    global MapOrder, MapColors
    defaults := DefaultMapDefinitions()
    MapOrder := defaults[1]
    MapColors := defaults[2]
}

MapExists(name) {
    global MapColors
    return MapColors.Has(name)
}

RestoreCurrentMapFromFile() {
    global CurrentMap, CurrentMapFile, MapOrder
    try {
        desired := Trim(FileRead(CurrentMapFile, "UTF-8"))
        if MapExists(desired) {
            CurrentMap := desired
            return
        }
    }
    if !MapExists(CurrentMap) && MapOrder.Length
        CurrentMap := MapOrder[1]
}

ReloadMappingsIfChanged() {
    global ConfigFile
    static lastText := Chr(0)

    if !FileExist(ConfigFile)
        return

    try text := FileRead(ConfigFile, "UTF-8")
    catch
        return

    if (text = lastText)
        return

    try {
        LoadMappingsFromText(text)
        lastText := text
    } catch Error as e {
        Log("CONFIG RELOAD REJECTED: " e.Message)
    }
}

WriteCurrentMap() {
    global CurrentMap, CurrentMapFile
    try {
        f := FileOpen(CurrentMapFile, "w", "UTF-8")
        f.Write(CurrentMap)
        f.Close()
    }
}

CheckRuntimeCommand() {
    global CommandFile

    if !FileExist(CommandFile)
        return

    try cmd := Trim(FileRead(CommandFile, "UTF-8"))
    catch
        return

    try FileDelete(CommandFile)

    if (cmd = "EXIT") {
        Log("RUNTIME COMMAND EXIT")
        ExitApp()
    }
}

AddMap(mapName, layer, phys, action) {
    global Mappings
    Mappings[mapName . "|" . layer . "|" . phys] := action
}

InitMappings() {
    AddMap("Keymap 1", "N", "ALTBTN", "MAP|clip_studio")
    AddMap("Keymap 1", "N", "DUp", "K|Home")
    AddMap("Keymap 1", "N", "DRight", "K|d")
    AddMap("Keymap 1", "N", "DLeft", "K|LControl+LAlt+c")
    AddMap("Keymap 1", "N", "DDown", "K|End")
    AddMap("Keymap 1", "N", "01", "K|LControl+LShift+t")
    AddMap("Keymap 1", "N", "02", "K|LShift+LControl+LAlt+Tab")
    AddMap("Keymap 1", "N", "03", "K|LControl+LAlt+Tab")
    AddMap("Keymap 1", "N", "04", "K|Backspace")
    AddMap("Keymap 1", "N", "05", "K|Esc")
    AddMap("Keymap 1", "N", "06", "K|LControl+w")
    AddMap("Keymap 1", "N", "07", "K|LControl+LShift+Tab")
    AddMap("Keymap 1", "N", "08", "K|LControl+Tab")
    AddMap("Keymap 1", "N", "09", "K|NumpadEnter")
    AddMap("Keymap 1", "N", "10", "K|LControl+t")
    AddMap("Keymap 1", "N", "11", "K|LShift")
    AddMap("Keymap 1", "N", "12", "K|F5")
    AddMap("Keymap 1", "N", "13", "K|Up")
    AddMap("Keymap 1", "N", "17", "K|Left")
    AddMap("Keymap 1", "N", "18", "K|Down")
    AddMap("Keymap 1", "N", "19", "K|Right")
    AddMap("Keymap 1", "N", "16", "K|LControl")
    AddMap("Keymap 1", "N", "14", "K|F2")
    AddMap("Keymap 1", "N", "15", "K|Space")
    AddMap("Keymap 1", "N", "20", "HYPER")
    AddMap("Keymap 1", "H", "20", "HYPER")
    AddMap("Keymap 1", "H", "01", "MAP|Controller")
    AddMap("Keymap 1", "H", "02", "K|F11")
    AddMap("Keymap 1", "H", "03", "K|f")
    AddMap("Keymap 1", "H", "04", "K|LShift+Delete")
    AddMap("Keymap 1", "H", "05", "K|Delete")
    AddMap("Keymap 1", "H", "10", "K|LControl+LAlt+F11")
    AddMap("Keymap 1", "H", "15", "K|LControl+v")
    AddMap("Keymap 1", "H", "14", "K|LControl+c")
    AddMap("Keymap 1", "H", "13", "K|LControl+x")
    AddMap("Keymap 1", "H", "12", "K|LControl+a")
    AddMap("Keymap 1", "H", "11", "K|Tab")
    AddMap("Keymap 1", "H", "16", "K|LWin+1")
    AddMap("Keymap 1", "H", "ScrollUp", "MEDIA|Volume_Up")
    AddMap("Keymap 1", "H", "ScrollDown", "MEDIA|Volume_Down")
    AddMap("Keymap 1", "H", "06", "MAP|aseprite")
    AddMap("Keymap 1", "H", "09", "K|LShift+LControl+n")
    AddMap("Keymap 1", "H", "07", "MAP|blender")
    AddMap("Keymap 1", "H", "08", "K|LShift+LWin+s")
    AddMap("Controller", "N", "01", "K|Esc")
    AddMap("Controller", "N", "02", "DISABLE")
    AddMap("Controller", "N", "03", "DISABLE")
    AddMap("Controller", "N", "04", "K|3")
    AddMap("Controller", "N", "05", "DISABLE")
    AddMap("Controller", "N", "08", "K|w")
    AddMap("Controller", "N", "12", "K|a")
    AddMap("Controller", "N", "13", "K|s")
    AddMap("Controller", "N", "14", "K|d")
    AddMap("Controller", "N", "ALTBTN", "K|z")
    AddMap("Controller", "N", "DUp", "K|5")
    AddMap("Controller", "N", "DRight", "K|6")
    AddMap("Controller", "N", "DDown", "K|8")
    AddMap("Controller", "N", "DLeft", "K|7")
    AddMap("Controller", "N", "06", "DISABLE")
    AddMap("Controller", "N", "07", "K|q")
    AddMap("Controller", "N", "09", "K|e")
    AddMap("Controller", "N", "10", "K|r")
    AddMap("Controller", "N", "15", "K|x")
    AddMap("Controller", "N", "11", "K|LShift")
    AddMap("Controller", "N", "16", "K|LControl")
    AddMap("Controller", "N", "17", "K|v")
    AddMap("Controller", "N", "18", "K|b")
    AddMap("Controller", "N", "19", "K|c")
    AddMap("Controller", "N", "20", "HYPER")
    AddMap("Controller", "H", "20", "HYPER")
    AddMap("Controller", "H", "01", "MAP|Keymap 1")
    AddMap("Controller", "H", "02", "DISABLE")
    AddMap("Controller", "H", "03", "DISABLE")
    AddMap("Controller", "H", "04", "DISABLE")
    AddMap("Controller", "H", "05", "DISABLE")
    AddMap("Controller", "H", "06", "DISABLE")
    AddMap("Controller", "H", "07", "DISABLE")
    AddMap("Controller", "H", "08", "K|w")
    AddMap("Controller", "H", "09", "K|g")
    AddMap("Controller", "H", "10", "K|h")
    AddMap("Controller", "H", "11", "K|Tab")
    AddMap("Controller", "H", "12", "K|a")
    AddMap("Controller", "H", "13", "K|s")
    AddMap("Controller", "H", "14", "K|d")
    AddMap("Controller", "H", "15", "K|l")
    AddMap("Controller", "H", "16", "K|LAlt")
    AddMap("Controller", "H", "17", "DISABLE")
    AddMap("Controller", "H", "18", "DISABLE")
    AddMap("Controller", "H", "19", "K|m")
    AddMap("Controller", "H", "ALTBTN", "DISABLE")
    AddMap("Controller", "N", "ScrollUp", "K|F1")
    AddMap("Controller", "N", "ScrollDown", "K|9")
    AddMap("clip_studio", "N", "05", "K|LControl+LAlt+1")
    AddMap("clip_studio", "N", "10", "K|f")
    AddMap("clip_studio", "N", "15", "K|Space")
    AddMap("clip_studio", "N", "04", "K|Enter")
    AddMap("clip_studio", "N", "09", "MOUSE|RButton")
    AddMap("clip_studio", "N", "14", "K|r")
    AddMap("clip_studio", "N", "03", "K|LControl+LAlt+Tab")
    AddMap("clip_studio", "N", "08", "K|LShift+LWin+s")
    AddMap("clip_studio", "N", "13", "K|LControl+z")
    AddMap("clip_studio", "N", "02", "K|LShift+LControl+LAlt+Tab")
    AddMap("clip_studio", "N", "07", "K|LAlt+PrintScreen")
    AddMap("clip_studio", "N", "12", "K|LShift+LControl+z")
    AddMap("clip_studio", "N", "01", "K|Delete")
    AddMap("clip_studio", "N", "06", "K|LAlt")
    AddMap("clip_studio", "N", "11", "K|LShift")
    AddMap("clip_studio", "N", "16", "K|LControl")
    AddMap("clip_studio", "N", "20", "HYPER")
    AddMap("clip_studio", "H", "20", "HYPER")
    AddMap("clip_studio", "N", "ALTBTN", "MAP|Keymap 1")
    AddMap("clip_studio", "H", "05", "K|LControl+v")
    AddMap("clip_studio", "H", "04", "K|LControl+c")
    AddMap("clip_studio", "H", "03", "K|t")
    AddMap("clip_studio", "H", "02", "K|u")
    AddMap("clip_studio", "H", "01", "DISABLE")
    AddMap("clip_studio", "H", "10", "K|o")
    AddMap("clip_studio", "H", "09", "K|j")
    AddMap("clip_studio", "H", "ScrollUp", "K|p")
    AddMap("clip_studio", "H", "ScrollDown", "K|z")
    AddMap("clip_studio", "H", "08", "K|g")
    AddMap("clip_studio", "H", "07", "K|b")
    AddMap("clip_studio", "H", "06", "K|w")
    AddMap("clip_studio", "H", "15", "K|2")
    AddMap("clip_studio", "H", "14", "K|e")
    AddMap("clip_studio", "H", "13", "K|v")
    AddMap("clip_studio", "H", "12", "K|LShift+LControl+i")
    AddMap("clip_studio", "H", "11", "K|LControl+s")
    AddMap("clip_studio", "N", "19", "K|q")
    AddMap("clip_studio", "N", "18", "K|1")
    AddMap("clip_studio", "N", "17", "K|LControl+LAlt+9")
    AddMap("clip_studio", "H", "19", "K|c")
    AddMap("clip_studio", "H", "18", "K|x")
    AddMap("clip_studio", "H", "17", "K|m")
    AddMap("clip_studio", "H", "16", "K|LControl+d")
    AddMap("aseprite", "N", "05", "K|LControl+LAlt+1")
    AddMap("aseprite", "N", "10", "K|f")
    AddMap("aseprite", "N", "15", "K|Space")
    AddMap("aseprite", "N", "04", "K|Enter")
    AddMap("aseprite", "N", "09", "MOUSE|RButton")
    AddMap("aseprite", "N", "14", "K|r")
    AddMap("aseprite", "N", "03", "K|LControl+LAlt+Tab")
    AddMap("aseprite", "N", "08", "K|LShift+LWin+s")
    AddMap("aseprite", "N", "13", "K|LControl+z")
    AddMap("aseprite", "N", "02", "K|LShift+LControl+LAlt+Tab")
    AddMap("aseprite", "N", "07", "K|LAlt+PrintScreen")
    AddMap("aseprite", "N", "12", "K|LShift+LControl+z")
    AddMap("aseprite", "N", "01", "K|Delete")
    AddMap("aseprite", "N", "06", "K|LAlt")
    AddMap("aseprite", "N", "11", "K|LShift")
    AddMap("aseprite", "N", "16", "K|LControl")
    AddMap("aseprite", "N", "20", "HYPER")
    AddMap("aseprite", "H", "20", "HYPER")
    AddMap("aseprite", "N", "ALTBTN", "MAP|Keymap 1")
    AddMap("aseprite", "H", "05", "K|LControl+v")
    AddMap("aseprite", "H", "04", "K|LControl+c")
    AddMap("aseprite", "H", "03", "K|t")
    AddMap("aseprite", "H", "02", "K|u")
    AddMap("aseprite", "H", "01", "MAP|Keymap 1")
    AddMap("aseprite", "H", "10", "K|7")
    AddMap("aseprite", "H", "09", "K|j")
    AddMap("aseprite", "H", "ScrollUp", "K|Up")
    AddMap("aseprite", "H", "ScrollDown", "K|Down")
    AddMap("aseprite", "H", "08", "K|g")
    AddMap("aseprite", "H", "07", "K|b")
    AddMap("aseprite", "H", "06", "K|w")
    AddMap("aseprite", "H", "15", "K|2")
    AddMap("aseprite", "H", "14", "K|e")
    AddMap("aseprite", "H", "13", "K|v")
    AddMap("aseprite", "H", "12", "K|LShift+LControl+i")
    AddMap("aseprite", "H", "11", "K|LControl+s")
    AddMap("aseprite", "N", "19", "K|q")
    AddMap("aseprite", "N", "18", "K|1")
    AddMap("aseprite", "N", "17", "K|k")
    AddMap("aseprite", "H", "19", "K|LShift+x")
    AddMap("aseprite", "H", "18", "K|x")
    AddMap("aseprite", "H", "17", "K|m")
    AddMap("aseprite", "H", "16", "K|LControl+d")
    AddMap("aseprite", "N", "DLeft", "K|Left")
    AddMap("aseprite", "N", "DRight", "K|Right")
    AddMap("aseprite", "N", "DUp", "K|Up")
    AddMap("aseprite", "N", "DDown", "K|Down")
    AddMap("aseprite", "N", "ScrollUp", "K|Left")
    AddMap("aseprite", "N", "ScrollDown", "K|Right")
    AddMap("blender", "H", "01", "MAP|Keymap 1")
    AddMap("blender", "N", "20", "HYPER")
    AddMap("blender", "H", "20", "HYPER")
    AddMap("blender", "N", "15", "K|Numpad0")
    AddMap("blender", "N", "18", "K|NumpadDot")
    AddMap("blender", "H", "11", "K|LControl+s")
}

; ------------------------------------------------------------
; Output
; ------------------------------------------------------------

HoldKeyboardAction(action) {
    keys := StrSplit(SubStr(action, 3), "+")
    for key in keys
        OutputKeyDown(key)
}

ReleaseKeyboardAction(action) {
    keys := StrSplit(SubStr(action, 3), "+")

    Loop keys.Length {
        idx := keys.Length - A_Index + 1
        OutputKeyUp(keys[idx])
    }
}

OutputKeyDown(key) {
    global OutputCounts, AHI, OutputKeyboard

    sc := GetKeySC(key)
    if (!sc) {
        Log("NO SC DOWN " key)
        return
    }

    count := OutputCounts.Has(key) ? OutputCounts[key] : 0
    OutputCounts[key] := count + 1

    if (count = 0) {
        Log("SEND DOWN " key " sc=" sc " via keyboard " OutputKeyboard)
        AHI.SendKeyEvent(OutputKeyboard, sc, 1)
    }
}

OutputKeyUp(key) {
    global OutputCounts, AHI, OutputKeyboard

    if !OutputCounts.Has(key)
        return

    count := OutputCounts[key]

    if (count <= 1) {
        OutputCounts.Delete(key)
        sc := GetKeySC(key)

        if (sc) {
            Log("SEND UP " key " sc=" sc " via keyboard " OutputKeyboard)
            AHI.SendKeyEvent(OutputKeyboard, sc, 0)
        }
    } else {
        OutputCounts[key] := count - 1
    }
}

HoldMouseAction(action) {
    global AHI, OutputMouse, MouseOutputCounts

    if (!OutputMouse)
        return

    button := SubStr(action, 7)
    code := MouseButtonCode(button)
    if (code < 0)
        return

    count := MouseOutputCounts.Has(button) ? MouseOutputCounts[button] : 0
    MouseOutputCounts[button] := count + 1
    if (count = 0)
        AHI.SendMouseButtonEvent(OutputMouse, code, 1)
}

ReleaseMouseAction(action) {
    global AHI, OutputMouse, MouseOutputCounts

    if (!OutputMouse)
        return

    button := SubStr(action, 7)
    code := MouseButtonCode(button)
    if (code < 0 || !MouseOutputCounts.Has(button))
        return

    count := MouseOutputCounts[button]
    if (count <= 1) {
        MouseOutputCounts.Delete(button)
        AHI.SendMouseButtonEvent(OutputMouse, code, 0)
    } else {
        MouseOutputCounts[button] := count - 1
    }
}

MouseButtonCode(name) {
    static Codes := Map(
        "LButton", 0,
        "RButton", 1,
        "MButton", 2,
        "XButton1", 3,
        "XButton2", 4
    )
    return Codes.Has(name) ? Codes[name] : -1
}

ExecuteInstant(action) {
    if (action = "" || action = "DISABLE" || action = "DEFAULT")
        return

    if (SubStr(action, 1, 2) = "K|") {
        HoldKeyboardAction(action)
        ReleaseKeyboardAction(action)
        return
    }

    if (SubStr(action, 1, 4) = "MAP|") {
        SwitchMap(SubStr(action, 5))
        return
    }

    if (SubStr(action, 1, 6) = "MOUSE|") {
        HoldMouseAction(action)
        ReleaseMouseAction(action)
        return
    }

    if (SubStr(action, 1, 6) = "MEDIA|") {
        key := SubStr(action, 7)
        SendEvent("{" . key . "}")
        return
    }

    if (SubStr(action, 1, 6) = "WHEEL|") {
        direction := SubStr(action, 7)

        if (direction = "1")
            SendEvent("{WheelUp}")
        else if (direction = "-1")
            SendEvent("{WheelDown}")

        return
    }
}

; ------------------------------------------------------------
; UI
; ------------------------------------------------------------

SwitchMap(name) {
    global CurrentMap

    if !MapExists(name) {
        Log("MAP rejected -> " name)
        return
    }

    CurrentMap := name
    Log("MAP -> " name)
    SendLedState(name)
    WriteCurrentMap()
    UpdateTray()
    ShowMapStatus()
}

SendLedState(name) {
    global LedStateFile, HyperShift

    try {
        layer := HyperShift ? "H" : "N"
        tmp := LedStateFile . ".tmp"
        try FileDelete(tmp)
        f := FileOpen(tmp, "w", "UTF-8")
        f.Write(name . "`t" . layer)
        f.Close()
        FileMove(tmp, LedStateFile, 1)
    } catch Error as e {
        Log("LED STATE WRITE ERROR: " e.Message)
    }
}

UpdateTray() {
    global CurrentMap, HyperShift, OutputKeyboard, MapOrder

    hs := HyperShift ? " [HS]" : ""
    A_IconTip := "Tartarus AHK v10.1.5 AUDIT1 - " . CurrentMap . hs . " / OUT KBD " . OutputKeyboard

    ; Rebuild only our own compact tray menu.
    A_TrayMenu.Delete()

    status := "現在: " . CurrentMap . hs
    A_TrayMenu.Add(status, TrayNoop)
    A_TrayMenu.Disable(status)
    A_TrayMenu.Add()

    for mapName in MapOrder
        A_TrayMenu.Add("Keymap: " mapName, TraySwitchMap.Bind(mapName))

    A_TrayMenu.Add()
    A_TrayMenu.Add("設定を開く", TrayOpenSettings)
    A_TrayMenu.Add("LEDを再同期", TrayLedResync)
    A_TrayMenu.Add("Tartarusを再起動", TrayRestart)
    A_TrayMenu.Add()
    A_TrayMenu.Add("終了", TrayExit)
}

TrayNoop(*) {
}

TraySwitchMap(mapName, *) {
    SwitchMap(mapName)
}

TrayOpenSettings(*) {
    Run("http://127.0.0.1:8765/")
}

TrayLedResync(*) {
    global CurrentMap
    SendLedState(CurrentMap)
    ShowMapStatus()
}

TrayRestart(*) {
    cmd := 'wscript.exe "' . A_ScriptDir . '\Tartarus_Runtime.vbs" restart'
    Run(cmd, , "Hide")
}

TrayExit(*) {
    ; Let the runtime stop the mapper, LED daemon, and settings server in order.
    cmd := 'wscript.exe "' . A_ScriptDir . '\Tartarus_Runtime.vbs" stop'
    Run(cmd, , "Hide")
    ; Close this tray instance without relying on external process detection.
    ExitApp()
}

ShowMapStatus() {
    global CurrentMap, HyperShift

    hs := HyperShift ? "  /  HyperShift" : ""
    ToolTip("Tartarus: " . CurrentMap . hs)
    SetTimer(ClearMapStatus, -800)
}

ClearMapStatus() {
    ToolTip()
}

Log(msg) {
    global DebugFile, VerboseLogging

    ; Do not perform synchronous disk I/O on the input hot path in normal use.
    ; Create ENABLE_VERBOSE_LOGGING.txt next to the scripts only when a full
    ; event trace is required for diagnostics.
    if !VerboseLogging {
        if RegExMatch(msg, "^(RAW |DOWN |UP |SEND |REPEAT_SW |ACTION )")
            return
    }

    try {
        if FileExist(DebugFile) && FileGetSize(DebugFile) > 2097152 {
            old := DebugFile . ".1"
            try FileDelete(old)
            try FileMove(DebugFile, old, 1)
        }
        FileAppend(A_TickCount "`t" msg "`r`n", DebugFile, "UTF-8")
    }
}

Cleanup(*) {
    global OutputCounts, MouseOutputCounts, AHI, OutputKeyboard, OutputMouse, RepeatTimers

    ; LED daemon lifetime is owned exclusively by Tartarus_Runtime.ps1.
    ; Writing __EXIT__ here used to race with a newly started daemon during a
    ; restart, causing lighting control to stop while the mapper kept running.

    for token, fn in RepeatTimers {
        try SetTimer(fn, 0)
    }

    for key, count in OutputCounts {
        try {
            sc := GetKeySC(key)
            if (sc)
                AHI.SendKeyEvent(OutputKeyboard, sc, 0)
        }
    }

    if OutputMouse {
        for button, count in MouseOutputCounts {
            try {
                code := MouseButtonCode(button)
                if (code >= 0)
                    AHI.SendMouseButtonEvent(OutputMouse, code, 0)
            }
        }
    }

    CloseAnalogMapping()
    try AHI.SetState(false)
}

SwitchMapByIndex(index) {
    global MapOrder
    if (index <= MapOrder.Length)
        SwitchMap(MapOrder[index])
}

