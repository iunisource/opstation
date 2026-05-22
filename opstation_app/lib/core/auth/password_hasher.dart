import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Utility for hashing and verifying passwords.
///
/// This is **local-device** auth. A real backend slice will replace this
/// with proper server-side verification (bcrypt/argon2 or an identity
/// provider). For now: SHA-256(salt + password) hex-encoded, with a
/// random 16-byte salt per user.
class PasswordHasher {
  static final _rng = Random.secure();

  /// Generate a new random 16-byte salt, hex-encoded.
  static String newSalt() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return _toHex(bytes);
  }

  /// Hash `password` with the given `salt`. Both are combined as
  /// UTF-8 bytes: salt || password.
  static String hash(String password, String salt) {
    final bytes = utf8.encode(salt + password);
    return sha256.convert(bytes).toString();
  }

  /// Returns true if `candidate` matches the stored [hash] for [salt].
  static bool verify(String candidate, String salt, String expectedHash) {
    return hash(candidate, salt) == expectedHash;
  }

  static String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
