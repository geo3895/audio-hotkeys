# Audio Hotkeys

Global microphone and speaker mute hotkeys for Windows, in one AutoHotkey v2
script. Press a key anywhere — game, browser, Teams, Discord, a full-screen app —
and the default device flips between muted and live, with a small confirmation
toast in the top-right corner.

It exists because PowerToys retired the "Conference mute" module, which was the
one thing many people used it for.

## Features

- **Default devices, automatically.** Always targets whatever Windows currently
  uses as the default microphone and default speakers, so plugging in a USB
  headset, a webcam mic or desk speakers needs no configuration.
- **No drivers, services or virtual devices.** Muting goes through the Windows
  Core Audio API (`IAudioEndpointVolume`) directly.
- **Visible confirmation.** A rounded, non-activating toast in the top-right
  corner says whether the device is muted or live. A global hotkey otherwise
  gives no feedback at all.
- **Suppresses the key.** A matched hotkey never reaches the focused app.
- **Safe on exit.** The mute states found at startup are restored when the
  script reloads or exits, so it cannot leave you silently muted.
- **Two files.** One `.ahk` script and this README; no build step.

## Requirements

- Windows 10 or 11
- [AutoHotkey v2](https://www.autohotkey.com/) (v2.0 or newer — the script
  declares `#Requires AutoHotkey v2.0` and will not run on v1)

## Install

1. Install AutoHotkey v2.
2. Put `AudioHotkeys.ahk` somewhere permanent, e.g. `%USERPROFILE%\audio-hotkeys\`.
3. Double-click it. A tray icon appears and the hotkeys are live immediately.

Autostart is optional — see [Start with Windows](#start-with-windows).

## Usage

| Key | Action |
| --- | ------ |
| `Numpad-` | Microphone: toggle mute |
| `Numpad*` | Speakers: toggle mute |

Both are single presses with no modifiers and are unaffected by NumLock.

Right-click the tray icon for the same two actions plus **Reload script**,
**Edit script**, **Open folder** and **Exit**.

The script logs every press and any error to `%TEMP%\AudioHotkeys.log`, which is
the first place to look when something misbehaves.

## Turning features off, and their notifications

Two tables at the top of the script control everything. `CFG` switches features
on, off and quiet:

```ahk
CFG := Map(
    "mic", { enabled: true, toastMuted: true, toastLive: true },
    "spk", { enabled: true, toastMuted: true, toastLive: true }
)
```

| Field | `true` | `false` |
| ----- | ------ | ------- |
| `enabled` | the hotkey is live | the key is **not captured at all** — it reaches the focused app like any other keystroke, so `Numpad-` types `-` again. The tray item still works, so the feature stays reachable. |
| `toastMuted` | show the panel when the device goes **muted** | stay silent on the way into mute |
| `toastLive` | show the panel when the device goes **live** | stay silent on the way out of mute |

The two toast flags are independent, so a feature can warn you in one direction
only — being told "you are muted now" matters a lot more than being told "you
are audible again".

**Recipes** — replace the whole `CFG := Map( … )` with one of these:

```ahk
; warn me when the mic goes muted, stay quiet when it comes back
CFG := Map(
    "mic", { enabled: true, toastMuted: true, toastLive: false },
    "spk", { enabled: true, toastMuted: true, toastLive: true }
)

; hand Numpad* back to other applications, keep the mic hotkey
CFG := Map(
    "mic", { enabled: true,  toastMuted: true, toastLive: true },
    "spk", { enabled: false, toastMuted: true, toastLive: true }
)

; run entirely silently
CFG := Map(
    "mic", { enabled: true, toastMuted: false, toastLive: false },
    "spk", { enabled: true, toastMuted: false, toastLive: false }
)
```

Apply with **Reload script** in the tray menu (or restart the script). To confirm
what took effect, read the last `config …` line in `%TEMP%\AudioHotkeys.log`,
written on every start — a disabled feature shows `off` instead of a key:

```
config mic=NumpadSub toast(muted=on,live=on)  spk=off toast(muted=on,live=on)
```

## Changing the keys

The keys live in the `DEV` table, next to everything else that differs between
the two features:

```ahk
DEV := Map()
DEV["mic"] := { flow: 1, key: "NumpadSub", hint: "Numpad-"
              , label: "Microphone", live: "4CC26A"
              , glyphMuted: Chr(0xE720), glyphLive: Chr(0xE720) }
```

Change `key` and, if you like, `hint` (the spelling shown in the tray menu):

```ahk
key: "F13"        ; a dedicated keyboard/mouse macro key
key: "XButton1"   ; mouse side button
key: "^!m"        ; Ctrl+Alt+M  (^ Ctrl, ! Alt, + Shift, # Win)
key: "!s"         ; Alt+S
```

Save, then choose **Reload script** in the tray menu. Key names are in the
[AutoHotkey key list](https://www.autohotkey.com/docs/v2/KeyList.htm);
`NumpadSub` is the keypad's `-`, `NumpadMult` its `*`.

Because the same table feeds the hotkey, the tray label and the `enabled`
switch, a rebind cannot fall out of step with them — there is only one place
the key is written.

### If a new key does nothing

Some combinations are registered by other software through Windows'
`RegisterHotKey` and never reach AutoHotkey's keyboard hook — the script then
looks fine and simply never fires. Display drivers commonly take
`Ctrl+Alt+↑/↓/←/→`; system utilities, IMEs, GPU panels, headset software and
some Electron apps take others.

Test a candidate by binding it, reloading and pressing it. If no toast appears,
something else owns it — pick another. Bare keys (`Numpad-`, `Numpad*`, `F13`,
mouse side buttons) almost never collide.

## Start with Windows

Two options; they differ only in whether the hotkeys also work while an
**administrator** window has focus.

### Logon task (elevated)

Covers everything, including elevated windows. Windows blocks a non-elevated
program from seeing input aimed at an elevated one — AutoHotkey's
[UAC FAQ](https://www.autohotkey.com/docs/v2/FAQ.htm) puts it plainly: "Hotkeys
are also blocked, so for instance, a non-elevated program cannot spy on input
intended for an elevated program."

Creating the task needs administrator rights **once** (`schtasks /Create … /RL
HIGHEST` from a normal prompt fails with *Access is denied*); afterwards it starts
elevated at login with no prompt.

```bat
schtasks /Create /TN "Audio Hotkeys" ^
  /TR "\"%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe\" \"%USERPROFILE%\audio-hotkeys\AudioHotkeys.ahk\"" ^
  /SC ONLOGON /RL HIGHEST /F
```

Remove it with `schtasks /Delete /TN "Audio Hotkeys" /F`.

Trade-off: the script runs with an administrator token, so anything it launches
from the tray menu inherits that token too.

### Startup shortcut (no admin)

Lighter, but its hotkeys are ignored while an admin window is focused.

1. `Win+R` → `shell:startup` → Enter.
2. Right-click → **New → Shortcut**, and use:

   ```
   "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" "%USERPROFILE%\audio-hotkeys\AudioHotkeys.ahk"
   ```

Delete the shortcut to undo it. Use one or the other, not both — two copies fight
over the same keys.

## Troubleshooting

| Symptom | Likely cause |
| ------- | ------------ |
| Key does nothing, no toast, nothing in the log | Another program owns the combo, or the script isn't running (check the tray icon). |
| Key types `-`/`*` into the app instead of muting | The hotkey was not active at that instant: script not running, an admin window has focus, or another app owns the key. A matched hotkey is always suppressed. |
| Toast appears but the device doesn't change | Check `%TEMP%\AudioHotkeys.log` for an `ERROR` line; the audio call failed. |
| Nothing works while an admin window is focused | Expected without the elevated logon task above. |
| Wrong device muted | It follows the Windows *default* device — change that in Settings → System → Sound. |
| Two tray icons | Two copies running; remove one autostart method. |

If the keys stop responding while the tray icon is still there, choose **Reload
script**; the log will show whether presses were arriving before that.

## How it works

- `CoCreateInstance(MMDeviceEnumerator)` → `GetDefaultAudioEndpoint(flow,
  eConsole)` → `Activate(IID_IAudioEndpointVolume)` → `SetMute` / `GetMute`,
  where `flow` is `0` for render (speakers) and `1` for capture (microphone).
- The endpoint is resolved on every press, which is why headset swaps are picked
  up without configuration.
- The toast is a borderless, non-activating, always-on-top layered window placed
  in the top-right of the primary monitor's work area, with a rounded window
  region. It fades in, holds about a second, then fades out.
- Errors are caught and logged instead of raising a modal dialog, because a
  dialog raised from a hotkey thread blocks the script's message loop and every
  hotkey goes dead while the process still looks healthy.
