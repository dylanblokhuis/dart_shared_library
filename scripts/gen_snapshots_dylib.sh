#!/usr/bin/env bash
# Generate Dart AOT snapshots for use with dart_dll and as Mach-O dylib for symbol inspection.
# Uses Dart SDK gen_snapshot (3.8.2; no app-aot-macho-dylib) and frontend_server with AOT/TFA.
#
# Produces:
#   - Core snapshot: vm_snapshot_data, vm_snapshot_instructions,
#     isolate_snapshot_data, isolate_snapshot_instructions (four .bin files)
#   - App AOT dylib: app_snapshot.dylib built from app-aot-assembly (Dart 3.8.2 compatible)
#
# The app dylib exposes: kDartVmSnapshotData, kDartVmSnapshotInstructions,
#   kDartIsolateSnapshotData, kDartIsolateSnapshotInstructions (inspect with nm -gU).
#
# Usage:
#   ./scripts/gen_snapshots_dylib.sh [OUTPUT_DIR]
#   OUTPUT_DIR defaults to ./build/snapshots
#
# Env (optional): GEN_SNAPSHOT, DART_SDK_ROOT
# Requires: clang (to assemble/link .S -> .dylib)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/build/snapshots}"
# Canonicalize so frontend_server (which may run with different cwd) can open the file
OUTPUT_DIR="$(cd "$REPO_ROOT" && mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
GEN_SNAPSHOT="${GEN_SNAPSHOT:-/Users/dylanblokhuis/Downloads/dart-sdk-3.8.2/bin/utils/gen_snapshot}"
DART_SDK_ROOT="${DART_SDK_ROOT:-$(dirname "$(dirname "$(dirname "$GEN_SNAPSHOT")")")}"
PLATFORM_KERNEL="${DART_SDK_ROOT}/lib/_internal/vm_platform_strong.dill"
DART_AOT_RUNTIME="${DART_SDK_ROOT}/bin/dartaotruntime"
FRONTEND_SNAPSHOT="${DART_SDK_ROOT}/bin/snapshots/frontend_server_aot.dart.snapshot"

# Minimal Dart app used only for generating the AOT dylib (for symbol inspection)
MINIMAL_APP="$REPO_ROOT/examples/simple_example/hello_world.dart"

# All paths passed to frontend_server must be absolute (it may run with different cwd)
APP_DILL="$OUTPUT_DIR/app_aot.dill"
APP_DYLIB="$OUTPUT_DIR/app_snapshot.dylib"

cd "$OUTPUT_DIR"

echo "=== Output directory: $OUTPUT_DIR ==="
echo "=== gen_snapshot: $GEN_SNAPSHOT ==="
echo "=== Dart SDK root: $DART_SDK_ROOT ==="
echo ""

# --- 1. Core snapshot (four artifacts for VM bootstrap) ---
echo "--- Generating core snapshot (vm + isolate data + instructions) ---"
if [[ ! -f "$PLATFORM_KERNEL" ]]; then
  echo "Error: Platform kernel not found: $PLATFORM_KERNEL" >&2
  exit 1
fi

"$GEN_SNAPSHOT" \
  --snapshot_kind=core \
  --vm_snapshot_data=vm_snapshot_data.bin \
  --vm_snapshot_instructions=vm_snapshot_instructions.bin \
  --isolate_snapshot_data=isolate_snapshot_data.bin \
  --isolate_snapshot_instructions=isolate_snapshot_instructions.bin \
  "$PLATFORM_KERNEL"

echo "Core snapshot files:"
ls -la vm_snapshot_data.bin vm_snapshot_instructions.bin isolate_snapshot_data.bin isolate_snapshot_instructions.bin 2>/dev/null || true
echo ""

# --- 2. App AOT as Mach-O dylib (Dart 3.8.2: use app-aot-assembly then assemble/link) ---
echo "--- Generating app AOT dylib (assembly -> clang -> dylib) ---"

APP_ASSEMBLY="$OUTPUT_DIR/app_snapshot.S"
APP_OBJECT="$OUTPUT_DIR/app_snapshot.o"

# Build AOT kernel using frontend_server (required for gen_snapshot)
# Use absolute paths so frontend_server can open files regardless of its cwd.
if [[ -f "$DART_AOT_RUNTIME" && -f "$FRONTEND_SNAPSHOT" && -f "$PLATFORM_KERNEL" ]]; then
  "$DART_AOT_RUNTIME" "$FRONTEND_SNAPSHOT" \
    --sdk-root="$DART_SDK_ROOT" \
    --platform="$PLATFORM_KERNEL" \
    --aot --tfa --link-platform \
    --output-dill="$APP_DILL" \
    "$MINIMAL_APP" >/tmp/gen_snapshots_frontend.log 2>&1 || true
  if [[ ! -f "$APP_DILL" || ! -s "$APP_DILL" ]]; then
    echo "Warning: AOT kernel not produced; see /tmp/gen_snapshots_frontend.log" >&2
    APP_DILL=""
  fi
else
  echo "Warning: dartaotruntime or frontend_server_aot not found; skipping app dylib." >&2
  APP_DILL=""
fi

if [[ -f "$APP_DILL" ]]; then
  # Dart 3.8.2 has no app-aot-macho-dylib; use app-aot-assembly and build dylib ourselves
  "$GEN_SNAPSHOT" \
    --snapshot_kind=app-aot-assembly \
    --assembly="$APP_ASSEMBLY" \
    "$APP_DILL"

  if [[ ! -f "$APP_ASSEMBLY" ]]; then
    echo "Warning: gen_snapshot did not produce $APP_ASSEMBLY" >&2
  elif command -v clang &>/dev/null; then
    ARCH=$(uname -m)
    clang -c -arch "$ARCH" -o "$APP_OBJECT" "$APP_ASSEMBLY"
    clang -shared -arch "$ARCH" -o "$APP_DYLIB" "$APP_OBJECT"
    echo "App dylib: $APP_DYLIB"
    ls -la "$APP_DYLIB"
    echo ""
    echo "--- Symbols exposed by the AOT dylib (nm -gU) ---"
    nm -gU "$APP_DYLIB" 2>/dev/null
    echo ""
    echo "--- (Full symbol list: nm -gU $APP_DYLIB) ---"
  else
    echo "Assembly written to $APP_ASSEMBLY (clang not found; not building dylib)." >&2
  fi
else
  echo "Skipped app dylib (no AOT kernel file)."
fi

echo ""
echo "Done. Core snapshot files and (if generated) app dylib are in: $OUTPUT_DIR"
