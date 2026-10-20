import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flclashx/common/common.dart';

class CoreUpdater {
  factory CoreUpdater() {
    _instance ??= CoreUpdater._internal();
    return _instance!;
  }

  CoreUpdater._internal();

  static CoreUpdater? _instance;

  String? _cachedHash;
  DateTime? _cachedMtime;
  int? _cachedSize;

  /// SHA-256 of the core binary currently on disk. Cached by mtime+size so
  /// repeated helper pings don't rehash the file.
  Future<String?> calcCoreSha256() async {
    try {
      final file = File(appPath.corePath);
      final stat = await file.stat();
      if (_cachedHash != null &&
          stat.modified == _cachedMtime &&
          stat.size == _cachedSize) {
        return _cachedHash;
      }
      final digest = await sha256.bind(file.openRead()).first;
      _cachedMtime = stat.modified;
      _cachedSize = stat.size;
      _cachedHash = digest.toString();
      return _cachedHash;
    } catch (e) {
      commonPrint.log("calcCoreSha256 failed: $e");
      return null;
    }
  }

  /// The helper service only launches a core whose SHA-256 matches its
  /// allow-list; keep that list in sync with the binary on disk. A plain write
  /// covers per-user installs; Program Files needs one UAC prompt.
  Future<void> syncHelperAllowedHash() async {
    final hash = await calcCoreSha256();
    if (hash == null) {
      return;
    }
    final path = appPath.allowedCoreHashPath;
    try {
      await File(path).writeAsString(hash, flush: true);
      commonPrint.log("helper allowed-hash updated");
    } catch (_) {
      final ok = windows?.runas("cmd.exe", '/c echo $hash> "$path"') ?? false;
      commonPrint.log("helper allowed-hash elevated write: $ok");
    }
  }

}

final coreUpdater = CoreUpdater();
