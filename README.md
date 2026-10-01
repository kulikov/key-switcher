# Key Switcher

A tiny macOS menu bar app for people who type in English and Russian. Typed a word in the wrong
layout? Tap the left Option key, and the word is retyped in the other layout, which becomes active.

![Menu bar](assets/menu-bar.png)

## What it does

- **Fix the last word.** `ghbdtn` + tap left Option → `привет`, and the layout switches to Russian.
  Trailing spaces are kept.
- **Fix a selection.** With nothing typed yet, select text and tap left Option: the selection is
  retyped in the other layout and stays selected. The direction is detected from the characters.
- **Just switch.** Anywhere else a tap only switches the layout.
- **Menu bar flag.** A monochrome UK or Russian flag shows the current layout and follows every
  switch, whether it came from Key Switcher, a system shortcut or the Input menu.
- **Launch at login.** The app registers itself in Login Items on first start.

A tap means pressing and releasing left Option alone within half a second. Option used together with
another key is left alone.

## Safety

- Before deleting anything, the text left of the caret is read through Accessibility and compared with
  the buffered word; on a mismatch the app only switches the layout.
- The word buffer resets on clicks, app switches, shortcuts, arrows, Fn/Globe and Caps Lock, so a stale
  word is never retyped somewhere else.
- Under Secure Event Input (password fields, `sudo` in a terminal) the app only switches the layout.

## Requirements

- macOS 13 or later, Xcode Command Line Tools.
- Two keyboard layouts in System Settings → Keyboard → Input Sources, e.g. ABC and Russian. With more
  than two, "the other layout" is the first one macOS lists that is not active.
- An `Apple Development` signing identity in the keychain. Without one, change `--sign` in the
  Makefile to `-` for an ad-hoc signature; Accessibility permission then has to be granted again after
  every rebuild.

## Install

```sh
make run
```

This builds the app, copies it to `~/Applications/Key Switcher.app` and launches it. On first launch
grant Accessibility access in System Settings → Privacy & Security → Accessibility.

To avoid two layout indicators, turn off "Show Input menu in menu bar" in System Settings → Keyboard →
Input Sources.

## Uninstall

Remove Key Switcher from System Settings → General → Login Items, then:

```sh
pkill -x KeySwitcher
rm -rf ~/Applications/Key\ Switcher.app
```
