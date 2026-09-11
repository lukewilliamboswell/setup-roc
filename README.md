[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Setup Roc

A GitHub Action to download and setup one or two Roc compilers.

## Usage

Add this step to your CI workflow:

### Stable Tooling and a New-Compiler Nightly

Install the action-owned stable release alongside the latest new-compiler
nightly:

```yaml
- name: Install stable and nightly Roc
  id: roc
  uses: roc-lang/setup-roc@<commit-sha>
  with:
    version: stable-and-nightly

- name: Run stable tooling against the nightly compiler
  run: '"$ROC_STABLE" scripts/all_tests.roc'
  env:
    ROC: ${{ steps.roc.outputs.nightly-executable }}
```

The stable default is an action-owned, pinned new-compiler nightly. Both
selections come from `roc-lang/nightlies` and can be overridden with exact
release tags:

```yaml
with:
  version: stable-and-nightly
  stable-tag: nightly-2026-09-10-a670e34
  nightly-tag: nightly-2026-09-10-a670e34
```

When `stable-tag` is omitted, the action uses its reviewed pinned tag. When
`nightly-tag` is omitted, the action resolves the latest release. Both exact
resolved tags are reported.

Dual mode adds an alias directory to `PATH`, providing the unambiguous commands
`roc-stable` and `roc-nightly`. It does not expose an unqualified `roc`. Choose
a compiler using an alias, these outputs, or equivalent environment variables:

```roc
#!/usr/bin/env roc-stable
```

| Output | Environment variable |
| --- | --- |
| `stable-tag` | `ROC_STABLE_TAG` |
| `stable-executable` | `ROC_STABLE` |
| `stable-install-dir` | `ROC_STABLE_INSTALL_DIR` |
| `nightly-tag` | `ROC_NIGHTLY_TAG` |
| `nightly-executable` | `ROC_NIGHTLY` |
| `nightly-install-dir` | `ROC_NIGHTLY_INSTALL_DIR` |

Glue, when included, lives under `<install-dir>/glue`; dual mode does not
export a second set of glue variables.

### Stable Only

Jobs that only need the pinned stable new compiler can avoid resolving and
installing the latest nightly:

```yaml
- name: Install stable Roc
  id: roc
  uses: roc-lang/setup-roc@<commit-sha>
  with:
    version: stable

- run: roc scripts/update_config.roc
```

`stable` uses the same action-owned default and optional `stable-tag` override
as dual mode. Because it installs one compiler, it provides both `roc` and
`roc-stable` on `PATH`. It exposes both the `stable-*` outputs and the generic
single-mode outputs, and exports `ROC_STABLE`, `ROC_STABLE_TAG`, and
`ROC_STABLE_INSTALL_DIR`.

### For New Compiler Nightly Releases

```yaml
- uses: roc-lang/setup-roc@cbe782d6f165b89c87d99f50a59ac4f5f73b4427
  with:
    version: nightly-new-compiler
    nightly-tag: nightly-2026-June-27-127861d # remove nightly-tag to just get the latest one
```

### For Old Major Releases

```yaml
- uses: roc-lang/setup-roc@cbe782d6f165b89c87d99f50a59ac4f5f73b4427
  with:
    version: alpha4-rolling
```
> Note: we recommend using this @commit-sha way to specify the setup-roc version. This makes sure that the alpha4 release can not be altered if one of our github accounts is hacked.  

### For Old Nightly Releases

```yaml
- uses: roc-lang/setup-roc@cbe782d6f165b89c87d99f50a59ac4f5f73b4427
  with:
    # Note: nightly hashes are not verified because they are updated regularly.
    version: nightly
```

## Platform Support

This action supports the following platforms:

| OS | Architecture | Status |
|----|--------------|--------|
| Linux | x86_64 | ✅ |
| Linux | arm64 | ✅ |
| macOS | x86_64 (Intel) | ✅ |
| macOS | arm64 (Apple Silicon) | ✅ |
| Windows | x86_64 | ✅ |
| Windows | arm64 | ❌ |

Windows arm64 can be made available again with the next zig release (after 0.16.0).

Dual mode supports every platform for which the selected new-compiler nightly
releases both provide an archive.

## What it does

1. Detects your operating system and architecture
2. Resolves the selected Roc release or releases
3. Verifies stable checksums and new-compiler nightly asset digests
4. Installs each artifact under the runner tool cache by tag and platform
5. Adds `roc` to `PATH` in single mode and explicit role aliases in stable,
   new-compiler-nightly, and dual modes

Single mode also exposes the `resolved-version`, `executable`, and `install-dir`
outputs. Existing single-version behavior and glue environment variables remain
available. `nightly-new-compiler` additionally provides `roc-nightly`, while
`stable` provides `roc-stable`.

For new-compiler nightlies that include glue support, this action also exports:

| Environment variable | Description |
| --- | --- |
| `ROC_GLUE_DIR` | Directory containing generated glue specs for the installed Roc version |
| `ROC_RUST_GLUE` | Rust glue spec path |
| `ROC_ZIG_GLUE` | Zig glue spec path |
| `ROC_C_GLUE` | C glue spec path |
| `ROC_GLUE_PLATFORM_URL` | URL of the matching glue platform package |

Example:

```yaml
- uses: roc-lang/setup-roc@<commit-sha-with-glue-support>
  with:
    version: nightly-new-compiler

- run: roc glue "$ROC_RUST_GLUE" ./platform/main.roc --output-dir ./platform
```

Pin to a `setup-roc` commit that includes glue support; older pinned commits do
not export these variables.

## Security

For major releases, the action verifies the SHA256 checksum of the downloaded file to ensure it hasn't been tampered with. If the checksum doesn't match, the action will fail.

New-compiler nightlies are verified against the SHA256 digest in their GitHub
release metadata. The legacy moving `nightly` release has no published digest;
its downloaded bytes are hashed to isolate that installation from later builds.
