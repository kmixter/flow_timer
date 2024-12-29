import 'task.dart';
import 'package:intl/intl.dart';

const String defaultDateFormat = 'EEE, MMM d, yyyy';

enum ParseState { beginRegion, readingTodos, readingNotes }

class NotesFile {
  final List<NotesRegion> regions = [];

  Future<void> parse(String content) async {
    final lines = content.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    NotesRegion? currentRegion;
    regions.clear();

    ParseState state = ParseState.beginRegion;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Handle region changes in any context.
      if (_isDateLine(line) &&
          i + 1 < lines.length &&
          _isSeparatorLine(lines[i + 1])) {
        if (currentRegion != null) {
          regions.add(currentRegion);
        }
        currentRegion = NotesRegion(date: _parseDate(line)!);
        ++i; // Skip the separator line.
        state = ParseState.beginRegion;
        continue;
      }

      switch (state) {
        case ParseState.beginRegion:
          if (_isTodoLine(line)) {
            currentRegion?.todoLine = line;
            state = ParseState.readingTodos;
          } else if (line.trim().isNotEmpty) {
            state = ParseState.readingNotes;
            i--; // Reprocess this line in the next state.
          }
          break;

        case ParseState.readingTodos:
          if (Task.isTodoLine(line)) {
            currentRegion?.tasks.add(Task.fromLine(line));
          } else {
            state = ParseState.readingNotes;
            i--; // Reprocess this line in the next state.
          }
          break;

        case ParseState.readingNotes:
          final trimmed = line.trim();
          if (trimmed.isEmpty && currentRegion?.notes.isEmpty == true) {
            // Skip empty lines between tasks and notes.
            continue;
          }
          currentRegion?.notes.add(line.trim());
          break;
      }
    }

    if (currentRegion != null) {
      regions.add(currentRegion);
    }

    // Remove trailing empty note lines from all regions
    for (var region in regions) {
      while (region.notes.isNotEmpty && region.notes.last.isEmpty) {
        region.notes.removeLast();
      }
    }
  }

  List<DateTime> getDates() {
    return regions.map((region) => region.date).toList();
  }

  NotesRegion getRegion(DateTime date) {
    return regions.firstWhere((region) => region.date == date);
  }

  NotesRegion createRegion(DateTime date) {
    final region = NotesRegion(date: date);
    regions.add(region);
    return region;
  }

  void recompute({DateTime? now}) {
    for (var region in regions) {
      region.recompute(now: now);
    }
  }

  StringBuffer _toStringBuffer() {
    final buffer = StringBuffer();
    for (var region in regions) {
      final dateLine = DateFormat(defaultDateFormat).format(region.date);
      buffer.writeln(dateLine);
      buffer.writeln('-' * dateLine.length);
      if (region.tasks.isNotEmpty) {
        buffer.writeln(region.todoLine ?? 'TODOs:');
        for (var task in region.tasks) {
          buffer.writeln(task.toLine());
        }
        buffer.writeln();
      }
      if (region.notes.isNotEmpty) {
        buffer.writeln(region.notes.join('\n'));
        buffer.writeln();
      }
      if (region.tasks.isEmpty && region.notes.isEmpty) {
        buffer.writeln();
      }
    }
    return buffer;
  }

  @override
  String toString() {
    return _toStringBuffer().toString();
  }

  bool _isDateLine(String line) {
    return _parseDate(line) != null;
  }

  bool _isSeparatorLine(String line) {
    return RegExp(r'^-+$').hasMatch(line);
  }

  bool _isTodoLine(String line) {
    return RegExp(r'^TODOs(:)?\s*(?:##.*)?$').hasMatch(line.trim());
  }

  DateTime? _parseDate(String line) {
    final formats = [
      DateFormat('yyyy-MM-dd'), // YYYY-MM-DD
      DateFormat('EEE, MMM d, yyyy'), // Day, Month DD, YYYY
      // Add more formats as needed
    ];

    for (var format in formats) {
      try {
        return format.parseStrict(line);
      } catch (e) {
        // Ignore parse errors and try the next format
      }
    }
    return null;
  }
}

class NotesRegion {
  final DateTime date;
  String? todoLine;
  List<Task> tasks = [];
  List<String> notes = [];

  NotesRegion({
    required this.date,
  });

  void setNotesFromString(String notesString) {
    notes = notesString.split('\n');
    if (notes.last.isEmpty) {
      notes.removeLast();
    }
  }

  String getNotesString() {
    return notes.map((a) => '$a\n').join('');
  }

  void recompute({DateTime? now}) {
    for (var task in tasks) {
      task.computeDaysLeft(now: now);
    }
    sortTasks();
    final totalsAnnotation = getTotalsAnnotation();
    if (totalsAnnotation == null) {
      todoLine = 'TODOs:';
    } else {
      todoLine = _formatAnnotations('TODOs:', [totalsAnnotation]);
    }
  }

  void sortTasks() {
    final pending = <Task>[];
    final completedByDay = List.generate(7, (_) => <Task>[]);

    for (final task in tasks) {
      if (task.dayNumber >= 0) {
        completedByDay[task.dayNumber].add(task);
      } else {
        pending.add(task);
      }
    }

    pending.sort((a, b) => _getPendingTaskPriority(b) > _getPendingTaskPriority(a) ? 1 : -1);

    final sortedTasks = <Task>[];
    sortedTasks.addAll(pending);
    for (final dayTasks in completedByDay) {
      sortedTasks.addAll(dayTasks);
    }

    tasks = sortedTasks;
  }

  static double _getPendingTaskPriority(Task task) {
    if (!task.hasCompletionRate) {
      return -1;
    }
    if (task.isElapsed) {
      return double.maxFinite;
    }
    return task.getCompletionRate();
  }

  String? getTotalsAnnotation() {
    if (tasks.any((task) => task.isElapsed)) {
      return '∑: ELAPSED!';
    }
    double sumCompletionRate = 0;
    for (final task in tasks) {
      sumCompletionRate += task.getCompletionRate();
    }
    if (sumCompletionRate == 0) {
      return null;
    }
    return '∑: ${Task.formatMinutes(sumCompletionRate)}/d';
  }

  static String _formatAnnotations(String line, List<String> annotations) {
    line = _stripAnnotations(line);
    return '${line.padRight(65)} ## ${annotations.join(' ')}';
  }

  static String _stripAnnotations(String line) {
    final index = line.indexOf('##');
    if (index != -1) {
      line = line.substring(0, index).trim();
    }
    return line;
  }
}
