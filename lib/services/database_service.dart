import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/category.dart';
import '../models/receipt.dart';

// ---------------------------------------------------------------------------
// Top-level Hashing-Funktion (compute-kompatibel)
// ---------------------------------------------------------------------------

/// Berechnet den SHA-256-Hash der Datei unter [filePath] und gibt ihn als
/// Hex-String zurück.
///
/// Diese Top-level-Funktion ist für [compute] geeignet, damit das Hashing
/// großer Bilddateien den UI-Thread nicht blockiert.
///
/// Gibt `null` zurück, wenn die Datei nicht existiert oder ein Fehler
/// auftritt.
Future<String?> computeFileHash(String filePath) async {
  try {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  } catch (e) {
    debugPrint('[computeFileHash] Fehler beim Hashing von $filePath: $e');
    return null;
  }
}

/// Service für die lokale SQLite-Datenbank.
///
/// Kapselt alle Datenbankoperationen für [Receipt]- und [Category]-Objekte:
///   - Initialisierung der Datenbank
///   - Einfügen, Laden und Löschen von Belegen
///   - Einfügen, Laden, Aktualisieren und Löschen von Kategorien
///   - Upsert und Laden von Produkt-Korrekturen ([product_mappings])
class DatabaseService {
  static const _dbName = 'belegscanner.db';
  static const _tableName = 'receipts';
  static const _categoriesTable = 'user_categories';

  /// Tabelle für den Lern-Feedback-Loop: speichert manuelle OCR-Korrekturen.
  static const _mappingsTable = 'product_mappings';

  /// Tabelle für händlerspezifische Parsing-Profile (Lern-Loop).
  static const _vendorProfilesTable = 'vendor_profiles';

  static const _dbVersion = 10;

  Database? _db;

  /// Gibt die geöffnete Datenbankinstanz zurück.
  /// Öffnet die Datenbank beim ersten Aufruf (Lazy Initialization).
  Future<Database> get database async {
    _db ??= await _openDatabase();
    return _db!;
  }

  Future<Database> _openDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL,
            totalAmount REAL NOT NULL,
            items TEXT NOT NULL,
            categories TEXT NOT NULL DEFAULT '[]',
            imagePath TEXT,
            storeName TEXT,
            spatialData TEXT,
            rawText TEXT,
            status TEXT NOT NULL DEFAULT 'completed',
            progress REAL NOT NULL DEFAULT 1.0,
            fileHash TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE $_categoriesTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            keywords TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE $_mappingsTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            raw_ocr_name TEXT NOT NULL UNIQUE,
            corrected_name TEXT NOT NULL,
            category_id INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE $_vendorProfilesTable (
            store_name TEXT PRIMARY KEY,
            preferred_strategy TEXT NOT NULL DEFAULT 'auto',
            success_count INTEGER NOT NULL DEFAULT 0,
            last_updated TEXT
          )
        ''');
        await _insertDefaultCategories(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Version 1 hatte imagePath TEXT NOT NULL.
          // SQLite unterstützt kein direktes ALTER COLUMN,
          // daher Tabelle neu erstellen und Daten übertragen.
          // Die neue Tabelle enthält bereits die categories-Spalte (v3).
          await db.execute('''
            CREATE TABLE ${_tableName}_new (
              id TEXT PRIMARY KEY,
              date TEXT NOT NULL,
              totalAmount REAL NOT NULL,
              items TEXT NOT NULL,
              categories TEXT NOT NULL DEFAULT '[]',
              imagePath TEXT,
              rawText TEXT,
              status TEXT NOT NULL DEFAULT 'completed',
              progress REAL NOT NULL DEFAULT 1.0,
              fileHash TEXT
            )
          ''');
          await db.execute('''
            INSERT INTO ${_tableName}_new
              (id, date, totalAmount, items, categories, imagePath,
               rawText, status, progress, fileHash)
              SELECT id, date, totalAmount, items, '[]', imagePath,
                     NULL, 'completed', 1.0, NULL
              FROM $_tableName
          ''');
          await db.execute('DROP TABLE $_tableName');
          await db.execute(
            'ALTER TABLE ${_tableName}_new RENAME TO $_tableName',
          );
        } else if (oldVersion < 3) {
          // Version 2 → Version 3: Kategorien-Spalte hinzufügen.
          await db.execute(
            "ALTER TABLE $_tableName ADD COLUMN categories TEXT NOT NULL DEFAULT '[]'",
          );
          // Direkt weiter zu v4 (rawText-Spalte) wenn nötig
          if (newVersion >= 4) {
            await db.execute(
              'ALTER TABLE $_tableName ADD COLUMN rawText TEXT',
            );
          }
          if (newVersion >= 9) {
            await db.execute('ALTER TABLE $_tableName ADD COLUMN storeName TEXT');
            await db.execute('ALTER TABLE $_tableName ADD COLUMN spatialData TEXT');
          }
        } else if (oldVersion < 4) {
          // Version 3 → Version 4: Roh-OCR-Text-Spalte hinzufügen.
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN rawText TEXT',
          );
        }
        // Version 4 → Version 5: Kategorien-Tabelle hinzufügen.
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $_categoriesTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              keywords TEXT NOT NULL DEFAULT '',
              color TEXT NOT NULL DEFAULT ''
            )
          ''');
          await _insertDefaultCategories(db);
        }
        // Version 5 → Version 6: Status- und Fortschritts-Spalten hinzufügen.
        if (oldVersion < 6) {
          await db.execute(
            "ALTER TABLE $_tableName ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'",
          );
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN progress REAL NOT NULL DEFAULT 1.0',
          );
        }
        // Version 6 → Version 7: fileHash-Spalte für Duplikatserkennung.
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE $_tableName ADD COLUMN fileHash TEXT',
          );
        }
        // Version 7 → Version 8: product_mappings-Tabelle für Lern-Loop.
        if (oldVersion < 8) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $_mappingsTable (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              raw_ocr_name TEXT NOT NULL UNIQUE,
              corrected_name TEXT NOT NULL,
              category_id INTEGER
            )
          ''');
        }
        // Version 8 → Version 9: storeName und spatialData
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE $_tableName ADD COLUMN storeName TEXT');
          await db.execute('ALTER TABLE $_tableName ADD COLUMN spatialData TEXT');
        }
        // Version 9 → Version 10: vendor_profiles-Tabelle für Händler-Lern-Loop.
        if (oldVersion < 10) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS $_vendorProfilesTable (
              store_name TEXT PRIMARY KEY,
              preferred_strategy TEXT NOT NULL DEFAULT 'auto',
              success_count INTEGER NOT NULL DEFAULT 0,
              last_updated TEXT
            )
          ''');
        }
      },
    );
  }

  /// Speichert einen [Receipt] in der Datenbank.
  ///
  /// Bereits vorhandene Einträge mit derselben ID werden ersetzt.
  Future<void> insertReceipt(Receipt receipt) async {
    final db = await database;
    await db.insert(
      _tableName,
      receipt.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Gibt alle gespeicherten Belege zurück, absteigend nach Datum sortiert.
  Future<List<Receipt>> getAllReceipts() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      orderBy: 'date DESC',
    );
    return maps.map(Receipt.fromMap).toList();
  }

  /// Löscht einen Beleg anhand seiner [id] aus der Datenbank.
  Future<void> deleteReceipt(String id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Aktualisiert einen bestehenden [Receipt] vollständig in der Datenbank.
  Future<void> updateReceipt(Receipt receipt) async {
    final db = await database;
    await db.update(
      _tableName,
      receipt.toMap(),
      where: 'id = ?',
      whereArgs: [receipt.id],
    );
  }

  /// Gibt alle Belege mit dem Status `'processing'` zurück.
  ///
  /// Wird beim App-Start verwendet, um unterbrochene Verarbeitungen zu erkennen
  /// und als `'failed'` zu markieren.
  Future<List<Receipt>> getProcessingReceipts() async {
    final db = await database;
    final maps = await db.query(
      _tableName,
      where: 'status = ?',
      whereArgs: ['processing'],
    );
    return maps.map(Receipt.fromMap).toList();
  }

  /// Sucht nach einem Beleg mit dem angegebenen [fileHash].
  ///
  /// Gibt die ID des ersten Treffers zurück oder `null`, wenn kein
  /// übereinstimmender Eintrag gefunden wird.  Wird zur Duplikatserkennung
  /// eingesetzt, bevor ein neues Bild verarbeitet wird.
  Future<String?> findReceiptIdByFileHash(String fileHash) async {
    final db = await database;
    final rows = await db.query(
      _tableName,
      columns: ['id'],
      where: 'fileHash = ?',
      whereArgs: [fileHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as String;
  }

  /// Gibt den vollständigen Pfad zur Datenbankdatei zurück.
  Future<String> getDatabaseFilePath() async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, _dbName);
  }

  /// Gibt das Verzeichnis zurück, in dem die Datenbank gespeichert ist.
  ///
  /// Dieses Verzeichnis ist app-privat und beschreibbar – geeignet für
  /// temporäre Export-Dateien.
  Future<String> getDatabasesDirectory() async {
    return getDatabasesPath();
  }

  /// Schließt die Datenbankverbindung.
  Future<void> close() async {
    try {
      await _db?.close();
    } finally {
      _db = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Kategorie-CRUD
  // ---------------------------------------------------------------------------

  /// Gibt alle benutzerdefinierten Kategorien zurück.
  Future<List<Category>> getCategories() async {
    final db = await database;
    final maps = await db.query(_categoriesTable, orderBy: 'name ASC');
    return maps.map(Category.fromMap).toList();
  }

  /// Fügt eine neue [Category] ein und gibt die erzeugte ID zurück.
  Future<int> insertCategory(Category category) async {
    final db = await database;
    return db.insert(
      _categoriesTable,
      category.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Aktualisiert eine bestehende [Category] (anhand ihrer [Category.id]).
  Future<void> updateCategory(Category category) async {
    assert(category.id != null, 'Kategorie muss eine ID haben');
    final db = await database;
    await db.update(
      _categoriesTable,
      category.toMap(),
      where: 'id = ?',
      whereArgs: [category.id],
    );
  }

  /// Gibt die Ausgaben des angegebenen Monats gruppiert nach Kategorie zurück.
  ///
  /// Jedes Element der Liste ist eine Map mit den Schlüsseln:
  ///   - `category` (String): Kategoriename
  ///   - `total` (double): Summe der Beträge in dieser Kategorie
  ///
  /// Belege ohne Kategorie-Zuordnung werden unter „Sonstiges" zusammengefasst.
  /// Die Zuordnung erfolgt über die pro-Artikel gespeicherte `categories`-Liste.
  /// Wenn [month] nicht angegeben ist, wird der aktuelle Monat verwendet.
  Future<List<Map<String, dynamic>>> getCategoryTotals({DateTime? month}) async {
    final db = await database;
    final ref = month ?? DateTime.now();
    final firstDay =
        DateTime(ref.year, ref.month, 1).toIso8601String();
    // DateTime akzeptiert month > 12 und rollt automatisch ins nächste Jahr.
    final lastDay =
        DateTime(ref.year, ref.month + 1, 1).toIso8601String();

    final rows = await db.query(
      _tableName,
      columns: ['items', 'categories', 'totalAmount'],
      where: 'date >= ? AND date < ?',
      whereArgs: [firstDay, lastDay],
    );

    // Aggregiere Beträge pro Kategorie über alle Artikel aller Belege.
    final Map<String, double> totals = {};

    for (final row in rows) {
      final items =
          (jsonDecode(row['items'] as String) as List<dynamic>).cast<String>();
      final categories = row['categories'] != null
          ? (jsonDecode(row['categories'] as String) as List<dynamic>)
              .cast<String>()
          : <String>[];

      for (int i = 0; i < items.length; i++) {
        final category =
            i < categories.length ? categories[i] : 'Sonstiges';
        // Preis aus dem Artikel-String extrahieren (Format: "Name  Preis")
        final parts = items[i].split('  ');
        double price = 0.0;
        if (parts.length >= 2) {
          // Deutschen Dezimaltrenner normalisieren und dann sauber parsen
          final rawPrice =
              parts.last.trim().replaceAll(',', '.').replaceAll(RegExp(r'[^0-9\.]'), '');
          // Sicherstellen, dass nur ein Dezimalpunkt vorhanden ist
          final dotCount = rawPrice.split('.').length - 1;
          final cleanPrice =
              dotCount > 1 ? rawPrice.replaceAll('.', '').padRight(3, '0') : rawPrice;
          price = double.tryParse(cleanPrice) ?? 0.0;
        }
        if (price > 0) {
          totals[category] = (totals[category] ?? 0.0) + price;
        }
      }

      // Wenn keine Artikel aufgeteilt werden können (z. B. ältere Belege),
      // den Gesamtbetrag unter „Sonstiges" zählen.
      if (items.isEmpty) {
        final amount = (row['totalAmount'] as num).toDouble();
        totals['Sonstiges'] = (totals['Sonstiges'] ?? 0.0) + amount;
      }
    }

    return totals.entries
        .map((e) => {'category': e.key, 'total': e.value})
        .toList()
      ..sort((a, b) =>
          (b['total'] as double).compareTo(a['total'] as double));
  }

  /// Löscht eine Kategorie anhand ihrer [id].
  Future<void> deleteCategory(int id) async {
    final db = await database;
    await db.delete(
      _categoriesTable,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // Produkt-Mappings (Lern-Feedback-Loop)
  // ---------------------------------------------------------------------------

  /// Speichert oder aktualisiert eine manuelle OCR-Korrektur.
  ///
  /// [rawOcrName] ist der Originaltext aus dem OCR-Ergebnis (nach Normalisierung),
  /// [correctedName] der vom Nutzer eingegebene korrekte Name,
  /// [categoryId] die optionale Datenbank-ID der zugeordneten Kategorie.
  ///
  /// Bereits existierende Einträge für denselben [rawOcrName] werden
  /// vollständig überschrieben (REPLACE-Semantik auf dem UNIQUE-Index).
  Future<void> upsertProductMapping(
    String rawOcrName,
    String correctedName,
    int? categoryId,
  ) async {
    final db = await database;
    await db.insert(
      _mappingsTable,
      {
        'raw_ocr_name': rawOcrName,
        'corrected_name': correctedName,
        'category_id': categoryId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    debugPrint(
        '[DatabaseService] Mapping gespeichert: "$rawOcrName" → '
        '"$correctedName" (category_id=$categoryId)');
  }

  /// Gibt alle gespeicherten Produkt-Mappings als Liste von Maps zurück.
  ///
  /// Jede Map enthält die Schlüssel `raw_ocr_name` (String),
  /// `corrected_name` (String) und `category_id` (int?).
  Future<List<Map<String, dynamic>>> getProductMappings() async {
    final db = await database;
    return db.query(_mappingsTable);
  }

  // ---------------------------------------------------------------------------
  // Händler-Profil (vendor_profiles)
  // ---------------------------------------------------------------------------

  /// Gibt das Händler-Profil für [storeName] zurück, oder `null`, wenn kein
  /// Profil vorhanden ist.
  ///
  /// Die zurückgegebene Map enthält die Schlüssel `store_name` (String),
  /// `preferred_strategy` (String: `'auto'`, `'tax_code'`, `'standard'`,
  /// `'spatial'`), `success_count` (int) und `last_updated` (String?).
  Future<Map<String, dynamic>?> getVendorProfile(String storeName) async {
    final db = await database;
    final rows = await db.query(
      _vendorProfilesTable,
      where: 'store_name = ?',
      whereArgs: [storeName],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Speichert oder aktualisiert das Händler-Profil für [storeName].
  ///
  /// [preferredStrategy] wird immer durch den neuen Wert ersetzt.
  /// [success_count] wird um 1 erhöht, wenn [incrementSuccess] `true` ist;
  /// andernfalls bleibt er unverändert (bzw. wird auf 0 gesetzt bei
  /// einem Neu-Eintrag ohne [incrementSuccess]).
  Future<void> upsertVendorProfile(
    String storeName, {
    required String preferredStrategy,
    bool incrementSuccess = false,
  }) async {
    final db = await database;
    final existing = await getVendorProfile(storeName);
    final newCount = (existing?['success_count'] as int? ?? 0) +
        (incrementSuccess ? 1 : 0);
    await db.insert(
      _vendorProfilesTable,
      {
        'store_name': storeName,
        'preferred_strategy': preferredStrategy,
        'success_count': newCount,
        'last_updated': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    debugPrint(
        '[DatabaseService] Vendor-Profil gespeichert: "$storeName" → '
        'Strategie="$preferredStrategy" success_count=$newCount');
  }

  // ---------------------------------------------------------------------------
  // Hilfsmethoden
  // ---------------------------------------------------------------------------

  /// Fügt die Standard-Kategorien in die Datenbank ein.
  ///
  /// Wird beim ersten App-Start (onCreate) und bei der Migration auf Version 5
  /// aufgerufen. Doppelte Einträge werden per IGNORE-Konflikt-Algorithmus
  /// verhindert – falls die Tabelle bereits Einträge enthält, werden keine
  /// weiteren Standardkategorien hinzugefügt.
  static Future<void> _insertDefaultCategories(Database db) async {
    const defaults = [
      {
        'name': 'Lebensmittel',
        'keywords':
            'Bio,Tofu,Milch,Brot,Obst,Gemüse,Fruchtaufstr,Alpro,Sbudget,Gnocchi',
        'color': '#4CAF50',
      },
      {
        'name': 'Drogerie',
        'keywords': 'Shampoo,Zahnpasta,Duschgel,Balea,Hygiene,Seife',
        'color': '#2196F3',
      },
      {
        'name': 'Getränke',
        'keywords': 'Red Bull,Cola,Wasser,Saft,Wein,Bier,Coke',
        'color': '#FF9800',
      },
      {
        'name': 'Pfand',
        'keywords': 'Pfand,Leergut',
        'color': '#FFC107',
      },
    ];

    for (final cat in defaults) {
      await db.insert(
        _categoriesTable,
        cat,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }
}
