#!/usr/bin/env bash
#
# Build a PyCharm Linux x64 package that runs directly on CentOS 7.
#
# The package contains:
#   * official PyCharm Linux x64 files
#   * the CentOS 7 / glibc 2.17 compatible JBR from jchanghong023/JetBrainsRuntime
#   * a private GCC 13.2 C++ runtime (libstdc++.so.6 + libgcc_s.so.1)
#
# Why the private C++ runtime is required:
# PyCharm 2026.2's Skiko/Compose native library requires newer GLIBCXX/CXXABI
# symbols than CentOS 7's GCC 4.8 libstdc++. Some corporate environments also
# inject GCC 4.8 into LD_LIBRARY_PATH. The packaged pycharm.sh prepends only
# this IDE's private runtime, so no global shell/module configuration is needed.
#
# We intentionally do NOT bundle a newer glibc. CentOS 7's glibc 2.17 remains
# the system ABI. The bundled GCC runtime is selected to run on that ABI.
#
# Usage:
#   ./scripts/build_pycharm_centos7.sh [options]
#
# Options:
#   --version <ver|latest>  PyCharm version to package (default: latest)
#   --jbr-release <tag|latest>
#                           JBR release tag from jchanghong023/JetBrainsRuntime
#                           (default: latest)
#   --jbr-repo <owner/repo> repository hosting JBR releases
#                           (default: jchanghong023/JetBrainsRuntime)
#   --jbr-asset <glob>      JBR asset glob
#                           (default: jbr_lb-*-linux-x64-*.tar.gz)
#   --keep                  keep the work directory
#
# Environment overrides:
#   PYCHARM_VERSION, JBR_RELEASE, JBR_REPO, JBR_ASSET_PATTERN,
#   CXX_RUNTIME_BASE_URL, LIBSTDCXX_PACKAGE, LIBSTDCXX_SHA256,
#   LIBGCC_PACKAGE, LIBGCC_SHA256, OUT_DIR, WORK_DIR, GITHUB_TOKEN
#
# Output:
#   <OUT_DIR>/pycharm-<version>-centos7.tar.gz
#   <OUT_DIR>/SHA256SUMS
#

set -euo pipefail

PYCHARM_VERSION="${PYCHARM_VERSION:-latest}"
JBR_RELEASE="${JBR_RELEASE:-latest}"
JBR_REPO="${JBR_REPO:-jchanghong023/JetBrainsRuntime}"
JBR_ASSET_PATTERN="${JBR_ASSET_PATTERN:-jbr_lb-*-linux-x64-*.tar.gz}"

# GCC 13.2 matches the runtime that was already verified on the target machine.
# These conda-forge linux-64 packages provide the runtime libraries without
# replacing the CentOS 7 system glibc.
CXX_RUNTIME_BASE_URL="${CXX_RUNTIME_BASE_URL:-https://conda.anaconda.org/conda-forge/linux-64}"
LIBSTDCXX_PACKAGE="${LIBSTDCXX_PACKAGE:-libstdcxx-ng-13.2.0-hc0a3c3a_7.conda}"
LIBSTDCXX_SHA256="${LIBSTDCXX_SHA256:-35f1e08be0a84810c9075f5bd008495ac94e6c5fe306dfe4b34546f11fed850f}"
LIBGCC_PACKAGE="${LIBGCC_PACKAGE:-libgcc-ng-13.2.0-h77fa898_7.conda}"
LIBGCC_SHA256="${LIBGCC_SHA256:-62af2b89acbe74a21606c8410c276e57309c0a2ab8a9e8639e3c8131c0b60c92}"

OUT_DIR="${OUT_DIR:-dist}"
WORK_DIR="${WORK_DIR:-/tmp/pycharm-centos7-build}"
KEEP_WORK=0

log() { printf '[build] %s\n' "$*"; }
die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)      PYCHARM_VERSION="$2"; shift 2 ;;
    --jbr-release)  JBR_RELEASE="$2"; shift 2 ;;
    --jbr-repo)     JBR_REPO="$2"; shift 2 ;;
    --jbr-asset)    JBR_ASSET_PATTERN="$2"; shift 2 ;;
    --keep)         KEEP_WORK=1; shift ;;
    *)              die "unknown argument: $1" ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
need curl
need tar
need sha256sum
need unzip
need zstd
need strings
need ldd

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
version_ge() {
  local actual="$1" minimum="$2"
  [ "$(printf '%s\n%s\n' "$actual" "$minimum" | sort -V | tail -1)" = "$actual" ]
}

version_le() {
  local actual="$1" maximum="$2"
  [ "$(printf '%s\n%s\n' "$actual" "$maximum" | sort -V | tail -1)" = "$maximum" ]
}

max_symbol_version() {
  local file="$1" prefix="$2"
  {
    strings "$file" 2>/dev/null \
      | grep -oE "${prefix}_[0-9]+(\.[0-9]+)*" \
      | sed "s/^${prefix}_//" \
      | sort -V \
      | tail -1
  } || true
}

# ---------------------------------------------------------------------------
# Resolve latest PyCharm from the official JetBrains release service.
# ---------------------------------------------------------------------------
fetch_latest_pycharm() {
  local api="https://data.services.jetbrains.com/products/releases?code=PCP&latest=true&type=release"
  local json ver link shalink
  json="$(curl -fsSL "$api")" || die "failed to fetch JetBrains releases API"
  ver="$(printf '%s' "$json" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
  link="$(printf '%s' "$json" | sed -n 's/.*"linux":{"link":"\([^"]*\)".*/\1/p' | head -1)"
  shalink="$(printf '%s' "$json" | sed -n 's/.*"linux":{"link":"[^"]*"[^}]*"checksumLink":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$ver" ]     || die "could not resolve latest PyCharm version"
  [ -n "$link" ]    || die "could not resolve PyCharm linux download link"
  [ -n "$shalink" ] || die "could not resolve PyCharm checksum link"
  printf '%s|%s|%s\n' "$ver" "$link" "$shalink"
}

# ---------------------------------------------------------------------------
# Resolve newest JBR release, including pre-releases.
# ---------------------------------------------------------------------------
resolve_latest_jbr_release() {
  local api="https://api.github.com/repos/${JBR_REPO}/releases?per_page=1"
  local json tag
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    json="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api")" || return 1
  else
    json="$(curl -fsSL "$api")" || return 1
  fi
  tag="$(printf '%s' "$json" | grep -oE '"tag_name": ?"[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}

# ---------------------------------------------------------------------------
# Robust download with retries and resume.
# ---------------------------------------------------------------------------
download() {
  local url="$1" out="$2" attempt=0
  while [ "$attempt" -lt 6 ]; do
    attempt=$((attempt + 1))
    if curl -fsSL --retry 3 --connect-timeout 20 \
         --speed-time 60 --speed-limit 2048 -C - "$url" -o "$out"; then
      return 0
    fi
    log "  download attempt $attempt/6 failed, retrying"
    sleep 5
  done
  die "failed to download $url"
}

verify_sha256() {
  local file="$1" expected="$2"
  (
    cd "$(dirname "$file")"
    printf '%s  %s\n' "$expected" "$(basename "$file")" | sha256sum -c -
  ) || die "sha256 verification failed: $(basename "$file")"
}

# ---------------------------------------------------------------------------
# Extract the payload from a .conda package.
# ---------------------------------------------------------------------------
extract_conda_payload() {
  local package="$1" destination="$2" scratch="$3" payload
  rm -rf "$scratch" "$destination"
  mkdir -p "$scratch" "$destination"
  unzip -q "$package" -d "$scratch"
  payload="$(find "$scratch" -maxdepth 1 -type f -name 'pkg-*.tar.zst' -print -quit)"
  [ -n "$payload" ] || die "no pkg-*.tar.zst payload in $(basename "$package")"
  zstd -dc "$payload" | tar -xf - -C "$destination"
}

# ---------------------------------------------------------------------------
# Install the private GCC runtime into <pycharm>/lib/centos7-runtime.
# ---------------------------------------------------------------------------
install_private_cxx_runtime() {
  local dir="$1"
  local std_pkg="$WORK/$LIBSTDCXX_PACKAGE"
  local gcc_pkg="$WORK/$LIBGCC_PACKAGE"
  local std_root="$WORK/libstdcxx-root"
  local gcc_root="$WORK/libgcc-root"
  local runtime="$dir/lib/centos7-runtime"
  local std_src gcc_src std_glibc_req gcc_glibc_req glibcxx_max cxxabi_max

  log "downloading private GCC 13.2 runtime for CentOS 7"
  download "$CXX_RUNTIME_BASE_URL/$LIBSTDCXX_PACKAGE" "$std_pkg"
  download "$CXX_RUNTIME_BASE_URL/$LIBGCC_PACKAGE" "$gcc_pkg"
  verify_sha256 "$std_pkg" "$LIBSTDCXX_SHA256"
  verify_sha256 "$gcc_pkg" "$LIBGCC_SHA256"

  extract_conda_payload "$std_pkg" "$std_root" "$WORK/libstdcxx-conda"
  extract_conda_payload "$gcc_pkg" "$gcc_root" "$WORK/libgcc-conda"

  std_src="$std_root/lib/libstdc++.so.6"
  gcc_src="$gcc_root/lib/libgcc_s.so.1"
  [ -e "$std_src" ] || die "$LIBSTDCXX_PACKAGE does not contain lib/libstdc++.so.6"
  [ -e "$gcc_src" ] || die "$LIBGCC_PACKAGE does not contain lib/libgcc_s.so.1"

  mkdir -p "$runtime"
  cp -L "$std_src" "$runtime/libstdc++.so.6"
  cp -L "$gcc_src" "$runtime/libgcc_s.so.1"
  chmod 0755 "$runtime/libstdc++.so.6" "$runtime/libgcc_s.so.1"

  std_glibc_req="$(max_symbol_version "$runtime/libstdc++.so.6" GLIBC)"
  glibcxx_max="$(max_symbol_version "$runtime/libstdc++.so.6" GLIBCXX)"
  cxxabi_max="$(max_symbol_version "$runtime/libstdc++.so.6" CXXABI)"

  [ -n "$std_glibc_req" ] || die "could not read GLIBC requirements from bundled libstdc++.so.6"
  [ -n "$glibcxx_max" ] || die "could not read GLIBCXX versions from bundled libstdc++.so.6"
  [ -n "$cxxabi_max" ] || die "could not read CXXABI versions from bundled libstdc++.so.6"

  version_le "$std_glibc_req" "2.17" \
    || die "bundled libstdc++.so.6 requires GLIBC_$std_glibc_req (CentOS 7 limit: GLIBC_2.17)"
  version_ge "$glibcxx_max" "3.4.22" \
    || die "bundled libstdc++.so.6 only provides GLIBCXX_$glibcxx_max (need >= GLIBCXX_3.4.22)"
  version_ge "$cxxabi_max" "1.3.9" \
    || die "bundled libstdc++.so.6 only provides CXXABI_$cxxabi_max (need >= CXXABI_1.3.9)"

  gcc_glibc_req="$(max_symbol_version "$runtime/libgcc_s.so.1" GLIBC)"
  [ -n "$gcc_glibc_req" ] || die "could not read GLIBC requirements from bundled libgcc_s.so.1"
  version_le "$gcc_glibc_req" "2.17" \
    || die "bundled libgcc_s.so.1 requires GLIBC_$gcc_glibc_req (CentOS 7 limit: GLIBC_2.17)"

  cat > "$runtime/README.txt" <<EOF
PyCharm CentOS 7 private C++ runtime
====================================

This directory is prepended to LD_LIBRARY_PATH by bin/pycharm.sh only.
It is not a replacement for the CentOS 7 system glibc.

Source:
  $CXX_RUNTIME_BASE_URL/$LIBSTDCXX_PACKAGE
  SHA256: $LIBSTDCXX_SHA256
  $CXX_RUNTIME_BASE_URL/$LIBGCC_PACKAGE
  SHA256: $LIBGCC_SHA256

Reason:
  PyCharm/Skiko requires at least GLIBCXX_3.4.22 and CXXABI_1.3.9,
  while CentOS 7's GCC 4.8 libstdc++ is too old.
EOF

  log "  private runtime installed: $runtime"
  log "  libstdc++ requires GLIBC_$std_glibc_req; provides GLIBCXX_$glibcxx_max / CXXABI_$cxxabi_max"
}

# ---------------------------------------------------------------------------
# Patch pycharm.sh so the package wins over an old user/system libstdc++.
# The change is scoped to the PyCharm process tree; it does not modify the
# caller's shell environment or ~/.cshrc.
# ---------------------------------------------------------------------------
patch_pycharm_sh() {
  local f="$1/bin/pycharm.sh" tmp first_line
  [ -f "$f" ] || die "missing $f"

  if grep -q 'pycharmcentos7 private C++ runtime' "$f"; then
    return 0
  fi

  IFS= read -r first_line < "$f" || die "cannot read $f"
  case "$first_line" in
    '#!'*) ;;
    *) die "$f has no shebang" ;;
  esac

  tmp="${f}.centos7.$$"
  {
    printf '%s\n' "$first_line"
    cat <<'EOF'

# >>> pycharmcentos7 private C++ runtime >>>
# Keep the bundled GCC runtime ahead of CentOS 7 / site-provided GCC 4.8.
# This fixes Skiko/Compose GLIBCXX/CXXABI resolution without changing the
# machine-wide environment.
_PYCHARM_BIN_HOME=$(dirname "$(realpath "$0")")
_PYCHARM_CXX_RUNTIME="${_PYCHARM_BIN_HOME}/../lib/centos7-runtime"
if [ -d "$_PYCHARM_CXX_RUNTIME" ]; then
  case ":${LD_LIBRARY_PATH:-}:" in
    *":${_PYCHARM_CXX_RUNTIME}:"*) ;;
    *)
      if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        LD_LIBRARY_PATH="${_PYCHARM_CXX_RUNTIME}:${LD_LIBRARY_PATH}"
      else
        LD_LIBRARY_PATH="${_PYCHARM_CXX_RUNTIME}"
      fi
      export LD_LIBRARY_PATH
      ;;
  esac
fi
unset _PYCHARM_BIN_HOME _PYCHARM_CXX_RUNTIME
# <<< pycharmcentos7 private C++ runtime <<<

EOF
    tail -n +2 "$f"
  } > "$tmp"
  chmod 0755 "$tmp"
  mv "$tmp" "$f"
  log "  patched bin/pycharm.sh to use the private GCC runtime first"
}

# ---------------------------------------------------------------------------
# Verify launchers and the Skiko C++ ABI resolution.
# ---------------------------------------------------------------------------
verify_pycharm_dir() {
  local dir="$1" label="$2" launcher out rc
  log "verifying $label"

  [ -x "$dir/jbr/bin/java" ] || die "$label: missing jbr/bin/java"
  [ -f "$dir/lib/centos7-runtime/libstdc++.so.6" ] \
    || die "$label: missing private libstdc++.so.6"
  [ -f "$dir/lib/centos7-runtime/libgcc_s.so.1" ] \
    || die "$label: missing private libgcc_s.so.1"
  grep -q 'pycharmcentos7 private C++ runtime' "$dir/bin/pycharm.sh" \
    || die "$label: pycharm.sh runtime patch is missing"

  log "  jbr/bin/java -version"
  "$dir/jbr/bin/java" -version 2>&1 || die "$label: jbr/bin/java -version failed"

  for launcher in bin/pycharm bin/pycharm.sh; do
    log "  $launcher --version"
    if out="$(cd "$dir" && "./$launcher" --version 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    printf '%s\n' "$out" | sed 's/^/    /'
    [ "$rc" -eq 0 ] || die "$label: $launcher --version failed (rc=$rc)"
    printf '%s' "$out" | grep -qi 'pycharm' \
      || die "$label: $launcher --version returned unexpected output"
  done
}

verify_skiko_runtime() {
  local dir="$1" label="$2" skiko runtime out req_glibcxx req_cxxabi have_glibcxx have_cxxabi
  skiko="$(find "$dir" -type f -name 'libskiko-linux-x64.so' -print -quit)"
  if [ -z "$skiko" ]; then
    log "$label: libskiko-linux-x64.so not present; skipping Skiko-specific ABI check"
    return 0
  fi

  runtime="$dir/lib/centos7-runtime"
  req_glibcxx="$(max_symbol_version "$skiko" GLIBCXX)"
  req_cxxabi="$(max_symbol_version "$skiko" CXXABI)"
  have_glibcxx="$(max_symbol_version "$runtime/libstdc++.so.6" GLIBCXX)"
  have_cxxabi="$(max_symbol_version "$runtime/libstdc++.so.6" CXXABI)"

  log "$label: Skiko requires GLIBCXX_${req_glibcxx:-unknown} / CXXABI_${req_cxxabi:-unknown}"
  if [ -n "$req_glibcxx" ]; then
    version_ge "$have_glibcxx" "$req_glibcxx" \
      || die "$label: private libstdc++ does not satisfy Skiko GLIBCXX_$req_glibcxx"
  fi
  if [ -n "$req_cxxabi" ]; then
    version_ge "$have_cxxabi" "$req_cxxabi" \
      || die "$label: private libstdc++ does not satisfy Skiko CXXABI_$req_cxxabi"
  fi

  out="$(
    LD_LIBRARY_PATH="$runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      ldd "$skiko" 2>&1 || true
  )"
  printf '%s\n' "$out" | sed 's/^/    /'

  printf '%s\n' "$out" | grep -F "$runtime/libstdc++.so.6" >/dev/null \
    || die "$label: ldd did not select the packaged libstdc++.so.6 for Skiko"
  if printf '%s\n' "$out" | grep -Eq '(GLIBCXX_|CXXABI_)[0-9.]+.*not found'; then
    die "$label: Skiko still has unresolved GLIBCXX/CXXABI symbols"
  fi
}

# ---------------------------------------------------------------------------
# Apply all CentOS 7 package changes.
# ---------------------------------------------------------------------------
apply_centos7_tweaks() {
  local dir="$1" f
  log "applying CentOS 7 package changes to $dir"

  # Keep the existing workstation tuning from this project.
  f="$dir/bin/pycharm64.vmoptions"
  cat > "$f" <<'EOF'
-Xms2g
-Xmx8g
-XX:ReservedCodeCacheSize=1024m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=100
-XX:+HeapDumpOnOutOfMemoryError
-XX:-OmitStackTraceInFastThrow
-XX:CICompilerCount=2
-XX:+IgnoreUnrecognizedVMOptions
-XX:+UnlockDiagnosticVMOptions
-XX:TieredOldPercentage=100000
-XX:+UseCompactObjectHeaders
--sun-misc-unsafe-memory-access=allow
-ea
-Dsun.io.useCanonCaches=false
-Dsun.java2d.metal=true
-Djbr.catch.SIGABRT=true
-Djdk.http.auth.tunneling.disabledSchemes=""
-Djdk.attach.allowAttachSelf=true
-Djdk.module.illegalAccess.silent=true
-Djdk.nio.maxCachedBufferSize=2097152
-Djava.util.zip.use.nio.for.zip.file.access=true
-Dkotlinx.coroutines.debug=off
-Dskiko.rendering.useScreenMenuBar=false
-Djava.nio.file.spi.DefaultFileSystemProvider=com.intellij.platform.core.nio.fs.MultiRoutingFileSystemProvider
-Dwelcome.screen.defaultWidth=1000
-Dwelcome.screen.defaultHeight=720
-Dintellij.startup.wizard.initial.timeout=1
-Dsun.tools.attach.tmp.only=true
-Dawt.lock.fair=true
-Dawt.toolkit.name=auto
EOF

  f="$dir/bin/idea.properties"
  if grep -q '^#idea.true.smooth.scrolling=true' "$f"; then
    sed -i 's/^#idea\.true\.smooth\.scrolling=true/idea.true.smooth.scrolling=true/' "$f"
    log "  enabled idea.true.smooth.scrolling in bin/idea.properties"
  fi

  install_private_cxx_runtime "$dir"
  patch_pycharm_sh "$dir"

  # The upstream native launcher itself requires a newer glibc. Use the shell
  # launcher, which now also installs the private C++ runtime.
  f="$dir/bin/pycharm"
  cat > "$f" <<'EOF'
#!/bin/sh
# CentOS 7 (glibc 2.17) compatible launcher.
exec "$(dirname "$(realpath "$0")")/pycharm.sh" "$@"
EOF
  chmod 0755 "$f"
  log "  replaced bin/pycharm native launcher with the CentOS 7 shell launcher"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  rm -rf "$WORK_DIR"
  mkdir -p "$OUT_DIR" "$WORK_DIR"
  WORK="$(cd "$WORK_DIR" && pwd)"
  OUT="$(cd "$OUT_DIR" && pwd)"

  # ---- resolve PyCharm download ----
  if [ "$PYCHARM_VERSION" = "latest" ]; then
    IFS='|' read -r PYCHARM_VERSION PYCHARM_URL PYCHARM_SHA_URL <<< "$(fetch_latest_pycharm)"
    log "latest PyCharm version resolved: $PYCHARM_VERSION"
  else
    PYCHARM_URL="https://download.jetbrains.com/python/pycharm-${PYCHARM_VERSION}.tar.gz"
    PYCHARM_SHA_URL="${PYCHARM_URL}.sha256"
  fi
  PYCHARM_TGZ="$(basename "$PYCHARM_URL")"

  # ---- download + verify PyCharm ----
  log "downloading PyCharm: $PYCHARM_URL"
  download "$PYCHARM_URL" "$WORK/$PYCHARM_TGZ"
  curl -fsSL "$PYCHARM_SHA_URL" -o "$WORK/$PYCHARM_TGZ.sha256"
  ( cd "$WORK" && sha256sum -c "$PYCHARM_TGZ.sha256" ) \
    || die "PyCharm sha256 verification failed"

  # ---- resolve + download + verify JBR ----
  if [ "$JBR_RELEASE" = "latest" ]; then
    JBR_RELEASE="$(resolve_latest_jbr_release)" \
      || die "could not resolve latest JBR release from $JBR_REPO; set --jbr-release explicitly"
    log "latest JBR release resolved: $JBR_RELEASE"
  fi

  JBR_BASE="https://github.com/${JBR_REPO}/releases/download/${JBR_RELEASE}"
  log "resolving JBR asset from $JBR_RELEASE"
  curl -fsSL "$JBR_BASE/SHA256SUMS" -o "$WORK/SHA256SUMS.jbr" \
    || die "failed to fetch JBR SHA256SUMS (release $JBR_RELEASE)"

  JBR_FILE=""
  JBR_HASH=""
  while read -r _h _f; do
    _f="${_f#./}"
    if [[ "$_f" == $JBR_ASSET_PATTERN ]]; then
      JBR_FILE="$_f"
      JBR_HASH="$_h"
      break
    fi
  done < "$WORK/SHA256SUMS.jbr"

  [ -n "$JBR_FILE" ] || die "no JBR asset matched '$JBR_ASSET_PATTERN' in release $JBR_RELEASE"
  log "JBR asset: $JBR_FILE"
  download "$JBR_BASE/$JBR_FILE" "$WORK/$JBR_FILE"
  verify_sha256 "$WORK/$JBR_FILE" "$JBR_HASH"

  # ---- extract PyCharm ----
  log "extracting PyCharm"
  tar -xzf "$WORK/$PYCHARM_TGZ" -C "$WORK"
  PYCHARM_DIR="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'pycharm-*' -print -quit)"
  [ -n "$PYCHARM_DIR" ] || die "could not find PyCharm extract directory"
  PYCHARM_NAME="$(basename "$PYCHARM_DIR")"
  [ -d "$PYCHARM_DIR/jbr" ] || die "PyCharm has no jbr/ directory to replace"

  # ---- swap JBR ----
  rm -rf "$PYCHARM_DIR/jbr"
  mkdir -p "$WORK/jbr-extract"
  log "extracting JBR"
  tar -xzf "$WORK/$JBR_FILE" -C "$WORK/jbr-extract"
  JBR_ROOT="$(find "$WORK/jbr-extract" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [ -n "$JBR_ROOT" ] || die "JBR tarball has no top-level directory"
  mv "$JBR_ROOT" "$PYCHARM_DIR/jbr"
  log "JBR installed into $PYCHARM_DIR/jbr"

  # ---- apply package changes ----
  apply_centos7_tweaks "$PYCHARM_DIR"

  # ---- verify the assembled tree before packaging ----
  verify_pycharm_dir "$PYCHARM_DIR" "assembled tree ($(uname -sr))"
  verify_skiko_runtime "$PYCHARM_DIR" "assembled tree"

  # ---- repackage ----
  OUT_TGZ="$OUT/pycharm-${PYCHARM_VERSION}-centos7.tar.gz"
  log "repackaging -> $OUT_TGZ"
  tar -czf "$OUT_TGZ" -C "$WORK" "$PYCHARM_NAME"
  ( cd "$OUT" && sha256sum "$(basename "$OUT_TGZ")" > SHA256SUMS )

  # ---- end-to-end validation from the produced archive ----
  if command -v docker >/dev/null 2>&1; then
    log "validating produced archive inside centos:7 (glibc 2.17)"
    docker run --rm -v "$OUT:/dist:ro" centos:7 \
      bash -c "
        set -e
        mkdir -p /tmp/v
        tar xzf /dist/$(basename "$OUT_TGZ") -C /tmp/v
        cd /tmp/v/$PYCHARM_NAME

        test -f lib/centos7-runtime/libstdc++.so.6
        test -f lib/centos7-runtime/libgcc_s.so.1
        grep -q 'pycharmcentos7 private C++ runtime' bin/pycharm.sh

        # Deliberately put CentOS 7's old libstdc++ on the incoming path.
        # pycharm.sh must still start because it prepends the packaged runtime.
        env LD_LIBRARY_PATH=/usr/lib64:/lib64 ./bin/pycharm --version
        env LD_LIBRARY_PATH=/usr/lib64:/lib64 ./bin/pycharm.sh --version
        ./jbr/bin/java -version

        SKIKO=\$(find . -type f -name 'libskiko-linux-x64.so' -print -quit)
        if [ -n \"\$SKIKO\" ]; then
          LD_LIBRARY_PATH=\"\$PWD/lib/centos7-runtime:/usr/lib64:/lib64\" \
            ldd \"\$SKIKO\" > /tmp/skiko-ldd.txt 2>&1 || true
          cat /tmp/skiko-ldd.txt

          grep -F \"\$PWD/lib/centos7-runtime/libstdc++.so.6\" /tmp/skiko-ldd.txt
          if grep -Eq '(GLIBCXX_|CXXABI_)[0-9.]+.*not found' /tmp/skiko-ldd.txt; then
            echo 'Skiko still has unresolved GLIBCXX/CXXABI symbols' >&2
            exit 1
          fi
        fi
      " || die "validation inside centos:7 container failed"
  else
    log "docker not present - validating a fresh local extraction"
    CHECK_DIR="$WORK/check"
    mkdir -p "$CHECK_DIR"
    tar -xzf "$OUT_TGZ" -C "$CHECK_DIR"
    verify_pycharm_dir "$CHECK_DIR/$PYCHARM_NAME" "produced archive (fresh extract)"
    verify_skiko_runtime "$CHECK_DIR/$PYCHARM_NAME" "produced archive"
  fi

  if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK_DIR"
  fi

  log "DONE: $OUT_TGZ"
  cat "$OUT/SHA256SUMS"
}

main "$@"
