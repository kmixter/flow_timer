import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:flow_timer/local_storage.dart';

void main() {
  late LocalStorage localStorage;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    localStorage = LocalStorage();
    await localStorage.initialize(overrideStorageDirectory: tempDir.path);
    await localStorage.loadMetadata();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('initialize creates storage directory', () async {
    expect(await localStorage.storageDirectory.exists(), isTrue);
  });

  test('loadMetadata loads existing metadata', () async {
    final metadataFile = File(path.join(tempDir.path, 'metadata.json'));
    await metadataFile.writeAsString('{"refreshToken": "token"}');
    await localStorage.loadMetadata();
    expect(localStorage.refreshToken, 'token');
  });

  test('writeMetadata writes metadata to file', () async {
    localStorage.metadata.refreshToken = 'new_token';
    await localStorage.writeMetadata();
    final metadataFile = File(path.join(tempDir.path, 'metadata.json'));
    final content = await metadataFile.readAsString();
    expect(content, contains('"refreshToken":"new_token"'));
  });

  test('storeRefreshToken updates refresh token', () async {
    await localStorage.storeRefreshToken('stored_token');
    expect(localStorage.refreshToken, 'stored_token');
  });

  test('createNewProject creates a new project', () async {
    final project = await localStorage.createNewProject('TestProject');
    expect(project.name, 'TestProject');
    expect(await File(localStorage.getAbsolutePath(project)).exists(), isTrue);
  });

  test('getProjectMetadata returns correct metadata', () {
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path', null);
    final project = localStorage.getProjectMetadata('TestProject');
    expect(project?.name, 'TestProject');
  });

  test('getFirstProjectMetadata returns first project', () {
    localStorage.metadata.projects['FirstProject'] =
        ProjectMetadata('FirstProject', 'path', null);
    localStorage.metadata.projects['SecondProject'] =
        ProjectMetadata('SecondProject', 'path', null);
    final project = localStorage.getFirstProjectMetadata();
    expect(project?.name, 'FirstProject');
  });

  test('getProjectNames returns list of project names', () {
    localStorage.metadata.projects['FirstProject'] =
        ProjectMetadata('FirstProject', 'path', null);
    localStorage.metadata.projects['SecondProject'] =
        ProjectMetadata('SecondProject', 'path', null);
    final projectNames = localStorage.getProjectNames();
    expect(projectNames, containsAll(['FirstProject', 'SecondProject']));
  });

  test('markCloudSync updates last cloud sync time', () async {
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path', null);
    await localStorage.markCloudSync('TestProject');
    expect(localStorage.getProjectMetadata('TestProject')?.lastCloudSync,
        isNotNull);
  });

  test('isKnownProject returns true for known project', () {
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path', null);
    expect(localStorage.isKnownProject('TestProject'), isTrue);
  });

  test('isKnownProject returns false for unknown project', () {
    expect(localStorage.isKnownProject('UnknownProject'), isFalse);
  });

  test('store and read metadata', () async {
    final testDate = DateTime(2023, 1, 10);
    localStorage.metadata.refreshToken = 'test_token';
    localStorage.metadata.lastOpenedProject = 'TestProject';
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'relpath', testDate);
    localStorage.metadata.projects['AnotherProject'] =
        ProjectMetadata('AnotherProject', 'another_relpath', null);
    await localStorage.writeMetadata();

    final newLocalStorage = LocalStorage();
    await newLocalStorage.initialize(overrideStorageDirectory: tempDir.path);
    await newLocalStorage.loadMetadata();

    expect(newLocalStorage.refreshToken, 'test_token');
    expect(newLocalStorage.lastOpenedProject, 'TestProject');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.name, 'TestProject');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.relativePath, 'relpath');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.lastCloudSync, testDate);
    expect(newLocalStorage.getProjectMetadata('AnotherProject')?.name, 'AnotherProject');
  });

  test('getAbsolutePath returns correct absolute path', () async {
    final project = await localStorage.createNewProject('TestProject');
    final expectedPath = path.join(tempDir.path, 'TestProject.txt');
    expect(localStorage.getAbsolutePath(project), expectedPath);
  });
}
