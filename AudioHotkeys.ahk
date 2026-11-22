#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

;=============================================================
;  Audio Hotkeys  —  global mic / speaker mute toggles
;-------------------------------------------------------------
;  Default keys:   Numpad-  microphone mute toggle
;                  Numpad*  speakers mute toggle
;
;  Edit the "HOTKEYS" block at the bottom to rebind anything.
;  Everything else can stay as-is.
;
;  Controls the default capture / render device through the
;  Windows Core Audio API (IAudioEndpointVolume). No drivers,
;  no extra binaries, no admin rights needed for audio.
;  See README.md for install, autostart and rebinding.
;=============================================================

;------------------------- CONFIG -----------------------------
; One entry per feature. Nothing else in the file needs touching to
; switch a feature off or to silence it.
;
;   enabled : is the hotkey live?
;             true  -> the key is captured and toggles the device
;             false -> the key is NOT captured at all; it reaches the
;                      focused app as a normal keystroke. The tray menu
;                      item still works, so the feature stays reachable.
;
;   toastMuted : show the confirmation when the device becomes MUTED
;   toastLive  : show the confirmation when the device becomes LIVE
;             Setting one of them false keeps the other, so you can be
;             warned that you went silent without being told you came back.
;             `vol` has no muted/live split, so it just has `toast`.
;
; After editing, use "Reload script" in the tray menu.

CFG := {
    mic:  { enabled: true, toastMuted: true,  toastLive: true  },   ; Numpad-  microphone
    spk:  { enabled: true, toastMuted: true,  toastLive: true  },   ; Numpad*  speakers
}

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

OnError(LogError)

;------------------------- Core Audio ------------------------

GUID(s) {
    b := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "wstr", s, "ptr", b, "int")
        throw Error("CLSIDFromString failed: " s)
    return b
}
VT(p, i) => NumGet(NumGet(p, "ptr") + i * A_PtrSize, "ptr")
Rel(p) => DllCall(VT(p, 2), "ptr", p)

; flow: 0 = render (speakers), 1 = capture (mic). role: 0 = console.
ActivateEndpoint(flow) {
    static CLSID_MMDeviceEnumerator := "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
    static IID_IMMDeviceEnumerator  := "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
    static IID_IAudioEndpointVolume := "{5CDF2C82-841E-4546-9722-0CF74078229A}"

    enum := 0
    hr := DllCall("ole32\CoCreateInstance", "ptr", GUID(CLSID_MMDeviceEnumerator), "ptr", 0
                , "uint", 1, "ptr", GUID(IID_IMMDeviceEnumerator), "ptr*", &enum, "int")
    if (hr != 0)
        throw Error("CoCreateInstance failed (" hr ")")

    dev := 0
    hr := DllCall(VT(enum, 4), "ptr", enum, "int", flow, "int", 0, "ptr*", &dev, "int")
    Rel(enum)
    if (hr != 0)
        throw Error("No default audio endpoint (" Format("{:#x}", hr) ")")

    epv := 0
    hr := DllCall(VT(dev, 3), "ptr", dev, "ptr", GUID(IID_IAudioEndpointVolume)
                , "uint", 1, "ptr", 0, "ptr*", &epv, "int")
    Rel(dev)
    if (hr != 0)
        throw Error("IAudioEndpointVolume unavailable (" Format("{:#x}", hr) ")")
    return epv
}

GetMute(flow) {
    epv := ActivateEndpoint(flow)
    m := 0
    DllCall(VT(epv, 15), "ptr", epv, "int*", &m)
    Rel(epv)
    return m
}

SetMute(flow, mute) {
    epv := ActivateEndpoint(flow)
    hr := DllCall(VT(epv, 14), "ptr", epv, "int", mute ? 1 : 0, "int")
    Rel(epv)
    return hr = 0
}

;-------------------------- The HUD ---------------------------
;  Small rounded panel, top-right of the primary screen.
;  Fades in, holds ~1s, fades out. Never takes focus.

class Hud {
    static gui := 0
    static iconCtl := 0
    static titleCtl := 0
    static subCtl := 0
    static alpha := 0
    static phase := ""
    static t0 := 0
    static W := 168, H := 40, M := 24, Top := 56
    static HoldMs := 950
    static timer := 0

    static Build() {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000 -DPIScale", "AudioHud")
        g.BackColor := "1C1C1E"
        g.SetFont("s12", "Segoe MDL2 Assets")
        this.iconCtl := g.AddText("x10 y7 w24 h26 BackgroundTrans", "")
        g.SetFont("s9 bold", "Segoe UI")
        this.titleCtl := g.AddText("x38 y10 w122 h20 BackgroundTrans", "")
        g.SetFont("s8 norm", "Segoe UI")
        this.subCtl := g.AddText("x38 y30 w122 h12 BackgroundTrans", "")
        this.gui := g
    }

    static Show(glyph, title, sub, color, subColor := "9A9A9F") {
        if !this.gui
            this.Build()
        this.iconCtl.SetFont("c" color)
        this.iconCtl.Text := glyph
        this.titleCtl.SetFont("cEEEEEE")
        this.titleCtl.Text := title
        this.subCtl.SetFont("c" subColor)
        this.subCtl.Text := sub

        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        this.gui.Show("NA x" (r - this.W - this.M) " y" (t + this.Top) " w" this.W " h" this.H)
        this.Round(windowHwnd(this.gui))
        this.alpha := 0
        this.phase := "in"
        this.t0 := A_TickCount
        WinSetTransparent(0, this.gui)
        if !this.timer
            this.timer := this.Tick.Bind(this)
        SetTimer(this.timer, 15)
    }

    static Round(hwnd) {
        h := DllCall("gdi32\CreateRoundRectRgn", "int", 0, "int", 0, "int", this.W + 1
                    , "int", this.H + 1, "int", 12, "int", 12, "ptr")
        DllCall("user32\SetWindowRgn", "ptr", hwnd, "ptr", h, "int", 1)
    }

    static Tick() {
        elapsed := A_TickCount - this.t0
        switch this.phase {
            case "in":
                a := Min(242, elapsed * 242 / 140)
                WinSetTransparent(Round(a), this.gui)
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
                a := Max(0, 242 - elapsed * 242 / 220)
                WinSetTransparent(Round(a), this.gui)
                if (elapsed >= 220) {
                    SetTimer(this.timer, 0)
                    this.gui.Hide()
                    WinSetTransparent(255, this.gui)
                    this.phase := ""
                }
        }
    }
}

windowHwnd(g) => g.Hwnd

;------------------------- State ------------------------------

MicState() => GetMute(1)
SpkState() => GetMute(0)

AnnounceMic() {
    muted := MicState()
    if (muted ? !CFG.mic.toastMuted : !CFG.mic.toastLive)
        return
    if (muted)
        Hud.Show(Chr(0xE720), "Microphone muted", "", "FF4B4B")
    else
        Hud.Show(Chr(0xE720), "Microphone live", "", "4CC26A")
}

AnnounceSpk() {
    muted := SpkState()
    if (muted ? !CFG.spk.toastMuted : !CFG.spk.toastLive)
        return
    if (muted)
        Hud.Show(Chr(0xE74F), "Speakers muted", "", "FF4B4B")
    else
        Hud.Show(Chr(0xE767), "Speakers live", "", "EEEEEE")
}

;------------------------- Actions ----------------------------

; Every action is defensive: a thrown error used to raise a modal dialog from
; inside a hotkey thread, which blocks the script's message loop — the process
; stays alive but every hotkey stops working and the keys fall through to the
; focused app. Errors are logged instead, and never shown.
ToggleMic() {
    try {
        Log("mic toggle")
        SetMute(1, !MicState())
        AnnounceMic()
    } catch as e {
        Log("mic toggle FAILED: " e.Message " @ " e.Line)
    }
}
ToggleSpk() {
    try {
        Log("spk toggle")
        SetMute(0, !SpkState())
        AnnounceSpk()
    } catch as e {
        Log("spk toggle FAILED: " e.Message " @ " e.Line)
    }
}
;------------------------- Exit safety ------------------------
;  On reload/exit, put both devices back the way they were found,
;  so the script can never leave you muted by accident.

; Slurp the starting state, but never let a missing/disabled device abort startup.
try StartMic := GetMute(1)
catch {
    StartMic := 0
    Log("no default microphone at startup")
}
try StartSpk := GetMute(0)
catch {
    StartSpk := 0
    Log("no default output device at startup")
}

OnExit(Restore)

Restore(*) {
    try SetMute(1, StartMic)
    try SetMute(0, StartSpk)
}

;------------------------- Tray menu --------------------------

BuildMenu() {
    Front := A_TrayMenu
    Front.Delete()
    MicItem := "Toggle microphone  (Numpad-)" (CFG.mic.enabled ? "" : "  [hotkey off]")
    Front.Add(MicItem, (*) => ToggleMic())
    Front.Add("Toggle speakers  (Numpad*)" (CFG.spk.enabled ? "" : "  [hotkey off]"), (*) => ToggleSpk())
    Front.Add()
    Front.Add("Reload script", (*) => Reload())
    Front.Add("Edit script", (*) => Run(A_ScriptFullPath))
    Front.Add("Open folder", (*) => Run(A_ScriptDir))
    Front.Add()
    Front.Add("Exit", (*) => ExitApp())
    Front.Default := MicItem
}
try BuildMenu()

Log("started  admin=" A_IsAdmin "  exe=" A_AhkPath)

; Elevation is optional and only affects whether hotkeys fire while an
; administrator window has focus. Muting works in either case.
if A_IsAdmin
    A_IconTip := "Audio Hotkeys - elevated (hotkeys also work over admin windows)"
else
    A_IconTip := "Audio Hotkeys - hotkeys skip admin windows (optional fix in README)"

;------------------------- HOTKEYS ----------------------------
;  Toggles only, single keys, no modifiers:
;    Numpad-  (NumpadSub)  -> microphone mute toggle
;    Numpad*  (NumpadMult) -> speakers mute toggle
;  ^ = Ctrl  ! = Alt  + = Shift  # = Win, if you ever want combos.

NumpadSub::SetTimer(ToggleMic, -1)
NumpadMult::SetTimer(ToggleSpk, -1)

;------------------------- Apply CONFIG -----------------------
; A feature with enabled = false hands its key back to Windows: the key is
; not captured, so it reaches the focused app like any other keystroke.
ApplyConfig()

ApplyConfig() {
    Log("config  mic=" (CFG.mic.enabled ? "hotkey" : "no-hotkey")
        . " toast(muted=" (CFG.mic.toastMuted ? "on" : "off") ",live=" (CFG.mic.toastLive ? "on" : "off") ")"
        . " | spk=" (CFG.spk.enabled ? "hotkey" : "no-hotkey")
        . " toast(muted=" (CFG.spk.toastMuted ? "on" : "off") ",live=" (CFG.spk.toastLive ? "on" : "off") ")")
    for key, on in Map(
        "NumpadSub",  CFG.mic.enabled,
        "NumpadMult", CFG.spk.enabled
    )
        try Hotkey(key, on ? "On" : "Off")
}
