#!/bin/bash
set -e

FORCE=false
NOBUILD=false

source "$(dirname "$0")/common.sh"

usage() {
  echo "Usage: $0 [--force] [--nobuild] [-h]"
  echo "  --force    Ignore uncommitted changes"
  echo "  --nobuild  Skip the build step"
  echo "  -h         Show this help message"
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --force) FORCE=true ;;
    --nobuild) NOBUILD=true ;;
    -h) usage ;;
    *) echo "Unknown parameter passed: $1"; usage ;;
  esac
  shift
done

verify_git_status

prepare_build
clean_build

if ! $NOBUILD; then
  flutter build macos --profile
fi

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
mkdir -p $TEMP_DIR/flow_timer

# Copy built application
cp -r build/macos/Build/Products/Profile/flow_timer.app $TEMP_DIR/flow_timer/

# Create DMG
set -x
create-dmg --volname "Flow Timer $VERSION" --window-size 800 600 --icon-size 256 --app-drop-link 600 185 --icon "flow_timer.app" 200 185 $RELEASE_DIR/flow-timer-$VERSION.dmg $TEMP_DIR/flow_timer

# Remove the temporary directory
rm -rf $TEMP_DIR

echo "macOS build complete. DMG is in the $RELEASE_DIR directory."
