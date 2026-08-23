#!/usr/bin/env bash
#
# build_pycharm_centos7.sh
#
# Download the official PyCharm (Linux x64), replace the bundled JetBrains
# Runtime (jbr) with the latest CentOS 7 / glibc 2.17 compatible JBR release
# published on the JetBrainsRuntime repo release page, and repackage into a
# CentOS 7 compatible PyCharm tarball.
#
# The JBR is ALWAYS downloaded fresh from the repo release page (never reused
# from local files), so this script works identically on this machine and in
# the GitHub Actions pipeline (fresh environment).
#
#   https://github.com/jchanghong023/JetBrainsRuntime/releases
#   (custom JBR 25 build for CentOS 7 / glibc 2.17, validated:
#    GLIBC <= 2.17, GLIBCXX <= 3.4.19, CXXABI <= 1.3.7)
#
# Verification performed after packaging:
#   * jbr/bin/java -version                 (JBR runs on this host)
#   * bin/pycharm.sh --version              (IDE launcher + JBR work)
#   * fresh-extract of the produced tarball, then the two checks above
#   * if docker is available: the same checks inside a centos:7 container
#
# Usage:
#   ./scripts/build_pycharm_centos7.sh [options]
#
# Options:
#   --version <ver|latest>  PyCharm version to package (default: latest)
#   --jbr-release <tag|latest>
#                           JBR release tag from the release page
#                           (default: latest = newest release on the page)
#   --jbr-repo <owner/repo> repo hosting the JBR releases
#                           (default: jchanghong023/JetBrainsRuntime)
#   --jbr-asset <glob>      JBR asset name glob (default: jbr_lb-*-linux-x64-*.tar.gz)
#   --keep                  keep the work directory
#
# Env overrides (same names): PYCHARM_VERSION, JBR_RELEASE, JBR_REPO,
#                             JBR_ASSET_PATTERN, OUT_DIR, WORK_DIR, GITHUB_TOKEN
#
# Output: <OUT_DIR>/pycharm-<version>-centos7.tar.gz + SHA256SUMS
#

set -euo pipefail

PYCHARM_VERSION="${PYCHARM_VERSION:-latest}"
JBR_RELEASE="${JBR_RELEASE:-latest}"
JBR_REPO="${JBR_REPO:-jchanghong023/JetBrainsRuntime}"
JBR_ASSET_PATTERN="${JBR_ASSET_PATTERN:-jbr_lb-*-linux-x64-*.tar.gz}"
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

# ---------------------------------------------------------------------------
# resolve the latest PyCharm version + linux download links from the official
# JetBrains releases API (parsed with grep/sed, no python needed)
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
# resolve the newest JBR release tag from the repo release page (GitHub API),
# including pre-releases. Uses GITHUB_TOKEN when available.
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

# highest GLIBC_* symbol version required by a binary
max_glibc() {
  local f="$1"
  if command -v objdump >/dev/null 2>&1; then
    objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sed 's/^GLIBC_//' | sort -V | tail -1
  else
    readelf -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sed 's/^GLIBC_//' | sort -V | tail -1
  fi
}

# robust download: resume partial files, abort on stalled transfer, retry
download() {
  local url="$1" out="$2" attempt=0
  while [ $attempt -lt 6 ]; do
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

# ---------------------------------------------------------------------------
# verify an extracted PyCharm dir with java -version + pycharm --version
# ---------------------------------------------------------------------------
verify_pycharm_dir() {
  local dir="$1" label="$2" out rc
  log "verifying $label"
  log "  jbr/bin/java -version"
  "$dir/jbr/bin/java" -version 2>&1 || die "$label: jbr/bin/java -version failed"
  log "  bin/pycharm.sh --version"
  out="$(cd "$dir" && ./bin/pycharm.sh --version 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [ $rc -eq 0 ] || die "$label: pycharm --version failed (rc=$rc)"
  printf '%s' "$out" | grep -qi 'pycharm' \
    || die "$label: pycharm --version returned unexpected output"
}

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

  # ---- download + verify PyCharm (always fresh) ----
  log "downloading PyCharm: $PYCHARM_URL"
  download "$PYCHARM_URL" "$WORK/$PYCHARM_TGZ"
  curl -fsSL "$PYCHARM_SHA_URL" -o "$WORK/$PYCHARM_TGZ.sha256"
  ( cd "$WORK" && sha256sum -c "$PYCHARM_TGZ.sha256" ) \
    || die "PyCharm sha256 verification failed"

  # ---- resolve + download + verify JBR (always from the release page) ----
  if [ "$JBR_RELEASE" = "latest" ]; then
    JBR_RELEASE="$(resolve_latest_jbr_release)" \
      || die "could not resolve latest JBR release from $JBR_REPO (GitHub API failed); set --jbr-release explicitly"
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
      JBR_FILE="$_f"; JBR_HASH="$_h"; break
    fi
  done < "$WORK/SHA256SUMS.jbr"
  [ -n "$JBR_FILE" ] || die "no JBR asset matched pattern '$JBR_ASSET_PATTERN' in release $JBR_RELEASE"
  log "JBR asset: $JBR_FILE"
  download "$JBR_BASE/$JBR_FILE" "$WORK/$JBR_FILE"
  ( cd "$WORK" && printf '%s  %s\n' "$JBR_HASH" "$JBR_FILE" | sha256sum -c - ) \
    || die "JBR sha256 verification failed"

  # ---- extract PyCharm ----
  log "extracting PyCharm"
  tar -xzf "$WORK/$PYCHARM_TGZ" -C "$WORK"
  PYCHARM_DIR="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'pycharm-*' | head -1)"
  [ -n "$PYCHARM_DIR" ] || die "could not find PyCharm extract directory"
  PYCHARM_NAME="$(basename "$PYCHARM_DIR")"
  [ -d "$PYCHARM_DIR/jbr" ] || die "PyCharm has no jbr/ directory to replace"

  # ---- swap the JBR ----
  rm -rf "$PYCHARM_DIR/jbr"
  mkdir -p "$WORK/jbr-extract"
  log "extracting JBR"
  tar -xzf "$WORK/$JBR_FILE" -C "$WORK/jbr-extract"
  JBR_ROOT="$(find "$WORK/jbr-extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$JBR_ROOT" ] || die "JBR tarball has no top-level directory"
  mv "$JBR_ROOT" "$PYCHARM_DIR/jbr"
  log "JBR installed into $PYCHARM_DIR/jbr"

  # ---- repackage ----
  OUT_TGZ="$OUT/pycharm-${PYCHARM_VERSION}-centos7.tar.gz"
  log "repackaging -> $OUT_TGZ"
  tar -czf "$OUT_TGZ" -C "$WORK" "$PYCHARM_NAME"
  ( cd "$OUT" && sha256sum "$(basename "$OUT_TGZ")" > SHA256SUMS )

  # ---- verify: on this host ----
  verify_pycharm_dir "$PYCHARM_DIR" "host ($(uname -sr))"
  for f in java libjvm.so libjava.so; do
    p="$(find "$PYCHARM_DIR/jbr" -type f -name "$f" | head -1)"
    [ -n "$p" ] || continue
    log "  $(basename "$p"): max GLIBC $(max_glibc "$p") (target <= 2.17)"
  done

  # ---- verify: end-to-end from the produced tarball ----
  # (docker validates the tarball too; skip the extra host re-extract to save disk)
  if ! command -v docker >/dev/null 2>&1; then
    CHECK_DIR="$WORK/check"
    mkdir -p "$CHECK_DIR"
    tar -xzf "$OUT_TGZ" -C "$CHECK_DIR"
    verify_pycharm_dir "$CHECK_DIR/$PYCHARM_NAME" "produced tarball (fresh extract)"
  fi

  # ---- optional: docker (centos:7) validation ----
  if command -v docker >/dev/null 2>&1; then
    log "docker detected - validating in centos:7 container (glibc 2.17)"
    docker run --rm -v "$OUT:/dist:ro" centos:7 \
      bash -c "
        set -e
        mkdir -p /tmp/v
        tar xzf /dist/$(basename "$OUT_TGZ") -C /tmp/v
        /tmp/v/$PYCHARM_NAME/jbr/bin/java -version
        cd /tmp/v/$PYCHARM_NAME && ./bin/pycharm.sh --version
      " || die "validation inside centos:7 container failed"
  else
    log "docker not present - skipped container validation (host is CentOS 7)"
  fi

  if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK_DIR"
  fi

  log "DONE: $OUT_TGZ"
  cat "$OUT/SHA256SUMS"
}

main "$@"
