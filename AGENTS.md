# Agent Notes

## macOS Privacy Permissions

This app needs both macOS privacy permissions before capture can work:

- Privacy & Security > Accessibility
- Privacy & Security > Screen & System Audio Recording

Use `dist/Ebook Capture.app` for manual testing. Avoid testing the raw `.build`
executable for capture behavior because macOS privacy settings are app-identity
sensitive and `.build` paths are awkward to grant reliably.

After enabling either permission, quit and reopen `Ebook Capture.app`. Screen
Recording permission may not apply to an already-running process.

`make app` signs the bundle ad-hoc but embeds a stable designated requirement:

```text
designated => identifier "com.kdmsnr.ebook-capture"
```

This avoids tying TCC/privacy identity to a changing cdhash after each rebuild.
If an older build was already granted permissions before this signing rule was
added, reset or remove the old `Ebook Capture.app` entries from both privacy
panes once, open the freshly built `dist/Ebook Capture.app`, grant the
permissions again, then quit and reopen the app. Subsequent rebuilds should keep
the same privacy identity as long as the bundle identifier stays unchanged.
