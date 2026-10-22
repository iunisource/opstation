import 'dart:math';

final _rnd = Random();
int _seq = 0;

/// A row id that can't collide, even for two rows created in the same
/// millisecond (on the web DateTime.now() only has millisecond precision, so
/// "prefix_<microseconds>" repeats when two audit entries fire back to back).
String uniqueId(String prefix) {
  _seq = (_seq + 1) % 1000000;
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_seq.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';
}
