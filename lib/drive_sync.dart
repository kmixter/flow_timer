import 'dart:convert';
import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

final _driveFolderName = 'FlowTimer';
final _localPreferencesDir = '.config/FlowTimer';
final _logger = Logger('DriveSync');

class DriveSync {
  oauth2.Client? oauth2Client;
  String? driveFolderId;
  static const _scopes = ['https://www.googleapis.com/auth/drive.file'];
  late Map<String, dynamic> _credentials;

  Future<void> loadCredentials() async {
    final file = File('assets/client_secret.json');
    final contents = await file.readAsString();
    _credentials = jsonDecode(contents);
  }

  Future<void> login() async {
    if (Platform.isLinux) {
      await _loginWithOAuth2();
    } else if (Platform.isAndroid) {
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

    await _storeRefreshToken(client.credentials.refreshToken);

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

  Future<void> _storeRefreshToken(String? refreshToken) async {
    if (refreshToken != null) {
      final directory = await _getPreferencesDirectory();
      final file = File(path.join(directory.path, 'refresh_token.txt'));
      await file.writeAsString(refreshToken);
    }
  }

  Future<String?> _loadRefreshToken() async {
    final directory = await _getPreferencesDirectory();
    final file = File(path.join(directory.path, 'refresh_token.txt'));
    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  Future<void> refreshAccessToken() async {
    final refreshToken = await _loadRefreshToken();
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

      await _storeRefreshToken(client.credentials.refreshToken);
    }
  }

  Future<void> syncNotesToDrive(String notesDescriptor, String contents) async {
    if (driveFolderId == null) {
      _logger.info('Not logged in. Cannot save to Drive.');
      return;
    }

    final fileName = '$notesDescriptor.txt';
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

  Future<Set<String>> _reconcileWithOAuth2() async {
    Set<String> modifiedPaths = {};
    if (driveFolderId == null) {
      _logger.info('Google Drive folder not found. Cannot reconcile.');
      return modifiedPaths;
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
      return modifiedPaths;
    }

    for (var file in listResult['files']) {
      final driveFileName = file['name'];
      _logger.fine('Considering Drive file: $driveFileName');
      _logger.fine('All Drive metadata is: $file');
      final localFilePath = _getNotesPathFromDriveFileName(driveFileName);
      _logger.fine('Equivalent local path: $localFilePath');
      final localFile = File(localFilePath);

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

      if (await localFile.exists()) {
        final localFileModifiedTime = await localFile.lastModified();
        _logger.info(
            'Comparing local ($localFileModifiedTime) vs drive ($driveFileModifiedTime)');
        if (driveFileModifiedTime.isAfter(localFileModifiedTime)) {
          _logger.info('Synchronizing local file to drive');
          await localFile.writeAsString(driveFileContents);
          modifiedPaths.add(localFilePath);
        } else {
          _logger.info(
              'Local file is newer than drive, letting using manually save');
        }
      } else {
        await _createParentDirectories(localFilePath);
        await localFile.writeAsString(driveFileContents);
        _logger.info('Created local file: $localFilePath');
      }
    }
    return modifiedPaths;
  }

  Future<Directory> _getPreferencesDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final preferencesDirectory =
        Directory(path.join(directory.path, _localPreferencesDir));
    if (!await preferencesDirectory.exists()) {
      await preferencesDirectory.create(recursive: true);
    }
    return preferencesDirectory;
  }

  Future<void> _createParentDirectories(String filePath) async {
    final directory = Directory(path.dirname(filePath));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  String getNotesDescriptor(String filepath) {
    return path.basename(path.dirname(filepath));
  }

  String _getNotesPath(String descriptor) {
    return path.join(
        Platform.environment['HOME']!, 'prj', descriptor, 'notes.txt');
  }

  String _getNotesPathFromDriveFileName(String driveFileName) {
    final descriptor = driveFileName.endsWith('.txt')
        ? driveFileName.substring(0, driveFileName.length - 4)
        : driveFileName;
    return _getNotesPath(descriptor);
  }
}
