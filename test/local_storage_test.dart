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
    await metadataFile.writeAsString(
        '{"version": 0.2, "refreshToken": "token", "projects": {"TestProject": {"name": "TestProject", "relativePath": "path", "driveFileId": "fileId"}}}');
    await localStorage.loadMetadata();
    expect(localStorage.refreshToken, 'token');
    expect(
        localStorage.getProjectMetadata('TestProject')?.driveFileId, 'fileId');
  });

  test('writeMetadata writes metadata to file', () async {
    localStorage.metadata.refreshToken = 'new_token';
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path', driveFileId: 'fileId');
    await localStorage.writeMetadata();
    final metadataFile = File(path.join(tempDir.path, 'metadata.json'));
    final content = await metadataFile.readAsString();
    expect(content, contains('"refreshToken":"new_token"'));
    expect(content, contains('"driveFileId":"fileId"'));
  });

  test('storeRefreshToken updates refresh token', () async {
    await localStorage.storeRefreshToken('stored_token');
    expect(localStorage.refreshToken, 'stored_token');
  });

  test('createNewProject creates a new project', () async {
    final project = await localStorage.createNewProject('TestProject',
        driveFileId: 'fileId', driveDigest: 'digest');
    expect(project.name, 'TestProject');
    expect(project.driveFileId, 'fileId');
    expect(project.driveDigest, 'digest');
    expect(await File(localStorage.getAbsolutePath(project)).exists(), isTrue);
  });

  test('getProjectMetadata returns correct metadata', () {
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path');
    final project = localStorage.getProjectMetadata('TestProject');
    expect(project?.name, 'TestProject');
  });

  test('getFirstProjectMetadata returns first project', () {
    localStorage.metadata.projects['FirstProject'] =
        ProjectMetadata('FirstProject', 'path');
    localStorage.metadata.projects['SecondProject'] =
        ProjectMetadata('SecondProject', 'path');
    final project = localStorage.getFirstProjectMetadata();
    expect(project?.name, 'FirstProject');
  });

  test('getProjectNames returns list of project names', () {
    localStorage.metadata.projects['FirstProject'] =
        ProjectMetadata('FirstProject', 'path');
    localStorage.metadata.projects['SecondProject'] =
        ProjectMetadata('SecondProject', 'path');
    final projectNames = localStorage.getProjectNames();
    expect(projectNames, containsAll(['FirstProject', 'SecondProject']));
  });

  test('updateDriveDigest updates drive digest', () async {
    final projectMetadata = ProjectMetadata('TestProject', 'path');
    localStorage.metadata.projects['TestProject'] = projectMetadata;
    await localStorage.updateDriveDigest(projectMetadata, 'new_digest');
    expect(localStorage.getProjectMetadata('TestProject')?.driveDigest,
        'new_digest');
  });

  test('isKnownProject returns true for known project', () {
    localStorage.metadata.projects['TestProject'] =
        ProjectMetadata('TestProject', 'path');
    expect(localStorage.isKnownProject('TestProject'), isTrue);
  });

  test('isKnownProject returns false for unknown project', () {
    expect(localStorage.isKnownProject('UnknownProject'), isFalse);
  });

  test('store and read metadata', () async {
    localStorage.metadata.refreshToken = 'test_token';
    localStorage.metadata.lastOpenedProject = 'TestProject';
    final projectMetadata =
        ProjectMetadata('TestProject', 'relpath', driveFileId: 'fileId');
    localStorage.metadata.projects['TestProject'] = projectMetadata;
    localStorage.metadata.projects['AnotherProject'] =
        ProjectMetadata('AnotherProject', 'another_relpath');
    await localStorage.writeMetadata();
    await localStorage.updateDriveDigest(projectMetadata, 'driveDigest');

    final newLocalStorage = LocalStorage();
    await newLocalStorage.initialize(overrideStorageDirectory: tempDir.path);
    await newLocalStorage.loadMetadata();

    expect(newLocalStorage.refreshToken, 'test_token');
    expect(newLocalStorage.lastOpenedProject, 'TestProject');
    expect(
        newLocalStorage.getProjectMetadata('TestProject')?.name, 'TestProject');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.relativePath,
        'relpath');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.driveDigest,
        'driveDigest');
    expect(newLocalStorage.getProjectMetadata('TestProject')?.driveFileId,
        'fileId');
    expect(newLocalStorage.getProjectMetadata('AnotherProject')?.name,
        'AnotherProject');
  });

  test('getAbsolutePath returns correct absolute path', () async {
    final project = await localStorage.createNewProject('TestProject');
    final expectedPath = path.join(tempDir.path, 'TestProject.txt');
    expect(localStorage.getAbsolutePath(project), expectedPath);
  });
}
