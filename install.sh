#!/usr/bin/env bash
set -euo pipefail

VERSION="$INPUT_VERSION"
STABLE_TAG="$INPUT_STABLE_TAG"
NIGHTLY_TAG="$INPUT_NIGHTLY_TAG"
TOKEN="$INPUT_TOKEN"
DEFAULT_STABLE_TAG="nightly-2026-09-10-a670e34"

validate_tag() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Error: '$name' must contain only letters, digits, '.', '_', and '-'."
    exit 1
  fi
}

validate_tag version "$VERSION"
[[ -z "$STABLE_TAG" ]] || validate_tag stable-tag "$STABLE_TAG"
[[ -z "$NIGHTLY_TAG" ]] || validate_tag nightly-tag "$NIGHTLY_TAG"

if [[ -n "$STABLE_TAG" && "$VERSION" != stable && "$VERSION" != stable-and-nightly ]]; then
  echo "Error: 'stable-tag' is only supported with version 'stable' or 'stable-and-nightly'."
  exit 1
fi
if [[ -n "$NIGHTLY_TAG" && "$VERSION" != nightly-new-compiler && "$VERSION" != stable-and-nightly ]]; then
  echo "Error: 'nightly-tag' is only supported with version 'nightly-new-compiler' or 'stable-and-nightly'."
  exit 1
fi

OS=$(uname -s)
ARCH=$(uname -m)
ASSET_EXT=tar.gz
ROC_EXE=roc
case "$OS-$ARCH" in
  Linux-x86_64) PLATFORM=linux_x86_64 ;;
  Linux-aarch64|Linux-arm64) PLATFORM=linux_arm64 ;;
  Darwin-x86_64) PLATFORM=macos_x86_64 ;;
  Darwin-arm64) PLATFORM=macos_apple_silicon ;;
  MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
    PLATFORM=windows_x86_64
    ASSET_EXT=zip
    ROC_EXE=roc.exe
    ;;
  *) echo "Error: Unsupported operating system and architecture: $OS $ARCH"; exit 1 ;;
esac

if [[ "$PLATFORM" == windows_* && "$VERSION" != stable && "$VERSION" != nightly-new-compiler && "$VERSION" != stable-and-nightly ]]; then
  echo "Error: Windows is currently supported only for 'nightly-new-compiler'."
  exit 1
fi

AUTH_HEADER=()
[[ -z "$TOKEN" ]] || AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
mkdir -p "$RUNNER_TEMP" "$RUNNER_TOOL_CACHE"
TEMP_ROOT=$(mktemp -d "$RUNNER_TEMP/setup-roc.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  else
    shasum -a 256 < "$1" | awk '{print $1}'
  fi
}

stable_sha() {
  case "$1-$PLATFORM" in
    alpha3-rolling-linux_x86_64) echo c96045f1f54dc3d9e20c33ede8698d79b01e43f09652795beb4f0bc7fb38cba8 ;;
    alpha3-rolling-linux_arm64) echo 3eaf492e5e11d39a1c5a549005589405c40902fc0bed517acf8e8a18d190a409 ;;
    alpha3-rolling-macos_x86_64) echo 205c70d1f6f6f46c2c681350a68cd91886bdb7a24fd09646f3ba5c2b1e1e1379 ;;
    alpha3-rolling-macos_apple_silicon) echo ef64605d0be3296ad25e34b2d6841ed506ded6208565cbd4289bc81c9dbd3c9d ;;
    alpha4-rolling-linux_x86_64) echo 96e8be05e6f7176433ada74532ff36a62b8dc44c5247a82cdf919f2dadc5178b ;;
    alpha4-rolling-linux_arm64) echo 95558e2b5564b9f2b19fb29ad7df440d4ef7163dea571ffcd39409ef678ecccf ;;
    alpha4-rolling-macos_x86_64) echo e8378bdec9fbeaf8f7bae49159a7b43d42050b047375521799984311dcda7078 ;;
    alpha4-rolling-macos_apple_silicon) echo 416fbd983280eda11ac87b0947e27bf0a86d186a94baebeb71e163942bb5bd84 ;;
    *) return 1 ;;
  esac
}

install_archive() {
  local tag="$1" url="$2" expected_sha="$3" archive_ext="$4"
  local install_dir="$RUNNER_TOOL_CACHE/roc/$tag/$PLATFORM"
  local executable="$install_dir/$ROC_EXE"
  local marker="$install_dir/.setup-roc-sha256"

  if [[ -f "$executable" && -f "$marker" && "$(<"$marker")" == "$expected_sha" ]]; then
    echo "Reusing verified Roc installation: $install_dir" >&2
    printf '%s\t%s\n' "$install_dir" "$executable"
    return
  fi
  if [[ -e "$install_dir" ]]; then
    echo "Error: Existing installation at '$install_dir' does not match the requested artifact."
    exit 1
  fi

  local work_dir="$TEMP_ROOT/$tag" archive extract_dir
  archive="$work_dir/roc.$archive_ext"
  extract_dir="$work_dir/extract"
  mkdir -p "$extract_dir"
  echo "Downloading Roc $tag for $PLATFORM..." >&2
  curl -fsSL -o "$archive" "$url"

  local actual_sha
  actual_sha=$(sha256_file "$archive")
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Error: SHA256 mismatch for Roc $tag." >&2
    echo "Expected: $expected_sha" >&2
    echo "Actual:   $actual_sha" >&2
    exit 1
  fi

  if [[ "$archive_ext" == zip ]]; then
    if zipinfo -1 "$archive" | awk '/(^\/|(^|\/)\.\.($|\/))/{bad=1} END{exit bad ? 0 : 1}'; then
      echo "Error: Refusing to extract an archive containing an unsafe path."
      exit 1
    fi
    unzip -q "$archive" -d "$extract_dir"
  else
    if tar -tzf "$archive" | awk '/(^\/|(^|\/)\.\.($|\/))/{bad=1} END{exit bad ? 0 : 1}'; then
      echo "Error: Refusing to extract an archive containing an unsafe path."
      exit 1
    fi
    tar -xzf "$archive" -C "$extract_dir"
  fi

  roots=()
  while IFS= read -r root; do
    roots+=("$root")
  done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d)
  if [[ "${#roots[@]}" -ne 1 ]]; then
    echo "Error: Expected one root directory in the Roc archive, found ${#roots[@]}."
    exit 1
  fi
  if [[ ! -f "${roots[0]}/$ROC_EXE" ]]; then
    echo "Error: Roc archive does not contain '$ROC_EXE'."
    exit 1
  fi

  mkdir -p "$(dirname "$install_dir")"
  printf '%s\n' "$expected_sha" > "${roots[0]}/.setup-roc-sha256"
  mv "${roots[0]}" "$install_dir"
  printf '%s\t%s\n' "$install_dir" "$executable"
}

install_stable() {
  local tag="$1" expected_sha
  if [[ "$PLATFORM" == windows_* ]]; then
    echo "Error: Stable Roc releases are not currently available for Windows."
    exit 1
  fi
  if ! expected_sha=$(stable_sha "$tag"); then
    echo "Error: Stable tag '$tag' is not in setup-roc's checksum allowlist for $PLATFORM."
    exit 1
  fi
  install_archive "$tag" "https://github.com/roc-lang/roc/releases/download/$tag/roc-$PLATFORM-$tag.tar.gz" "$expected_sha" tar.gz
}

install_new_nightly() {
  local requested_tag="$1" api_url
  if [[ -n "$requested_tag" ]]; then
    api_url="https://api.github.com/repos/roc-lang/nightlies/releases/tags/$requested_tag"
  else
    api_url=https://api.github.com/repos/roc-lang/nightlies/releases/latest
  fi

  local release_json="$TEMP_ROOT/nightly-release.json"
  curl -fsSL "${AUTH_HEADER[@]}" -o "$release_json" "$api_url"
  local resolved_tag asset_prefix asset_name match_count url digest result
  resolved_tag=$(jq -er .tag_name "$release_json")
  validate_tag nightly-tag "$resolved_tag"
  asset_prefix="roc_nightly-$PLATFORM-"
  match_count=$(jq --arg prefix "$asset_prefix" --arg suffix ".$ASSET_EXT" \
    '[.assets[] | select(.name | startswith($prefix)) | select(.name | endswith($suffix))] | length' "$release_json")
  if [[ "$match_count" -ne 1 ]]; then
    echo "Error: Expected one $PLATFORM .$ASSET_EXT asset in '$resolved_tag', found $match_count."
    exit 1
  fi
  asset_name=$(jq -er --arg prefix "$asset_prefix" --arg suffix ".$ASSET_EXT" \
    '.assets[] | select(.name | startswith($prefix)) | select(.name | endswith($suffix)) | .name' "$release_json")
  url=$(jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json")
  digest=$(jq -er --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest' "$release_json")
  if [[ ! "$digest" =~ ^sha256:([0-9a-f]{64})$ ]]; then
    echo "Error: Asset '$asset_name' does not provide a valid SHA256 digest."
    exit 1
  fi
  result=$(install_archive "$resolved_tag" "$url" "${BASH_REMATCH[1]}" "$ASSET_EXT")
  printf '%s\t%s\t%s\t%s\n' "$resolved_tag" "$result" "$asset_name" "$digest"
}

export_single_glue() {
  local install_dir="$1"
  if [[ -d "$install_dir/glue" ]]; then
    echo "ROC_GLUE_DIR=$install_dir/glue" >> "$GITHUB_ENV"
    [[ ! -f "$install_dir/glue/RustGlue.roc" ]] || echo "ROC_RUST_GLUE=$install_dir/glue/RustGlue.roc" >> "$GITHUB_ENV"
    [[ ! -f "$install_dir/glue/ZigGlue.roc" ]] || echo "ROC_ZIG_GLUE=$install_dir/glue/ZigGlue.roc" >> "$GITHUB_ENV"
    [[ ! -f "$install_dir/glue/CGlue.roc" ]] || echo "ROC_C_GLUE=$install_dir/glue/CGlue.roc" >> "$GITHUB_ENV"
    if [[ -f "$install_dir/glue/env" ]]; then
      while IFS='=' read -r name value; do
        case "$name" in
          ROC_GLUE_PLATFORM_URL|ROC_GLUE_PLATFORM_PACKAGE) echo "$name=$value" >> "$GITHUB_ENV" ;;
        esac
      done < "$install_dir/glue/env"
    fi
  fi
}

write_single_outputs() {
  local resolved="$1" install_dir="$2" executable="$3"
  {
    echo "resolved-version=$resolved"
    echo "executable=$executable"
    echo "install-dir=$install_dir"
  } >> "$GITHUB_OUTPUT"
  echo "$install_dir" >> "$GITHUB_PATH"
  export_single_glue "$install_dir"
}

ALIAS_DIR="$RUNNER_TEMP/setup-roc/bin"

write_alias() {
  local name="$1" executable="$2"
  mkdir -p "$ALIAS_DIR"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$executable" > "$ALIAS_DIR/$name"
  chmod +x "$ALIAS_DIR/$name"
  if [[ "$PLATFORM" == windows_* ]]; then
    local native_executable
    native_executable=$(cygpath -w "$executable")
    printf '@echo off\r\n"%s" %%*\r\n' "$native_executable" > "$ALIAS_DIR/$name.cmd"
  fi
}

publish_alias_path() {
  echo "$ALIAS_DIR" >> "$GITHUB_PATH"
}

if [[ "$VERSION" == stable-and-nightly ]]; then
  STABLE_TAG="${STABLE_TAG:-$DEFAULT_STABLE_TAG}"
  IFS=$'\t' read -r resolved_stable_tag stable_dir stable_exe stable_asset stable_digest < <(install_new_nightly "$STABLE_TAG")
  IFS=$'\t' read -r resolved_nightly_tag nightly_dir nightly_exe nightly_asset nightly_digest < <(install_new_nightly "$NIGHTLY_TAG")
  {
    echo "stable-tag=$resolved_stable_tag"
    echo "stable-executable=$stable_exe"
    echo "stable-install-dir=$stable_dir"
    echo "nightly-tag=$resolved_nightly_tag"
    echo "nightly-executable=$nightly_exe"
    echo "nightly-install-dir=$nightly_dir"
  } >> "$GITHUB_OUTPUT"
  {
    echo "ROC_STABLE=$stable_exe"
    echo "ROC_STABLE_TAG=$resolved_stable_tag"
    echo "ROC_STABLE_INSTALL_DIR=$stable_dir"
    echo "ROC_NIGHTLY=$nightly_exe"
    echo "ROC_NIGHTLY_TAG=$resolved_nightly_tag"
    echo "ROC_NIGHTLY_INSTALL_DIR=$nightly_dir"
  } >> "$GITHUB_ENV"
  write_alias roc-stable "$stable_exe"
  write_alias roc-nightly "$nightly_exe"
  publish_alias_path
  {
    echo '### Roc toolchains'
    echo
    echo "- Stable: \`$resolved_stable_tag\` (\`$stable_asset\`, \`$stable_digest\`)"
    echo "- Nightly: \`$resolved_nightly_tag\` (\`$nightly_asset\`, \`$nightly_digest\`)"
    echo '- PATH aliases: `roc-stable`, `roc-nightly`'
    echo '- Unqualified `roc`: none (dual mode)'
  } >> "$GITHUB_STEP_SUMMARY"
elif [[ "$VERSION" == stable ]]; then
  STABLE_TAG="${STABLE_TAG:-$DEFAULT_STABLE_TAG}"
  IFS=$'\t' read -r resolved_stable_tag install_dir executable _asset _digest < <(install_new_nightly "$STABLE_TAG")
  {
    echo "stable-tag=$resolved_stable_tag"
    echo "stable-executable=$executable"
    echo "stable-install-dir=$install_dir"
  } >> "$GITHUB_OUTPUT"
  {
    echo "ROC_STABLE=$executable"
    echo "ROC_STABLE_TAG=$resolved_stable_tag"
    echo "ROC_STABLE_INSTALL_DIR=$install_dir"
  } >> "$GITHUB_ENV"
  write_single_outputs "$resolved_stable_tag" "$install_dir" "$executable"
  write_alias roc-stable "$executable"
  publish_alias_path
elif [[ "$VERSION" == nightly-new-compiler ]]; then
  IFS=$'\t' read -r resolved_tag install_dir executable _asset _digest < <(install_new_nightly "$NIGHTLY_TAG")
  echo "nightly-tag=$resolved_tag" >> "$GITHUB_OUTPUT"
  write_single_outputs "$resolved_tag" "$install_dir" "$executable"
  write_alias roc-nightly "$executable"
  publish_alias_path
elif [[ "$VERSION" == nightly ]]; then
  url="https://github.com/roc-lang/roc/releases/download/nightly/roc_nightly-$PLATFORM-latest.tar.gz"
  probe_archive="$TEMP_ROOT/nightly-probe/roc.$ASSET_EXT"
  mkdir -p "$(dirname "$probe_archive")"
  curl -fsSL -o "$probe_archive" "$url"
  digest=$(sha256_file "$probe_archive")
  IFS=$'\t' read -r install_dir executable < <(install_archive "nightly-$digest" "file://$probe_archive" "$digest" "$ASSET_EXT")
  write_single_outputs nightly "$install_dir" "$executable"
else
  IFS=$'\t' read -r install_dir executable < <(install_stable "$VERSION")
  write_single_outputs "$VERSION" "$install_dir" "$executable"
fi

echo 'Roc setup completed successfully'
