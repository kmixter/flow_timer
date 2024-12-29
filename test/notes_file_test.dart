import 'package:test/test.dart';
import 'package:flow_timer/notes_file.dart';
import 'package:flow_timer/task.dart';

void main() {
  group('NotesFile', () {
    late NotesFile notesFile;
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
      notesFile = NotesFile();
      await notesFile.parse(testContent);
    });

    test('parse and getDates', () {
      final dates = notesFile.getDates();
      expect(dates, [DateTime(2023, 10, 1), DateTime(2024, 12, 10)]);
    });

    test('getTasksForDate', () {
      final region = notesFile.getRegion(DateTime(2023, 10, 1));
      final tasks = region.tasks;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'Task 1');
      expect(tasks[1].desc, 'Task 2');
    });

    test('getNotesForDate', () {
      final region = notesFile.getRegion(DateTime(2023, 10, 1));
      final notes = region.getNotesString();
      expect(notes, 'Notes for 2023-10-01\n');
    });

    test('Check toString returns what was parsed', () {
      final newContent = notesFile.toString();
      expect(newContent, testContent);
    });

    test('replaceTasksForDate', () async {
      final region = notesFile.getRegion(DateTime(2023, 10, 1));
      region.tasks = [
        Task(dayNumber: 0, desc: 'New Task 1'),
        Task(dayNumber: 1, desc: 'New Task 2'),
      ];
      final newContent = notesFile.toString();
      await notesFile.parse(newContent);
      final updatedRegion = notesFile.getRegion(DateTime(2023, 10, 1));
      final tasks = updatedRegion.tasks;
      expect(tasks.length, 2);
      expect(tasks[0].desc, 'New Task 1');
      expect(tasks[1].desc, 'New Task 2');
    });

    test('replaceNotesForDate', () async {
      final region = notesFile.getRegion(DateTime(2023, 10, 1));
      region.setNotesFromString('New notes for 2023-10-01\n');
      final newContent = notesFile.toString();
      await notesFile.parse(newContent);
      final updatedRegion = notesFile.getRegion(DateTime(2023, 10, 1));
      final notes = updatedRegion.getNotesString();
      expect(notes, 'New notes for 2023-10-01\n');
    });

    test('test reading empty file', () async {
      final emptyFile = NotesFile();
      await emptyFile.parse('');
      expect(emptyFile.regions.isEmpty, true);
    });

    test('test writing empty file', () async {
      final emptyFile = NotesFile();
      await emptyFile.parse('');
      final newContent = emptyFile.toString();
      expect(newContent, '');
    });

    test('test writing file with 2 empty regions', () async {
      final emptyFile = NotesFile();
      emptyFile.createRegion(DateTime(2023, 10, 1));
      emptyFile.createRegion(DateTime(2023, 10, 2));
      final newContent = emptyFile.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\n\nMon, Oct 2, 2023\n----------------\n\n');
    });

    test('test reading file with 2 empty regions', () async {
      final emptyFile = NotesFile();
      await emptyFile
          .parse('2023-10-01\n----------\n\n2023-10-02\n----------\n\n');
      expect(emptyFile.regions.length, 2);
      expect(emptyFile.regions[0].tasks.isEmpty, true);
      expect(emptyFile.regions[0].notes.isEmpty, true);
      expect(emptyFile.regions[1].tasks.isEmpty, true);
      expect(emptyFile.regions[1].notes.isEmpty, true);
    });

    test('test writing empty tasks', () async {
      final justNotes = NotesFile();
      final region = justNotes.createRegion(DateTime(2023, 10, 1));
      region.setNotesFromString('hi there, this is a note');
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nhi there, this is a note\n\n');
    });

    test('test reading empty tasks', () async {
      final justNotes = NotesFile();
      await justNotes
          .parse('2023-10-01\n----------\nhi there, this is a note\n\n');
      expect(justNotes.regions.length, 1);
      expect(justNotes.regions[0].tasks.isEmpty, true);
      expect(justNotes.regions[0].notes.length, 1);
      expect(justNotes.regions[0].notes[0], 'hi there, this is a note');
    });

    test('test adding first todo', () async {
      final justNotes = NotesFile();
      final region = justNotes.createRegion(DateTime(2023, 10, 1));
      region.tasks.add(Task(dayNumber: 0, desc: 'First Task'));
      final newContent = justNotes.toString();
      expect(newContent,
          'Sun, Oct 1, 2023\n----------------\nTODOs:\nM First Task\n\n');
    });

    test('test recompute day of week order', () async {
      final notes = NotesFile();
      final region = notes.createRegion(DateTime(2023, 10, 1));
      region.tasks.add(Task(dayNumber: 1, desc: 'Second Task'));
      region.tasks.add(Task(dayNumber: 0, desc: 'FIrst Task'));
      expect(region.tasks[0].dayNumber, 1);
      expect(region.tasks[1].dayNumber, 0);
      notes.recompute();
      expect(region.tasks.length, 2);
      expect(region.tasks[0].dayNumber, 0);
      expect(region.tasks[1].dayNumber, 1);
      expect(region.todoLine, 'TODOs:');
    });

    test('test recompute pending by completion rate', () async {
      final notes = NotesFile();
      final region = notes.createRegion(DateTime(2023, 10, 1));
      region.tasks.add(Task(
          dayNumber: -1,
          desc: 'Task 1',
          duration: 6,
          dueDate: DateTime(2023, 10, 7)));
      region.tasks.add(Task(
          dayNumber: -1,
          desc: 'Task 2',
          duration: 6,
          dueDate: DateTime(2023, 10, 4)));
      final now = DateTime(2023, 10, 1);
      notes.recompute(now: now);
      expect(region.tasks.length, 2);
      expect(region.tasks[0].desc, 'Task 2');
      expect(region.tasks[0].getCompletionRate(), 2);
      expect(region.tasks[1].desc, 'Task 1');
      expect(region.tasks[1].getCompletionRate(), 1);

      expect(region.getTotalsAnnotation(), '∑: 3m/d');
      expect(region.todoLine,
          'TODOs:                                                            ## ∑: 3m/d');
    });
  });
}
