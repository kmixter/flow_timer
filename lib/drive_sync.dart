import 'dart:convert';
import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher_string.dart';
import 'local_storage.dart';

final _driveFolderName = 'FlowTimer';
final _logger = Logger('DriveSync');

class DriveSync {
  oauth2.Client? oauth2Client;
  String? driveFolderId;
  static const _scopes = ['https://www.googleapis.com/auth/drive.file'];
  late Map<String, dynamic> _credentials;
  final LocalStorage _localStorage;
  VoidCallback? onLoginStateChanged;
  void Function(ProjectMetadata, String, String)? onConflictDetected;

  DriveSync(this._localStorage);

  Future<void> initialize() async {
    await loadCredentials();

    refreshAccessToken().then((_) async {
      if (oauth2Client != null) {
        await postLogin();
      }
    });
  }

  Future<void> loadCredentials() async {
    final contents = await rootBundle.loadString('assets/client_secret.json');
    _credentials = jsonDecode(contents);
  }

  Future<void> login() async {
    if (Platform.isLinux || Platform.isMacOS) {
      await _loginWithBrowserAndLocalhost();
    } else {
      await _loginWithGoogleSignIn();
    }
    onLoginStateChanged?.call();

    if (oauth2Client != null) {
      await postLogin();
      onLoginStateChanged?.call();
    }
  }

  Future<void> logout() async {
    oauth2Client = null;
    onLoginStateChanged?.call();
  }

  Future<void> _authenticateWithGoogle(GoogleSignInAccount account) async {
    final GoogleSignInAuthentication googleAuth = await account.authentication;

    final oauth2.Credentials credentials = oauth2.Credentials(
      googleAuth.accessToken!,
      tokenEndpoint: Uri.parse('https://oauth2.googleapis.com/token'),
      scopes: ['https://www.googleapis.com/auth/drive.file'],
    );

    oauth2Client = oauth2.Client(credentials);
    _logger.info('Access token: ${oauth2Client!.credentials.accessToken}');

    if (!oauth2Client!.credentials.canRefresh) {
      _logger.warning('No refresh token received');
    } else {
      await _localStorage
          .storeRefreshToken(oauth2Client!.credentials.refreshToken!);
    }
    onLoginStateChanged?.call();
  }

  Future<void> _loginWithGoogleSignIn() async {
    final googleSignIn = GoogleSignIn.standard(scopes: _scopes);
    final account = await googleSignIn.signIn();
    _logger.fine('currentUser=$account');

    if (account == null) {
      return;
    }

    await _authenticateWithGoogle(account);
  }

  Future<void> _loginWithBrowserAndLocalhost() async {
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

    await launchUrlString(authorizationUrl.toString());

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
    final request = await server.first;
    final queryParams = request.uri.queryParameters;
    oauth2Client = await grant.handleAuthorizationResponse(queryParams);

    _logger.info('Access token: ${oauth2Client!.credentials.accessToken}');

    if (!oauth2Client!.credentials.canRefresh) {
      _logger.warning('No refresh token received');
    }

    await _localStorage
        .storeRefreshToken(oauth2Client!.credentials.refreshToken!);

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set('Content-Type', ContentType.html.mimeType)
      ..write(
          '<html><h1>Authentication successful! You can close this window.</h1></html>');
    await request.response.close();
    await server.close();
  }

  Future<void> postLogin() async {
    try {
      await _syncDriveProjectsFolder();
    } catch (e) {
      _logger.warning('Exception during postLogin; disabling drive sync');
      oauth2Client = null;
    }
  }

  Future<void> refreshAccessToken() async {
    if (Platform.isLinux || Platform.isMacOS) {
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
        try {
          await client.refreshCredentials();
        } catch (e) {
          _logger
              .warning('Exception while trying to refresh oauth2 access token');
          oauth2Client = null;
          return;
        }

        oauth2Client = client;
        onLoginStateChanged?.call();
        _logger
            .info('Refreshed access token: ${client.credentials.accessToken}');

        await _localStorage.storeRefreshToken(client.credentials.refreshToken!);
      }
    } else {
      final googleSignIn = GoogleSignIn.standard(scopes: _scopes);
      final account = await googleSignIn.signInSilently();
      if (account != null) {
        await _authenticateWithGoogle(account);
      } else {
        _logger.warning('Failed to silently sign in with Google');
        oauth2Client = null;
      }
    }
  }

  Future<void> _findOrCreateDriveFolder() async {
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

  Map<String, String> _getDriveHeaders() {
    return {
      'Authorization': 'Bearer ${oauth2Client!.credentials.accessToken}',
      'Content-Type': 'application/json',
    };
  }

  Future<String> _getDriveDigest(String fileId) async {
    final driveFileMetadataResponse = await http.get(
      Uri.parse(
          'https://www.googleapis.com/drive/v3/files/$fileId?fields=md5Checksum'),
      headers: _getDriveHeaders(),
    );
    final driveFileMetadata = jsonDecode(driveFileMetadataResponse.body);
    return driveFileMetadata['md5Checksum'] as String;
  }

  Future<String> _getDriveContents(String fileId) async {
    final driveFileResponse = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media'),
      headers: _getDriveHeaders(),
    );
    return driveFileResponse.body;
  }

  Future<void> _syncDriveProjectsFolder() async {
    if (driveFolderId == null) {
      await _findOrCreateDriveFolder();
      if (driveFolderId == null) {
        _logger.warning('Google Drive folder not found. Cannot sync it.');
        return;
      }
    }

    final listResponse = await http.get(
      Uri.parse(
          'https://www.googleapis.com/drive/v3/files?q=\'$driveFolderId\' in parents'),
      headers: _getDriveHeaders(),
    );

    final listResult = jsonDecode(listResponse.body);
    if (listResult['files'] == null || listResult['files'].isEmpty) {
      _logger.info('No files found in the $_driveFolderName folder.');
      return;
    }

    for (var file in listResult['files']) {
      var localProjectMetadata = _localStorage
          .getProjectMetadata(path.basenameWithoutExtension(file['name']));
      if (localProjectMetadata == null) {
        final name = path.basenameWithoutExtension(file['name']);
        localProjectMetadata = await _localStorage.createNewProject(name,
            contents: '', driveFileId: file['id']);
        _localStorage.updateDriveDigest(localProjectMetadata,
            await _localStorage.getProjectFileMd5Digest(localProjectMetadata));
        _logger
            .info('Created stub project: ${localProjectMetadata.relativePath}');
      }
      await syncProject(localProjectMetadata);
    }
  }

  Future<void> syncProject(ProjectMetadata projectMetadata) async {
    if (oauth2Client == null) {
      return;
    }

    String? latestDriveDigest;
    if (projectMetadata.driveFileId == null) {
      final listResponse = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files?q=\'$driveFolderId\' in parents and name=\'${projectMetadata.name}.txt\''),
        headers: _getDriveHeaders(),
      );
      final listResult = jsonDecode(listResponse.body);
      if (listResult['files'] != null && listResult['files'].isNotEmpty) {
        final fileId = listResult['files'].first['id'];
        _logger
            .info('Linking file with the same name (${projectMetadata.name})');
        _localStorage.updateFileId(projectMetadata, fileId);
        // Leave projectMetadata.driveDigest as null to signify a conflict.
      }
    }

    latestDriveDigest = await _getDriveDigest(projectMetadata.driveFileId!);

    final localDigest =
        await _localStorage.getProjectFileMd5Digest(projectMetadata);

    _logger.fine(
        '${projectMetadata.name}: last sync at: ${projectMetadata.driveDigest}, latest drive: $latestDriveDigest, latest local: $localDigest');

    if (projectMetadata.driveDigest != null &&
        latestDriveDigest != projectMetadata.driveDigest &&
        localDigest == projectMetadata.driveDigest) {
      _logger.info('Pulling changes from Drive');
      final driveFileContents =
          await _getDriveContents(projectMetadata.driveFileId!);
      await _localStorage.overwriteProjectContents(
          projectMetadata, driveFileContents);
      await _localStorage.updateDriveDigest(projectMetadata, latestDriveDigest);
    } else if (latestDriveDigest == projectMetadata.driveDigest &&
        localDigest != projectMetadata.driveDigest) {
      _logger.info('Pushing local changes to Drive');
      await _pushLocalChangesToDrive(projectMetadata);
    } else if (latestDriveDigest != projectMetadata.driveDigest &&
        localDigest != projectMetadata.driveDigest) {
      _logger.warning('Conflict detected for project: ${projectMetadata.name}');

      if (onConflictDetected != null) {
        final pushedOnConflictDetected = onConflictDetected!;
        onConflictDetected = null; // To prevent reentry into user prompt.
        final driveFileContents =
            await _getDriveContents(projectMetadata.driveFileId!);
        pushedOnConflictDetected(
            projectMetadata, latestDriveDigest, driveFileContents);
        onConflictDetected = pushedOnConflictDetected;
      }
    } else {
      _logger.info('Local file is up-to-date with Drive');
    }
  }

  Future<void> _pushLocalChangesToDrive(ProjectMetadata projectMetadata) async {
    final contents = await _localStorage.getProjectContents(projectMetadata);
    String? fileId = projectMetadata.driveFileId;

    if (fileId != null) {
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
        throw Exception('Failed to update file: ${updateResponse.body}');
      }

      _logger.info('Updated file ID: $fileId');
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
  "name": "${projectMetadata.name}.txt",
  "parents": ["$driveFolderId"]
}

--foo_bar_baz
Content-Type: text/plain

$contents
--foo_bar_baz--
''',
      );

      if (createResponse.statusCode != 200) {
        throw Exception('Failed to create file: ${createResponse.body}');
      }
      final uploadResponse = jsonDecode(createResponse.body);
      fileId = uploadResponse['id'];
      _logger.info('Uploaded new file ID: $fileId');
    }

    final updatedDriveDigest = await _getDriveDigest(fileId!);
    final localDigest =
        await _localStorage.getProjectFileMd5Digest(projectMetadata);

    if (updatedDriveDigest != localDigest) {
      throw Exception(
          'Digest mismatch after update: local: $localDigest, drive: $updatedDriveDigest');
    }
    await _localStorage.updateDriveDigest(projectMetadata, updatedDriveDigest);
  }
}
