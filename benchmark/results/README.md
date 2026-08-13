# Release performance history

Each directory is the `tailscale` release represented by its reports. Report
files name the host platform and published baseline, for example:

```text
0.9.0/macos-arm64-vs-0.8.0.json
```

Keep one canonical full-profile report per platform and baseline. Reports retain
the raw samples and aggregate comparisons so later releases can be evaluated
against the same scenarios rather than a hand-selected subset. Experimental,
quick, dirty-checkout, and targeted diagnostic runs do not belong here.

Physical-device network profiles use the same version directory, under a
`devices/` child. The runner creates both raw JSON and a Markdown summary:

```text
0.9.0/devices/2026-08-13-ios-arm64.json
0.9.0/devices/2026-08-13-ios-arm64.md
```

Generate a candidate report with an explicit output path:

```sh
dart run \
  benchmark/release_compare.dart \
  --output=benchmark/results/<current-version>/<platform>-vs-<baseline>.json
```

Before committing it, confirm that:

- `current.commit` identifies the measured source and `current.dirty` is false;
- `current.version` matches the directory name, unless a `releaseVersion`
  explicitly associates a runtime-identical pre-release run with the final
  release while preserving the version and commit that were actually measured;
- the run used the default five trials and full iteration count;
- no credentials, state paths, or developer-specific absolute paths remain;
- the matching version directory summarizes material and inconclusive results.

For a device profile, also confirm that the device is physical, the checkout is
clean, every capability passed (apart from an explicitly advisory Ping warning),
the profile is complete and comparison-eligible, and the device/OS/network
setup is documented well enough to make a future comparison meaningful. The
public-Dart, direct-`tsnet`, and ordinary-LAN collections must all be complete.
Device reports intentionally omit device identifiers and tailnet addresses.

These reports are evidence, not a CI threshold. The comparison workflow remains
report-only until multiple environments establish stable variance bounds.
