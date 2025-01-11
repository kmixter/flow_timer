import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flow_timer/project.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:watcher/watcher.dart';
import 'package:synchronized/synchronized.dart';
import 'package:crypto/crypto.dart';

final Logger _logger = Logger('LocalStorage');

final _localStorageDir = '.config/FlowTimer';
final _lock = Lock();

const metadataVersion = 0.2;

class LocalStorage {
  late Directory _storageDirectory;
  late Metadata _metadata;
  VoidCallback? onChanges;

  Future<void> initialize({String? overrideStorageDirectory}) async {
    if (overrideStorageDirectory != null) {
      _storageDirectory = Directory(overrideStorageDirectory);
    } else {
      final directory = await getApplicationDocumentsDirectory();
      if (Platform.isLinux) {
        _storageDirectory =
            Directory(path.join(directory.path, _localStorageDir));
      } else {
        _storageDirectory = directory;
      }
    }
    if (!await _storageDirectory.exists()) {
      await _storageDirectory.create(recursive: true);
    }
    await loadMetadata();
  }

  Directory get storageDirectory => _storageDirectory;
  String? get refreshToken => _metadata.refreshToken;
  String? get lastOpenedProject => _metadata.lastOpenedProject;
  Metadata get metadata => _metadata;

  Future<void> loadMetadata() async {
    await _lock.synchronized(() async {
      final metadataFile =
          File(path.join(_storageDirectory.path, 'metadata.json'));
      _logger.info('Loading $metadataFile');
      if (await metadataFile.exists()) {
        final content = await metadataFile.readAsString();
        _metadata = Metadata.fromJson(jsonDecode(content));
      } else {
        _metadata = Metadata();
      }
      if (_metadata.version == 0.1) {
        throw Exception('Incompatible metadata version: ${_metadata.version}');
      }
      onChanges?.call();
    });
  }

  Future<void> logFilesInDocumentsDirectory() async {
    final documentsDir = _storageDirectory;
    final List<FileSystemEntity> entities = await documentsDir.list().toList();

    for (FileSystemEntity entity in entities) {
      if (entity is File) {
        _logger.info('File: ${entity.path}');
      } else if (entity is Directory) {
        _logger.info('Directory: ${entity.path}');
      }
    }
  }

  Future<void> writeMetadata() async {
    await _lock.synchronized(() async {
      final metadataFile =
          File(path.join(_storageDirectory.path, 'metadata.json'));
      final tempFile = File('${metadataFile.path}.tmp');
      await tempFile.writeAsString(jsonEncode(_metadata.toJson()));
      await tempFile.rename(metadataFile.path);
    });
  }

  Future<void> storeRefreshToken(String refreshToken) async {
    _metadata.refreshToken = refreshToken;
    await writeMetadata();
  }

  File _getProjectFile(ProjectMetadata project) {
    return File(getAbsolutePath(project));
  }

  Future<String> getProjectFileMd5Digest(ProjectMetadata project) async {
    return await _lock.synchronized(() async {
      final File localFile = _getProjectFile(project);
      final bytes = await localFile.readAsBytes();
      return md5.convert(bytes).toString();
    });
  }

  Future<String> getProjectContents(ProjectMetadata project) async {
    return await _lock.synchronized(() async {
      final File localFile = _getProjectFile(project);
      return await localFile.readAsString();
    });
  }

  Future<Project> loadProject(ProjectMetadata projectMetadata) async {
    return await _lock.synchronized(() async {
      final File localFile = _getProjectFile(projectMetadata);
      final content = await localFile.readAsString();
      final project = Project();
      await project.parse(content);
      return project;
    });
  }

  Future<void> overwriteProjectContents(
      ProjectMetadata project, String contents) async {
    await _lock.synchronized(() async {
      final File localFile = _getProjectFile(project);
      await localFile.writeAsString(contents);
      onChanges?.call();
    });
  }

  StreamSubscription<WatchEvent> watchProject(
      ProjectMetadata project, void Function(WatchEvent event) callback) {
    final watcher = FileWatcher(getAbsolutePath(project));
    return watcher.events.listen((event) {
      callback(event);
    });
  }

  @visibleForTesting
  String getAbsolutePath(ProjectMetadata project) {
    return path.join(_storageDirectory.path, project.relativePath);
  }

  Future<DateTime> getProjectFileModifiedTime(ProjectMetadata project) async {
    return await _lock.synchronized(() async {
      final File localFile = _getProjectFile(project);
      return await localFile.lastModified();
    });
  }

  Future<void> updateLastOpenedProject(String name) async {
    _metadata.lastOpenedProject = name;
    await writeMetadata();
  }

  Future<void> updateDriveDigest(
      ProjectMetadata project, String driveDigest) async {
    project.driveDigest = driveDigest;
    await writeMetadata();
  }

  Future<void> updateFileId(ProjectMetadata project, String driveFileId) async {
    project.driveFileId = driveFileId;
    await writeMetadata();
  }

  bool isKnownProject(String descriptor) {
    return _metadata.projects.containsKey(descriptor);
  }

  Future<ProjectMetadata> createNewProject(String name,
      {String contents = '', String? driveFileId, String? driveDigest}) async {
    ProjectMetadata projectMetadata = ProjectMetadata(name, '$name.txt',
        driveFileId: driveFileId, driveDigest: driveDigest);
    _metadata.projects[name] = projectMetadata;
    await overwriteProjectContents(projectMetadata, contents);
    await writeMetadata();
    return projectMetadata;
  }

  ProjectMetadata? getProjectMetadata(String name) {
    return _metadata.projects[name];
  }

  ProjectMetadata? getProjectMetadataFromFileId(String fileId) {
    return _metadata.projects.values.cast<ProjectMetadata?>().firstWhere(
        (project) => project!.driveFileId == fileId,
        orElse: () => null);
  }

  ProjectMetadata? getFirstProjectMetadata() {
    if (_metadata.projects.isEmpty) {
      return null;
    }
    return _metadata.projects.values.first;
  }

  List<String> getProjectNames() {
    return _metadata.projects.keys.toList();
  }
}

class Metadata {
  double version = metadataVersion;
  String? refreshToken;
  String? lastOpenedProject;
  Map<String, ProjectMetadata> projects = {};

  Metadata();

  Metadata.fromJson(Map<String, dynamic> json) {
    version = json['version'];
    refreshToken = json['refreshToken'];
    lastOpenedProject = json['lastOpenedProject'];
    final projectsJson = json['projects'];
    projects = {};
    if (projectsJson != null) {
      projects = projectsJson.map<String, ProjectMetadata>((key, value) =>
          MapEntry(key as String, ProjectMetadata.fromJson(value)));
    }
  }

  Map<String, dynamic> toJson() {
    version = metadataVersion;
    return {
      'version': version,
      'refreshToken': refreshToken,
      'lastOpenedProject': lastOpenedProject,
      'projects': projects
          .map<String, dynamic>((key, value) => MapEntry(key, value.toJson())),
    };
  }
}

class ProjectMetadata {
  final String name;
  String relativePath;
  String? driveDigest;
  String? driveFileId;

  ProjectMetadata(this.name, this.relativePath,
      {this.driveFileId, this.driveDigest});

  ProjectMetadata.empty(this.name)
      : relativePath = '',
        driveDigest = null,
        driveFileId = null;

  ProjectMetadata.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        relativePath = json['relativePath'],
        driveDigest = json['driveDigest'],
        driveFileId = json['driveFileId'];

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'relativePath': relativePath,
      'driveDigest': driveDigest,
      'driveFileId': driveFileId, // Serialize
    };
  }
}
