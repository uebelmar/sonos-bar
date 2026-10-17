# CLAUDE.md – SonosBar

Native macOS menu bar app controlling Sonos (S2) over the **local UPnP/SOAP API**. User-facing text is German.
Overview, feature list and build steps: `README.md`. This file holds the non-obvious findings.

## Layout & build

- `project.yml` (xcodegen) → `SonosBar.xcodeproj` is generated, **not checked in**. Run `xcodegen generate` after changing it.
- App target `SonosBar/` only has `@main`, Info.plist, entitlements. **All code lives in the `SonosKit` Swift package**
  so `cd SonosKit && swift test` covers it without an Xcode test target.
- Package settings: Swift 5 language mode, `defaultIsolation(MainActor.self)` – everything is main-actor; network work is async URLSession.
- `XElement` is our XML DOM. Do not name it `XMLNode` – clashes with Foundation's `XMLNode` on macOS.
- Debug build: `xcodebuild -project SonosBar.xcodeproj -scheme SonosBar -configuration Debug -derivedDataPath build build`.
- Release: `scripts/release.sh` (needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`; values live in the owner's
  KeePassXC entry `flinkest/Mobile/App Store Connect API-Key`). Signs with "Developer ID Application" (team G33B89LJ73),
  notarizes + staples the DMG and the app. `scripts/install.sh` → /Applications + autostart.
- App icon is our own design (never the Sonos logo): `swift scripts/make-icon.swift docs/icon.png`, then
  regenerate `SonosBar/Assets.xcassets/AppIcon.appiconset` with `sips -z` (16–512 pt, @1x/@2x).
- Author is **Markus Übeleis** (README, LICENSE, `NSHumanReadableCopyright`). Gatekeeper's "developer" comes from the
  signing cert and stays *flinkest FlexCo* – changing it needs a personal Apple Developer Program team.
- In zsh, `log` is a shell builtin – use `/usr/bin/log show --predicate 'subsystem == "at.uebeleis.sonosbar"' --info`.

## macOS gotchas

- Info.plist **must** have `NSLocalNetworkUsageDescription`, `NSBonjourServices = [_sonos._tcp]` and ATS
  `NSAllowsLocalNetworking`. Without the permission, connections fail with `unsatisfied (Local network prohibited)`
  in the system log – no error surfaces in the app. First launch blocks until the user allows it.
- Local-network permission is per binary: pyenv's python gets `No route to host` while `/usr/bin/python3` and `curl` work.
- Sandbox + `com.apple.security.network.client` is enough (outgoing only; no UPnP event server).
- `SMAppService.mainApp.register()` registers the *running* bundle path – only enable autostart from /Applications.
- Screenshots: `SonosBar --show-popover --tab rooms` prints `popover-window <n>`; then `screencapture -x -o -l <n> file.png`.
  Never take full-screen screenshots (private windows).

## Sonos API findings (S2, firmware 27.1)

- Use **HTTP port 1400**. Bonjour advertises 1443 (TLS) – only used to resolve the IP.
- `/status/topology` is empty on S2 → use `ZoneGroupTopology#GetZoneGroupState`. Skip members with `Invisible="1"`.
- Send transport/queue/group-volume commands to the **group coordinator** only.
- Favorites (`FV:2`): always replay with the stored `r:resMD` DIDL (carries `SA_RINCON<sid*256+7>_X_#Svc…-Token`);
  hand-built metadata gives 714/800.
  - `x-rincon-cpcontainer:` → queue path (clear, `AddURIToQueue`, `x-rincon-queue:<coordUUID>#0`, Play).
  - `x-sonosapi-hls-static:` / `x-sonosapi-stream:` → `SetAVTransportURI(uri, resMD)` + Play.
  - `r:type = shortcut` favorites (Sonos Radio) have no `res` → not playable here.
- **UPnP 800 on a favorite** = the service refuses that item (seen for several YouTube Music mixes, on every route:
  transport URI, queue, `x-sonos-http:` → 714). Not a client bug. App marks it and offers deletion.
- Delete favorite: `ContentDirectory#DestroyObject(ObjectID "FV:2/<n>")`. Probe safely with a nonexistent id → 701.
- Group volume: `SnapshotGroupVolume` before `SetGroupVolume`, otherwise member ratios drift.
- Join group: `SetAVTransportURI("x-rincon:<coordUUID>")` on the joining player. Sync is handled by Sonos.

## YouTube Music – full library browsing is NOT possible

- Service id **284**, `Auth="AppLink"`, SMAPI endpoint `https://music.googleapis.com/v1:sendRequest`.
- `getAppLink` from a third-party controller → `403 PERMISSION_DENIED` ("unregistered callers"). The service manifest's
  `apiKey` is encrypted per device class (`cr`/`zp`). Decided **not** to work around this. Only favorites are offered.

## Testing

- `swift test` uses real but **anonymized** responses in `Tests/SonosKitTests/Fixtures` (RINCON ids, IPs, account
  serials replaced). Keep them anonymized – the repo is public.
- `SONOS_LIVE=1 SONOS_HOST=<ip>:1400 swift test --filter liveFavorites` loads every YT favorite on a real player
  (changes its queue/transport, does not press Play).
- Anything that presses Play / groups / changes volume affects a real household – ask before running it.
