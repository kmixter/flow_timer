#!/bin/bash
set -e

# Verify that the current checkout is unchanged
if ! git diff-index --quiet HEAD --; then
  echo "There are uncommitted changes. Please commit or stash them before releasing."
  exit 1
fi

# Get the current tag
TAG=$(git describe --tags --exact-match 2>/dev/null)

if [[ $? -ne 0 ]]; then
  echo "No tag found on the current commit. Please tag the commit with a version like 'release-x.y.z'."
  exit 1
fi

# Extract version from the tag
if [[ $TAG =~ ^release-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  VERSION=${BASH_REMATCH[1]}
else
  echo "Tag format is incorrect. Please use 'release-x.y.z'."
  exit 1
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
dpkg-deb --build $TEMP_DIR/flow_timer flow-timer-$VERSION-$(date +%Y%m%d).deb

# Remove the temporary directory
rm -rf $TEMP_DIR