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
  flutter build linux --profile
fi

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
mkdir -p $TEMP_DIR/flow_timer/DEBIAN
mkdir -p $TEMP_DIR/flow_timer/usr/local/bin
mkdir -p $TEMP_DIR/flow_timer/usr/share/applications
mkdir -p $TEMP_DIR/flow_timer/usr/share/icons/hicolor/256x256/apps

# Copy built application and icon
cp -r build/linux/x64/release/bundle/* $TEMP_DIR/flow_timer/usr/local/bin/
cp assets/icon/icon_linux.png $TEMP_DIR/flow_timer/usr/share/icons/hicolor/256x256/apps/flow_timer.png

# Create control file
cat <<EOL > $TEMP_DIR/flow_timer/DEBIAN/control
Package: flow-timer
Version: $VERSION
Section: base
Priority: optional
Architecture: amd64
Depends: libgtk-3-0
Maintainer: Your Name <your.email@example.com>
Description: Flow Timer
 Plan and time your flow state.
EOL

# Create desktop entry file
cat <<EOL > $TEMP_DIR/flow_timer/usr/share/applications/flow_timer.desktop
[Desktop Entry]
Name=Flow Timer
Exec=/usr/local/bin/flow_timer
Icon=/usr/share/icons/hicolor/256x256/apps/flow_timer.png
Type=Application
Categories=Utility;
EOL

# Build Debian package
cd release
dpkg-deb --build $TEMP_DIR/flow_timer flow-timer-$VERSION.deb

# Remove the temporary directory
rm -rf $TEMP_DIR