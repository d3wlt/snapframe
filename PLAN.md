# Snapframe — plan

Native macOS menu bar app for screenshots and screen recordings, modelled on CleanShot X's feature set
(no cloud upload). Swift 6.2 toolchain in Swift 5 mode, SwiftPM only (Command Line Tools, no Xcode),
macOS 15+, universal binary (Apple Silicon + Intel). Icons: SF Symbols.

## Layout

- `Sources/SnapframeCore/App` — app delegate, menu bar, action router, global hotkeys (Carbon), URL scheme
- `Sources/SnapframeCore/Settings` — `Preferences.swift` (every setting, keys + defaults), settings window
- `Sources/SnapframeCore/Model`, `Output` — `CapturedItem`, item factory, save/clipboard/file naming, after-capture pipeline
- `Capture`, `OCR` — area/window/fullscreen/self-timer capture, desktop icon hiding, post-processing, text recognition
- `QuickAccess`, `Pin`, `History` — floating thumbnail overlay, pinned screenshots, capture history
- `Annotate` — annotation editor, background ("beautify") tool
- `Recording` — screen recording (MP4/GIF), controls, click/keystroke overlays, video trim editor
- `Tests/SnapframeSelfTest` — executable test runner (`swift run SnapframeSelfTest [filter]`)

## Work items

| ID | Item | Depends on |
|---|---|---|
| W0 | Skeleton: package, prefs, model, pipeline, menu bar, hotkeys, stubs, build script | — |
| W1 | Capture: area overlay (crosshair, magnifier, freeze), window capture with wallpaper/padding/shadow, fullscreen, self-timer, previous area, OCR, desktop icon hider, post-processing | W0 |
| W2 | Quick Access overlay, pin to screen, capture history store + window | W0 |
| W3 | Annotation editor + background tool + `BackgroundRenderer` | W0 |
| W4 | Recording: SCStream → MP4 (H.264/HEVC), mic/system audio, controls, dim, countdown, clicks/keystrokes, GIF export, trim editor | W0 (uses W1 `AreaSelector`) |
| W5 | Settings window (all tabs), shortcut recorder, start at login, app icon | W0 |
| W6 | Integration, universal build, end-to-end QA | all |

## Verification

- `swift build` clean, `swift run SnapframeSelfTest` green (pixel-level checks for rendering/compositing,
  geometry conversions, encoding, history pruning, OCR on a rendered image).
- `scripts/build-app.sh` produces a universal, signed (ad-hoc by default) `dist/Snapframe.app` + `dist/Snapframe.zip`.
- UI checked with real screenshots. Live capture/recording needs Screen Recording permission for Snapframe
  itself, so the final end-to-end check runs on a Mac where it has been granted.
