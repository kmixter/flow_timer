#!/bin/bash

# Check if the GoogleService-Info.plist file path is provided
if [ -z "$1" ]; then
  echo "Usage: $0 path/to/GoogleService-Info.plist"
  exit 1
fi

# Path to the provided GoogleService-Info.plist
GOOGLE_SERVICE_PLIST="$1"

# Path to the template Info.plist
TEMPLATE_INFO_PLIST="ios/Runner/Info.plist.template"

# Path to the new Info.plist
NEW_INFO_PLIST="ios/Runner/Info.plist"

# Copy the template Info.plist to the new Info.plist
cp "$TEMPLATE_INFO_PLIST" "$NEW_INFO_PLIST"

# Extract values from GoogleService-Info.plist using PlistBuddy
CLIENT_ID=$(/usr/libexec/PlistBuddy -c "Print :CLIENT_ID" "$GOOGLE_SERVICE_PLIST")
REVERSED_CLIENT_ID=$(/usr/libexec/PlistBuddy -c "Print :REVERSED_CLIENT_ID" "$GOOGLE_SERVICE_PLIST")
# Add any other keys you need to extract here...

# Add the extracted values to the new Info.plist using PlistBuddy
/usr/libexec/PlistBuddy -c "Add :GIDClientID string $CLIENT_ID" "$NEW_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$NEW_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$NEW_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$NEW_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $REVERSED_CLIENT_ID" "$NEW_INFO_PLIST"
# Add any other keys you extracted to the new Info.plist here...

echo "Successfully created $NEW_INFO_PLIST with values from $GOOGLE_SERVICE_PLIST"
