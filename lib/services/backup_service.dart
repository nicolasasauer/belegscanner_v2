import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_service.dart';

const String kBackupEnabledKey = 'db_backup_enabled';
const String kBackupFrequencyKey = 'db_backup_frequency'; // 'daily'|'weekly'
const String kBackupTimeKey = 'db_backup_time'; // 'HH:mm'
const String kBackupWeekdayKey = 'db_backup_weekday'; // 1-7
const String kBackupMaxVersionsKey = 'db_backup_max_versions';
const String kBackupLastRunKey = 'db_backup_last_run';

class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  bool enabled = true;
  String frequency = 'daily';
  String time = '03:00';
  int weekday = 1; // Montag
  int maxVersions = 3;
  DateTime? lastRun;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(kBackupEnabledKey) ?? true;
    frequency = prefs.getString(kBackupFrequencyKey) ?? 'daily';
    time = prefs.getString(kBackupTimeKey) ?? '03:00';
    weekday = prefs.getInt(kBackupWeekdayKey) ?? 1;
    maxVersions = prefs.getInt(kBackupMaxVersionsKey) ?? 3;
    final last = prefs.getString(kBackupLastRunKey);
    lastRun = last != null ? DateTime.tryParse(last) : null;
    debugPrint('[BackupService] Einstellungen geladen: enabled=$enabled, freq=$frequency, time=$time, max=$maxVersions');
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBackupEnabledKey, enabled);
    await prefs.setString(kBackupFrequencyKey, frequency);
    await prefs.setString(kBackupTimeKey, time);
    await prefs.setInt(kBackupWeekdayKey, weekday);
    await prefs.setInt(kBackupMaxVersionsKey, maxVersions);
    if (lastRun != null) await prefs.setString(kBackupLastRunKey, lastRun!.toIso8601String());
  }

  /// Prüft, ob ein planmäßiges Backup ausgeführt werden muss und führt es aus.
  Future<void> checkAndRunScheduledBackup() async {
    await loadSettings();
    if (!enabled) return;

    final now = DateTime.now();
    final scheduledToday = _scheduledDateFor(now);

    // Determine if we should run: if lastRun is null or lastRun < scheduledToday <= now
    if (scheduledToday != null) {
      final shouldRun = lastRun == null || lastRun!.isBefore(scheduledToday);
      if (shouldRun && now.isAfter(scheduledToday.subtract(const Duration(seconds: 1)))) {
        await performBackup();
      }
    }
  }

  DateTime? _scheduledDateFor(DateTime ref) {
    final parts = time.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]) ?? 3;
    final minute = int.tryParse(parts[1]) ?? 0;
    if (frequency == 'daily') {
      return DateTime(ref.year, ref.month, ref.day, hour, minute);
    } else if (frequency == 'weekly') {
      // find this week's weekday date for configured weekday (1=Mon..7=Sun)
      final desired = weekday; // 1..7
      final currentWeekday = ref.weekday; // 1..7
      final diff = desired - currentWeekday;
      final scheduledDay = ref.add(Duration(days: diff));
      return DateTime(scheduledDay.year, scheduledDay.month, scheduledDay.day, hour, minute);
    }
    return null;
  }

  Future<Directory> _backupsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'backups'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<String?> performBackup() async {
    try {
      final dbPath = await DatabaseService().getDatabaseFilePath();
      final dbFile = File(dbPath);
      if (!dbFile.existsSync()) return null;

      final dir = await _backupsDir();
      final ts = DateTime.now();
      final name = 'backup_${ts.toIso8601String().replaceAll(':', '-')}.db';
      final dest = File(p.join(dir.path, name));
      await dbFile.copy(dest.path);
      lastRun = DateTime.now();
      await saveSettings();
      await _cleanupOldBackups();
      debugPrint('[BackupService] Backup erstellt: ${dest.path}');
      return dest.path;
    } catch (e) {
      debugPrint('[BackupService] Backup fehlgeschlagen: $e');
      return null;
    }
  }

  Future<void> _cleanupOldBackups() async {
    final dir = await _backupsDir();
    final files = dir.listSync().whereType<File>().toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (files.length <= maxVersions) return;
    for (var i = maxVersions; i < files.length; i++) {
      try {
        await files[i].delete();
      } catch (_) {}
    }
  }

  Future<List<FileSystemEntity>> listBackups() async {
    final dir = await _backupsDir();
    final files = dir.listSync().whereType<File>().toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// Stellt die Datenbank aus einer Backup-Datei wieder her.
  /// Schließt zuvor die Datenbank, kopiert die Datei über die DB und lässt
  /// den Aufrufer die App neu initialisieren falls nötig.
  Future<bool> restoreBackup(String backupPath) async {
    try {
      final dbService = DatabaseService();
      await dbService.close();
      final dbPath = await dbService.getDatabaseFilePath();
      final src = File(backupPath);
      if (!src.existsSync()) return false;
      await src.copy(dbPath);
      debugPrint('[BackupService] Backup wiederhergestellt: $backupPath');
      return true;
    } catch (e) {
      debugPrint('[BackupService] Restore fehlgeschlagen: $e');
      return false;
    }
  }
}
