# Release performance history

Each directory is the `tailscale` package version being measured. Report files
name the host platform and published baseline, for example:

```text
0.8.1/macos-arm64-vs-0.8.0.json
```

Keep one canonical full-profile report per platform and baseline. Reports retain
the raw samples and aggregate comparisons so later releases can be evaluated
against the same scenarios rather than a hand-selected subset. Experimental,
quick, dirty-checkout, and targeted diagnostic runs do not belong here.

Generate a candidate report with an explicit output path:

```sh
dart run --enable-experiment=native-assets \
  benchmark/release_compare.dart \
  --output=benchmark/results/<current-version>/<platform>-vs-<baseline>.json
```

Before committing it, confirm that:

- `current.commit` identifies the measured source and `current.dirty` is false;
- `current.version` matches the directory name;
- the run used the default five trials and full iteration count;
- no credentials, state paths, or developer-specific absolute paths remain;
- the matching version directory summarizes material and inconclusive results.

These reports are evidence, not a CI threshold. The comparison workflow remains
report-only until multiple environments establish stable variance bounds.
