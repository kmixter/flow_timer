import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:intl/intl.dart';
import 'drive_sync.dart';
import 'project.dart';
import 'todo.dart';
import 'local_storage.dart';

final Logger _logger = Logger('main');
final String _noName = 'My Project';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.ALL;

  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(await createMyApp());
}

Future<MyApp> createMyApp({String? overrideStorageDirectory}) async {
  final localStorage = LocalStorage();
  await localStorage.initialize(overrideStorageDirectory: overrideStorageDirectory);
  await localStorage.logFilesInDocumentsDirectory();
  final driveSync = DriveSync(localStorage);
  await driveSync.initialize();
  final projectMetadata = await _pickInitialProject(localStorage);
  final project = await _loadProjectFromMetadata(localStorage, projectMetadata);
  return MyApp(
    localStorage: localStorage,
    driveSync: driveSync,
    projectMetadata: projectMetadata,
    project: project,
  );
}

Future<ProjectMetadata> _pickInitialProject(LocalStorage localStorage) async {
  ProjectMetadata? projectMetadata;
  if (localStorage.lastOpenedProject != null) {
    projectMetadata = localStorage.getProjectMetadata(localStorage.lastOpenedProject!);
  }
  projectMetadata ??= localStorage.getFirstProjectMetadata();
  projectMetadata ??= await localStorage.createNewProject(_noName);
  return projectMetadata;
}

Future<Project> _loadProjectFromMetadata(LocalStorage localStorage, ProjectMetadata projectMetadata) async {
  final project = await localStorage.loadProject(projectMetadata);
  await localStorage.updateLastOpenedProject(projectMetadata.name);

  project.createWeeklyIfNeeded();
  project.recompute();
  return project;
}

class MyApp extends StatelessWidget {
  final LocalStorage localStorage;
  final DriveSync driveSync;
  final ProjectMetadata projectMetadata;
  final Project project;

  const MyApp({
    super.key,
    required this.localStorage,
    required this.driveSync,
    required this.projectMetadata,
    required this.project,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlowTimer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MyHomePage(
        localStorage: localStorage,
        driveSync: driveSync,
        projectMetadata: projectMetadata,
        project: project,
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final LocalStorage localStorage;
  final DriveSync driveSync;
  final ProjectMetadata projectMetadata;
  final Project project;

  const MyHomePage({
    super.key,
    required this.localStorage,
    required this.driveSync,
    required this.projectMetadata,
    required this.project,
  });

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with SingleTickerProviderStateMixin {
  late LocalStorage _localStorage;
  bool _hasEdits = false;
  late DriveSync _driveSync;
  late ProjectMetadata _projectMetadata;
  late Project _project;
  late Weekly _weekly;
  final List<FocusNode> _focusNodes = [];
  final List<TextEditingController> _todoControllers = [];
  final TextEditingController _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _localStorage = widget.localStorage;
    _driveSync = widget.driveSync;
    _projectMetadata = widget.projectMetadata;
    _project = widget.project;
    _weekly = _project.weeklies.last;
    _populateTabsForSelectedWeekly();
    _initializeFileWatcher();
  }

  void _initializeFileWatcher() {
    final currentActiveProject = _projectMetadata.name;
    _localStorage.watchProject(_projectMetadata, (event) {
      if (currentActiveProject != _projectMetadata.name) {
        return;
      }
      _loadProjectFromMetadataIntoUI();
    });
  }

  Future<void> _loadProjectFromMetadataIntoUI() async {
    final project = await _loadProjectFromMetadata(_localStorage, _projectMetadata);
    project.createWeeklyIfNeeded();
    project.recompute();

    setState(() {
      _project = project;
      _weekly = project.weeklies.last;
      _populateTabsForSelectedWeekly();
    });

    _initializeFileWatcher();
  }

  void _populateTabsForSelectedWeekly() {
    setState(() {
      _todoControllers.clear();
      _focusNodes.clear();
      for (var todo in _weekly.todos) {
        _addTodoControllerAndFocusNode(todo.toLine());
      }
      _notesController.text = _weekly.getNotesString();
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
      if (newIndex == _weekly.todos.length) {
        _weekly.todos.add(todo);
        needsRecompute = true;
      }
      if (!_weekly.todos[newIndex].equals(todo)) {
        _weekly.todos[newIndex] = todo;
        needsRecompute = true;
      }
      if (!needsRecompute) {
        return;
      }

      _weekly.recompute();
      for (var i = 0; i < _todoControllers.length; i++) {
        _todoControllers[i].text = _weekly.todos[i].toLine();
      }
      setState(() {
        _hasEdits = true;
      });
    });
    _todoControllers.add(controller);
    _focusNodes.add(focusNode);
  }

  Future<void> _saveProject() async {
    _logger.info('Saving project to ${_projectMetadata.relativePath}');
    _weekly.setNotesFromString(_notesController.text);
    final contents = _project.toString();
    _localStorage.overwriteProjectContents(_projectMetadata, contents);
    _logger.info('Project saved to ${_projectMetadata.relativePath}');
    await _driveSync.syncProjectToDrive(_projectMetadata.name, contents);
    setState(() {
      _hasEdits = false;
    });
  }

  void _addNewItem() {
    setState(() {
      _addTodoControllerAndFocusNode('');
      _hasEdits = true;
    });
  }

  Future<String?> _promptForNewProjectName() async {
    String? projectName;
    await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        final TextEditingController controller = TextEditingController();
        return AlertDialog(
          title: const Text('Enter Project Name'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Project Name'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (_localStorage.getProjectMetadata(name) != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Project name already exists. Please choose a different name.'),
                    ),
                  );
                } else {
                  projectName = name;
                  Navigator.of(context).pop();
                }
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    return projectName;
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) {
          if (event.isControlPressed && event.logicalKey.keyLabel == 'S') {
            if (_hasEdits) {
              _saveProject();
            }
          }
        },
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_projectMetadata.name),
                Text(
                  DateFormat(defaultDateFormat).format(_weekly.date),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.login),
                onPressed: _driveSync.oauth2Client == null
                    ? _driveSync.login
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: _hasEdits
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
                ..._project.getWeeklies().map((date) {
                  return ListTile(
                    title: Text(DateFormat(defaultDateFormat).format(date)),
                    selected: _weekly.date == date,
                    selectedTileColor: Colors.yellow,
                    onTap: () {
                      setState(() {
                        _weekly = _project.weeklies
                            .firstWhere((weekly) => weekly.date == date);
                        _populateTabsForSelectedWeekly();
                        Navigator.pop(context); // Close the drawer
                      });
                    },
                  );
                }),
                Divider(),
                ListTile(
                  title: const Text('Projects'),
                ),
                ..._localStorage.getProjectNames().map((name) {
                  return ListTile(
                    title: Text(name),
                    selected: _projectMetadata.name == name,
                    selectedTileColor: Colors.yellow,
                    onTap: () async {
                      _projectMetadata =
                          _localStorage.getProjectMetadata(name)!;
                      await _loadProjectFromMetadataIntoUI();
                      setState(() {
                        Navigator.pop(context); // Close the drawer
                      });
                    },
                  );
                }),
                ListTile(
                  title: const Text('Create New Project'),
                  onTap: () async {
                    var name = await _promptForNewProjectName();
                    if (name == null) {
                      return;
                    }
                    _projectMetadata =
                        await _localStorage.createNewProject(name);
                    await _loadProjectFromMetadataIntoUI();
                    setState(() {
                      Navigator.pop(context);
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
                      Todo? todo = index < _weekly.todos.length
                          ? _weekly.todos[index]
                          : null;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 0, horizontal: 8.0),
                        child: TextField(
                          controller: _todoControllers[index],
                          focusNode: _focusNodes[index],
                          decoration: InputDecoration(
                            hintText: 'Enter todo',
                            fillColor:
                                todo != null && todo.startTime != null
                                    ? Colors.green.withOpacity(0.3)
                                    : null,
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          style: TextStyle(
                              fontSize: 16, fontFamily: 'monospace'),
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
                            border: InputBorder.none,
                          ),
                          style: TextStyle(
                              fontSize: 16, fontFamily: 'monospace'),
                          onChanged: (newValue) {
                            setState(() {
                              _hasEdits = true;
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
    );
  }

  @override
  void dispose() {
    for (var controller in _todoControllers) {
      controller.dispose();
    }
    _notesController.dispose();
    super.dispose();
  }
}
