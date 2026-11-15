# Roost

A macOS menu bar app that puts your windows back where they were when your monitors come back,
for example after the laptop sleeps while you get a coffee and macOS piles everything onto the
built-in screen. It can also give your Spaces names.

## What it does

### Saves and restores layouts for each display setup

- **One layout per display setup.** A setup is the set of connected monitors plus their
  arrangement and resolution. "Laptop + DELL on the left" and "Laptop + DELL on the right" are
  two different setups, and "laptop alone" is a third.
- **Saves before things go wrong.** Roost takes a snapshot at screen lock, display sleep,
  system sleep and fast user switching. It also takes one at the *start* of a display
  reconfiguration, while windows are still in place, and in the background every 2 minutes
  (configurable).
- **Never saves a broken layout.** No snapshots are taken while asleep or locked, or for 15 s
  after any display change or wake, so the "everything on the laptop" state can't overwrite a
  good layout.
- **Restores automatically.** When the displays settle, and after wake or unlock, Roost restores
  the layout saved for the setup that is now connected. A second pass 2.5 s later catches
  windows that macOS moves again after the first one.
- **Restores Spaces too.** Each window goes back to its own Space as well as its position. Roost
  first looks for the same Space; if that's gone, it uses the same desktop number on the same
  display.
- **Forgets old setups.** A setup that hasn't been connected for a month is deleted, along with
  its layout. This covers a desk you only used for a while, or an arrangement you changed in
  Display Settings. You can set this to 1 week, 2 weeks, 1 month, 3 months or never. You can
  also forget a setup by hand from **Saved Display Setups**.

### Space names (can be turned off)

- Rename the current Space from the menu (**Rename This Space…**), or any Space from the
  **Spaces** submenu.
- The current Space's name is shown in the menu bar.
- Each Space can show a label with its name. It can be a large watermark behind your windows or
  a small badge above them, in any corner, at the top or bottom center, or in the middle. The
  label belongs to its Space, so it slides along when you swipe between desktops.
- Turn the feature on or off in **Settings… → Space Names**. The menu bar name and the
  labels each have their own switch too.

### Menu (left- or right-click the menu bar icon)

- **Change Display Arrangement…** opens System Settings › Displays and presses the
  **Arrange…** button for you, so the arrangement sheet opens directly. There's no URL for that
  sheet, so Roost finds the button through Accessibility. The button only exists when two or
  more displays are connected; otherwise the Displays pane just stays open.
- **Displays Settings…**, **Restore Layout Now**, **Save Layout Now**
- **Saved Display Setups**: each setup with its window count and when it was last seen.
- **Settings…** (⌘,) opens the settings window:
  - **Window Layouts**: auto-restore, moving windows between Spaces, how often to save in the
    background, how long to keep unused display setups, and Launch at Login.
  - **Space Names**: the on/off switch, the name in the menu bar, labels on each Space, labels
    for unnamed Spaces, and label style and position. Options that depend on a switch are
    greyed out while it's off.

## Install

You need macOS 13 or later and Xcode or the Command Line Tools.

```sh
./build.sh install    # Release build, copied to ~/Applications
open ~/Applications/Roost.app
```

Every push also builds a universal `Roost-<version>.zip` on GitHub Actions; download it from the
**Build** workflow run.

On first launch, grant **Accessibility** access when asked (System Settings › Privacy &
Security › Accessibility). Roost needs it to move other apps' windows. It doesn't need Screen
Recording.

> **Signing tip:** macOS ties the Accessibility grant to the app's code signature. An ad-hoc
> build (the default) gets a new signature every time you rebuild, so you'd have to grant
> access again. Sign with your Apple Developer identity to avoid this:
> `DEVELOPMENT_TEAM=ABCDE12345 ./build.sh install`

**Recommended macOS setting:** System Settings › Desktop & Dock › Mission Control ›
**Displays have separate Spaces** = on. This is the default, and it is what lets each monitor
keep its own Spaces.

## How it works

| Part | API |
| --- | --- |
| Window list (all Spaces), frames, owners | `CGWindowListCopyWindowInfo` (public) |
| Moving and resizing windows | Accessibility `AXPosition` / `AXSize` (public, needs permission) |
| Windows on Spaces other than the current one | `_AXUIElementCreateWithRemoteToken` (private) |
| Display identity | `CGDisplayCreateUUIDFromDisplayID`: stable for each monitor, regardless of port |
| "About to reconfigure" and "reconfigured" events | `CGDisplayRegisterReconfigurationCallback` |
| Spaces, and which Space each window is on | `CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows` (private) |
| Moving a window to another Space | `CGSMoveWindowsToManagedSpace`, falling back to the `CGSSpaceSetCompatID` method on macOS 14.5+ (private) |

Windows are matched to saved records by WindowServer id first. That id survives sleep and
display changes. If the id doesn't match (for example, the app was relaunched), Roost falls back
to the app plus the window title, and then to the app plus the window's front-to-back position.

Layouts are stored in `~/Library/Application Support/Roost/layouts.json`. Settings and Space
names are stored in the `app.roost.Roost` user defaults.

Logs: `log stream --predicate 'subsystem == "app.roost.Roost"' --info`

## Limitations

- **Moving windows between Spaces uses private APIs.** Apple has restricted these before
  (macOS 14.5). If a move fails, the window still goes to the right display and position, but it
  lands on that display's current Space. The menu then shows "N couldn't change Space".
- Full-screen and minimized windows are left alone.
- A window that shows on all Spaces is put back on its display, but its Space isn't changed.
- Space labels are created the first time you visit each Space after Roost starts.

## Development

```sh
./build.sh            # Release build → build/Roost.app
./build.sh run        # Debug build and launch
./build.sh test       # Unit tests for RoostCore (models, store and pruning, matching, geometry)
./build.sh install    # Release build, copied to ~/Applications
./build.sh dist       # Universal Release build, zipped to build/Roost-<version>.zip
./build.sh clean
```

- `Sources/RoostCore` contains the pure logic and has no AppKit dependency.
- `Sources/Roost` is the app: event handling (`LayoutManager`), system access (`System/`,
  `Private/`) and UI (`UI/`).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
