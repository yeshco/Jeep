# Changelog

## 1.6.0

- The bar sits above Safari whenever it fits: 56 pt below the menu bar now suffices (was 68 pt). It sits 6 pt above the window and 4 pt below the menu bar.
- When the bar has to sit over Safari's page, it folds to a blue-tinted Jeep and springs open on hover, profiles cascading in, so it no longer covers the page. Unfolded, profiles sit on white circles; it slides shut as soon as the pointer leaves, never during a switch or with a menu open. Reduce Motion uses a short fade instead.
- Right-click a profile → **Close Window** closes it without switching to it; a visible profile hands its place to the next one in its Jeep window, following Settings → Profiles & Spaces when that one is on another desktop. Both profile menu items now have icons.
- The bar follows the next profile to another desktop after its window closes, whether from Jeep or Safari (⌘W). Before, it could stay tied to the closed window and never return.
- Choosing a profile whose window is on another desktop takes you to that desktop, as Settings → Profiles & Spaces promises by default. A profile window on no desktop at all (a window manager such as Swish can leave one there after a failed move, and a minimized window has none) comes back on your current desktop. Before, Jeep hid the current window and showed nothing, so the click seemed only to blank the screen.
- When the bar runs down Safari's side, it sits below the tab bar and favorites bar too, and slides up or down within about half a second as they appear or disappear (Reduce Motion places it without sliding). Before, it covered them in Safari 27, which nests the page one level deeper than Jeep looked.
- If Jeep cannot save its record of hidden windows (for example, the disk is full), it hides nothing and shows why. Before, it could hide a window whose record never reached disk, so a crash right after could leave it unrevealed.
- When Safari is busy or hung, Jeep's bar and menu pause briefly instead of freezing: each Accessibility request Jeep makes on its main thread gives up after a tenth of a second, a round stops looking through Safari's windows once it runs long, and after a slow round the bar makes no new Accessibility requests for two seconds.
- Fix a crash in the bar when its copy of a profile and Jeep's current one disagreed on the native profile name.
- New installs: **Open Jeep at login** starts checked in the welcome and is applied by **Start Jeep**. Existing installs keep their setting.
- Several Jeep windows: right-click a profile → **Move to New Jeep Window** gives it its own visible window and bar; right-click the Jeep logo → **Merge Into** joins two. Each Jeep window switches, hides, and hands off only its own profiles, keeps its own place (for example on another display), and has its own section in the menu-bar menu. New Safari windows join the Jeep window used last. Groups survive a Jeep relaunch while Safari keeps running. Quit, Pause, and Show All still reveal every window.
- The floating bars share one WindowServer scan and timer per tick; journal entries for bar transitions name their Jeep window once there are several.

## 1.5.1

- Keep unresolved hidden-window records across partial inventories and require three affirmative empty close confirmations before clearing the final record. Hide operations are restricted to ids persisted before the operation; reveal failures remain visible and retain recovery state.
- By design, Safari's Settings window and other windows that Safari reports have no web page are skipped when Jeep lists and hides windows. This has not been checked by hand against Safari. A window Jeep already recorded as hidden is still tracked even if it reports no page.
- An unchanged Safari error while Jeep waits to confirm that the last window closed is shown and logged once, not on every retry.
- Cancel queued profile selections on pause, Emergency Reveal, and termination without remembering an unfinished selection or disturbing a newer click.
- Resume and crash recovery re-hide inactive windows around a visible remembered owner even when Safari is in the background, without moving, showing, or activating its windows.
- A failed selection no longer automatically shows another profile. Profiles remain available in the menu when automatic startup cannot safely choose an owner.
- Preserve the floating bar's lease through slow close and profile-switch handoffs. Unrelated windows or a different Safari process cannot take over the pending replacement.
- Keep selected and incoming profiles visible in overflowing bars, disable profile actions consistently while switching, and keep welcome actions reachable in shorter windows.
- Refresh permission and login-item state when returning to the welcome; show non-permission failures in the menu without claiming that a failed reveal succeeded.
- Blank all window-title fields in new journal entries. A page title containing a dash is not reliable evidence of a Safari profile name. Window identities and geometry remain replayable; older logs are not rewritten.
- Read profile names from Safari's native controls instead of page-title prefixes, and cache verified names only for their exact window and Safari process lifetime. Unidentified windows remain separately selectable with numbered icons; only verified named profiles can read or change persistent labels.
- Keep historical window-ID labels untouched instead of assigning them to possibly reused window ids. Existing name-keyed labels remain supported.
- Remove native profile names from new journal entries without losing replayable identities or geometry.
- Profile icons use generic keywords by default; builds can bundle optional, git-ignored local keyword overrides.
- README: permissions table, what Jeep stores, and how to reveal windows without Jeep.

## 1.5.0

- UX and design pass on the welcome, Settings, and menu.
- Public-release cleanup: page titles never stored, Apple Event timeouts, Automation denial surfaced in the menu and Settings.

## 1.4.28

- **Open at login** toggle in Settings, backed by `SMAppService`.

## 1.4.27

- Vertical profile rail below Safari's toolbar when the horizontal bar does not fit, with the original artwork.
- The bar adapts to the available space and keeps Safari clicks smooth.

## 1.4.20 – 1.4.26

- Setting to bring a profile's window to the current Space when switching.
- Safari inventory is queried by window id, never by position.
- Local event journal in `~/Library/Logs/Jeep`.
- Renamed from SafariWindowSwitcher to Jeep; drag-to-install disk image.
