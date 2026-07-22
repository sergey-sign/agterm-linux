# Bundled symbolic icons

`hicolor/scalable/actions/` holds two kinds of icons:

- `agterm-*-symbolic.svg` — original agterm artwork (the macOS-matching toolbar glyphs),
  covered by the repository's MIT license.
- The remaining freedesktop-named icons (`preferences-system-symbolic.svg`,
  `input-keyboard-symbolic.svg`, `window-close-symbolic.svg`, …) are vendored unmodified from
  [adwaita-icon-theme](https://download.gnome.org/sources/adwaita-icon-theme/) 46.0,
  dual-licensed **CC-BY-SA 3.0 or LGPL-3** by the GNOME Project
  (see <https://creativecommons.org/licenses/by-sa/3.0/> and
  <https://www.gnu.org/licenses/lgpl-3.0.html>).

The vendored set exists because the app must not depend on the desktop's icon theme:
KDE and minimal environments often configure GTK with an icon theme that is missing or lacks
these names, and GTK then renders the "image-missing" placeholder.
The app registers this directory as a `GtkIconTheme` search path at startup
(`installAppIcons` in `Sources/AgtermLinux/App.swift`), where it behaves as a hicolor
fallback: a healthy desktop theme still wins, the bundled copies only fill gaps.
Every stock icon name referenced from `Sources/` must have a copy here — when adding a new
`*-symbolic` name to the code, vendor it into `hicolor/scalable/actions/` in the same change.
