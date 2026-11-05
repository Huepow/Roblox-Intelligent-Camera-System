# Changelog

## v10.0 "CHROME" (ICS2K)

A ground-up rewrite of the V9.4 camera. Same install, new everything.

### Modes
- Removed **ELASTIC** (the old mode 1). STANDARD now goes straight to FREE, as requested.
- **FREE** rebuilt: exponential spring zoom from 1° to 120° (was capped around 4.6x), sensitivity and speed scale with zoom, inertial flight with sliding collision, roll with auto-level and Z to level, mouse-lock toggle (M), speed-FOV, autofocus, bookmarks (B / G / N) with world markers, dolly rail (K / L / J) with Catmull-Rom playback and beams.
- **CINEMATIC** rebuilt as a director: 11 shot types, context scoring (moving / idle / indoors / group), line-of-sight rejection, cut-or-glide transitions driven by an energy setting, handheld micro-motion, hold (H), subject switching (P) with glide.
- New **PAPARAZZI** iPhone mode: 3D phone with a live lockscreen, third person raise + fly-into-screen intro, full screen lockscreen with the avatar cropped to the waist on a low-saturation gradient, front camera selfie POV, arm aiming, zoom chips, tap to focus, flash / torch, flip to back camera, shutter with capture, gallery with save / share / delete.
- New **TIKTOK STUDIO** mode: a ring light tripod with an iPhone 18 Pro Max assembles in front of you, your avatar auto-walks to a floor mark, the camera flies into the phone and you perform through its front camera. Smart buttons for ring light level and colour, wide angle, auto zoom pulses, center stage auto-framing, filters, timer, manual zoom, an emote strip, and clip recording (frame bursts saved as one gallery clip).
- New optional `ICS2K_Server.lua`: replicates the TIKTOK rig (with light level, colour and REC state) and the PAPARAZZI raised phone pose to every other player, with validation and rate limits.
- New **BODYCAM**, **DRONE**, **TACTICAL** and **CCTV** modes.

### Film look
- Post-processing stack (color correction, bloom, depth of field autofocus, blur) plus overlay grain (runtime EditableImage white noise with fallback), vignette, 2.39:1 letterbox, scanlines, glitches and screen flashes.
- Ten presets, full slider control, per-mode looks with a lock, custom look memory across mode changes.
- Paparazzi flashbulb FX and an AFK bouncing-logo screensaver.

### UI
- New Y2K chrome window (modes / settings / filter / gallery / keys), draggable, with iridescent strokes, glossy chrome pills, sparkles, toasts and a mode chip. Per-mode HUD overlays.
- Gallery backed by CaptureService: snapshot from any mode with Enter, view, save to device, share, delete.

### Bugs fixed from V9.4
- Entering free camera read roll as pitch (`ToEulerAnglesYXZ` returns pitch first), so the pitch was always reset to 0.
- All camera lerps and the zoom spring were per-frame constants, so the feel changed with frame rate. Everything is now dt-correct.
- Every slider connected two global input events and never disconnected them, leaking connections on every respawn. One global drag manager now serves every slider and the window.
- Keys held while pressing X stayed stuck (`STATE.keys` was never cleared outside mode 2). Keys are cleared on mode change, focus loss, menu open and text focus.
- AFK cinematic left the FOV wherever the last shot put it when waking into the standard camera. Wake now re-enters the previous mode properly and the standard camera gets its FOV back.
- Releasing RMB over a shop UI could leave the camera rotating with a free cursor. RMB is ignored when it starts over any button / scroll frame / shop UI, and cleared on focus loss.
- The character pivoted in place while flying because Roblox controls stayed enabled with WalkSpeed 0. Controls are now disabled through the PlayerModule (with a freeze fallback).
- `WalkSpeed == 6.5` magic-number checks replaced by a walk-speed manager that tracks the game's own changes.
- Free-camera hover settings were defined but never used; removed.
- Deprecated `spawn` replaced by `task.spawn`; unused services and the per-Heartbeat `GetGuiObjectsAtPosition` probe throttled to 12 Hz.
- Character respawn no longer destroys and rebuilds the UI; it rebinds the rig and keeps settings, bookmarks and gallery.
- The old file had no extension; it is now `IntelligentCameraSystem.lua`.
