import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:watcher/watcher.dart';
import 'drive_sync.dart';
import 'project.dart';
import 'todo.dart';

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
  List<File> _projectFiles = [];
  File? _projectFile;
  Project? _project;
  Weekly? _weekly;
  bool _hasChanges = false;
  final List<FocusNode> _focusNodes = [];
  final List<TextEditingController> _todoControllers = [];
  final TextEditingController _notesController = TextEditingController();
  FileWatcher? _fileWatcher;
  late DriveSync _driveSync;

  @override
  void initState() {
    super.initState();
    _initDriveSync();
    _findProjectFiles();
    _pickInitialProject();
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
    if (_projectFile != null) {
      _fileWatcher = FileWatcher(_projectFile!.path);
      _fileWatcher!.events.listen((event) {
        if (event.type == ChangeType.MODIFY) {
          _loadProject(_projectFile!);
        }
      });
    }
  }

  Future<void> _findProjectFiles() async {
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
      if (_projectFile != null) {
        _projectFile =
            _projectFiles.firstWhere((file) => file.path == _projectFile!.path);
      }
    });
  }

  Future<void> _pickInitialProject() async {
    final currentDir = Directory.current;
    try {
      File matchingFile = _projectFiles.firstWhere(
        (file) => currentDir.path.startsWith(path.dirname(file.path)),
      );
      _loadProject(matchingFile);
      return;
    } on StateError {
      // No matching file found.
    }
    await _promptProjectFileSelection(false);
  }

  Future<void> _promptProjectFileSelection(bool allowDismiss) async {
    while (true) {
      final directory = await FilePicker.platform.getDirectoryPath();
      if (directory == null) {
        if (allowDismiss) {
          return;
        }
        await _showFailedToSelectDirectoryDialog(
            'Must choose', 'You must select a directory to continue.');
        continue;
      }
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
      _projectFile = newFile;
      break;
    }
    _loadProject(_projectFile!);
  }

  Future<void> _loadProject(File file) async {
    _logger.info('Loading project from ${file.path}');
    final content = await file.readAsString();
    final project = Project();
    await project.parse(content);
    project.recompute();

    final currentDate = DateTime.now();
    if (project.weeklies.isEmpty) {
      project.createWeekly(currentDate);
    }

    setState(() {
      _projectFile = file;
      _project = project;
      _weekly = project.weeklies.last;
      _populateTabsForSelectedWeekly();
    });

    _initializeFileWatcher();
  }

  void _populateTabsForSelectedWeekly() {
    if (_project == null || _weekly == null) return;
    final todos = _weekly!.todos;
    final notes = _weekly!.getNotesString();
    setState(() {
      _todoControllers.clear();
      _focusNodes.clear();
      for (var todo in todos) {
        _addTodoControllerAndFocusNode(todo.toLine());
      }
      _notesController.text = notes;
    });
  }

  void _addTodoControllerAndFocusNode(String text) {
    final controller = TextEditingController(text: text);
    final focusNode = FocusNode();
    final newIndex = _todoControllers.length;
    focusNode.addListener(() {
      if (focusNode.hasFocus) return;
      final text = controller.text.trim();
      Todo? todo;
      try {
        todo = Todo.fromLine(text);
      } catch (e) {
        todo = Todo(dayNumber: -1, desc: text);
      }
      bool needsRecompute = false;
      if (newIndex == _weekly!.todos.length) {
        _weekly!.todos.add(todo);
        needsRecompute = true;
      }
      if (!_weekly!.todos[newIndex].equals(todo)) {
        _weekly!.todos[newIndex] = todo;
        needsRecompute = true;
      }
      if (!needsRecompute) {
        return;
      }

      _weekly!.recompute();
      for (var i = 0; i < _todoControllers.length; i++) {
        _todoControllers[i].text = _weekly!.todos[i].toLine();
      }
      setState(() {
        _hasChanges = true;
      });
    });
    _todoControllers.add(controller);
    _focusNodes.add(focusNode);
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
    _logger.info('Saving project to ${_projectFile!.path}');
    _weekly!.setNotesFromString(_notesController.text);
    final contents = _project!.toString();
    await _projectFile!.writeAsString(contents);
    String projectDescriptor =
        _driveSync.getProjectDescriptor(_projectFile!.path);
    await _driveSync.syncProjectToDrive(projectDescriptor, contents);
    setState(() {
      _hasChanges = false;
    });
    _findProjectFiles(); // Reload the dropdown with available files
  }

  void _addNewItem() {
    setState(() {
      _addTodoControllerAndFocusNode('');
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
                      .getProjectDescriptor(_projectFile?.path ?? '')),
                  if (_weekly != null)
                    Text(
                      DateFormat(defaultDateFormat).format(_weekly!.date),
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
                  ...?_project?.getWeeklies().map((date) {
                    return ListTile(
                      title: Text(DateFormat(defaultDateFormat).format(date)),
                      selected: _weekly?.date == date,
                      selectedTileColor: Colors.yellow,
                      onTap: () {
                        setState(() {
                          _weekly = _project?.weeklies
                              .firstWhere((weekly) => weekly.date == date);
                          _populateTabsForSelectedWeekly();
                          Navigator.pop(context); // Close the drawer
                        });
                      },
                    );
                  }),
                  if (_project?.weeklies
                          .where((weekly) => weekly.date == DateTime.now())
                          .isEmpty ??
                      true)
                    ListTile(
                      title: const Text('Create New Weekly'),
                      selected: _weekly?.date == DateTime.now(),
                      selectedTileColor: Colors.yellow,
                      onTap: () {
                        setState(() {
                          DateTime now = DateTime.now();
                          _weekly = _project!.createWeekly(now);
                          _populateTabsForSelectedWeekly();
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
                      selected: _projectFile == file,
                      selectedTileColor: Colors.yellow,
                      onTap: () {
                        setState(() {
                          _projectFile = file;
                          _loadProject(file);
                          Navigator.pop(context); // Close the drawer
                        });
                      },
                    );
                  }),
                  ListTile(
                    title: const Text('Create New Project'),
                    selected: _projectFile == null,
                    selectedTileColor: Colors.yellow,
                    onTap: () async {
                      await _promptProjectFileSelection(true);
                      setState(() {
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
                    itemCount: _todoControllers.length + 1,
                    itemBuilder: (context, index) {
                      if (index < _todoControllers.length) {
                        Todo? todo = index < _weekly!.todos.length
                            ? _weekly!.todos[index]
                            : null;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 0, horizontal: 8.0),
                          child: TextField(
                            controller: _todoControllers[index],
                            focusNode: _focusNodes[index],
                            decoration: InputDecoration(
                              hintText: 'Enter todo',
                              filled: true,
                              fillColor: todo != null && todo.startTime != null
                                  ? Colors.green.withOpacity(0.3)
                                  : null,
                            ),
                            style: TextStyle(
                                fontSize: 20, fontFamily: 'monospace'),
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
                            style: TextStyle(
                                fontSize: 20, fontFamily: 'monospace'),
                            onChanged: (newValue) {
                              setState(() {
                                _hasChanges = true;
                              });
                            },
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
              tooltip: 'Add Todo',
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
    for (var controller in _todoControllers) {
      controller.dispose();
    }
    _notesController.dispose();
    super.dispose();
  }
}
