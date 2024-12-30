import 'package:test/test.dart';
import 'package:flow_timer/project_file.dart';
import 'package:flow_timer/task.dart';

void main() {
  group('ProjectFile', () {
    late ProjectFile projectFile;
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
      projectFile = ProjectFile();
      await projectFile.parse(testContent);
    });

    test('parse and getDates', () {
      final dates = projectFile.getWeeklies();
      expect(dates, [DateTime(2023, 10, 1), DateTime(2024, 12, 10)]);
    });

    test('getTasksForDate', () {
      final weekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      final tasks = weekly.tasks;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'Task 1');
      expect(tasks[1].desc, 'Task 2');
    });

    test('getNotesForDate', () {
      final weekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      final notes = weekly.getNotesString();
      expect(notes, 'Notes for 2023-10-01\n');
    });

    test('Check toString returns what was parsed', () {
      final newContent = projectFile.toString();
      expect(newContent, testContent);
    });

    test('replaceTasksForDate', () async {
      final weekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      weekly.tasks = [
        Task(dayNumber: 0, desc: 'New Task 1'),
        Task(dayNumber: 1, desc: 'New Task 2'),
      ];
      final newContent = projectFile.toString();
      await projectFile.parse(newContent);
      final updatedWeekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      final tasks = updatedWeekly.tasks;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'New Task 1');
      expect(tasks[1].desc, 'New Task 2');
    });

    test('replaceNotesForDate', () async {
      final weekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      weekly.setNotesFromString('New notes for 2023-10-01\n');
      final newContent = projectFile.toString();
      await projectFile.parse(newContent);
      final updatedWeekly = projectFile.getWeekly(DateTime(2023, 10, 1));
      final notes = updatedWeekly.getNotesString();
      expect(notes, 'New notes for 2023-10-01\n');
    });

    test('test reading empty file', () async {
      final emptyFile = ProjectFile();
      await emptyFile.parse('');
      expect(emptyFile.weeklies.isEmpty, true);
    });

    test('test writing empty file', () async {
      final emptyFile = ProjectFile();
      await emptyFile.parse('');
      final newContent = emptyFile.toString();
      expect(newContent, '');
    });

    test('test writing file with 2 empty weeklies', () async {
      final emptyFile = ProjectFile();
      emptyFile.createWeekly(DateTime(2023, 10, 1));
      emptyFile.createWeekly(DateTime(2023, 10, 2));
      final newContent = emptyFile.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\n\nMon, Oct 2, 2023\n----------------\n\n');
    });

    test('test reading file with 2 empty weeklies', () async {
      final emptyFile = ProjectFile();
      await emptyFile
          .parse('2023-10-01\n----------\n\n2023-10-02\n----------\n\n');
      expect(emptyFile.weeklies.length, 2);
      expect(emptyFile.weeklies[0].tasks.isEmpty, true);
      expect(emptyFile.weeklies[0].notes.isEmpty, true);
      expect(emptyFile.weeklies[1].tasks.isEmpty, true);
      expect(emptyFile.weeklies[1].notes.isEmpty, true);
    });

    test('test writing empty tasks', () async {
      final justNotes = ProjectFile();
      final weekly = justNotes.createWeekly(DateTime(2023, 10, 1));
      weekly.setNotesFromString('hi there, this is a note');
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nhi there, this is a note\n\n');
    });

    test('test reading empty tasks', () async {
      final justNotes = ProjectFile();
      await justNotes
          .parse('2023-10-01\n----------\nhi there, this is a note\n\n');
      expect(justNotes.weeklies.length, 1);
      expect(justNotes.weeklies[0].tasks.isEmpty, true);
      expect(justNotes.weeklies[0].notes.length, 1);
      expect(justNotes.weeklies[0].notes[0], 'hi there, this is a note');
    });

    test('test adding first todo', () async {
      final justNotes = ProjectFile();
      final weekly = justNotes.createWeekly(DateTime(2023, 10, 1));
      weekly.tasks.add(Task(dayNumber: 0, desc: 'First Task'));
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nTODOs:\nM First Task\n\n');
    });

    test('test recompute day of week order', () async {
      final notes = ProjectFile();
      final weekly = notes.createWeekly(DateTime(2023, 10, 1));
      weekly.tasks.add(Task(dayNumber: 1, desc: 'Second Task'));
      weekly.tasks.add(Task(dayNumber: 0, desc: 'FIrst Task'));
      expect(weekly.tasks[0].dayNumber, 1);
      expect(weekly.tasks[1].dayNumber, 0);
      notes.recompute();
      expect(weekly.tasks.length, 2);
      expect(weekly.tasks[0].dayNumber, 0);
      expect(weekly.tasks[1].dayNumber, 1);
      expect(weekly.todoLine, 'TODOs:');
    });

    test('test recompute pending by completion rate', () async {
      final notes = ProjectFile();
      final weekly = notes.createWeekly(DateTime(2023, 10, 1));
      weekly.tasks.add(Task(
          dayNumber: -1,
          desc: 'Task 1',
          duration: 6,
          dueDate: DateTime(2023, 10, 7)));
      weekly.tasks.add(Task(
          dayNumber: -1,
          desc: 'Task 2',
          duration: 6,
          dueDate: DateTime(2023, 10, 4)));
      final now = DateTime(2023, 10, 1);
      notes.recompute(now: now);
      expect(weekly.tasks.length, 2);
      expect(weekly.tasks[0].desc, 'Task 2');
      expect(weekly.tasks[0].getCompletionRate(), 2);
      expect(weekly.tasks[1].desc, 'Task 1');
      expect(weekly.tasks[1].getCompletionRate(), 1);

      expect(weekly.getTotalsAnnotation(), '∑: 3m/d');
      expect(weekly.todoLine,
          'TODOs:                                                            ## ∑: 3m/d');
    });
  });
}
