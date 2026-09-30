# Doodle

1:1 Home Screen doodles — monorepo for the iOS app and the API.

```
doodle-draw/
  apps/
    ios/                 # Native SwiftUI + PencilKit app
    api/                 # Hono + SQLite backend (see apps/api/README.md)
  packages/
    contracts/           # Shared JSON schemas
```

## Run the iOS app

### 1. Open the project

```bash
open /Users/diassadykov/Projects/doodle-draw/apps/ios/Doodle.xcodeproj
```

Or in Finder: `apps/ios/Doodle.xcodeproj`.

### 2. Pick a simulator

In Xcode’s toolbar, choose an **iPhone** simulator (e.g. **iPhone 17** / iPhone 18 Pro).

### 3. Run

Press **⌘R** (or the Play button).

First launch may ask you to trust / select a Team under:

**Signing & Capabilities → Team** (your Apple ID is enough for the simulator).

Simulator builds usually work with automatic signing even with an empty Team for local run; if Xcode complains, add your Personal Team.

### 4. Try the flow

1. **Continue** on Sign In  
2. Pair via **Invite from Contacts**, **Share Link**, or **I have a code**  
3. Draw on the canvas (Apple **PencilKit**)  
4. Optional: **photo** button → draw on a picture  
5. **Send** (pink paper plane)  
6. Clock → latest from partner · Menu → History  

## What’s native Apple

- **SwiftUI** screens (lists, navigation, materials, capsules)
- **PencilKit** for drawing / eraser / undo
- **PhotosUI** for picking a photo to doodle on
- System grouped backgrounds, glass toolbar materials

## Notes

- The API exists (`apps/api`) but the app isn't connected to it yet — pair + send are still local demo state.
- Sign in with Apple is stubbed as **Continue** until you add a Team + Sign in with Apple capability.
- Home Screen widgets are included (`DoodleWidgetExtension`). After ⌘R, long-press Home Screen → **Edit** → **Add Widget** → search **Doodle**.
- App + widget share data via App Group `group.app.doodle.ios`. Draw → Send updates the widget. In Xcode, set **Team** on both `Doodle` and `DoodleWidgetExtension` so the App Group entitlement applies.

## Build from CLI (optional)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd apps/ios
xcodebuild -scheme Doodle -destination 'platform=iOS Simulator,name=iPhone 17' build
```

If `xcode-select` still points at Command Line Tools:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
