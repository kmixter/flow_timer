import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_timer/task.dart';

void main() {
  group('Task', () {
    test('parse() and toLine() - basic TODO', () {
      const line = '* This is a basic TODO';
      final task = Task.fromLine(line);
      expect(task.dayNumber, -1);
      expect(task.desc, 'This is a basic TODO');
      expect(task.toLine(), line);
    });

    test('parse() and toLine() - annotations stripped', () {
      const line = 'M This is a TODO  ## and skip all this';
      final task = Task.fromLine(line);
      expect(task.dayNumber, 0);
      expect(task.desc, 'This is a TODO');
      expect(task.toLine(), 'M This is a TODO');
    });

    test('parse() and toLine() - TODO with duration', () {
      const line = 'M This is a TODO with a duration 30m';
      final task = Task.fromLine(line);
      expect(task.dayNumber, 0);
      expect(task.desc, 'This is a TODO with a duration');
      expect(task.duration, 30);
      expect(task.toLine(), line);
    });

    test('parse() and toLine() - TODO with due date', () {
      const line = 'M This is a TODO with a due date <=12/31';
      final task = Task.fromLine(line);
      expect(task.dayNumber, 0);
      expect(task.desc, 'This is a TODO with a due date');
      final currentYear = DateTime.now().year;
      expect(task.dueDate, DateTime(currentYear, 12, 31, 23, 59, 59));
      expect(task.toLine(), line);
    });

    test('parse() and toLine() - TODO with all annotations', () {
      const line =
          '* This is a TODO with all bells and whistles 76m +2hr <=12/31 ## @8:56 10m/d';
      final fixedDate = DateTime(2024, 12, 24, 8, 56);
      final task = Task.fromLine(line, now: fixedDate);
      expect(task.dayNumber, -1);
      expect(task.desc, 'This is a TODO with all bells and whistles');
      expect(task.duration, 76);
      expect(task.dueDate, DateTime(2024, 12, 31, 23, 59, 59));
      expect(task.startTime, const TimeOfDay(hour: 8, minute: 56));
      expect(task.spentMinutes, 120);
      expect(task.daysLeft, 8);
      expect(task.toLine(), line);
    });
  });
}
