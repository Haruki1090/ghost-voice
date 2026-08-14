import GhostVoiceApp

// **ここには判断を書かない。** トップレベルコードは検査できない。
// 画面（HUD・設定）は `surfaces:` へ工場を足すことで繋ぐ（`AppSurface` の doc を読むこと）。
//
// **工場は `NSApplication.run()` のイベントループが回り始めた後にしか呼ばれない**
// （`LaunchSequence` / `RunLoopEntry`）。ここで `NotchHUDSurface` を作らないこと——
// run() の前に window を出すとアプリが活性化し、挿入先が壊れる（実測）。
GhostVoiceAppMain.main(surfaces: [
    { entry, services in NotchHUDSurface(entry, services: services) }
])
