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
;  everything that switches them on, off or quiet lives in CFG.
;  Edit one of those two tables and the hotkey, the tray item, the
;  startup log and the toast all follow.
;
;  Muting uses the Windows Core Audio API. No drivers, no extra
;  binaries, no admin rights needed for audio.
;  See README.md for install, autostart and rebinding.
;=============================================================

;------------------------- SETTINGS ---------------------------
; Debug: log every keypress, not just startup and failures.
Debug := false

; CFG: one entry per feature, keyed by the same name used in DEVICES.
;
;   enabled    : is the hotkey live?  false = the key is not captured at
;                all, so it reaches the focused app as a normal keystroke.
;                The tray item still works, so the feature stays reachable.
;   toastMuted : show the toast when the device becomes muted
;   toastLive  : show the toast when the device becomes live
;                Independent of each other: warn on silence, stay quiet
;                when sound comes back.
CFG := Map(
    "mic", { enabled: true, toastMuted: true, toastLive: true },
    "spk", { enabled: true, toastMuted: true, toastLive: true }
)

; DEVICES: the per-feature facts. `flow` is the Core Audio data flow —
; 1 = capture (microphone), 0 = render (speakers) — and `key` is its
; hotkey. `hint` is the human spelling shown in the tray menu.
DEV := Map()
DEV["mic"] := { flow: 1, key: "NumpadSub", hint: "Numpad-"
              , label: "Microphone", live: "4CC26A"
              , glyphMuted: Chr(0xE720), glyphLive: Chr(0xE720) }
DEV["spk"] := { flow: 0, key: "NumpadMult", hint: "Numpad*"
              , label: "Speakers", live: "EEEEEE"
              , glyphMuted: Chr(0xE74F), glyphLive: Chr(0xE767) }

;------------------------- Diagnostics ------------------------
; A modal error dialog raised from a hotkey thread blocks the script's message
; loop: the process stays alive but every hotkey goes dead and the keys fall
; through to the focused app. Errors are logged instead, never shown.
; Log: %TEMP%\AudioHotkeys.log

LogFile := A_Temp "\AudioHotkeys.log"

Log(msg) {
    global LogFile
    try FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", LogFile)
}

LogError(err, mode) {
    Log("ERROR [" mode "] " err.Message "   (" err.File ":" err.Line ")")
    return 1
}

OnError LogError

;------------------------- Core Audio ------------------------

GUID(s) {
    b := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", s, "ptr", b, "int")
        throw Error("CLSIDFromString failed: " s)
    return b
}

VT(p, i) => NumGet(NumGet(p, "ptr") + i * A_PtrSize, "ptr")
Rel(p) => DllCall(VT(p, 2), "ptr", p)

; Resolves the *current* default endpoint on every call on purpose: that is
; what makes a headset swap take effect without restarting the script.
ActivateEndpoint(flow) {
    static pEnum := GUID("{BCDE0395-E52F-467C-8E3D-C4579291692E}")
    static pIID  := GUID("{A95664D2-9614-4F35-A746-DE8DB63617E6}")
    static pEPV  := GUID("{5CDF2C82-841E-4546-9722-0CF74078229A}")

    enum := 0
    hr := DllCall("ole32\CoCreateInstance", "ptr", pEnum, "ptr", 0, "uint", 1
                , "ptr", pIID, "ptr*", &enum, "int")
    if (hr != 0)
        throw Error("CoCreateInstance failed (" Format("{:#x}", hr) ")")

    dev := 0
    hr := DllCall(VT(enum, 4), "ptr", enum, "int", flow, "int", 0, "ptr*", &dev, "int")
    Rel(enum)
    if (hr != 0)
        throw Error("no default audio endpoint (" Format("{:#x}", hr) ")")

    epv := 0
    hr := DllCall(VT(dev, 3), "ptr", dev, "ptr", pEPV, "uint", 1, "ptr", 0, "ptr*", &epv, "int")
    Rel(dev)
    if (hr != 0)
        throw Error("IAudioEndpointVolume unavailable (" Format("{:#x}", hr) ")")
    return epv
}

GetMute(flow) {
    epv := ActivateEndpoint(flow)
    m := 0
    hr := DllCall(VT(epv, 15), "ptr", epv, "int*", &m)
    Rel(epv)
    if (hr != 0)
        throw Error("GetMute failed (" Format("{:#x}", hr) ")")
    return m
}

SetMute(flow, mute) {
    epv := ActivateEndpoint(flow)
    hr := DllCall(VT(epv, 14), "ptr", epv, "int", mute ? 1 : 0, "int")
    Rel(epv)
    if (hr != 0)
        throw Error("SetMute failed (" Format("{:#x}", hr) ")")
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
        throw Error("mute toggle failed (" Format("{:#x}", hr) ")")
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
    static W := 168, H := 40, M := 24, Top := 56
    static HoldMs := 950
    static timer := 0

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
        this.phase := "in"
        this.t0 := A_TickCount
        WinSetTransparent(0, this.gui)
        if !this.timer
            this.timer := this.Tick.Bind(this)
        SetTimer(this.timer, 15)
    }

    static ApplyRegion() {
        h := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", this.W + 1
                    , "int", this.H + 1, "int", 12, "int", 12, "ptr")
        DllCall("user32\SetWindowRgn", "ptr", this.gui.Hwnd, "ptr", h, "int", 1)
    }

    static Tick() {
        elapsed := A_TickCount - this.t0
        switch this.phase {
            case "in":
                WinSetTransparent(Round(Min(242, elapsed * 242 / 140)), this.gui)
                if (elapsed >= 140) {
                    this.phase := "hold"
                    this.t0 := A_TickCount
                }
            case "hold":
                if (elapsed >= this.HoldMs) {
                    this.phase := "out"
                    this.t0 := A_TickCount
                }
            case "out":
                WinSetTransparent(Round(Max(0, 242 - elapsed * 242 / 220)), this.gui)
                if (elapsed >= 220) {
                    SetTimer(this.timer, 0)
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
           , muted ? "FF4B4B" : d.live)
}

; Bound to each hotkey and tray item with its feature name fixed in.
ToggleDevice(name, *) {
    global Debug, DEV, CFG
    try {
        if Debug
            Log(name " toggle")
        d := DEV[name]
        Announce(d, CFG[name], ToggleMute(d.flow))
    } catch as e {
        Log(name " toggle FAILED: " e.Message " @ " e.Line)
    }
}

;------------------------- Interface --------------------------

BuildMenu() {
    global DEV, CFG
    m := A_TrayMenu
    m.Delete()
    first := ""
    for name, d in DEV {
        item := "Toggle " d.label "  (" d.hint ")"
              . (CFG[name].enabled ? "" : "   [hotkey off]")
        m.Add(item, ToggleDevice.Bind(name))
        if (first = "")
            first := item
    }
    m.Add()
    m.Add("Reload script", (*) => Reload())
    m.Add("Edit script", (*) => Run(A_ScriptFullPath))
    m.Add("Open folder", (*) => Run(A_ScriptDir))
    m.Add()
    m.Add("Exit", (*) => ExitApp())
    m.Default := first
}

; Registers exactly the hotkeys CFG allows. A disabled feature registers
; nothing, so its key keeps working as an ordinary keystroke elsewhere.
ApplyConfig() {
    global DEV, CFG
    summary := "config "
    for name, d in DEV {
        conf := CFG[name]
        if conf.enabled
            try Hotkey(d.key, ToggleDevice.Bind(name))
        summary .= name "=" (conf.enabled ? d.key : "off")
                  . " toast(muted=" (conf.toastMuted ? "on" : "off")
                  . ",live=" (conf.toastLive ? "on" : "off") ")  "
    }
    Log(summary)
}

;------------------------- Startup ----------------------------
; Remember where the devices started, so a reload or an exit can put them
; back and the script can never leave you muted by accident.
for name, d in DEV {
    try d.start := GetMute(d.flow)
    catch {
        d.start := 0
        Log("no default device for " name " at startup")
    }
}

OnExit Restore

Restore(*) {
    global DEV
    for name, d in DEV
        try SetMute(d.flow, d.start)
}

BuildMenu()
ApplyConfig()

Log("started  admin=" A_IsAdmin "  exe=" A_AhkPath)
if A_IsAdmin
    A_IconTip := "Audio Hotkeys - elevated (hotkeys also work over admin windows)"
else
    A_IconTip := "Audio Hotkeys - hotkeys skip admin windows (optional fix in README)"
