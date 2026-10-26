# 0110. Every interactive control shows its hover, pressed, focused and disabled states

- **Date:** 2026-10-26
- **Status:** accepted

## Context

The operations panel's pause, resume and close buttons were borderless symbol buttons: nothing
changed under the mouse, so they didn't read as buttons until clicked. Dylan asked for a hover
state on the close button, and for a rule that every UI element has an interaction state from
now on. The path bar already draws a rounded `quaternaryLabelColor` fill under a hovered
segment ([0026](0026-path-bar.md)); nothing else in the app had a hover look.

## Decision

- **Every interactive control has four states that look different from rest:** hover (the mouse
  is over it), pressed (the mouse is down on it), focused (it has the keys, as with Full
  Keyboard Access) and disabled. A new control is not done until it has all four. A control
  AppKit draws with a bezel, such as a push button, already has them; a borderless one needs
  them drawn.
- **`HoverButton`** is the borderless symbol button that draws them: a rounded
  `quaternaryLabelColor` fill under the mouse, the path bar's hover color; a
  `tertiaryLabelColor` fill while pressed; the focus ring around the same rounded shape; and no
  fill, with AppKit's dimmed symbol, while disabled. Its tracking area uses `.inVisibleRect`,
  and hiding it or an ancestor, or moving it out of its window, drops the hover, since the
  button then gets no `mouseExited`. It is 22 pt square,
  so the fill has room around a symbol. The operations panel's row buttons use it.
- **A row or segment that acts on a click**, such as a path bar segment, takes the same hover
  fill.
- **The sidebar's eject button darkens its glyph instead.** (Amended 2026-10-26, Dylan: "eject
  icon should hover darker color".) Finder's sidebar eject button has no fill: its glyph is
  light at rest and darker under the mouse. `HoverButton`'s `.glyph` look draws that: the
  tertiary label color at rest, secondary under the mouse, the label color while pressed and
  quaternary while disabled, the focus ring as the `.fill` look draws it. A tint change on a
  small symbol is harder to see than a fill, as the alternative below says, but here it is
  Finder's look and the pressed state has its own tint.

## Alternatives considered

- **AppKit's bordered `accessoryBarAction` bezel** — rejected: it draws a box around each
  button at rest, which crowds a panel row with two buttons.
- **Hover by tinting the symbol only** — rejected: a change of tint on a small symbol is hard to
  see, and the pressed state would need a third tint.

## Consequences

Controls built before this rule don't all have the four states. They get them when next
changed, with `HoverButton` where it fits; the sidebar's eject button has them since
2026-10-26.
