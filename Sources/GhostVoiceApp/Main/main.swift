import GhostVoiceApp

// **ここには判断を書かない。** トップレベルコードは検査できない。
// 画面（HUD・設定・履歴）は `surfaces:` へ工場を足すことで繋ぐ（`AppSurface` の doc を読むこと）。
//
// **工場は `NSApplication.run()` のイベントループが回り始めた後にしか呼ばれない**
// （`LaunchSequence` / `RunLoopEntry`）。ここで画面を作らないこと——
// run() の前に window を出すとアプリが活性化し、挿入先が壊れる（実測）。
//
// 順序に意味がある。**HUD を先に作る**——`StatusMenuSurface` は
// `NSStatusBar` へ項目を足すだけだが、HUD は表示先の計算に `NSScreen` を読む。
// 診断の行が「表示先 → メニュー」の順で出るほうが、起動の追いかけがしやすい。
GhostVoiceAppMain.main(surfaces: [
    { entry, services in NotchHUDSurface(entry, services: services) },
    { entry, services in StatusMenuSurface(entry, services: services) },
])
