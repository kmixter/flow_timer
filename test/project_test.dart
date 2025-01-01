import 'package:test/test.dart';
import 'package:flow_timer/project.dart';
import 'package:flow_timer/todo.dart';

void main() {
  group('Project', () {
    late Project project;
    const testContent = '''
Sun, Oct 1, 2023
----------------
TODOs: ## This is a comment
M Task 1
T Task 2

Notes for 2023-10-01

Tue, Dec 10, 2024
-----------------
TODOs:
W Task 3
R Task 4

Notes for 12/10.

''';

    setUp(() async {
      project = Project();
      await project.parse(testContent);
    });

    test('parse and getDates', () {
      final dates = project.getWeeklies();
      expect(dates, [DateTime(2023, 10, 1), DateTime(2024, 12, 10)]);
    });

    test('getTasksForDate', () {
      final weekly = project.getWeekly(DateTime(2023, 10, 1));
      final tasks = weekly.todos;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'Task 1');
      expect(tasks[1].desc, 'Task 2');
    });

    test('getNotesForDate', () {
      final weekly = project.getWeekly(DateTime(2023, 10, 1));
      final notes = weekly.getNotesString();
      expect(notes, 'Notes for 2023-10-01\n');
    });

    test('Check toString returns what was parsed', () {
      final newContent = project.toString();
      expect(newContent, testContent);
    });

    test('replaceTasksForDate', () async {
      final weekly = project.getWeekly(DateTime(2023, 10, 1));
      weekly.todos = [
        Todo(dayNumber: 0, desc: 'New Task 1'),
        Todo(dayNumber: 1, desc: 'New Task 2'),
      ];
      final newContent = project.toString();
      await project.parse(newContent);
      final updatedWeekly = project.getWeekly(DateTime(2023, 10, 1));
      final tasks = updatedWeekly.todos;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'New Task 1');
      expect(tasks[1].desc, 'New Task 2');
    });

    test('replaceNotesForDate', () async {
      final weekly = project.getWeekly(DateTime(2023, 10, 1));
      weekly.setNotesFromString('New notes for 2023-10-01\n');
      final newContent = project.toString();
      await project.parse(newContent);
      final updatedWeekly = project.getWeekly(DateTime(2023, 10, 1));
      final notes = updatedWeekly.getNotesString();
      expect(notes, 'New notes for 2023-10-01\n');
    });

    test('test reading empty project', () async {
      final emptyProject = Project();
      await emptyProject.parse('');
      expect(emptyProject.weeklies.isEmpty, true);
    });

    test('test writing empty project', () async {
      final emptyProject = Project();
      await emptyProject.parse('');
      final newContent = emptyProject.toString();
      expect(newContent, '');
    });

    test('test writing project with 2 empty weeklies', () async {
      final emptyProject = Project();
      emptyProject.createWeekly(DateTime(2023, 10, 1));
      emptyProject.createWeekly(DateTime(2023, 10, 2));
      final newContent = emptyProject.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\n\nMon, Oct 2, 2023\n----------------\n\n');
    });

    test('test reading project with 2 empty weeklies', () async {
      final emptyProject = Project();
      await emptyProject
          .parse('2023-10-01\n----------\n\n2023-10-02\n----------\n\n');
      expect(emptyProject.weeklies.length, 2);
      expect(emptyProject.weeklies[0].todos.isEmpty, true);
      expect(emptyProject.weeklies[0].notes.isEmpty, true);
      expect(emptyProject.weeklies[1].todos.isEmpty, true);
      expect(emptyProject.weeklies[1].notes.isEmpty, true);
    });

    test('test writing empty todos', () async {
      final justNotes = Project();
      final weekly = justNotes.createWeekly(DateTime(2023, 10, 1));
      weekly.setNotesFromString('hi there, this is a note');
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nhi there, this is a note\n\n');
    });

    test('test reading empty tasks', () async {
      final justNotes = Project();
      await justNotes
          .parse('2023-10-01\n----------\nhi there, this is a note\n\n');
      expect(justNotes.weeklies.length, 1);
      expect(justNotes.weeklies[0].todos.isEmpty, true);
      expect(justNotes.weeklies[0].notes.length, 1);
      expect(justNotes.weeklies[0].notes[0], 'hi there, this is a note');
    });

    test('test adding first todo', () async {
      final justNotes = Project();
      final weekly = justNotes.createWeekly(DateTime(2023, 10, 1));
      weekly.todos.add(Todo(dayNumber: 0, desc: 'First Task'));
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nTODOs:\nM First Task\n\n');
    });

    test('test recompute day of week order', () async {
      final notes = Project();
      final weekly = notes.createWeekly(DateTime(2023, 10, 1));
      weekly.todos.add(Todo(dayNumber: 1, desc: 'Second Task'));
      weekly.todos.add(Todo(dayNumber: 0, desc: 'FIrst Task'));
      expect(weekly.todos[0].dayNumber, 1);
      expect(weekly.todos[1].dayNumber, 0);
      notes.recompute();
      expect(weekly.todos.length, 2);
      expect(weekly.todos[0].dayNumber, 0);
      expect(weekly.todos[1].dayNumber, 1);
      expect(weekly.todoLine, 'TODOs:');
    });

    test('test recompute pending by completion rate', () async {
      final notes = Project();
      final weekly = notes.createWeekly(DateTime(2023, 10, 1));
      weekly.todos.add(Todo(
          dayNumber: -1,
          desc: 'Task 1',
          duration: 6,
          dueDate: DateTime(2023, 10, 7)));
      weekly.todos.add(Todo(
          dayNumber: -1,
          desc: 'Task 2',
          duration: 6,
          dueDate: DateTime(2023, 10, 4)));
      final now = DateTime(2023, 10, 1);
      notes.recompute(now: now);
      expect(weekly.todos.length, 2);
      expect(weekly.todos[0].desc, 'Task 2');
      expect(weekly.todos[0].getCompletionRate(), 2);
      expect(weekly.todos[1].desc, 'Task 1');
      expect(weekly.todos[1].getCompletionRate(), 1);

      expect(weekly.getTotalsAnnotation(), '∑: 3m/d');
      expect(weekly.todoLine,
          'TODOs:                                                            ## ∑: 3m/d');
    });

    test('createWeeklyIfNeeded creates a new weekly if project is empty', () {
      final project = Project();
      // NB: 10/1/23 is a Sunday.
      project.createWeeklyIfNeeded(now: DateTime(2023, 10, 1));

      expect(project.weeklies.length, 1);
      expect(project.weeklies.first.date, DateTime(2023, 9, 25));
    });

    test('createWeeklyIfNeeded moves pending tasks to new w)eekly', () {
      final project = Project();
      project.createWeekly(DateTime(2023, 10, 1));
      final previousWeekly = project.weeklies.last;
      previousWeekly.todos.add(Todo.fromLine('* Task 1'));
      previousWeekly.todos.add(Todo.fromLine('* Task 2'));
      previousWeekly.todos.add(Todo.fromLine('F Task 3'));

      project.createWeeklyIfNeeded(now: DateTime(2023, 10, 2));

      expect(project.weeklies.length, 2);
      final newWeekly = project.weeklies.last;
      expect(newWeekly.date, DateTime(2023, 10, 2));
      expect(newWeekly.todos.length, 2);
      expect(newWeekly.todos[0].desc, 'Task 1');
      expect(newWeekly.todos[1].desc, 'Task 2');
      expect(previousWeekly.todos.length, 1);
      expect(previousWeekly.todos[0].desc, 'Task 3');
    });
  });
}
