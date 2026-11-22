#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

;=============================================================
;  Audio Hotkeys  —  global mic / speaker mute toggles
;-------------------------------------------------------------
;  Two features, one hotkey each:
;     Numpad-  microphone mute toggle
;     Numpad*  speakers mute toggle
;
;  Everything that differs between the features lives in DEVICES;
;  everything that switches them on, off or quiet lives in CONFIG.
;  Edit those two tables and the hotkey, tray item, startup log and
;  toast all follow. Keep each row's `key` and `keyLabel` in sync.
;
;  Muting uses the Windows Core Audio API. No drivers, no extra
;  binaries, no admin rights needed for audio.
;  See README.md for install, autostart and rebinding.
;=============================================================

;------------------------- SETTINGS ---------------------------
; Debug: log every keypress, not just startup and failures.
Debug := false

; CONFIG: one entry per feature, keyed by the same name used in DEVICES.
;
;   enabled    : is the hotkey live?  false = the key is not captured at
;                all, so it reaches the focused app as a normal keystroke.
;                The tray item still works, so the feature stays reachable.
;   toastMuted : show the toast when the device becomes muted
;   toastLive  : show the toast when the device becomes live
;                Independent of each other: warn on silence, stay quiet
;                when sound comes back.
CONFIG := Map(
    "mic", { enabled: true, toastMuted: true, toastLive: true },
    "spk", { enabled: true, toastMuted: true, toastLive: true }
)

; DEVICES: the per-feature facts. `flow` is the Core Audio data flow —
; 1 = capture (microphone), 0 = render (speakers) — and `key` is its
; hotkey. `keyLabel` is the human spelling shown in the tray menu.
DEVICES := Map(
    "mic", { label: "Microphone", flow: 1
           , key: "NumpadSub", keyLabel: "Numpad-"
           , glyphMuted: Chr(0xE720), glyphLive: Chr(0xE720)
           , liveColor: "4CC26A" },
    "spk", { label: "Speakers", flow: 0
           , key: "NumpadMult", keyLabel: "Numpad*"
           , glyphMuted: Chr(0xE74F), glyphLive: Chr(0xE767)
           , liveColor: "EEEEEE" }
)

;------------------------- Diagnostics ------------------------
; A modal error dialog raised from a hotkey thread blocks the script's message
; loop: the process stays alive but every hotkey goes dead and the keys fall
; through to the focused app. Errors are logged instead, never shown.
; Log: %TEMP%\AudioHotkeys.log

LogFile := A_Temp "\AudioHotkeys.log"

Log(msg) {
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LogFile)
}

LogError(err, mode) {
    Log("ERROR [" mode "] " err.Message "   (" err.File ":" err.Line ")")
    if err.Stack
        Log(err.Stack)
    return 1
}

OnError LogError

; Format an HRESULT the way the Windows SDK spells it. AHK numbers are 64-bit,
; so mask first: 0x80070057, not 0xffffffff80070057.
HrText(hr) => Format("0x{:08X}", hr & 0xFFFFFFFF)

;------------------------- Core Audio ------------------------

; 16-byte buffer holding the CLSID/IID named by `s`.
GUID(s) {
    b := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", s, "ptr", b, "int")
        throw Error("CLSIDFromString failed: " s)
    return b
}

; COM vtable helpers: VT(p, n) is method n's address; Rel calls Release.
VT(p, i) => NumGet(NumGet(p, "ptr") + i * A_PtrSize, "ptr")
Rel(p) => DllCall(VT(p, 2), "ptr", p)

; Resolves the *current* default endpoint on every call on purpose: that is
; what makes a headset swap take effect without restarting the script.
ActivateEndpoint(flow) {
    static pEnum := GUID("{BCDE0395-E52F-467C-8E3D-C4579291692E}")
    static pIID  := GUID("{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    static pEPV  := GUID("{5CDF2C82-841E-4546-9722-0CF74078229A}")

    ; CoCreateInstance(MMDeviceEnumerator, CLSCTX_INPROC_SERVER).
    enum := 0
    hr := DllCall("ole32\CoCreateInstance", "ptr", pEnum, "ptr", 0, "uint", 1
                , "ptr", pIID, "ptr*", &enum, "int")
    if (hr != 0)
        throw Error("CoCreateInstance failed (" HrText(hr) ")")

    ; GetDefaultAudioEndpoint(flow, eConsole).
    dev := 0
    hr := DllCall(VT(enum, 4), "ptr", enum, "int", flow, "int", 0, "ptr*", &dev, "int")
    Rel(enum)
    if (hr != 0)
        throw Error("no default audio endpoint (" HrText(hr) ")")

    ; IMMDevice::Activate(IID_IAudioEndpointVolume).
    epv := 0
    hr := DllCall(VT(dev, 3), "ptr", dev, "ptr", pEPV, "uint", 1, "ptr", 0, "ptr*", &epv, "int")
    Rel(dev)
    if (hr != 0)
        throw Error("IAudioEndpointVolume unavailable (" HrText(hr) ")")
    return epv
}

GetMute(flow) {
    epv := ActivateEndpoint(flow)
    m := 0
    hr := DllCall(VT(epv, 15), "ptr", epv, "int*", &m)
    Rel(epv)
    if (hr != 0)
        throw Error("GetMute failed (" HrText(hr) ")")
    return m
}

SetMute(flow, mute) {
    epv := ActivateEndpoint(flow)
    hr := DllCall(VT(epv, 14), "ptr", epv, "int", mute ? 1 : 0, "int")
    Rel(epv)
    if (hr != 0)
        throw Error("SetMute failed (" HrText(hr) ")")
}

; Flip the device and return the state it actually ended up in. One endpoint
; activation per press: read, set and verify on that same object.
ToggleMute(flow) {
    epv := ActivateEndpoint(flow)
    m := 0
    hr := DllCall(VT(epv, 15), "ptr", epv, "int*", &m)
    if (hr = 0)
        hr := DllCall(VT(epv, 14), "ptr", epv, "int", m ? 0 : 1, "int")
    if (hr = 0)
        hr := DllCall(VT(epv, 15), "ptr", epv, "int*", &m)
    Rel(epv)
    if (hr != 0)
        throw Error("mute toggle failed (" HrText(hr) ")")
    return m
}

;-------------------------- The HUD ---------------------------
;  Small rounded panel, top-right of the primary screen.
;  Fades in, holds ~1s, fades out. Never takes focus.

class Hud {
    static gui := 0
    static icon := 0
    static title := 0
    static phase := ""
    static t0 := 0
    static W := 168, H := 40, M := 24, Top := 56, Radius := 12
    static HoldMs := 950
    static FadeInMs := 140
    static FadeOutMs := 220
    static MaxAlpha := 242
    static tickFn := 0

    static Build() {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale", "AudioHud")
        g.BackColor := "1C1C1E"
        g.SetFont("s12", "Segoe MDL2 Assets")
        this.icon := g.AddText("x10 y7 w24 h26 BackgroundTrans", "")
        g.SetFont("s9 bold", "Segoe UI")
        this.title := g.AddText("x38 y10 w122 h20 BackgroundTrans", "")
        this.gui := g
    }

    static Show(glyph, text, color) {
        if !this.gui
            this.Build()
        this.icon.SetFont("c" color)
        this.icon.Text := glyph
        this.title.SetFont("cEEEEEE")
        this.title.Text := text

        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        this.gui.Show("NA x" (r - this.W - this.M) " y" (t + this.Top) " w" this.W " h" this.H)
        this.ApplyRegion()
        WinSetTransparent(0, this.gui)
        this.phase := "in"
        this.t0 := A_TickCount
        if !this.tickFn
            this.tickFn := this.Tick.Bind(this)
        SetTimer(this.tickFn, 15)
    }

    static ApplyRegion() {
        h := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", this.W + 1
                    , "int", this.H + 1, "int", this.Radius, "int", this.Radius, "ptr")
        DllCall("user32\SetWindowRgn", "ptr", this.gui.Hwnd, "ptr", h, "int", 1)
    }

    static Tick() {
        elapsed := A_TickCount - this.t0
        switch this.phase {
            case "in":
                alpha := Round(Min(this.MaxAlpha, elapsed * this.MaxAlpha / this.FadeInMs))
                WinSetTransparent(alpha, this.gui)
                if (elapsed >= this.FadeInMs) {
                    this.phase := "hold"
                    this.t0 := A_TickCount
                }
            case "hold":
                if (elapsed >= this.HoldMs) {
                    this.phase := "out"
                    this.t0 := A_TickCount
                }
            case "out":
                alpha := Round(Max(0, this.MaxAlpha - elapsed * this.MaxAlpha / this.FadeOutMs))
                WinSetTransparent(alpha, this.gui)
                if (elapsed >= this.FadeOutMs) {
                    SetTimer(this.tickFn, 0)
                    this.gui.Hide()
                    WinSetTransparent(255, this.gui)
                    this.phase := ""
                }
        }
    }
}

;------------------------- Actions ----------------------------

; The toast, or nothing, depending on the two per-feature switches.
Announce(d, conf, muted) {
    if (muted ? !conf.toastMuted : !conf.toastLive)
        return
    Hud.Show(muted ? d.glyphMuted : d.glyphLive
           , d.label (muted ? " muted" : " live")
           , muted ? "FF4B4B" : d.liveColor)
}

; Bound to each hotkey and tray item with its feature name fixed in.
ToggleDevice(name, *) {
    try {
        if Debug
            Log(name " toggle")
        if !DEVICES.Has(name)
            throw Error("DEVICES has no entry for " name)
        if !CONFIG.Has(name)
            throw Error("CONFIG has no entry for " name)
        d := DEVICES[name]
        Announce(d, CONFIG[name], ToggleMute(d.flow))
    } catch as e {
        LogError(e, name " toggle")
    }
}

;------------------------- Interface --------------------------

BuildMenu() {
    m := A_TrayMenu
    m.Delete()
    first := ""
    for name, d in DEVICES {
        if !CONFIG.Has(name) {
            Log("menu: CONFIG has no entry for " name)
            continue
        }
        conf := CONFIG[name]
        suffix := ""
        if !conf.enabled
            suffix := "   [hotkey off]"
        else if d.HasProp("registered") && !d.registered
            suffix := "   [hotkey unavailable - see log]"
        item := "Toggle " d.label "  (" d.keyLabel ")" suffix
        m.Add(item, ToggleDevice.Bind(name))
        if (first = "")
            first := item
    }
    m.Add()
    m.Add("Reload script", (*) => Reload())
    m.Add("Edit script", (*) => Run(A_ScriptFullPath))
    m.Add("Open folder", (*) => Run(A_ScriptDir))
    m.Add("Open log", (*) => OpenLog())
    m.Add()
    m.Add("Exit", (*) => ExitApp())
    if (first != "")
        m.Default := first
}

OpenLog() {
    try {
        FileAppend("", LogFile)   ; create it even before the first event
        Run(LogFile)
    } catch as e {
        TrayTip("Could not open " LogFile "`n" e.Message, "Audio Hotkeys", "Icon!")
    }
}

; Registers exactly the hotkeys CONFIG allows. A disabled feature registers
; nothing, so its key keeps working as an ordinary keystroke elsewhere.
ApplyConfig() {
    summary := "config "
    for name, d in DEVICES {
        if !CONFIG.Has(name) {
            Log("config: CONFIG has no entry for " name)
            continue
        }
        conf := CONFIG[name]
        status := "off"
        d.registered := false
        if conf.enabled {
            try {
                Hotkey(d.key, ToggleDevice.Bind(name))
                d.registered := true
                status := d.key
            } catch as e {
                status := "FAILED"
                Log("hotkey " d.key " for " name " FAILED: " e.Message)
            }
        }
        summary .= Format("{}={} toast(muted={},live={})  "
            , name, status
            , conf.toastMuted ? "on" : "off"
            , conf.toastLive ? "on" : "off")
    }
    Log(summary)
    for name in CONFIG
        if !DEVICES.Has(name)
            Log("config: unused CONFIG entry " name)
}

;------------------------- Startup ----------------------------
; Remember where the devices started, so a reload or an exit can put them
; back and the script can never leave you muted by accident. Restore writes
; to whatever device is default at that moment, exactly like the toggles.
for name, d in DEVICES {
    try d.start := GetMute(d.flow)
    catch as e {
        d.start := 0
        Log("no default device for " name " at startup: " e.Message)
    }
}

OnExit Restore

Restore(*) {
    for name, d in DEVICES {
        try SetMute(d.flow, d.start)
        catch as e
            LogError(e, "restore " name)
    }
}

Log(Format("started  admin={}  debug={}  exe={}", A_IsAdmin, Debug, A_AhkPath))
ApplyConfig()
BuildMenu()   ; after ApplyConfig, so a failed registration shows in the menu

if A_IsAdmin
    A_IconTip := "Audio Hotkeys - elevated (hotkeys also work over admin windows)"
else
    A_IconTip := "Audio Hotkeys - hotkeys skip admin windows (optional fix in README)"
