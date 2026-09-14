# Manual release

Trace archives as an Apple-silicon-only, Hardened Runtime, unsandboxed Developer ID app. Library validation remains enabled; Xcode signs the embedded GRDB custom framework with the same team.

## One-time setup

1. Copy `Config/Signing.xcconfig.example` to the ignored `Config/Signing.xcconfig` and fill in the team and Developer ID application identity.
2. Store App Store Connect notarization credentials in Keychain:

   ```sh
   xcrun notarytool store-credentials TraceNotary \
     --apple-id YOUR_APPLE_ID \
     --team-id YOUR_TEAM_ID \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

3. Confirm the profile without exposing its secret: `xcrun notarytool history --keychain-profile TraceNotary`.

## Release gate

Run unit/UI tests, the real-corpus benchmark matrix, accessibility inspection, the network audit, and a deny-network smoke launch. Then:

```sh
TRACE_NOTARY_PROFILE=TraceNotary Scripts/release.sh
```

The script regenerates the checked-in project, archives and signs Trace, audits the binary, builds and signs a DMG with system tools, submits it with `notarytool`, staples the ticket, and verifies the app and disk image with `codesign` and `spctl`. It deliberately does not upload a release or implement an updater.
