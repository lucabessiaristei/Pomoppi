# Cutting a Pomoppi release

A concrete, followable checklist for shipping a new version. See `SPEC.md`
§15 for the behavior this feeds (version source, unsigned-for-now posture,
the update checker).

**v0.3.0 was released 2026-09-24** — both `.github/workflows/macos.yml`
and `windows.yml` ran green through the actual `release: published` path,
tag guard and all, and uploaded their assets successfully.

## 1. Bump the version

```sh
node Scripts/set-version.js 0.4.0
```

Rewrites `pomoppiVersion` in `Sources/PomoppiCore/Version.swift` in place —
never hand-edit that file. This is the single source every build script
and both release workflows read from.

## 2. Commit

```sh
git add Sources/PomoppiCore/Version.swift
git commit -m "Bump version to 0.4.0"
```

## 3. Tag and push

```sh
git tag v0.4.0
git push origin main --tags
```

The tag name must be `v` + exactly what `Version.swift` now says —
`Scripts/check-tag-version.js` fails the release build otherwise (both
workflows run it as their first step, but only when triggered by
`release: published`, not by `workflow_dispatch`).

## 4. Create and publish a GitHub release from that tag

Either via `gh` or the web UI, pointed at the tag just pushed:

```sh
gh release create v0.4.0 --title "v0.4.0" --notes "..."
```

**Consider publishing a pre-release first** (`gh release create v0.4.0
--prerelease ...`, or the "Set as a pre-release" checkbox in the web UI).
`GET /releases/latest` — what the update checker polls (`SPEC.md` §15) —
excludes drafts and prereleases automatically, server-side. A pre-release
is therefore a safe way to test the whole pipeline (tag guard, both
platform builds, artifact upload) without it ever reaching a real user's
update-check. Promote it to a full release afterward once it looks right,
or just publish for real directly once the pipeline is trusted.

## 5. What happens automatically

Publishing the release fires `release: published` on both
`.github/workflows/macos.yml` and `.github/workflows/windows.yml`:

1. `Scripts/check-tag-version.js` verifies the release tag matches
   `pomoppiVersion` — fails the whole run loudly if not, rather than
   shipping a mismatched artifact.
2. Each platform builds and packages: `Scripts/make-pkg.js` (unsigned
   `.pkg`) on macOS, `Scripts/make-windows-app.js --installer` (zip +
   Inno Setup `.exe`) on Windows.
3. Each workflow uploads its installer straight onto the GitHub release
   (`gh release upload ... --clobber`): the `.pkg` and the Setup `.exe`.

Nothing here is signed (see `SPEC.md` §15's "Unsigned, on purpose, for
now" — that's R2, deliberately deferred, not an oversight). A recipient
downloading the result hits Gatekeeper/SmartScreen friction — see
`README.md`'s install section for the exact steps to give them.

## 6. Verify

- Check both workflow runs went green under the Actions tab.
- Confirm the release page carries both expected assets:
  `Pomoppi-<version>_macOS.pkg` and `Pomoppi-Setup-<version>_Windows.exe`.
  The portable `Pomoppi-win.zip` is deliberately not attached; it's only a
  workflow artifact.
- If this was a pre-release test run, delete or leave it as-is (it's
  invisible to `/releases/latest` either way) before publishing the real
  one.
