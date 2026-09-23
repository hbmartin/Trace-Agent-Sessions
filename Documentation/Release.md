# Manual release

Trace ships as an Apple-silicon-only, Hardened Runtime, unsandboxed Developer ID app. Library validation remains enabled; Xcode signs the embedded GRDB custom framework with the same team. Debug builds permit debugger attachment, while Release builds omit `get-task-allow`.

## One-time setup

1. Copy `Config/Signing.xcconfig.example` to the ignored `Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM = MGPHJKUJSY`. Install a valid `Developer ID Application` certificate for that team in your keychain; an Apple Development certificate alone cannot sign a release. `security find-identity -v -p codesigning` lists available identities.
2. Store App Store Connect notarization credentials in Keychain:

   ```sh
   xcrun notarytool store-credentials TraceNotary \
     --apple-id YOUR_APPLE_ID \
     --team-id MGPHJKUJSY \
     --password YOUR_APP_SPECIFIC_PASSWORD
   ```

3. Confirm the profile without exposing its secret: `xcrun notarytool history --keychain-profile TraceNotary`.

## Release gate

Run unit/UI tests, the real-corpus benchmark matrix, accessibility inspection, the network audit, and a deny-network smoke launch. Then:

```sh
TRACE_NOTARY_PROFILE=TraceNotary Scripts/release.sh
```

The script uses the current Xcode project, archives Trace, and exports the archive using Xcode's `developer-id` distribution method. It checks the exported app and embedded code for the expected Developer ID identity and team, a secure timestamp, hardened runtime, valid signatures, and the absence of `get-task-allow`. Only then does it package and sign the DMG, submit it with `notarytool`, staple and validate the ticket, and assess the app and DMG with `codesign` and `spctl`. It deliberately does not upload a release or implement an updater.
