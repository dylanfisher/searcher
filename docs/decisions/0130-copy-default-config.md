# 0130. Copy Default Config puts a new config file's text on the pasteboard

- **Date:** 2026-10-28
- **Status:** accepted
- **Builds on:** [0123](0123-config-is-the-settings.md) (the General pane's config buttons),
  [0126](0126-config-comments.md) (a new file's comments)

## Context

Dylan, 2026-10-28: "add a copy default config button".

## Decision

- **One source for the text.** `ConfigFile.defaultText` is `ConfigFile.data` with no values and
  no shortcuts: every preference at its default, `"shortcuts": {}`, a comment above each key.
  It is byte for byte the file Searcher writes where there is none. No second template.
- **A command.** `SystemCommands.copyDefaultConfig` (Copy Default Config, no chord) is
  registered as Open Config File is, so the palette runs it, the Shortcuts pane lists it and
  App ▸ Copy Default Config sits under Open Config File. It needs no config file, so it is
  always on, in `AppMenuResponder` too when no browser window has the keys.
- **The button.** Settings ▸ General's config buttons end with Copy Default Config. After a
  copy its title is "Copied" for 1.5 s, on an injected clock, and VoiceOver hears "Copied"; a
  second copy starts the 1.5 s again. The label holds both titles, the one not showing at zero
  opacity, so the button keeps its width and the row doesn't move. No alert.
- **The buttons are a list.** `GeneralSettings.ConfigButton` lists the five buttons in order,
  with their titles, and the pane draws a bordered push button for each, so a test can check
  what the pane shows: SwiftUI's accessibility tree is empty in the test process, shown or not.
- **The General pane is 640 points wide**, as wide as Shortcuts. Five buttons need 586 points,
  and at 520 SwiftUI cut their titles short. A test checks that the row fits.
- **`WorkspaceSystemActions` takes its pasteboard.** The app passes the general one; tests get a
  pasteboard of their own by default, so no test writes to the user's clipboard.

## Alternatives considered

- **A second row of buttons** instead of a wider pane: rejected, the pane has the room and one
  row keeps the config actions together.
- **An alert or a note under the buttons** to confirm: rejected, heavier than the title change
  that macOS's own Copy buttons use.
