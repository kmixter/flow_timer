#!/bin/bash
set -v

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
mkdir -p $TEMP_DIR/flow_timer/DEBIAN
mkdir -p $TEMP_DIR/flow_timer/usr/local/bin
mkdir -p $TEMP_DIR/flow_timer/usr/share/applications
mkdir -p $TEMP_DIR/flow_timer/usr/share/icons/hicolor/256x256/apps

# Copy built application and icon
cp -r build/linux/x64/release/bundle/* $TEMP_DIR/flow_timer/usr/local/bin/
cp assets/logo.jpg $TEMP_DIR/flow_timer/usr/share/icons/hicolor/256x256/apps/flow_timer.jpg

# Create control file
cat <<EOL > $TEMP_DIR/flow_timer/DEBIAN/control
Package: flow-timer
Version: 1.0
Section: base
Priority: optional
Architecture: amd64
Depends: libgtk-3-0
Maintainer: Your Name <your.email@example.com>
Description: Flow Timer
 A brief description of your Flutter application.
EOL

# Create desktop entry file
cat <<EOL > $TEMP_DIR/flow_timer/usr/share/applications/flow_timer.desktop
[Desktop Entry]
Name=Flow Timer
Exec=/usr/local/bin/flow_timer
Icon=/usr/share/icons/hicolor/256x256/apps/flow_timer.jpg
Type=Application
Categories=Utility;
EOL

# Build Debian package
cd release
dpkg-deb --build $TEMP_DIR/flow_timer flow-timer-20250105.deb

# Remove the temporary directory
rm -rf $TEMP_DIR
