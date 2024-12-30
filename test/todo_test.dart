import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_timer/todo.dart';

void main() {
  group('Todo', () {
    test('parse() and toLine() - basic TODO', () {
      const line = '* This is a basic TODO';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, -1);
      expect(todo.desc, 'This is a basic TODO');
      expect(todo.toLine(), line);
    });

    test('parse() and toLine() - annotations stripped', () {
      const line = 'M This is a TODO  ## and skip all this';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, 0);
      expect(todo.desc, 'This is a TODO');
      expect(todo.toLine(), 'M This is a TODO');
    });

    test('parse() and toLine() - TODO with duration', () {
      const line = 'M This is a TODO with a duration 30m';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, 0);
      expect(todo.desc, 'This is a TODO with a duration');
      expect(todo.duration, 30);
      expect(todo.toLine(), line);
    });

    test('parse() and toLine() - TODO with due date', () {
      const line = 'M This is a TODO with a due date <=12/31';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, 0);
      expect(todo.desc, 'This is a TODO with a due date');
      final currentYear = DateTime.now().year;
      expect(todo.dueDate, DateTime(currentYear, 12, 31, 23, 59, 59));
      expect(todo.toLine(), line);
    });

    test('parse() and toLine() - TODO with all annotations', () {
      const line =
          '* This is a TODO with all bells and whistles 76m +2hr <=12/31 ## @8:56 10m/d';
      final fixedDate = DateTime(2024, 12, 24, 8, 56);
      final todo = Todo.fromLine(line, now: fixedDate);
      expect(todo.dayNumber, -1);
      expect(todo.desc, 'This is a TODO with all bells and whistles');
      expect(todo.duration, 76);
      expect(todo.dueDate, DateTime(2024, 12, 31, 23, 59, 59));
      expect(todo.startTime, const TimeOfDay(hour: 8, minute: 56));
      expect(todo.spentMinutes, 120);
      expect(todo.daysLeft, 8);
      expect(todo.toLine(), line);
    });
  });
}
