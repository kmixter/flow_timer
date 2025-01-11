import 'todo.dart';
import 'package:intl/intl.dart';

const String defaultDateFormat = 'EEE, MMM d, yyyy';

enum ParseState { beginWeekly, readingTodos, readingNotes }

class Project {
  final List<Weekly> weeklies = [];

  final datePattern = RegExp(r'^[A-Za-z]{3}, [A-Za-z]{3} \d{1,2}, \d{4}$');
  final dateFormat = DateFormat('EEE, MMM d, yyyy');

  Future<void> parse(String content) async {
    final lines = content.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    Weekly? curentWeekly;
    weeklies.clear();

    ParseState state = ParseState.beginWeekly;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Handle region changes in any context.
      if (_isDateLine(line) &&
          i + 1 < lines.length &&
          _isSeparatorLine(lines[i + 1])) {
        if (curentWeekly != null) {
          weeklies.add(curentWeekly);
        }
        curentWeekly = Weekly(date: _parseDate(line)!);
        ++i; // Skip the separator line.
        state = ParseState.beginWeekly;
        continue;
      }

      switch (state) {
        case ParseState.beginWeekly:
          if (_isTodoLine(line)) {
            curentWeekly?.todoLine = line;
            state = ParseState.readingTodos;
          } else if (line.trim().isNotEmpty) {
            state = ParseState.readingNotes;
            i--; // Reprocess this line in the next state.
          }
          break;

        case ParseState.readingTodos:
          if (Todo.isTodoLine(line)) {
            curentWeekly?.todos.add(Todo.fromLine(line));
          } else {
            state = ParseState.readingNotes;
            i--; // Reprocess this line in the next state.
          }
          break;

        case ParseState.readingNotes:
          final trimmed = line.trim();
          if (trimmed.isEmpty && curentWeekly?.notes.isEmpty == true) {
            // Skip empty lines between todos and notes.
            continue;
          }
          curentWeekly?.notes.add(line.trim());
          break;
      }
    }

    if (curentWeekly != null) {
      weeklies.add(curentWeekly);
    }

    // Remove trailing empty note lines from all regions
    for (var region in weeklies) {
      while (region.notes.isNotEmpty && region.notes.last.isEmpty) {
        region.notes.removeLast();
      }
    }
  }

  List<DateTime> getWeeklies() {
    return weeklies.map((region) => region.date).toList();
  }

  Weekly getWeekly(DateTime date) {
    return weeklies.firstWhere((region) => region.date == date);
  }

  Weekly createWeekly(DateTime date) {
    Weekly newWeekly = Weekly(date: date);
    weeklies.add(newWeekly);
    return newWeekly;
  }

  void createWeeklyIfNeeded({DateTime? now}) {
    final currentDate = now ?? DateTime.now();
    final lastMondayDate =
        DateTime(currentDate.year, currentDate.month, currentDate.day)
            .subtract(Duration(days: currentDate.weekday - DateTime.monday));
    if (weeklies.isEmpty || weeklies.last.date.isBefore(lastMondayDate)) {
      weeklies.add(Weekly(date: lastMondayDate));
      // Bring forward pending tasks from last week and remove them from last week
      if (weeklies.length > 1) {
        final lastWeekly = weeklies[weeklies.length - 2];
        final lastWeekPending =
            lastWeekly.todos.where((todo) => todo.dayNumber == -1).toList();
        lastWeekly.todos.removeWhere((todo) => todo.dayNumber == -1);
        weeklies.last.todos.insertAll(0, lastWeekPending);
      }
    }
  }

  void recompute({DateTime? now}) {
    for (var weekly in weeklies) {
      weekly.recompute(now: now);
    }
  }

  StringBuffer _toStringBuffer() {
    final buffer = StringBuffer();
    for (var weekly in weeklies) {
      final dateLine = DateFormat(defaultDateFormat).format(weekly.date);
      buffer.writeln(dateLine);
      buffer.writeln('-' * dateLine.length);
      if (weekly.todos.isNotEmpty) {
        buffer.writeln(weekly.todoLine ?? 'TODOs:');
        for (var todo in weekly.todos) {
          buffer.writeln(todo.toLine());
        }
        buffer.writeln();
      }
      if (weekly.notes.isNotEmpty) {
        buffer.writeln(weekly.notes.join('\n'));
        buffer.writeln();
      }
      if (weekly.todos.isEmpty && weekly.notes.isEmpty) {
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
    if (datePattern.hasMatch(line)) {
      return dateFormat.tryParse(line);
    }
    return null;
  }
}

class Weekly {
  final DateTime date;
  String? todoLine;
  List<Todo> todos = [];
  List<String> notes = [];

  Weekly({
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
    for (var todo in todos) {
      todo.computeDaysLeft(now: now);
    }
    sortTodos(now: now);
    final totalsAnnotation = getTotalsAnnotation();
    if (totalsAnnotation == null) {
      todoLine = 'TODOs:';
    } else {
      todoLine = _formatAnnotations('TODOs:', [totalsAnnotation]);
    }
  }

  void sortTodos({DateTime? now}) {
    final pending = <Todo>[];
    final completedByDay = List.generate(7, (_) => <Todo>[]);

    for (final todo in todos) {
      if (todo.dayNumber >= 0) {
        completedByDay[todo.dayNumber].add(todo);
      } else {
        pending.add(todo);
      }
    }

    pending.sort((a, b) => _comparePendingTodos(a, b, now: now));

    final sortedTodos = <Todo>[];
    sortedTodos.addAll(pending);
    for (final dayTodos in completedByDay) {
      sortedTodos.addAll(dayTodos);
    }

    todos = sortedTodos;
  }

  int _comparePendingTodos(Todo a, Todo b, {DateTime? now}) {
    if (a.isElapsed != b.isElapsed) {
      return a.isElapsed ? -1 : 1;
    }
    if (a.hasCompletionRate != b.hasCompletionRate) {
      return a.hasCompletionRate ? -1 : 1;
    }
    if (a.hasCompletionRate && b.hasCompletionRate) {
      return b.getCompletionRate().compareTo(a.getCompletionRate());
    }
    if (a.hasCoinRate != b.hasCoinRate) {
      return a.hasCoinRate ? -1 : 1;
    }
    if (a.hasCoinRate && b.hasCoinRate) {
      return b.getCoinRate().compareTo(a.getCoinRate());
    }
    return 0;
  }

  String? getTotalsAnnotation() {
    double sumCompletionRate = 0;
    double totalTimeRemaining = 0;
    double totalCoinsRemaining = 0;
    double totalCoins = 0;
    double totalHours = 0;

    for (final todo in todos) {
      sumCompletionRate += todo.getCompletionRate();
      if (!todo.isDone) {
        if (todo.duration != null) {
          totalTimeRemaining += todo.duration!;
        }
        if (todo.coins != null) {
          totalCoinsRemaining += todo.coins!;
        }
        if (todo.duration != null && todo.coins != null) {
          totalCoins += todo.coins!;
          totalHours += todo.duration! / 60;
        }
      }
    }

    final annotations = <String>[];
    if (todos.any((todo) => todo.isElapsed)) {
      annotations.add('ELAPSED!');
    } else if (sumCompletionRate > 0) {
      annotations.add('${Todo.formatMinutes(sumCompletionRate)}/d');
    }
    if (totalTimeRemaining > 0) {
      annotations.add(Todo.formatMinutes(totalTimeRemaining));
    }
    if (totalCoinsRemaining > 0) {
      annotations.add(
          '${totalCoinsRemaining.toStringAsFixed(2).replaceAll(RegExp(r'\.?0*$'), '')}c');
    }
    if (totalHours > 0) {
      final coinRate = totalCoins / totalHours;
      annotations.add(
          '${coinRate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0*$'), '')}c/hr');
    }

    if (annotations.isEmpty) {
      return null;
    }

    return '∑: ${annotations.join(' ')}';
  }

  static String _formatAnnotations(String line, List<String> annotations) {
    line = _stripAnnotations(line);
    return '${line.padRight(65)} ##${annotations.join(' ')}';
  }

  static String _stripAnnotations(String line) {
    final index = line.indexOf('##');
    if (index != -1) {
      line = line.substring(0, index).trim();
    }
    return line;
  }
}
