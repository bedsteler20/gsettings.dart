import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:xdg_directories/xdg_directories.dart';

import 'gsettings_backend.dart';
import 'gsettings_dconf_backend.dart';
import 'gsettings_memory_backend.dart';
import 'gsettings_keyfile_backend.dart';
import 'gvariant_database.dart';

/// Get the names of the installed GSettings schemas.
/// These schemas can be accessed using a [GSettings] object.
Future<List<String>> listGSettingsSchemas() async {
  var schemaNames = <String>{};
  for (var dir in _getSchemaDirs()) {
    try {
      var database = GVariantDatabase('${dir.path}/gschemas.compiled');
      schemaNames.addAll(await database.list(dir: ''));
    } on FileSystemException {
      continue;
    }
  }
  return schemaNames.toList();
}

/// An object to access settings stored in a GSettings database.
class GSettings {
  /// The name of the schema for these settings, e.g. 'org.gnome.desktop.interface'.
  final String schemaName;

  /// The path to the settings, e.g. '/org/gnome/desktop/notifications/application/org-gnome-terminal/' or null if this is a non-relocatable schema.
  final String? path;

  /// A stream of settings key names as they change.
  Stream<List<String>> get keysChanged => _keysChangedController.stream;
  final _keysChangedController = StreamController<List<String>>.broadcast();

  // Backend in use.
  late final GSettingsBackend _backend;

  /// Creates an object to access settings from the shema with name [schemaName].
  /// If this schema is relocatable [path] is required to be set.
  /// If the schema is not relocatable an exception will be thrown if [path] is set.
  GSettings(this.schemaName,
      {this.path,
      DBusClient? systemBus,
      DBusClient? sessionBus,
      GSettingsBackend? backend}) {
    if (backend == null) {
      var backendName = Platform.environment['GSETTINGS_BACKEND'];
      switch (backendName) {
        case 'memory':
          backend = GSettingsMemoryBackend();
          break;
        case 'keyfile':
          backend = GSettingsKeyfileBackend();
          break;
        case 'dconf':
        case null:
          // Handled below
          break;
        default:
          stderr.write("Unsupported gsettings backend '$backendName'\n");
          break;
      }
    }
    // Default to DConf
    _backend = backend ??
        GSettingsDConfBackend(systemBus: systemBus, sessionBus: sessionBus);

    if (path != null) {
      if (path!.isEmpty) {
        throw ArgumentError.value(path, 'path', 'Empty path given');
      }
      if (!path!.startsWith('/')) {
        throw ArgumentError.value(
            path, 'path', 'Path must begin with a slash (/)');
      }
      if (!path!.endsWith('/')) {
        throw ArgumentError.value(
            path, 'path', 'Path must end with a slash (/)');
      }
      if (path!.contains('//')) {
        throw ArgumentError.value(
            path, 'path', 'Path must not contain two adjacent slashes (//)');
      }
    }
    _keysChangedController.onListen = () {
      _load().then((table) {
        var path = _getPath(table);
        _keysChangedController.addStream(_backend.valuesChanged
            .where((keys) => keys.any((key) => key.startsWith(path)))
            .map((keys) =>
                keys.map((key) => key.substring(path.length)).toList()));
      });
    };
  }

  /// Gets the names of the settings keys available.
  /// If the schema is not installed will throw a [GSettingsSchemaNotInstalledException].
  Future<List<String>> list() async {
    var table = await _load();
    return table.list(dir: '', type: 'v');
  }

  /// Reads the value of the settings key with [name].
  /// Attempting to read an unknown key will throw a [GSettingsUnknownKeyException].
  /// If the schema is not installed will throw a [GSettingsSchemaNotInstalledException].
  Future<DBusValue> get(String name) async {
    var table = await _load();
    var schemaEntry = _getSchemaEntry(table, name);
    var path = _getPath(table);

    var value =
        await _backend.get(path + name, schemaEntry.defaultValue.signature);
    return value ?? _getDefaultValue(schemaEntry);
  }

  /// Reads the default value of the settings key with [name].
  /// If this key is not set, then this value will be returned by [get].
  /// Attempting to read an unknown key will throw a [GSettingsUnknownKeyException].
  /// If the schema is not installed will throw a [GSettingsSchemaNotInstalledException].
  Future<DBusValue> getDefault(String name) async {
    var table = await _load();
    var schemaEntry = _getSchemaEntry(table, name);
    return _getDefaultValue(schemaEntry);
  }

  /// Check if the settings key with [name] is set.
  Future<bool> isSet(String name) async {
    var table = await _load();
    var schemaEntry = _getSchemaEntry(table, name);
    var path = _getPath(table);
    return await _backend.get(
            path + name, schemaEntry.defaultValue.signature) !=
        null;
  }

  /// Writes a single settings keys.
  /// If you need to set multiple values, use [setAll].
  Future<void> set(String name, DBusValue value) async {
    var table = await _load();
    var path = _getPath(table);
    await _backend.set({path + name: value});
  }

  /// Removes a setting value.
  /// The key will now return the default value specified in the GSetting schema.
  Future<void> unset(String name) async {
    var table = await _load();
    var path = _getPath(table);
    await _backend.set({path + name: null});
  }

  /// Writes multiple settings keys in a single transaction.
  /// Writing a null value will reset it to its default value.
  Future<void> setAll(Map<String, DBusValue?> values) async {
    var table = await _load();
    var path = _getPath(table);
    await _backend
        .set(values.map((name, value) => MapEntry(path + name, value)));
  }

  /// Terminates any open connections. If a settings object remains unclosed, the Dart process may not terminate.
  Future<void> close() async {
    await _backend.close();
  }

  // Get the database entry for this schema.
  Future<GVariantDatabaseTable> _load() async {
    for (var dir in _getSchemaDirs()) {
      var database = GVariantDatabase('${dir.path}/gschemas.compiled');
      try {
        var table = await database.lookupTable(schemaName);
        if (table != null) {
          return table;
        }
      } on FileSystemException {
        continue;
      }
    }

    throw GSettingsSchemaNotInstalledException(schemaName);
  }

  _GSettingsSchemaEntry _getSchemaEntry(
      GVariantDatabaseTable table, String name) {
    var entry = table.lookup(name)?.asStruct();
    if (entry == null) {
      throw GSettingsUnknownKeyException(schemaName, name);
    }
    var defaultValue = entry[0];
    List<int>? words;
    DBusValue? minimumValue;
    DBusValue? maximumValue;
    Map<String, DBusValue>? desktopOverrides;
    for (var item in entry.skip(1)) {
      var valueEntry = item.asStruct();
      switch (valueEntry[0].asByte()) {
        case 108: // 'l' - localization
          //var l10n = valueEntry[1].asByte(); // 'm': messages, 't': time.
          //var unparsedDefaultValue = (valueEntry[2].asString();
          break;
        case 102: // 'f' - flags
        case 101: // 'e' - enum
        case 99: // 'c' - choice
          words = valueEntry[1].asUint32Array().toList();
          break;
        case 114: // 'r' - range
          var range = valueEntry[1].asStruct();
          minimumValue = range[0];
          maximumValue = range[1];
          break;
        case 100: // 'd' - desktop overrides
          desktopOverrides = valueEntry[1].asStringVariantDict();
          break;
      }
    }
    return _GSettingsSchemaEntry(
        defaultValue: defaultValue,
        words: words,
        minimumValue: minimumValue,
        maximumValue: maximumValue,
        desktopOverrides: desktopOverrides);
  }

  DBusValue _getDefaultValue(_GSettingsSchemaEntry entry) {
    if (entry.desktopOverrides != null) {
      var xdgCurrentDesktop = Platform.environment['XDG_CURRENT_DESKTOP'] ?? '';
      for (var desktop in xdgCurrentDesktop.split(':')) {
        var defaultValue = entry.desktopOverrides![desktop];
        if (defaultValue != null) {
          return defaultValue;
        }
      }
    }

    return entry.defaultValue;
  }

  // Get the key path from the database table.
  String _getPath(GVariantDatabaseTable table) {
    var pathValue = table.lookup('.path');
    if (pathValue == null) {
      if (path == null) {
        throw GSettingsException(
            'No path provided for relocatable schema $schemaName');
      }
      return path!;
    }
    if (path != null) {
      throw GSettingsException(
          'Path provided for non-relocatable schema $schemaName');
    }
    return pathValue.asString();
  }
}

// Get the directories that contain schemas.
List<Directory> _getSchemaDirs() {
  var schemaDirs = <Directory>[];

  var schemaDir = Platform.environment['GSETTINGS_SCHEMA_DIR'];
  if (schemaDir != null) {
    schemaDirs.addAll(schemaDir.split(':').map((path) => Directory(path)));
  }

  for (var dataDir in dataDirs) {
    var path = dataDir.path;
    if (!path.endsWith('/')) {
      path += '/';
    }
    path += 'glib-2.0/schemas';

    if (!File('$path/gschemas.compiled').existsSync()) {
      continue;
    }

    schemaDirs.add(Directory(path));
  }

  schemaDirs.add(Directory('${dataHome.path}/glib-2.0/schemas'));

  return schemaDirs;
}

/// Exception thrown when an error occurs in GSettings.
class GSettingsException implements Exception {
  final String _message;

  const GSettingsException(this._message);

  @override
  String toString() => _message;
}

/// Exception thrown when trying to access a GSettings schema that is not installed.
class GSettingsSchemaNotInstalledException implements Exception {
  /// The name of the GSettings schema that was being accessed.
  final String schemaName;

  const GSettingsSchemaNotInstalledException(this.schemaName);

  @override
  String toString() => 'GSettings schema $schemaName not installed';
}

/// Exception thrown when trying to access a key not in a GSettings schema.
class GSettingsUnknownKeyException implements Exception {
  /// The name of the GSettings schema that was being accessed.
  final String schemaName;

  /// The name of the key being accessed.
  final String keyName;

  const GSettingsUnknownKeyException(this.schemaName, this.keyName);

  @override
  String toString() => 'Key $keyName not in GSettings schema $schemaName';
}

class _GSettingsSchemaEntry {
  final DBusValue defaultValue;
  final List<int>? words;
  final DBusValue? minimumValue;
  final DBusValue? maximumValue;
  final Map<String, DBusValue>? desktopOverrides;

  const _GSettingsSchemaEntry(
      {required this.defaultValue,
      this.words,
      this.minimumValue,
      this.maximumValue,
      this.desktopOverrides});

  @override
  String toString() =>
      '$runtimeType(defaultValue: $defaultValue, words: $words, minimumValue: $minimumValue, maximumValue: $maximumValue, desktopOverrides: $desktopOverrides)';
}
