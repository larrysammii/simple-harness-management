## Download and install

**[Download the universal macOS DMG](https://github.com/larrysammii/simple-harness-management/releases/download/v0.1.0/Harness-Manager-0.1.0-universal.dmg)**

Requires **macOS 14.4+**. Includes **Apple Silicon (arm64)** and **Intel (x86_64)**. No development tools or Node.js installation are needed.

1. Open the DMG
2. Drag **Harness Manager** to **Applications**
3. Open the app from Applications, then eject the DMG

## First-launch warning

**This release is ad-hoc signed, not Apple Developer ID-signed or notarized.** macOS may block its first launch.

Only if you trust this release and downloaded it from this repository: attempt to open the app, then use **System Settings → Privacy & Security → Open Anyway** if offered. See [Apple's instructions](https://support.apple.com/en-us/102445). Do not disable Gatekeeper globally.

## Included

- Native SwiftUI inventory for local skills and MCP configurations
- Global/repository scopes, creator/harness filtering, and protected inherited entries
- Recoverable single/batch removal and Pi package unregister without deleting cached downloads
- JSON/JSONC, TOML, and YAML configuration support with verified edits and conflict-aware restore
- Local-only operation; no server connections, inventory uploads, or execution of package code

## Verify the download

Download `SHA256SUMS.txt` alongside the DMG and run in that folder:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The checksum verifies download integrity, not Apple notarization or a Developer ID publisher identity.

## License

MIT. Complete third-party notices and native parser licenses are included inside the app bundle.
