import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:watcher/watcher.dart';
import 'drive_sync.dart';
import 'project_file.dart';
import 'task.dart';

final Logger _logger = Logger('main');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.ALL;

  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlowTimer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with SingleTickerProviderStateMixin {
  final List<TextEditingController> _controllers = [];
  final List<FocusNode> _focusNodes = [];
  bool _hasChanges = false;
  List<File> _projectFiles = [];
  File? _selectedFile;
  ProjectFile? _projectFile;
  DateTime? _selectedDate;
  final TextEditingController _notesController = TextEditingController();
  FileWatcher? _fileWatcher;
  late DriveSync _driveSync;

  @override
  void initState() {
    super.initState();
    _initDriveSync();
    _loadProjectFiles();
    _pickSelectedFileBasedOnCwd();
    _notesController.addListener(() {
      setState(() {
        _hasChanges = true;
      });
    });
  }

  Future<void> _initDriveSync() async {
    _driveSync = DriveSync();
    await _driveSync.loadCredentials();

    _driveSync.refreshAccessToken().then((_) async {
      if (_driveSync.oauth2Client != null) {
        await _driveSync.postLoginWithOAuth2();
      }
    });
  }

  void _initializeFileWatcher() {
    if (_selectedFile != null) {
      _fileWatcher = FileWatcher(_selectedFile!.path);
      _fileWatcher!.events.listen((event) {
        if (event.type == ChangeType.MODIFY) {
          _loadProject(_selectedFile);
        }
      });
    }
  }

  Future<void> _loadProjectFiles() async {
    final homeDir = Directory(path.join(Platform.environment['HOME']!, 'prj'));
    final directories = homeDir.listSync().whereType<Directory>();
    final projectFiles = directories
        .expand((dir) => [
              File(path.join(dir.path, 'notes.txt')),
              File(path.join(dir.path, 'project.txt'))
            ])
        .where((file) => file.existsSync())
        .toList();

    setState(() {
      _projectFiles = projectFiles;
      // Re-select the file if it still exists.
      if (_selectedFile != null) {
        _selectedFile = _projectFiles
            .firstWhere((file) => file.path == _selectedFile!.path);
      }
    });
  }

  void _pickSelectedFileBasedOnCwd() {
    final currentDir = Directory.current;
    try {
      File matchingFile = _projectFiles.firstWhere(
        (file) => currentDir.path.startsWith(path.dirname(file.path)),
      );
      _loadProject(matchingFile);
    } on StateError {
      // No matching file found.
    }
  }

  Future<void> _loadProject(File? file) async {
    if (file == null) {
      setState(() {
        _selectedFile = null;
        _controllers.clear();
        _projectFile = null;
        _selectedDate = null;
      });
      return;
    }
    _logger.info('Loading project from ${file.path}');
    final content = await file.readAsString();
    final projectFile = ProjectFile();
    await projectFile.parse(content);

    final currentDate = DateTime.now();
    if (projectFile.weeklies.isEmpty) {
      projectFile.createWeekly(currentDate);
    }

    setState(() {
      _selectedFile = file;
      _projectFile = projectFile;
      _selectedDate = projectFile.getWeeklies().last;
      _populateTabsForSelectedDate();
    });

    _initializeFileWatcher();
  }

  void _populateTabsForSelectedDate() {
    if (_projectFile == null || _selectedDate == null) return;
    final weekly = _projectFile!.getWeekly(_selectedDate!);
    final tasks = weekly.tasks;
    final notes = weekly.getNotesString();
    setState(() {
      _controllers.clear();
      _focusNodes.clear();
      for (var task in tasks) {
        _setTaskControllerAndFocusNode(null, task.toLine());
      }
      _notesController.text = notes;
    });
  }

  void _setTaskControllerAndFocusNode(int? index, String text) {
    final controller = TextEditingController(text: text);
    final focusNode = FocusNode();
    focusNode.addListener(() {
      if (focusNode.hasFocus) return;
      final text = controller.text.trim();
      Task? task;
      try {
        task = Task.fromLine(text);
      } catch (e) {
        task = Task(dayNumber: -1, desc: text);
        controller.text = task.toLine();
        controller.selection = TextSelection.fromPosition(
            TextPosition(offset: controller.text.length));
        setState(() {
          _hasChanges = true;
        });
      }
    });
    if (index != null) {
      _controllers[index] = controller;
      _focusNodes[index] = focusNode;
    } else {
      _controllers.add(controller);
      _focusNodes.add(focusNode);
    }
  }

  String getTasksTabText() {
    String? totalsAnnotation;
    if (_selectedDate != null) {
      totalsAnnotation =
          _projectFile?.getWeekly(_selectedDate!).getTotalsAnnotation();
    }
    return totalsAnnotation != null ? 'Tasks ($totalsAnnotation)' : 'Tasks';
  }

  Future<void> _showFailedToSelectDirectoryDialog(
      String title, String content) async {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveProject() async {
    if (_selectedFile == null) {
      while (true) {
        final directory = await FilePicker.platform.getDirectoryPath();
        if (directory == null) return; // User canceled the picker
        String requiredPath = path.join(Platform.environment['HOME']!, 'prj');

        if (!directory.startsWith(requiredPath) || directory == requiredPath) {
          await _showFailedToSelectDirectoryDialog('Invalid Directory',
              'Please select a directory directly under $requiredPath.');
          continue;
        }
        final newFile = File(path.join(directory, 'project.txt'));
        if (await newFile.exists()) {
          await _showFailedToSelectDirectoryDialog('File Already Exists',
              'A project.txt file already exists in the selected directory. Please choose a different directory.');
          continue;
        }
        _selectedFile = newFile;
        break;
      }
    }
    _logger.info('Saving project to ${_selectedFile!.path}');
    final weekly = _projectFile!.getWeekly(_selectedDate!);
    weekly.tasks = _controllers
        .map((controller) => Task.fromLine(controller.text))
        .toList();
    weekly.setNotesFromString(_notesController.text);
    final contents = _projectFile!.toString();
    await _selectedFile!.writeAsString(contents);
    String projectDescriptor =
        _driveSync.getProjectDescriptor(_selectedFile!.path);
    await _driveSync.syncProjectToDrive(projectDescriptor, contents);
    setState(() {
      _hasChanges = false;
    });
    _loadProjectFiles(); // Reload the dropdown with available files
  }

  void _addNewItem() {
    setState(() {
      _setTaskControllerAndFocusNode(null, '');
      _hasChanges = true;
    });
  }

  Future<void> _login() async {
    await _driveSync.login();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) {
          if (event.isControlPressed && event.logicalKey.keyLabel == 'S') {
            if (_hasChanges) {
              _saveProject();
            }
          }
        },
        child: WillPopScope(
          onWillPop: _onWillPop,
          child: Scaffold(
            appBar: AppBar(
              backgroundColor: Theme.of(context).colorScheme.inversePrimary,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_driveSync
                      .getProjectDescriptor(_selectedFile?.path ?? '')),
                  if (_selectedDate != null)
                    Text(
                      DateFormat(defaultDateFormat).format(_selectedDate!),
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                    ),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.login),
                  onPressed: _driveSync.oauth2Client == null ? _login : null,
                ),
                IconButton(
                  icon: const Icon(Icons.save),
                  onPressed: _hasChanges
                      ? () {
                          _saveProject();
                        }
                      : null,
                ),
              ],
            ),
            drawer: Drawer(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  DrawerHeader(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    child: Text(
                      'FlowTimer',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                      ),
                    ),
                  ),
                  ListTile(
                    title: const Text('Weeklies'),
                  ),
                  ...?_projectFile?.getWeeklies().map((date) {
                    return ListTile(
                      title: Text(DateFormat(defaultDateFormat).format(date)),
                      selected: _selectedDate == date,
                      selectedTileColor: Colors.yellow,
                      onTap: () {
                        setState(() {
                          _selectedDate = date;
                          _populateTabsForSelectedDate();
                          Navigator.pop(context); // Close the drawer
                        });
                      },
                    );
                  }),
                  ListTile(
                    title: const Text('<create new weekly>'),
                    selected: _selectedDate == DateTime.now(),
                    selectedTileColor: Colors.yellow,
                    onTap: () {
                      setState(() {
                        _selectedDate = DateTime.now();
                        _populateTabsForSelectedDate();
                        Navigator.pop(context); // Close the drawer
                      });
                    },
                  ),
                  Divider(),
                  ListTile(
                    title: const Text('Projects'),
                  ),
                  ..._projectFiles.map((file) {
                    return ListTile(
                      title: Text(_driveSync.getProjectDescriptor(file.path)),
                      selected: _selectedFile == file,
                      selectedTileColor: Colors.yellow,
                      onTap: () {
                        setState(() {
                          _selectedFile = file;
                          _loadProject(file);
                          Navigator.pop(context); // Close the drawer
                        });
                      },
                    );
                  }),
                  ListTile(
                    title: const Text('<create a new file>'),
                    selected: _selectedFile == null,
                    selectedTileColor: Colors.yellow,
                    onTap: () {
                      setState(() {
                        _selectedFile = null;
                        _loadProject(null);
                        Navigator.pop(context); // Close the drawer
                      });
                    },
                  ),
                ],
              ),
            ),
            body: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: _controllers.length + 1,
                    itemBuilder: (context, index) {
                      if (index < _controllers.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 0, horizontal: 8.0),
                          child: TextField(
                            controller: _controllers[index],
                            focusNode: _focusNodes[index],
                            decoration: InputDecoration(hintText: 'Enter task'),
                            style: TextStyle(fontSize: 24),
                            onChanged: (newValue) {
                              setState(() {
                                _hasChanges = true;
                              });
                            },
                          ),
                        );
                      } else {
                        return Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: TextField(
                            controller: _notesController,
                            maxLines: null,
                            decoration: InputDecoration(
                              hintText: 'Enter notes',
                              border: OutlineInputBorder(),
                            ),
                            style: TextStyle(fontSize: 24),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _addNewItem,
              tooltip: 'Add Task',
              child: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (_hasChanges) {
      return (await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Unsaved Changes'),
              content: const Text(
                  'You have unsaved changes. Do you really want to quit?'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('No'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Yes'),
                ),
              ],
            ),
          )) ??
          false;
    }
    return true;
  }

  @override
  void dispose() {
    _fileWatcher = null;
    for (var controller in _controllers) {
      controller.dispose();
    }
    _notesController.dispose();
    super.dispose();
  }
}
