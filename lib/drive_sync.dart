import 'dart:convert';
import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'local_storage.dart';

final _driveFolderName = 'FlowTimer';
final _logger = Logger('DriveSync');

class DriveSync {
  oauth2.Client? oauth2Client;
  String? driveFolderId;
  static const _scopes = ['https://www.googleapis.com/auth/drive.file'];
  late Map<String, dynamic> _credentials;
  final LocalStorage _localStorage;

  DriveSync(this._localStorage);

  Future<void> initialize() async {
    await loadCredentials();

    refreshAccessToken().then((_) async {
      if (oauth2Client != null) {
        await postLoginWithOAuth2();
      }
    });
  }

  Future<void> loadCredentials() async {
    final contents = await rootBundle.loadString('assets/client_secret.json');
    _credentials = jsonDecode(contents);
  }

  Future<void> login() async {
    if (Platform.isLinux || Platform.isMacOS) {
      await _loginWithOAuth2();
    } else {
      await _loginWithGoogleSignIn();
    }
  }

  Future<void> _loginWithGoogleSignIn() async {
    final googleSignIn = GoogleSignIn.standard(scopes: _scopes);
    final account = await googleSignIn.signIn();
    _logger.fine('currentUser=$account');
  }

  Future<void> _loginWithOAuth2() async {
    final authorizationEndpoint = Uri.parse(_credentials['web']['auth_uri']);
    final tokenEndpoint = Uri.parse(_credentials['web']['token_uri']);
    final identifier = _credentials['web']['client_id'];
    final secret = _credentials['web']['client_secret'];
    final redirectUrl = Uri.parse(_credentials['web']['redirect_uris'][0]);

    final grant = oauth2.AuthorizationCodeGrant(
      identifier,
      authorizationEndpoint,
      tokenEndpoint,
      secret: secret,
    );

    Uri authorizationUrl =
        grant.getAuthorizationUrl(redirectUrl, scopes: _scopes);
    authorizationUrl = authorizationUrl.replace(queryParameters: {
      ...authorizationUrl.queryParameters,
      'access_type': 'offline',
      'prompt': 'select_account consent'
    });

    await launch(authorizationUrl.toString());

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
    final request = await server.first;
    final queryParams = request.uri.queryParameters;
    final client = await grant.handleAuthorizationResponse(queryParams);

    oauth2Client = client;
    _logger.info('Access token: ${client.credentials.accessToken}');

    if (!client.credentials.canRefresh) {
      _logger.warning('No refresh token received');
    }

    await _localStorage.storeRefreshToken(client.credentials.refreshToken!);

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set('Content-Type', ContentType.html.mimeType)
      ..write(
          '<html><h1>Authentication successful! You can close this window.</h1></html>');
    await request.response.close();
    await server.close();

    await postLoginWithOAuth2();
  }

  Future<void> postLoginWithOAuth2() async {
    await _findOrCreateDriveFolderWithOAuth2();
    await _reconcileWithOAuth2();
  }

  Future<void> refreshAccessToken() async {
    final refreshToken = _localStorage.refreshToken;
    if (refreshToken != null) {
      final credentials = oauth2.Credentials(
        '',
        refreshToken: refreshToken,
        tokenEndpoint: Uri.parse(_credentials['web']['token_uri']),
      );

      final client = oauth2.Client(credentials,
          identifier: _credentials['web']['client_id'],
          secret: _credentials['web']['client_secret']);
      await client.refreshCredentials();

      oauth2Client = client;
      _logger.info('Refreshed access token: ${client.credentials.accessToken}');

      await _localStorage.storeRefreshToken(client.credentials.refreshToken!);
    }
  }

  Future<void> syncProjectToDrive(
      String projectDescriptor, String contents) async {
    if (driveFolderId == null) {
      _logger.info('Not logged in. Cannot save to Drive.');
      return;
    }

    final fileName = '$projectDescriptor.txt';
    final headers = {
      'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
      'Content-Type': 'application/json',
    };

    final searchResponse = await http.get(
      Uri.parse(
          'https://www.googleapis.com/drive/v3/files?q=name=\'$fileName\' and \'$driveFolderId\' in parents'),
      headers: headers,
    );

    final searchResult = jsonDecode(searchResponse.body);
    if (searchResult['files'] != null && searchResult['files'].isNotEmpty) {
      final fileId = searchResult['files'].first['id'];
      final updateResponse = await http.patch(
        Uri.parse(
            'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media'),
        headers: {
          'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
          'Content-Type': 'text/plain',
        },
        body: contents,
      );

      if (updateResponse.statusCode != 200) {
        _logger.severe('Failed to update file: ${updateResponse.body}');
      } else {
        _logger.info('Updated file ID: $fileId');
        await _localStorage.markCloudSync(projectDescriptor);
      }
    } else {
      final createResponse = await http.post(
        Uri.parse(
            'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart'),
        headers: {
          'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
          'Content-Type': 'multipart/related; boundary=foo_bar_baz',
        },
        body: '''
--foo_bar_baz
Content-Type: application/json; charset=UTF-8

{
  "name": "$fileName",
  "parents": ["$driveFolderId"]
}

--foo_bar_baz
Content-Type: text/plain

$contents
--foo_bar_baz--
''',
      );

      if (createResponse.statusCode != 200) {
        _logger.severe('Failed to create file: ${createResponse.body}');
      } else {
        final createdFile = jsonDecode(createResponse.body);
        _logger.info('Created file ID: ${createdFile['id']}');
        await _localStorage.markCloudSync(projectDescriptor);
      }
    }
  }

  Future<void> _findOrCreateDriveFolderWithOAuth2() async {
    final headers = {
      'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
      'Content-Type': 'application/json',
    };

    final searchResponse = await http.get(
      Uri.parse(
          'https://www.googleapis.com/drive/v3/files?q=name=\'$_driveFolderName\' and mimeType=\'application/vnd.google-apps.folder\''),
      headers: headers,
    );

    final searchResult = jsonDecode(searchResponse.body);
    if (searchResult['files'] != null && searchResult['files'].isNotEmpty) {
      driveFolderId = searchResult['files'].first['id'];
      _logger.fine('Found folder ID: $driveFolderId');
    } else {
      final createResponse = await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files'),
        headers: headers,
        body: jsonEncode({
          'name': _driveFolderName,
          'mimeType': 'application/vnd.google-apps.folder',
        }),
      );

      final createdFolder = jsonDecode(createResponse.body);
      driveFolderId = createdFolder['id'];
      _logger.info('Created folder ID: $driveFolderId');
    }
  }

  Future<void> _reconcileWithOAuth2() async {
    if (driveFolderId == null) {
      _logger.info('Google Drive folder not found. Cannot reconcile.');
      return;
    }

    final headers = {
      'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
      'Content-Type': 'application/json',
    };

    final listResponse = await http.get(
      Uri.parse(
          'https://www.googleapis.com/drive/v3/files?q=\'$driveFolderId\' in parents'),
      headers: headers,
    );

    final listResult = jsonDecode(listResponse.body);
    if (listResult['files'] == null || listResult['files'].isEmpty) {
      _logger.info('No files found in the $_driveFolderName folder.');
      return;
    }

    for (var file in listResult['files']) {
      final driveFileName = file['name'];
      _logger.fine('Considering Drive file: $driveFileName');
      _logger.fine('All Drive metadata is: $file');
      final name = path.basenameWithoutExtension(driveFileName);
      var localProjectMetadata = _localStorage.getProjectMetadata(name);
      _logger.fine('Equivalent local relative path: ${localProjectMetadata?.relativePath}');

      final driveFileResponse = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files/${file['id']}?alt=media'),
        headers: headers,
      );

      final driveFileContents = driveFileResponse.body;
      final driveFileMetadataResponse = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files/${file['id']}?fields=modifiedTime'),
        headers: headers,
      );
      final driveFileMetadata = jsonDecode(driveFileMetadataResponse.body);
      final driveFileModifiedTime =
          DateTime.parse(driveFileMetadata['modifiedTime']);

      if (localProjectMetadata == null) {
        _localStorage.createNewProject(name, contents: driveFileContents);
        localProjectMetadata = _localStorage.getProjectMetadata(name);
        await _localStorage.markCloudSync(name);
        _logger.info('Created local project: ${localProjectMetadata!.relativePath}');
      }

      final localFileModifiedTime = await _localStorage.getProjectFileModifiedTime(localProjectMetadata);
      _logger.info(
          'Comparing local ($localFileModifiedTime) vs drive ($driveFileModifiedTime)');
      if (driveFileModifiedTime.isAfter(localFileModifiedTime)) {
        _logger.info('Synchronizing local file to drive');
        await _localStorage.overwriteProjectContents(localProjectMetadata, driveFileContents);
        await _localStorage.markCloudSync(name);
      } else {
        _logger
            .info('Local file is newer than drive, letting user manually save');
      }
    }
  }
}
