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
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(await createMyApp());
}

Future<MyApp> createMyApp({String? overrideStorageDirectory}) async {
  final localStorage = LocalStorage();
  await localStorage.initialize(
      overrideStorageDirectory: overrideStorageDirectory);
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
    projectMetadata =
        localStorage.getProjectMetadata(localStorage.lastOpenedProject!);
  }
  projectMetadata ??= localStorage.getFirstProjectMetadata();
  projectMetadata ??= await localStorage.createNewProject(_noName);
  return projectMetadata;
}

Future<Project> _loadProjectFromMetadata(
    LocalStorage localStorage, ProjectMetadata projectMetadata) async {
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
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.grey, brightness: Brightness.dark),
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

class DeferredSaver {
  final Function saveFile;
  Timer? _timer;

  DeferredSaver({required this.saveFile});

  void registerEdit() {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: 4), () async {
      await saveFile();
      _timer?.cancel();
    });
  }
}

class FocusState {
  final int? focusedTodoIndex;
  final int? cursorPosition;

  FocusState({this.focusedTodoIndex, this.cursorPosition});
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
  late DriveSync _driveSync;
  late ProjectMetadata _projectMetadata;
  late Project _project;
  late Weekly _weekly;
  final List<FocusNode> _todoFocusNodes = [];
  final List<TextEditingController> _todoControllers = [];
  final FocusNode _notesFocusNode = FocusNode();
  final TextEditingController _notesController = TextEditingController();
  StreamSubscription? _currentProjectStreamSubscription;
  late DeferredSaver _deferredSaver;

  @override
  void initState() {
    super.initState();
    _localStorage = widget.localStorage;
    _driveSync = widget.driveSync;
    _projectMetadata = widget.projectMetadata;
    _project = widget.project;
    _weekly = _project.weeklies.last;
    _populateTabsForSelectedWeekly();
    _setupFileWatcher();
    _deferredSaver = DeferredSaver(saveFile: _saveProject);
    super.initState();
    _localStorage.onChanges = () {
      setState(() {});
    };
    _driveSync.onLoginStateChanged = () {
      _logger.info('OAuth2 login state changed');
      setState(() {});
    };
  }

  void _setupFileWatcher() {
    _currentProjectStreamSubscription?.cancel();
    _currentProjectStreamSubscription =
        _localStorage.watchProject(_projectMetadata, (event) {
      _logger.info('File changed: ${event.path}');
      final focusState = _saveFocusState();
      _deferredSaver.registerEdit();
      _loadProjectFromMetadataIntoUI().then((_) {
        _restoreFocusState(focusState);
      });
    });
  }

  FocusState _saveFocusState() {
    for (int i = 0; i < _todoFocusNodes.length; i++) {
      if (_todoFocusNodes[i].hasFocus) {
        return FocusState(
          focusedTodoIndex: i,
          cursorPosition: _todoControllers[i].selection.baseOffset,
        );
      }
    }
    if (_notesFocusNode.hasFocus) {
      return FocusState(
        focusedTodoIndex: null,
        cursorPosition: _notesController.selection.baseOffset,
      );
    }
    return FocusState();
  }

  void _restoreFocusState(FocusState focusState) {
    if (focusState.focusedTodoIndex != null &&
        focusState.focusedTodoIndex! < _todoFocusNodes.length) {
      _todoFocusNodes[focusState.focusedTodoIndex!].requestFocus();
      _todoControllers[focusState.focusedTodoIndex!].selection =
          TextSelection.collapsed(
        offset: focusState.cursorPosition ??
            _todoControllers[focusState.focusedTodoIndex!].text.length,
      );
    } else if (focusState.cursorPosition != null) {
      _notesController.selection = TextSelection.collapsed(
        offset: focusState.cursorPosition ?? _notesController.text.length,
      );
      _notesFocusNode.requestFocus();
    }
  }

  Future<void> _loadProjectFromMetadataIntoUI() async {
    final project =
        await _loadProjectFromMetadata(_localStorage, _projectMetadata);
    project.createWeeklyIfNeeded();
    project.recompute();

    setState(() {
      _project = project;
      _weekly = project.weeklies.last;
      _populateTabsForSelectedWeekly();
    });

    _setupFileWatcher();
  }

  void _populateTabsForSelectedWeekly() {
    setState(() {
      _todoControllers.clear();
      _todoFocusNodes.clear();
      for (var todo in _weekly.todos) {
        _addTodoControllerAndFocusNode(todo.toLine());
      }
      _notesController.text = _weekly.getNotesString();
    });
  }

  void _addTodoControllerAndFocusNode(String text) {
    final controller = TextEditingController(text: text);
    final focusNode = FocusNode();
    final capturedLength = _todoControllers.length;

    focusNode.addListener(() {
      if (focusNode.hasFocus) return;
      _handleTodoFocusExit(focusNode, controller, capturedLength);
    });

    _todoControllers.add(controller);
    _todoFocusNodes.add(focusNode);
  }

  void _handleTodoFocusExit(
      FocusNode focusNode, TextEditingController controller, int index) async {
    final text = controller.text.trim();
    bool needsRecompute = false;

    if (text.isEmpty) {
      _removeTodoAt(index);
      needsRecompute = true;
    } else {
      needsRecompute = _updateTodoAt(index, text);
    }

    if (needsRecompute) {
      _recomputeTodos();
    }
  }

  void _removeTodoAt(int index) {
    _weekly.todos.removeAt(index);
    _todoControllers.removeLast();
    _todoFocusNodes.removeLast();
  }

  bool _updateTodoAt(int index, String text) {
    Todo todo;
    try {
      todo = Todo.fromLine(text);
    } catch (e) {
      todo = Todo(dayNumber: -1, desc: text);
    }

    bool needsRecompute = false;
    if (!_weekly.todos[index].equals(todo)) {
      _weekly.todos[index] = todo;
      needsRecompute = true;
    }

    return needsRecompute;
  }

  void _recomputeTodos() {
    _weekly.recompute();
    for (var i = 0; i < _todoControllers.length; i++) {
      _todoControllers[i].text = _weekly.todos[i].toLine();
    }
    _deferredSaver.registerEdit();
    setState(() {});
  }

  Future<void> _saveProject() async {
    _logger.info('Saving project to ${_projectMetadata.relativePath}');
    _weekly.setNotesFromString(_notesController.text);
    final contents = _project.toString();
    _localStorage.overwriteProjectContents(_projectMetadata, contents);
    _logger.info('Project saved to ${_projectMetadata.relativePath}');
    await _driveSync.syncProjectToDrive(_projectMetadata.name, contents);
  }

  void _addNewItem() {
    setState(() {
      _addTodoControllerAndFocusNode('');
      _weekly.todos.add(Todo(dayNumber: -1, desc: ''));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _todoFocusNodes.last.requestFocus();
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
              icon: Icon(_driveSync.oauth2Client == null
                  ? Icons.cloud_off
                  : Icons.cloud),
              tooltip: _driveSync.oauth2Client == null ? 'Login' : 'Connected',
              onPressed:
                  _driveSync.oauth2Client == null ? _driveSync.login : null,
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
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'FlowTimer',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                    ),
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
                  selectedTileColor: Colors.blue[900],
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
                  selectedTileColor: Colors.blue[900],
                  onTap: () async {
                    _projectMetadata = _localStorage.getProjectMetadata(name)!;
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
                  _projectMetadata = await _localStorage.createNewProject(name);
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
                        focusNode: _todoFocusNodes[index],
                        decoration: InputDecoration(
                          hintText: 'Enter todo',
                          fillColor: todo != null && todo.startTime != null
                              ? Colors.green.withAlpha(76)
                              : null,
                          isDense: true,
                          border: InputBorder.none,
                        ),
                        style: TextStyle(fontSize: 16, fontFamily: 'monospace'),
                      ),
                    );
                  } else {
                    return Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: TextField(
                        controller: _notesController,
                        focusNode: _notesFocusNode,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText: 'Enter notes',
                          border: InputBorder.none,
                        ),
                        style: TextStyle(fontSize: 16, fontFamily: 'monospace'),
                        onChanged: (newValue) {
                          _deferredSaver.registerEdit();
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
    );
  }

  @override
  void dispose() {
    for (var controller in _todoControllers) {
      controller.dispose();
    }
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }
}
