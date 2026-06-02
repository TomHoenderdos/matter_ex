# Apple Matter Probe

Small macOS Matter.framework commissioning probe for reproducing Apple controller
behavior outside the Home app.

Build:

```sh
swiftc AppleMatterProbe.swift -framework Matter -framework Security -o apple-matter-probe
```

Bundle and sign for macOS framework permission checks:

```sh
mkdir -p AppleMatterProbe.app/Contents/MacOS
cp apple-matter-probe AppleMatterProbe.app/Contents/MacOS/apple-matter-probe
cp Info.plist AppleMatterProbe.app/Contents/Info.plist
codesign --force --sign - AppleMatterProbe.app
```

`Probe.entitlements` documents the restricted Apple setup-payload entitlement.
Do not ad-hoc sign with it; macOS rejects unprovisioned restricted entitlements.

Run with BLE/Wi-Fi commissioning:

```sh
AppleMatterProbe.app/Contents/MacOS/apple-matter-probe --payload 'MT:Y.K9042C00KA0648G00' --ssid 'Tom&Ilona'
```

The tool prompts for the Wi-Fi password so it does not need to be stored in the
repository or shell history.
