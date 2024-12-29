import 'package:flutter/material.dart';

class Task {
  static const List<String> dayOfWeekStrings = [
    'M',
    'T',
    'W',
    'R',
    'F',
    'S',
    'N'
  ];

  static final RegExp durationRe = RegExp(r' ([\d\.]+)m\b| ([\d\.]+)hr(s)?\b');
  static final RegExp dueDateRe = RegExp(r' <=(\d+)/(\d+)\b');
  static final RegExp startTimeRe = RegExp(r'@(\d+):(\d+)');
  static final RegExp spentTimeRe = RegExp(r' \+([\d\.]+)(m|hr)');

  int dayNumber = -1; // -1 for pending, 0 for Monday, 1 for Tuesday, etc.
  String desc = '';
  double? duration; // in minutes
  DateTime? dueDate;
  int? daysLeft;
  TimeOfDay? startTime;
  double? spentMinutes;

  Task({
    required this.dayNumber,
    required this.desc,
    this.duration,
    this.dueDate,
    this.startTime,
    this.spentMinutes,
  });

  Task.fromLine(String line, {DateTime? now}) {
    if (!isTodoLine(line)) {
      throw ArgumentError('Invalid TODO line format: $line');
    }
    if (line[0] == '*') {
      dayNumber = -1;
    } else {
      dayNumber = dayOfWeekStrings.indexOf(line[0]);
    }
    desc = _stripAnnotations(line.substring(2));
    desc = desc
        .replaceAll(durationRe, '')
        .replaceAll(dueDateRe, '')
        .replaceAll(startTimeRe, '')
        .replaceAll(spentTimeRe, '')
        .trim();

    // Parse duration
    final durationMatch = durationRe.firstMatch(line);
    if (durationMatch != null) {
      duration = durationMatch.group(1) != null
          ? double.parse(durationMatch.group(1)!)
          : double.parse(durationMatch.group(2)!) * 60;
    }

    // Parse due date
    final dueDateMatch = dueDateRe.firstMatch(line);
    if (dueDateMatch != null) {
      final dueMonth = int.parse(dueDateMatch.group(1)!);
      final dueDay = int.parse(dueDateMatch.group(2)!);
      final currentDate = now ?? DateTime.now();
      dueDate = DateTime(currentDate.year, dueMonth, dueDay, 23, 59, 59);
      computeDaysLeft(now: now);
    }

    // Parse start time
    final startTimeMatch = startTimeRe.firstMatch(line);
    if (startTimeMatch != null) {
      startTime = TimeOfDay(
        hour: int.parse(startTimeMatch.group(1)!),
        minute: int.parse(startTimeMatch.group(2)!),
      );
    }

    // Parse spent time
    final spentTimeMatch = spentTimeRe.firstMatch(line);
    if (spentTimeMatch != null) {
      spentMinutes = double.parse(spentTimeMatch.group(1)!);
      if (spentTimeMatch.group(2) == 'hr') {
        spentMinutes = spentMinutes! * 60;
      }
    }
  }

  void computeDaysLeft({DateTime? now}) {
    if (dueDate == null) {
      daysLeft = null;
      return;
    }
    final currentDate = now ?? DateTime.now();
    final msecPerDay = 1000 * 60 * 60 * 24;
    final timeDelta =
        dueDate!.millisecondsSinceEpoch - currentDate.millisecondsSinceEpoch;
    daysLeft = (timeDelta / msecPerDay).ceil();
  }

  String _stripAnnotations(String desc) {
    // Remove everything after ## from desc
    final index = desc.indexOf('##');
    if (index != -1) {
      desc = desc.substring(0, index);
    }
    return desc;
  }

  String toLine() {
    String line = dayNumber == -1 ? '* ' : '${dayOfWeekStrings[dayNumber]} ';
    line += desc;

    if (duration != null) {
      line += ' ${formatMinutes(duration!)}';
    }
    if (spentMinutes != null) {
      line += ' +${formatMinutes(spentMinutes!)}';
    }
    if (dueDate != null) {
      line += ' <=${dueDate!.month}/${dueDate!.day}';
    }

    if (dayNumber == -1 &&
        (startTime != null || isElapsed || hasCompletionRate)) {
      final annotations = <String>[];
      if (startTime != null) {
        annotations.add(
            '@${startTime!.hour}:${startTime!.minute.toString().padLeft(2, '0')}');
      }
      if (isElapsed) {
        annotations.add('ELAPSED!');
      } else if (hasCompletionRate) {
        annotations.add('${formatMinutes(getCompletionRate())}/d');
      }
      line = '$line ## ${annotations.join(' ')}';
    }

    return line;
  }

  // Helper method to format minutes
  static String formatMinutes(double minutes) {
    if (minutes >= 90 || minutes == 60) {
      String hoursStr = (minutes / 60).toStringAsFixed(2);
      hoursStr = hoursStr.replaceAll(RegExp(r'\.?0*$'), '');
      return '${hoursStr}hr';
    }
    return '${minutes.round()}m';
  }

  bool get isElapsed => daysLeft != null && daysLeft! < 1;

  bool get hasCompletionRate => daysLeft != null && duration != null;

  double getCompletionRate() {
    if (!hasCompletionRate) {
      return 0;
    }
    return duration! / daysLeft!;
  }

  static bool isTodoLine(String line) {
    return RegExp(r'^[MTWRFSN\*] ').hasMatch(line);
  }
}
