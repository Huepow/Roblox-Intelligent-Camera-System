# ICS2K · Intelligent Camera System 2000 (v10 "CHROME")

A single LocalScript that turns the Roblox camera into eight cameras, a film-look stack, an iPhone selfie mode with a working gallery, and a Y2K chrome control panel. PC only (mouse + keyboard); touch and VR fall back to the stock camera automatically.

Try it live in **Trippingout Hub**: https://www.roblox.com/share?code=d0f365461fbc33478cffb196837bfab1&type=ExperienceDetails&stamp=1756400669737

---

## Install (60 seconds)

1. Open your place in Roblox Studio.
2. Go to **StarterPlayer → StarterPlayerScripts**.
3. Insert a **LocalScript**, name it `IntelligentCameraSystem`.
4. Delete its default code, paste the contents of `IntelligentCameraSystem.lua`.
5. Save and play. Press **C**.

Nothing else is required: no server script, no assets to upload, no folders to create. Everything (phone model, markers, UI, post-processing) is built at runtime on the client.

---

## The modes

Press **C** to cycle, **X** to return to the standard camera, **I** for the control panel. Every switch glides smoothly into the next camera (toggle in settings).

| Mode | What it is | Highlights |
| --- | --- | --- |
| **STANDARD** | The stock Roblox camera, untouched | The script leaves shift-lock, first person and the camera scripts alone here |
| **FREE** | Smooth drone flight | 1° to 120° exponential zoom with a critically damped spring; mouse sensitivity and fly speed scale with zoom; inertial acceleration; sliding collision (or noclip); roll with auto-level; autofocus depth of field; **bookmarks** (B / G) and a **dolly rail** (K / L) with Catmull-Rom playback and neon markers in the world |
| **CINEMATIC** | An AI shot director | 11 shot types (orbit, dolly in, crane, hero low, track side, over shoulder, vertigo / dolly zoom, handheld, top spiral, wide, group). It reads the scene before choosing: moving vs idle, indoors vs outdoors, nearby players, and rejects shots without line of sight. Cuts vs glides depend on the **energy** setting. Films other players (P). |
| **PAPARAZZI** | Pull out an iPhone | Third person raise → camera flies into the phone screen → lockscreen with *you* on it (head to waist crop, low-saturation gradient, live clock) → front camera. Walk while filming, aim the arm with the mouse, zoom .5x to 5x, tap to focus, flash / torch, flip to the back camera, shutter → gallery. |
| **BODYCAM** | First person body camera | Mouse turns the body, head bob tied to speed, landing dip, sprint FOV, timestamp + REC overlay, desaturated bodycam look |
| **DRONE** | An autonomous follow drone | Spring physics with tunable stiffness / damping, lead prediction on the look target, obstacle avoidance, banking into turns, auto orbit when you stand still, telemetry HUD |
| **TACTICAL** | Top down command view | Deadzone follow, Q/E 45° snaps, free tilt, and **x-ray roofs**: anything between the camera and you turns translucent (locally) instead of the camera being pushed in |
| **CCTV** | Security cameras you placed | Uses your FREE bookmarks as cameras (or 4 auto cams). PTZ tracking with motor-like slew, smart switching when the target is lost, auto cycle, signal glitches, timestamp overlay |

### Keys

Global: **C** next mode · **X** standard · **I** window · **U** hide every UI (Esc or U restores) · **Enter** snapshot to the gallery · **hold Shift** runway walk (6.5 speed) in third-person modes.

| Mode | Keys |
| --- | --- |
| FREE | W A S D fly · R / F up / down (Space = up) · Q / E roll · Z level · Wheel zoom · Ctrl+Wheel speed · RMB look · M lock mouse · hold T body runs with the camera · B bookmark · G glide to next bookmark · N clear bookmarks · K rail keyframe · L play / stop rail · J clear rail |
| CINEMATIC | O next shot · P film next player · H hold director · Wheel shot scale |
| PAPARAZZI | Enter / shutter button take the picture · F flash · V flip · G gallery · RMB drag aim the arm · Wheel zoom · click the viewfinder to focus · W / S walk · A / D turn · Space jump |
| BODYCAM | Mouse look · W A S D · Shift sprint · Wheel FOV |
| DRONE | RMB drag orbit / height · Wheel distance · O auto orbit |
| TACTICAL | RMB drag rotate / tilt · Q / E rotate 45° · Wheel zoom |
| CCTV | N / P next / previous cam · T PTZ tracking · Y auto cycle |

---

## The window (press I)

A draggable Y2K chrome panel with five tabs:

- **modes** – cards for every camera; the small **C** switch on each card decides whether it is in the C-cycle.
- **settings** – every tunable, grouped per mode: sensitivity, fly speed, acceleration, smoothing, zoom step, max zoom, roll, collision, speed-FOV, autofocus, rail timing, director energy / shot length / handheld, phone arm length / FOV / shake / flash brightness, bodycam FOV / bob / sprint, drone distance / height / stiffness / damping / look-ahead / orbit, tactical zoom / tilt / deadzone / x-ray, CCTV cycle / tracking / glitches, AFK timeout, UI sounds, toasts. Plus a bookmark manager and a reset button.
- **filter** – the look. Presets: **OFF, KODAK, TEAL, NOIR, VHS, DREAM, Y2K, CCTV, BODYCAM, PORTRAIT**. Sliders: film grain, vignette, 2.39:1 letterbox, scanlines, bloom + size, contrast, saturation, brightness, soft blur, depth of field + focus range, tint. **lock look** stops modes from changing it; otherwise CINEMATIC / PAPARAZZI / BODYCAM / CCTV bring their own look and the other modes return to the one you picked.
- **gallery** – every capture (snapshots and selfies). Click one to view it large; **SAVE TO DEVICE** writes it to your computer through Roblox's capture prompt, **SHARE** opens the share prompt, **DELETE** removes it. **SAVE ALL** exports everything.
- **keys** – the keybinds for the current mode.

A small chrome chip in the corner shows the current mode when the window is closed.

---

## Film look details

- **Grain** is real white noise generated at runtime with `EditableImage` (two tiled layers jittered at 24 Hz like actual stock). Roblox only allows `EditableImage` in experiences where the creator is ID-verified and **Allow Mesh / Image APIs** is switched on in the experience's Security settings; everywhere else the script falls back to a built-in texture automatically, nothing breaks.
- **Depth of field** autofocuses: on whatever the crosshair hits in FREE, on the subject in CINEMATIC / DRONE / CCTV, on your face in PAPARAZZI, and on where you click in the phone viewfinder.
- Letterbox adapts to the viewport aspect so the picture is always 2.39:1.
- Post effects live in `Lighting` under `ICS2K_*` names and are local to your client only.
- Optional FX: **paparazzi flashbulbs** (random camera flashes popping around the subject) and the AFK **bouncing logo** screensaver.

---

## PAPARAZZI, step by step

1. Enter the mode: the camera glides to a three-quarter shot while the right arm raises the phone (two-bone IK on R15, aim IK on R6, blended over the animation so it looks like a real raise).
2. The camera dollies straight into the phone screen until the lockscreen fills the view.
3. The lockscreen is yours: full-body avatar cropped head to waist on a low-saturation lavender / rose / slate gradient, live clock and date, status bar, dynamic island.
4. Tap (any key or click) to unlock: the camera app opens with the front camera looking at your face from the phone. The screen is masked to a portrait phone with a 4:3 viewfinder, zoom chips, flash, mode strip, shutter, gallery thumbnail and flip.
5. Walk around with W / S, turn with A / D, jump with Space, drag with RMB to move the phone around your face, scroll to zoom, click the viewfinder to focus.
6. Shutter (Enter or the button): the phone lights up your face, the picture is taken with the UI hidden, the viewfinder blinks, the thumbnail pops in. Pictures are stored in the gallery for the session; export them with SAVE TO DEVICE.
7. **F** toggles the torch (a spotlight from the screen), **V** flips to the back camera so you film the world through the phone, **G** opens the gallery, **X** puts the phone away.

The phone is a client-side prop: other players do not see it (replicating it needs a server script, see below).

---

## Smart systems under the hood

- Every smoothing in the file is frame-rate independent (`1 - e^(-rate·dt)` decay and sub-stepped spring-dampers), so 30 fps and 240 fps feel identical.
- A single render loop with per-mode error isolation: a bug in one mode cannot kill the camera; it is logged once every two seconds instead.
- Mode transitions capture the current camera and glide into the new one; modes that run their own intro (PAPARAZZI) opt out.
- The arm IK writes `Motor6D.Transform` during `Stepped`, after the animator and before physics, and blends with the animation so raise / lower look natural.
- Pointer-over-UI probing (12 Hz) so right-click drags never start over buttons, scroll frames, the ICS2K window, or anything that looks like a shop / inventory UI. Shop UIs and the camera coexist.
- Inputs are cleared whenever the window loses focus, the Roblox menu opens or a text box is focused, so keys cannot get stuck.
- AFK (3 minutes by default) drifts into CINEMATIC with a bouncing DVD-style logo; any input wakes you back into exactly the mode you were in, FOV and all.
- Respawn, death and camera replacement all drop cleanly back to STANDARD and rebind the new character, phone and IK.
- Collision raycasts ignore collectibles, mannequins, display models and anything tagged `IgnoreCameraCollision` or `Collectible` (CollectionService), plus all player characters.

---

## Configuration you may want to touch (top of the file)

| Field | Purpose |
| --- | --- |
| `CFG.sounds` | Click / ping / shutter / swoosh sounds. Defaults use legacy built-in `rbxasset://sounds/*` files; drop in your own `rbxassetid://` ids for nicer ones. |
| `CFG.phoneGrip` | Where the phone sits in the hand (`CFrame`). Tuned for Rthro-style hands; adjust for blocky rigs if the phone looks off during the raise. |
| `CFG.afkTimeout`, `S.general.afkTimeout` | Seconds of idle before the cinematic screensaver. |
| `CFG.collisionIgnoreNames` / `collisionIgnoreTags` | Objects the camera should pass through. |
| `CFG.shopGuiWords` | Name fragments that mark a ScreenGui as a shop / inventory (mouse stays free over them). |
| `S` (the settings table) | Factory defaults for every slider and toggle in the window. |

Settings live for the session (a LocalScript cannot write DataStores). If you want them to persist, forward `S` to a server script through a RemoteEvent and save it there.

---

## Known limits

- PC only. On touch / VR the script returns early and leaves the stock camera.
- `CaptureService` prompts (save / share) only work in the live Roblox client; in Studio, captures may be unavailable and the gallery will say so with a toast.
- The phone, markers and flashbulbs are local instances in `workspace.ICS2K_Local`; other players do not see them.
- `EditableImage` grain / scanlines need the Allow Mesh / Image APIs toggle; otherwise a texture fallback is used.
- Works with both classic `Motor6D` rigs and the newer `AnimationConstraint` rigs (AvatarJointUpgrade) for the phone arm IK.

---

## Project notes

The whole file is written in the Lua 5.1 compatible subset of Luau on purpose: it is parse-checked and executed end to end in a headless mock of the Roblox API (all 8 modes, every key, capture, gallery, AFK, respawn, UI widgets) before release. See `CHANGELOG.md` for what changed from V9.4.
