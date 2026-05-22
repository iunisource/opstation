import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Mirrors the mobile app's PasswordHasher exactly so users created on
/// web can authenticate via mobile and vice versa. Algorithm:
///   - salt: 16 random bytes, hex-encoded (32 hex chars)
///   - hash: sha256(utf8(salt + password)), hex-encoded
///
/// This is local-device auth. A real backend slice would replace it
/// with bcrypt/argon2 or an identity provider.
class PasswordHasher {
  static final _rng = Random.secure();

  /// Generate a new random 16-byte salt, hex-encoded.
  static String newSalt() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return _toHex(bytes);
  }

  /// Hash [password] with the given [salt]. Bytes are concatenated
  /// salt + password as UTF-8 before hashing.
  static String hash(String password, String salt) {
    final bytes = utf8.encode(salt + password);
    return sha256.convert(bytes).toString();
  }

  /// Returns true if [candidate] hashes to [expectedHash] under [salt].
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
