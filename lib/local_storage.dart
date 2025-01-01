import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final _localStorageDir = '.config/FlowTimer';

class LocalStorage {
  late Directory _storageDirectory;
  late Metadata _metadata;

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
    final metadataFile =
        File(path.join(_storageDirectory.path, 'metadata.json'));
    if (await metadataFile.exists()) {
      final content = await metadataFile.readAsString();
      _metadata = Metadata.fromJson(jsonDecode(content));
    } else {
      _metadata = Metadata();
    }
  }

  Future<void> writeMetadata() async {
    final metadataFile =
        File(path.join(_storageDirectory.path, 'metadata.json'));
    await metadataFile.writeAsString(jsonEncode(_metadata.toJson()));
  }

  Future<void> storeRefreshToken(String refreshToken) async {
    _metadata.refreshToken = refreshToken;
    await writeMetadata();
  }

  Future<void> updateProjectPath(String descriptor, String filePath) async {
    _metadata.projects[descriptor]!.path = filePath;
    await writeMetadata();
  }

  Future<void> updateLastOpenedProject(String name) async {
    _metadata.lastOpenedProject = name;
    await writeMetadata();
  }

  Future<void> markCloudSync(String descriptor) async {
    _metadata.projects[descriptor]!.lastCloudSync = DateTime.now();
    await writeMetadata();
  }

  bool isKnownProject(String descriptor) {
    return _metadata.projects.containsKey(descriptor);
  }

  Future<ProjectMetadata> createNewProject(String name,
      {String contents = ''}) async {
    final localFile = path.join(_storageDirectory.path, '$name.txt');
    _metadata.projects[name] = ProjectMetadata(name, localFile, null);
    File localProject = File(localFile);
    await localProject.writeAsString(contents);
    await writeMetadata();
    return _metadata.projects[name]!;
  }

  ProjectMetadata? getProjectMetadata(String name) {
    return _metadata.projects[name];
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
  final double version = 1.0;
  String? refreshToken;
  String? lastOpenedProject;
  Map<String, ProjectMetadata> projects = {};

  Metadata();

  Metadata.fromJson(Map<String, dynamic> json) {
    refreshToken = json['refreshToken'];
    lastOpenedProject = json['lastOpenedProject'];
    final projectsJson = json['projects'];
    projects = {};
    if (projectsJson != null) {
      projects = projectsJson.map<String, ProjectMetadata>(
            (key, value) => MapEntry(key as String, ProjectMetadata.fromJson(value)));
    }
  }

  Map<String, dynamic> toJson() {
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
  String path;
  DateTime? lastCloudSync;

  ProjectMetadata(this.name, this.path, this.lastCloudSync);

  ProjectMetadata.empty(this.name)
      : path = '',
        lastCloudSync = null;

  ProjectMetadata.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        path = json['path'],
        lastCloudSync = json['lastCloudSync'] != null
            ? DateTime.parse(json['lastCloudSync'])
            : null;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'lastCloudSync': lastCloudSync?.toIso8601String(),
    };
  }
}
