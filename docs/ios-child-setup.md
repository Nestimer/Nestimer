# Setting up NesTimer on a child's iPhone

Use this checklist for a child's iPhone running the Development-signed Release build. That
build is installed from the dev Mac over a cable; it isn't on the App Store yet.

## Before you start (parent)

1. The child's Apple ID is a **child member of your Family Sharing** group.
2. In the dashboard (my.nestimer.com), open the child's profile, add a device and choose
   the **iPhone** platform. Copy the setup string (`https://my.nestimer.com|TOKEN`).

## On the child's iPhone

1. **Settings → Screen Time → Share Across Devices: OFF.**
   If it's on, time spent on the Mac is counted again on the iPhone.
2. **Settings → General → Date & Time → Set Automatically: ON.**
   If the child changes the clock by hand, NesTimer shows "Clock changed" and blocks apps.
3. Connect the phone to the dev Mac by cable and tap "Trust".
4. On the dev Mac, install the app (registers the phone the first time):
   ```bash
   cd ios-agent
   xcodebuild -project NesTimerChild.xcodeproj -scheme NesTimerChild \
     -configuration Release -destination 'id=<UDID>' -derivedDataPath build \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   xcrun devicectl device install app --device <UDID> \
     build/Build/Products/Release-iphoneos/NesTimerChild.app
   ```
   Get the UDID from `xcrun devicectl list devices`.
5. **Settings → Privacy & Security → Developer Mode: ON** (the phone restarts).
   The option appears only after the first install from Xcode.
6. Open NesTimer, paste the setup string and tap **Connect**.
7. Tap **Allow Screen Time access**. iOS asks for the **parent's** Apple ID password; the
   parent enters it on the child's phone. After that, the child can't remove the app
   without the parent.
8. **What counts:** tap "All Apps & Categories" at the top, then Done.
9. **Always allowed:** find and tick Messages. Phone is never blocked.
10. Allow notifications. They give warnings at 15, 10, 5 and 1 minute.

## Check after setup

- The app shows the time left. The dashboard shows the iPhone as online.
- After a few minutes of use, the dashboard's usage grows (it updates about every 5 minutes).
- A code from the parent app unlocks for 5 minutes.
