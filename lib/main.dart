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
  Timer? _flowTimeTimer;

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
    _driveSync.onConflictDetected = _handleConflict;
    _startFlowTimeTimer();
  }

  void _startFlowTimeTimer() {
    _flowTimeTimer?.cancel();
    _flowTimeTimer = Timer.periodic(Duration(minutes: 1), (timer) {
      setState(() {});
    });
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
        _addTodoControllerAndFocusNode(todo.desc);
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
    _weekly.todos[index].desc = text;
    return true;
  }

  void _recomputeTodos() {
    _weekly.recompute();
    for (var i = 0; i < _todoControllers.length; i++) {
      _todoControllers[i].text = _weekly.todos[i].desc;
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
    await _driveSync.syncProject(_projectMetadata);
  }

  Future<void> _handleConflict(ProjectMetadata projectMetadata,
      String driveDigest, String driveContents) async {
    if (_projectMetadata.name == projectMetadata.name) {
      final result = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('Conflict Detected'),
            content: const Text(
                'A conflict was detected between the local and cloud versions of this project. Would you like to keep the local version or the cloud version?'),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop('Keep Local');
                },
                child: const Text('Keep Local'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop('Keep Cloud');
                },
                child: const Text('Keep Cloud'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop('cancel');
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );

      if (result == 'Keep Local') {
        await _localStorage.updateDriveDigest(_projectMetadata, driveDigest);
        await _driveSync.syncProject(_projectMetadata);
      } else if (result == 'Keep Cloud') {
        await _localStorage.overwriteProjectContents(
            _projectMetadata, driveContents);
        await _localStorage.updateDriveDigest(_projectMetadata,
            await _localStorage.getProjectFileMd5Digest(projectMetadata));
        await _loadProjectFromMetadataIntoUI();
      }
    }
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

  void _editMinutes(Todo todo, int index, {bool isDuration = false}) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final TextEditingController minutesController = TextEditingController(
          text: isDuration
              ? todo.duration?.toString() ?? ''
              : todo.spentMinutes?.toString() ?? '',
        );
        return AlertDialog(
          title: Text(isDuration ? 'Edit Duration' : 'Edit Time Spent'),
          content: TextField(
            controller: minutesController,
            decoration: InputDecoration(hintText: 'Minutes'),
            keyboardType: TextInputType.number,
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
                setState(() {
                  if (isDuration) {
                    todo.duration = double.tryParse(minutesController.text);
                  } else {
                    todo.spentMinutes = double.tryParse(minutesController.text);
                  }
                  _todoControllers[index].text = todo.desc;
                  _deferredSaver.registerEdit();
                });
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _editCoins(Todo todo, int index) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        final TextEditingController coinsController = TextEditingController(
          text: todo.coins?.toString() ?? '',
        );
        return AlertDialog(
          title: const Text('Edit Coins'),
          content: TextField(
            controller: coinsController,
            decoration: const InputDecoration(hintText: 'Coins'),
            keyboardType: TextInputType.number,
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
                setState(() {
                  todo.coins = double.tryParse(coinsController.text);
                  _todoControllers[index].text = todo.desc;
                  _deferredSaver.registerEdit();
                });
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showEndFlowTimeDialog(Todo todo) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('End Flow Time'),
          content: const Text('Do you want to end the flow time?'),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  final now = DateTime.now();
                  final startTime = DateTime(now.year, now.month, now.day,
                      todo.startTime!.hour, todo.startTime!.minute);
                  final minutesSpent = now.difference(startTime).inMinutes;
                  todo.spentMinutes = (todo.spentMinutes ?? 0) + minutesSpent;
                  todo.startTime = null;
                  _deferredSaver.registerEdit();
                });
                Navigator.of(context).pop();
              },
              child: const Text('End'),
            ),
          ],
        );
      },
    );
  }

  void _toggleFlowTime(Todo todo) {
    setState(() {
      final now = DateTime.now();
      if (todo.startTime != null) {
        _showEndFlowTimeDialog(todo);
      } else {
        for (var t in _weekly.todos) {
          if (t.startTime != null) {
            final startTime = DateTime(now.year, now.month, now.day,
                t.startTime!.hour, t.startTime!.minute);
            final minutesSpent = now.difference(startTime).inMinutes;
            t.spentMinutes = (t.spentMinutes ?? 0) + minutesSpent;
            t.startTime = null;
          }
        }
        todo.startTime = TimeOfDay(hour: now.hour, minute: now.minute);
        _deferredSaver.registerEdit();
      }
    });
  }

  void _showAddOptions(Todo todo, int index) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return Wrap(
          children: <Widget>[
            ListTile(
              leading: Icon(Icons.timer),
              title: Text('Minutes Remaining'),
              onTap: () {
                Navigator.pop(context);
                _editMinutes(todo, index);
              },
            ),
            ListTile(
              leading: Icon(Icons.access_time),
              title:
                  Text(todo.startTime == null ? 'Flow Time' : 'End Flow Time'),
              onTap: () {
                Navigator.pop(context);
                _toggleFlowTime(todo);
              },
            ),
            ListTile(
              leading: Icon(Icons.calendar_today),
              title: Text('Due Date'),
              onTap: () {
                Navigator.pop(context);
                _selectDueDate(todo);
              },
            ),
            ListTile(
              leading: Icon(Icons.monetization_on),
              title: Text('Coins'),
              onTap: () {
                Navigator.pop(context);
                _editCoins(todo, index);
              },
            ),
          ],
        );
      },
    );
  }

  void _selectDueDate(Todo todo) async {
    DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: todo.dueDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );

    if (pickedDate != null) {
      setState(() {
        todo.dueDate = pickedDate;
        _deferredSaver.registerEdit();
      });
    } else {
      setState(() {
        todo.dueDate = null;
        _deferredSaver.registerEdit();
      });
    }
  }

  void _selectDayOfWeek(Todo todo) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Day of Week'),
          content: DropdownButton<int>(
            value: todo.dayNumber,
            items: List.generate(7, (index) {
              return DropdownMenuItem(
                value: index,
                child:
                    Text(DateFormat.E().format(DateTime(2023, 1, index + 2))),
              );
            }),
            onChanged: (int? newValue) {
              setState(() {
                todo.dayNumber = newValue!;
                _deferredSaver.registerEdit();
              });
              Navigator.of(context).pop();
            },
          ),
        );
      },
    );
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
            Container(
              padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 8.0),
              color: Colors.blueGrey,
              alignment: Alignment.centerLeft,
              child: Text(
                _weekly.todoLine?.replaceAll(RegExp(r'[\s#]+'), ' ') ??
                    'TODOs:',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _todoControllers.length + 2, // Adjusted item count
                itemBuilder: (context, index) {
                  if (index < _todoControllers.length) {
                    Todo? todo = index < _weekly.todos.length
                        ? _weekly.todos[index]
                        : null;
                    return Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 0, horizontal: 8.0),
                          color: todo != null && todo.startTime != null
                              ? Colors.green.withAlpha(76)
                              : Colors.transparent,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start, // Align to top
                                children: [
                                  Checkbox(
                                    value: todo?.dayNumber != -1,
                                    onChanged: (bool? value) {
                                      setState(() {
                                        todo?.dayNumber = value == true
                                            ? DateTime.now().weekday % 7
                                            : -1;
                                        _deferredSaver.registerEdit();
                                      });
                                    },
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: _todoControllers[index],
                                      focusNode: _todoFocusNodes[index],
                                      decoration: InputDecoration(
                                        hintText: 'Enter todo',
                                        isDense: true,
                                        border: InputBorder.none,
                                      ),
                                      style: TextStyle(
                                        fontSize: 20,
                                      ),
                                      maxLines: null,
                                      onChanged: (text) {
                                        setState(() {
                                          todo?.desc = text;
                                          _deferredSaver.registerEdit();
                                        });
                                      },
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => _showAddOptions(todo!, index),
                                    child: Chip(
                                      label: Text(
                                        'Add...',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      backgroundColor: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    if (todo?.dayNumber != -1)
                                      GestureDetector(
                                        onTap: () => _selectDayOfWeek(todo),
                                        child: Chip(
                                          label: Text(
                                            'Done ${DateFormat.E().format(DateTime(2023, 1, todo!.dayNumber + 2))}',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo?.startTime != null)
                                      GestureDetector(
                                        onTap: () =>
                                            _showEndFlowTimeDialog(todo),
                                        child: Chip(
                                          label: Text(
                                            'Flow time: ${DateTime.now().difference(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, todo!.startTime!.hour, todo.startTime!.minute)).inMinutes}m',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo?.duration != null &&
                                        todo?.duration != 0)
                                      GestureDetector(
                                        onTap: () => _editMinutes(todo, index,
                                            isDuration: true),
                                        child: Chip(
                                          label: Text(
                                            '${todo!.duration!.toInt()}m',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo?.spentMinutes != null &&
                                        todo?.spentMinutes! != 0)
                                      GestureDetector(
                                        onTap: () => _editMinutes(todo, index),
                                        child: Chip(
                                          label: Text(
                                            '+${todo!.spentMinutes!.toInt()}m',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo?.coins != null &&
                                        todo?.coins! != 0)
                                      GestureDetector(
                                        onTap: () => _editCoins(todo, index),
                                        child: Chip(
                                          label: Text(
                                            '${todo!.coins!.toStringAsFixed(2)}c',
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo?.dueDate != null)
                                      GestureDetector(
                                        onTap: () => _selectDueDate(todo),
                                        child: Chip(
                                          label: Text(
                                            DateFormat.yMd()
                                                .format(todo!.dueDate!),
                                            style:
                                                TextStyle(color: Colors.white),
                                          ),
                                          backgroundColor: Colors.blue,
                                        ),
                                      ),
                                    if (todo != null &&
                                        _getTodoAnnotations(todo) != null)
                                      GestureDetector(
                                        onTap:
                                            () {}, // Add any desired action here
                                        child: Chip(
                                          label: Text(
                                            _getTodoAnnotations(todo)!,
                                            style:
                                                TextStyle(color: Colors.black),
                                          ),
                                          backgroundColor: Colors.grey[300],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(),
                      ],
                    );
                  } else if (index == _todoControllers.length) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 0, horizontal: 8.0),
                      color: Colors.blueGrey,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Notes:',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
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
                        style: TextStyle(
                          fontSize: 16,
                        ),
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

  String? _getTodoAnnotations(Todo todo) {
    final line = todo.toLine();
    final index = line.indexOf('##');
    if (index != -1) {
      return line.substring(index + 2).trim();
    }
    return null;
  }

  @override
  void dispose() {
    _flowTimeTimer?.cancel();
    for (var controller in _todoControllers) {
      controller.dispose();
    }
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }
}
