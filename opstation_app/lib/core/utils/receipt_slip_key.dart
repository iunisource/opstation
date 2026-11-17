/// Receipt slips with a letter series (SQL 487): a book "B" 1201–1300 has
/// slips B1201 … B1300. A slip is kept as ONE int key so the existing number
/// logic (sets, gaps, sorting) keeps working: key = letterCode × 10^10 + number.
/// Plain numbers (no letter) keep key == number, exactly as before.
///
/// Letters count only when they are a letter of an issued book ([known]), so
/// stray text in old CR#s ("CR# 391") is read as before.
const int slipBase = 10000000000; // 10^10

int slipLetterCode(String? letters) {
  final p = (letters ?? '').toUpperCase();
  if (p.isEmpty || p.length > 3 || !RegExp(r'^[A-Z]+$').hasMatch(p)) return 0;
  var c = 0;
  for (final u in p.codeUnits) {
    c = c * 27 + (u - 64);
  }
  return c;
}

String slipLetters(int code) {
  if (code <= 0) return '';
  final out = <String>[];
  var c = code;
  while (c > 0) {
    out.insert(0, String.fromCharCode(64 + c % 27));
    c ~/= 27;
  }
  return out.join();
}

int slipKey(String? letters, int n) => slipLetterCode(letters) * slipBase + n;
int slipNumber(int key) => key % slipBase;
String slipPrefixOf(int key) => slipLetters(key ~/ slipBase);

/// "B1250" for a lettered slip, "1250" for a plain one.
String slipLabel(int key) => '${slipPrefixOf(key)}${slipNumber(key)}';

/// Every slip on a CR# as keys — "B1250 & 51" → B1250, B1251; "32282 83 84"
/// → 32282, 32283, 32284. [known] = upper-case letters of issued books.
List<int> slipKeys(String raw, Set<String> known) {
  final out = <int>[];
  int? prev;
  String? prevPre;
  for (final m in RegExp(r'(?:([A-Za-z]+)[ \-]?)?(\d+)').allMatches(raw)) {
    final letters = m.group(1)?.toUpperCase();
    final t = m.group(2)!;
    if (t.length > 15) continue;
    String? pre = (letters != null && known.contains(letters)) ? letters : null;
    if (letters == null) pre = prevPre; // "B1250 & 51": 51 is B1251
    final int n;
    if (prev == null || t.length >= prev.toString().length) {
      n = int.parse(t);
    } else {
      var p10 = 1;
      for (var i = 0; i < t.length; i++) {
        p10 *= 10;
      }
      n = (prev - (prev % p10)) + int.parse(t);
    }
    out.add(slipKey(pre, n));
    prev = n;
    prevPre = pre;
  }
  return out;
}
