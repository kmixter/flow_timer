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
          '* This is a TODO with all bells and whistles 76m +2hr <=12/31     ##@8:56 10m/d';
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

    test('parse() and toLine() - TODO with coins', () {
      const line = 'M This is a TODO with coins 50c';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, 0);
      expect(todo.desc, 'This is a TODO with coins');
      expect(todo.coins, 50);
      expect(todo.toLine(), line);
    });

    test('parse() and toLine() - TODO with coin rate', () {
      const line =
          '* This is a TODO with coin rate 2hr 50c                           ##25c/hr';
      final todo = Todo.fromLine(line);
      expect(todo.dayNumber, -1);
      expect(todo.desc, 'This is a TODO with coin rate');
      expect(todo.duration, 120);
      expect(todo.coins, 50);
      expect(todo.getCoinRate(), 25); // 50 coins / 2 hours
      expect(todo.toLine(), line);
    });

    test('parse() and toLine() - TODO with all annotations including coin rate',
        () {
      const line =
          '* This is a TODO with all bells and whistles 76m +2hr 115c <=12/31 ##@8:56 10m/d 91c/hr';
      final fixedDate = DateTime(2024, 12, 24, 8, 56);
      final todo = Todo.fromLine(line, now: fixedDate);
      expect(todo.dayNumber, -1);
      expect(todo.desc, 'This is a TODO with all bells and whistles');
      expect(todo.duration, 76);
      expect(todo.spentMinutes, 120);
      expect(todo.dueDate, DateTime(2024, 12, 31, 23, 59, 59));
      expect(todo.startTime, const TimeOfDay(hour: 8, minute: 56));
      expect(todo.coins, 115);
      expect(todo.toLine(), line);
    });

    test('equals() - identical TODOs', () {
      const line = 'M This is a TODO with a duration 30m';
      final todo1 = Todo.fromLine(line);
      final todo2 = Todo.fromLine(line);
      expect(todo1.equals(todo2), isTrue);
    });

    test('equals() - different TODOs', () {
      const line1 = 'M This is a TODO with a duration 30m';
      const line2 = 'T This is a different TODO with a duration 30m';
      final todo1 = Todo.fromLine(line1);
      final todo2 = Todo.fromLine(line2);
      expect(todo1.equals(todo2), isFalse);
    });
  });
}
