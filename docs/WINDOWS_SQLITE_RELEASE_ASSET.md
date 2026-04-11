# Windows SQLite Release Asset

Windows uses a pinned `sqlite3.exe` instead of depending on whatever `sqlite3`
happens to exist on `PATH`.

Current pinned upstream bundle:

- SQLite version: `3.51.3`
- Upstream archive: `https://sqlite.org/2026/sqlite-tools-win-x64-3510300.zip`
- Upstream zip SHA3-256: `76a25f8a95a8a29487218ae443f34a14c1aa65cd2cc1d409309d3f7586b7f80d`

Installer behavior:

1. Try the project GitHub Release asset with the same archive filename.
2. If that asset is unavailable, fall back to the official SQLite upstream URL.
3. Extract `sqlite3.exe` into the Local Figma Port state dir.
4. Validate FTS5 with `CREATE VIRTUAL TABLE ... USING fts5(...)`.

Default resolution:

- Primary: `https://github.com/echo-ae/local_figma_port/releases/latest/download/sqlite-tools-win-x64-3510300.zip`
- Optional override by tag: set `LOCAL_FIGMA_PORT_RELEASE_TAG=<tag>`
- Optional direct override: set `LOCAL_FIGMA_PORT_SQLITE_ZIP_URL=<url>`

## Release Runbook

1. Download the pinned upstream archive from SQLite and verify the published SHA3-256.
2. Upload that exact zip file to the GitHub release as `sqlite-tools-win-x64-3510300.zip`.
3. Publish the release.
4. Run a clean Windows install and verify that the installer fetches the asset from `releases/latest/download/...`.
5. Run `scripts/verify/windows.ps1` on that machine.

If the pinned SQLite version changes later:

1. Update the asset filename and version constants in [scripts/install/windows.ps1](/Users/alex/Documents/src/figma_port/scripts/install/windows.ps1).
2. Update this document and the Windows section in [README.md](/Users/alex/Documents/src/figma_port/README.md).
3. Attach the new zip to the release before asking users to install it.

Recommended release-asset naming:

- `sqlite-tools-win-x64-3510300.zip`

Recommended release-asset location:

- `https://github.com/echo-ae/local_figma_port/releases/download/<tag>/sqlite-tools-win-x64-3510300.zip`
