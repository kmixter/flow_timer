# Flow Timer

Plan and time your flow state. Create todos/notes across multiple projects,
sychronized across platforms in your Google Drive account (optionally).
Provides heuristics to make it clearer which TODOs to work on next.

This application is vscode-text-todos compliant app.
See the vscode text-todos extension for more details of this file format.

# Cloud sync

To build this, you will need to create a new Google Cloud project: https://console.cloud.google.com/welcome.

Enable APIs and Services > + Enable APIs and Services > Google Drive API > ENABLE

Credentials > Configure Consent screen > User Type: external
   > fill out page one > scopes > add or remove scopes
   > in the filter field, type drive.file and select
   > Add just the emails needed for testing up to 100.

Credentials > + Create Credentials > OAuth client ID
   > Application Type: Web Application > Name: Flutter Client
   > Authorized redirect URIs: http://localhost:8080
   > Click DOWNLOAD JSON and save this to your Google Drive
   > Also copy it into assets/client_secret.json 

It is recommended you save this file in Google Drive as something like flow-timer-client_secret.json for safe keeping.

# Dependencies

On Linux:

sudo apt-get install zenity

You will need to create an appopriate Google Cloud project with drive.file permission
which is required for cloud synchronizing.

On MacOS:

brew install create-dmg

# Icons

To update iOS/Mac icons use:

flutter pub run flutter_launcher_icons:main

# Release

To release, create a new release-x.y.z tag and use the script:

scripts/build_linux_release.sh
scripts/build_macos_release.sh
