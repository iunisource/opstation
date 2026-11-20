import 'receipt_fix.dart';
import '../../../core/utils/receipt_book_rules.dart';
import 'package:flutter/material.dart';
import '../../../core/utils/receipt_slip_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart' show receiptSlipPendingProvider;
import '../../../core/format/time_format.dart';

/// Reports → Receipt Books (SQL 411).
///
/// Each salesperson is issued the serial range of a physical CR book. With
/// Admin Settings → "Receipt books" ON the app accepts only unused slips from
/// the person's own open book. Here: issue / close / reopen / remove books,
/// cancel spoiled slips, and see per book what is used, cancelled and unused,
/// with flags for skipped, repeated, out-of-order and someone else's slips —
/// plus collections whose CR# is not from any book.
class ErpReceiptBooksScreen extends ConsumerStatefulWidget {
  const ErpReceiptBooksScreen({super.key});
  @override
  ConsumerState<ErpReceiptBooksScreen> createState() => _State();
}

class _Book {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> used;      // {serial, user_id, user_name, at, amount, …}
  final List<Map<String, dynamic>> cancelled; // {id, serial, reason, by, at}
  _Book(this.row, this.used, this.cancelled);

  /// "Mark as checked" rows for this book (SQL 458): {id, serial, kind, note, checked_by_name, checked_at}.
  List<Map<String, dynamic>> checks = const [];
  Map<String, dynamic>? checkOf(String kind, int n) {
    for (final c in checks) {
      if (c['kind'] == kind && (c['serial'] as num).toInt() == n) return c;
    }
    return null;
  }

  String get id => row['id'] as String;
  int get start => (row['start_no'] as num).toInt();
  int get end => (row['end_no'] as num).toInt();
  /// The book's letter (SQL 487), e.g. "B" → slips B1201…; null = plain numbers.
  String? get prefix {
    final p = '${row['prefix'] ?? ''}'.trim().toUpperCase();
    return p.isEmpty ? null : p;
  }
  String fmt(int n) => '${prefix ?? ''}$n';
  String get range => '${fmt(start)}–${fmt(end)}';
  /// A slip key (receipt_slip_key.dart) of this book?
  bool holds(int key) => slipPrefixOf(key) == (prefix ?? '') && slipNumber(key) >= start && slipNumber(key) <= end;
  int get size => end - start + 1;
  bool get open => row['status'] == 'open';
  String get holderId => '${row['user_id'] ?? ''}';
  String get holder => '${row['user_name'] ?? ''}';

  late final Set<int> usedSet = {for (final u in used) (u['serial'] as num).toInt()};
  late final Map<int, Map<String, dynamic>> cancelMap = {
    for (final c in cancelled) (c['serial'] as num).toInt(): c,
  };
  /// Slips cleared with a reason: used, but could not be recorded under their number
  /// (kind 'unrecorded' in receipt_slip_checks). Accounted for — not missing, not cancelled.
  Set<int> get manual => {for (final c in checks) if (c['kind'] == 'unrecorded') (c['serial'] as num).toInt()};
  int get manualCount => manual.where((n) => !usedSet.contains(n) && !cancelMap.containsKey(n)).length;
  int get unused => size - usedSet.length - cancelMap.keys.where((n) => !usedSet.contains(n)).length - manualCount;
  int? get highestUsed => usedSet.isEmpty ? null : usedSet.reduce((a, b) => a > b ? a : b);

  /// Not used and not cancelled, below the highest used slip.
  List<int> get skipped {
    final hi = highestUsed;
    if (hi == null || !open) return <int>[]; // a closed book lists them under "Missing at close"
    final m = manual;
    return [for (var n = start; n < hi; n++) if (!usedSet.contains(n) && !cancelMap.containsKey(n) && !m.contains(n)) n];
  }

  /// Unused slips of a CLOSED book are missing too.
  List<int> get missingAtClose {
    if (open) return <int>[];
    return unaccountedSlips(start, end, usedSet, {...cancelMap.keys, ...manual});
  }

  late final List<int> repeated = () {
    final c = <int, int>{};
    for (final u in used) {
      final n = (u['serial'] as num).toInt();
      c[n] = (c[n] ?? 0) + 1;
    }
    return (c.entries.where((e) => e.value > 1).map((e) => e.key).toList()..sort());
  }();

  // Only the holder's own slips decide the order (see receipt_book_rules.dart).
  late final List<int> outOfOrder = outOfOrderSerials(used, holderId);

  /// Slips of this book written by someone other than the holder.
  late final List<Map<String, dynamic>> byOthers =
      used.where((u) => '${u['user_id'] ?? ''}' != holderId).toList();

  /// Flagged slips still to look at (not marked as checked).
  List<int> get openRepeated => [for (final n in repeated) if (checkOf('repeated', n) == null) n];
  List<int> get openOutOfOrder => [for (final n in outOfOrder) if (checkOf('out_of_order', n) == null) n];
  List<Map<String, dynamic>> get checkedRows => [
        for (final c in checks)
          if (c['kind'] == 'unrecorded' ||
              (c['kind'] == 'repeated' && repeated.contains((c['serial'] as num).toInt())) ||
              (c['kind'] == 'out_of_order' && outOfOrder.contains((c['serial'] as num).toInt())))
            c
      ];

  int get issues => skipped.length + missingAtClose.length + openRepeated.length + openOutOfOrder.length + byOthers.length;
}

/// One kind of issue in one book, as the "Resolve issues" dialog shows it.
class _Group {
  _Group(this.book, this.kind, this.title, this.slips, this.actions) : picked = {...slips};
  final _Book book;
  final String kind; // missing | skipped | repeated | ooo
  final String title;
  final List<int> slips;
  final List<(String, String)> actions; // (code, label)
  String action = 'leave';
  Set<int> picked;
}

class _State extends ConsumerState<ErpReceiptBooksScreen> {
  SupabaseClient get _db => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  final _df = DateFormat('d MMM yyyy');

  bool _loading = true;
  String? _error;
  bool _flowOn = false;
  bool _canIssue = false;
  List<_Book> _books = [];
  List<Map<String, dynamic>> _team = [];
  // Collections whose CR# is from no book (holders of books, since their first book).
  List<Map<String, dynamic>> _outside = [];
  bool _isAdmin = false; // admins / master admins can correct or release a CR# (SQL 479)
  Map<String, Map<String, dynamic>> _released = {}; // "visitId|serial" → release (SQL 482)
  String _status = 'open'; // open | closed | all
  bool _byRep = false; // list the books under each salesperson
  String _query = '';
  bool _busy = false;
  final Map<String, String> _custNames = {}; // customer id -> shop name (for slip details)

  /// Shop names for the given customer ids (fetched once, in small batches).
  Future<void> _ensureCustNames(Iterable<dynamic> ids) async {
    final want = {for (final i in ids) if (i != null && '$i'.isNotEmpty && !_custNames.containsKey('$i')) '$i'}.toList();
    for (var i = 0; i < want.length; i += 100) {
      try {
        final rows = await _db.from('customers').select('id, shop_name')
            .inFilter('id', want.sublist(i, i + 100 > want.length ? want.length : i + 100));
        for (final r in rows as List) {
          _custNames['${r['id']}'] = '${r['shop_name'] ?? ''}';
        }
      } catch (_) {}
    }
  }

  String _shopOf(Map<String, dynamic> u) => _custNames['${u['customer_id'] ?? ''}'] ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final me = ref.read(currentUserProvider);
      final cfg = await _db.from('app_config').select('key, value').eq('org_id', orgId)
          .inFilter('key', ['org.receipt_books_flow', 'org.receipt_book_issuer_users']);
      var on = false;
      var issuers = <String>{};
      for (final c in cfg as List) {
        if (c['key'] == 'org.receipt_books_flow') on = '${c['value']}' == 'true';
        if (c['key'] == 'org.receipt_book_issuer_users') {
          issuers = '${c['value'] ?? ''}'.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
        }
      }
      final isAdmin = me?.role == WebUserRole.superAdmin || me?.role == WebUserRole.masterAdmin || me?.role == WebUserRole.admin;

      final res = await _db.rpc('receipt_books_status', params: {'p_org': orgId});
      final books = <_Book>[
        for (final r in res as List)
          _Book(Map<String, dynamic>.from(r as Map),
              List<Map<String, dynamic>>.from((r['used'] as List?) ?? const []),
              List<Map<String, dynamic>>.from((r['cancelled'] as List?) ?? const [])),
      ];
      final team = List<Map<String, dynamic>>.from(await _db.from('users')
          .select('id, name, role, is_active').eq('org_id', orgId)
          .or('role.is.null,role.neq.retailer').order('name') as List)
          .where((u) => u['is_active'] != false).toList();

      // Collections not from any book, by people who hold (or held) a book.
      final outside = <Map<String, dynamic>>[];
      final letters = {for (final b in books) if (b.prefix != null) b.prefix!};
      if (books.isNotEmpty) {
        final holders = {for (final b in books) b.holderId}.toList();
        DateTime first = DateTime.now();
        for (final b in books) {
          final t = DateTime.tryParse('${b.row['issued_at']}');
          if (t != null && t.isBefore(first)) first = t;
        }
        for (var f = 0;; f += 1000) {
          final page = List<Map<String, dynamic>>.from(await _db.from('visits')
              .select('id, user_id, user_name, receipt_number, amount, timestamp, customers(shop_name)')
              .eq('org_id', orgId).inFilter('user_id', holders)
              .gt('amount', 0).gte('timestamp', first.toUtc().toIso8601String())
              .order('timestamp').range(f, f + 999) as List);
          for (final v in page) {
            final slips = slipKeys('${v['receipt_number'] ?? ''}', letters);
            final bad = [for (final k in slips) if (!books.any((b) => b.holds(k))) slipNumber(k)];
            if (slips.isEmpty || bad.isNotEmpty) outside.add({...v, 'bad': bad});
          }
          if (page.length < 1000 || f > 100000) break;
        }
      }
      // Slips already marked as checked (SQL 458; missing table = none yet).
      try {
        final rows = List<Map<String, dynamic>>.from(await _db.from('receipt_slip_checks')
            .select('id, book_id, serial, kind, note, checked_by_name, checked_at').eq('org_id', orgId) as List);
        for (final b in books) {
          b.checks = [for (final r in rows) if (r['book_id'] == b.id) r];
        }
      } catch (_) {}
      final released = await loadSlipReleases(orgId);
      if (!mounted) return;
      setState(() {
        _released = released;
        _flowOn = on;
        _canIssue = isAdmin || (me != null && issuers.contains(me.id));
        _isAdmin = isAdmin;
        _books = books;
        _team = team;
        _outside = outside;
        _loading = false;
      });
      ref.invalidate(receiptSlipPendingProvider); // keep the menu counter in step
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError('Could not load receipt books', e); _loading = false; });
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(String done, Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      _snack(done);
      await _load();
      ref.invalidate(receiptSlipPendingProvider); // menu counter
    } catch (e) {
      _snack(friendlyError('Could not save', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _issue() async {
    String? userId;
    final fromCtrl = TextEditingController();
    final toCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final prefixCtrl = TextEditingController();
    String? err;
    // Suggest the next range after the highest book issued.
    final hi = _books.isEmpty ? null : _books.map((b) => b.end).reduce((a, b) => a > b ? a : b);
    if (hi != null) {
      fromCtrl.text = '${hi + 1}';
      toCtrl.text = '${hi + 50}';
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final a = int.tryParse(fromCtrl.text.trim()), b = int.tryParse(toCtrl.text.trim());
        final count = (a != null && b != null && b >= a) ? b - a + 1 : null;
        final pre = prefixCtrl.text.trim().toUpperCase();
        return AlertDialog(
          title: const Text('Issue a receipt book'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Searchable person picker.
              InkWell(
                onTap: () async {
                  final picked = await _pickPerson(ctx);
                  if (picked != null) setLocal(() { userId = picked; err = null; });
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                      labelText: 'Issue to', suffixIcon: Icon(Icons.search, size: 18)),
                  child: Text(
                    userId == null
                        ? 'Search and pick a person…'
                        : '${_team.firstWhere((u) => u['id'] == userId, orElse: () => const {})['name'] ?? ''}',
                    style: TextStyle(color: userId == null ? AppTheme.textSecondary : null),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (userId != null && _books.where((x) => x.open && x.holderId == userId).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Open now: ${_books.where((x) => x.open && x.holderId == userId).map((x) => x.range).join(', ')}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              const SizedBox(height: 10),
              Row(children: [
                SizedBox(width: 90, child: TextField(
                  controller: prefixCtrl,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z]')),
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: const InputDecoration(labelText: 'Letter', hintText: 'e.g. B'),
                  onChanged: (_) => setLocal(() {}),
                )),
                const SizedBox(width: 12),
                Expanded(child: TextField(
                  controller: fromCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'First slip #'),
                  onChanged: (_) => setLocal(() {}),
                )),
                const SizedBox(width: 12),
                Expanded(child: TextField(
                  controller: toCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Last slip #'),
                  onChanged: (_) => setLocal(() {}),
                )),
              ]),
              if (count != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      '$count slips${pre.isEmpty ? '' : ' · $pre$a – $pre$b'}'
                      '${pre.isEmpty ? ' · leave Letter empty when the slips have only numbers' : ''}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(labelText: 'Book number', hintText: 'As printed on the book, e.g. 12'),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (userId == null) return setLocal(() => err = 'Pick who the book is issued to.');
                if (a == null || b == null) return setLocal(() => err = 'Enter the first and last slip numbers.');
                if (b < a) return setLocal(() => err = 'The last slip must be after the first.');
                if (b - a >= 1000) return setLocal(() => err = 'A book can have up to 1000 slips.');
                // Same serials can never be issued twice (any book, open or closed).
                // (Under another letter the same numbers are a different series.)
                for (final x in _books) {
                  if ((x.prefix ?? '') == pre && x.start <= b && x.end >= a) {
                    return setLocal(() => err = 'Serials ${x.range} are already issued to '
                        '${x.holder}${x.open ? '' : ' (closed book)'}. Each serial can be issued only once.');
                  }
                }
                // A book number belongs to one person.
                final lbl = labelCtrl.text.trim().toLowerCase();
                if (lbl.isEmpty) return setLocal(() => err = 'Enter the book number.');
                {
                  for (final x in _books) {
                    if ('${x.row['label'] ?? ''}'.trim().toLowerCase() == lbl) {
                      return setLocal(() => err = 'Book "${labelCtrl.text.trim()}" is already issued to '
                          '${x.holder}${x.open ? '' : ' (closed book)'}.');
                    }
                  }
                }
                if (_books.where((x) => x.open && x.holderId == userId).length >= 2) {
                  return setLocal(() => err = 'This person already has 2 open books. Close one first.');
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Issue'),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    await _run('Book issued', () async {
      await _db.rpc('receipt_book_issue', params: {
        'p_org': _orgId, 'p_user': userId, 'p_start': int.parse(fromCtrl.text.trim()),
        'p_end': int.parse(toCtrl.text.trim()), 'p_label': labelCtrl.text.trim(),
        if (prefixCtrl.text.trim().isNotEmpty) 'p_prefix': prefixCtrl.text.trim().toUpperCase(),
      });
    });
  }

  /// Search the team by name / role and pick one.
  Future<String?> _pickPerson(BuildContext context) {
    var q = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final qq = q.trim().toLowerCase();
        final list = qq.isEmpty
            ? _team
            : _team.where((u) => matchesQuery('${u['name'] ?? ''} ${u['role'] ?? ''}', qq)).toList();
        return AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
          title: const Text('Issue to', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 420,
            height: 460,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Search name…',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) => setLocal(() => q = v),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('No one matches.', style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final u = list[i];
                          final open = _books.where((x) => x.open && x.holderId == u['id']).toList();
                          return ListTile(
                            dense: true,
                            title: Text('${u['name'] ?? ''}'),
                            subtitle: Text([
                              if ('${u['role'] ?? ''}'.isNotEmpty) '${u['role']}',
                              if (open.isNotEmpty) 'Open: ${open.map((x) => x.range).join(', ')}',
                            ].join(' · '), style: const TextStyle(fontSize: 11.5)),
                            onTap: () => Navigator.pop(ctx, u['id'] as String),
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      }),
    );
  }

  Future<String?> _askText(String title, String label, {String? hint, bool required = false, String? body}) async {
    final c = TextEditingController();
    String? err;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (body != null) Text(body, style: const TextStyle(fontSize: 13)),
            TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label, hintText: hint)),
            if (err != null)
              Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (required && c.text.trim().isEmpty) return setLocal(() => err = 'This is required.');
              Navigator.pop(ctx, c.text.trim());
            },
            child: const Text('OK'),
          ),
        ],
      )),
    );
  }

  Future<void> _cancelSlip(_Book b) async {
    final serialTxt = await _askText('Cancel a slip — ${b.range}', 'Slip number', required: true);
    if (serialTxt == null) return;
    // The book's letter may be typed or left out.
    final n = int.tryParse(RegExp(r'\d+').firstMatch(serialTxt)?.group(0) ?? '');
    if (n == null || n < b.start || n > b.end) {
      _snack('Slip $serialTxt is not in this book (${b.range}).');
      return;
    }
    final reason = await _askText('Cancel slip ${b.fmt(n)}', 'Reason', hint: 'e.g. slip torn', required: true);
    if (reason == null) return;
    await _run('Slip ${b.fmt(n)} cancelled', () async {
      await _db.rpc('receipt_slip_cancel', params: {'p_book': b.id, 'p_serial': n, 'p_reason': reason});
    });
  }

  /// Close dialog: a note, and — when slips are still unused — a tick box to
  /// account for them as "Returned blank" (cancelled) instead of leaving them
  /// to show as missing.
  Future<({String note, bool blank})?> _askClose(_Book b) async {
    final c = TextEditingController();
    final blankSlips = unaccountedSlips(b.start, b.end, b.usedSet, b.cancelMap.keys.toSet());
    var blank = false;
    return showDialog<({String note, bool blank})>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: Text('Close book ${b.range}?'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Note (optional)')),
            if (blankSlips.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('${blankSlips.length} slip${blankSlips.length == 1 ? ' is' : 's are'} not used yet.',
                  style: const TextStyle(fontSize: 13)),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: blank,
                onChanged: (v) => setLocal(() => blank = v ?? false),
                title: Text(
                    'They came back blank — mark ${blankSlips.length == 1 ? 'it' : 'all ${blankSlips.length}'} as returned blank',
                    style: const TextStyle(fontSize: 13)),
                subtitle: const Text('Leave unticked if slips are really missing: they will show as missing.',
                    style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, (note: c.text.trim(), blank: blank)), child: const Text('Close book')),
        ],
      )),
    );
  }

  /// Clear ONE unused slip with a reason: it WAS used but could not be recorded
  /// under its number (for example the app refused the number, so the collection
  /// went in under another). It is kept as "used manually" with the reason and
  /// the person who cleared it — not cancelled. Works on open and closed books.
  Future<void> _clearUnusedSlip(_Book b, int n) async {
    final reason = await _askText('Clear slip ${b.fmt(n)}', 'Reason',
        hint: 'e.g. Used manually — the app refused this number; entered as A138',
        required: true,
        body: 'Use this when the slip WAS used but is not recorded under this number. '
            'It is kept as used manually, with your reason — it is not cancelled.\n');
    if (reason == null) return;
    await _run('Slip ${b.fmt(n)} cleared', () async {
      await _db.rpc('receipt_slip_clear', params: {
        'p_book': b.id,
        'p_serial': n,
        'p_reason': reason,
        'p_by': ref.read(currentUserProvider)?.name,
      });
    });
  }

  /// Cancel ONE unused slip from its own dialog — also in a CLOSED book (the book
  /// menu offers "Cancel a slip" only while a book is open). If the server will
  /// not cancel in a closed book, the book is reopened for a moment, the slip
  /// cancelled and the book closed again; the close note keeps who closed it
  /// first and when.
  Future<void> _cancelUnusedSlip(_Book b, int n) async {
    final reason = await _askText('Cancel slip ${b.fmt(n)}', 'Reason',
        hint: 'e.g. torn, voided, returned blank',
        required: true,
        body: b.open ? null : 'This book is closed. If needed it is reopened for a moment and closed again.\n');
    if (reason == null) return;
    await _run('Slip ${b.fmt(n)} cancelled', () async {
      Future<void> cancel() => _db.rpc('receipt_slip_cancel', params: {'p_book': b.id, 'p_serial': n, 'p_reason': reason});
      if (b.open) {
        await cancel();
        return;
      }
      try {
        await cancel(); // the server may allow it on a closed book
        return;
      } catch (e) {
        final msg = '$e'.toLowerCase();
        if (!(msg.contains('clos') || msg.contains('open'))) rethrow; // some other problem
      }
      final oldNote = '${b.row['close_note'] ?? ''}'.trim();
      final who = '${b.row['closed_by_name'] ?? '—'}';
      final when = _fmt(b.row['closed_at']);
      await _db.rpc('receipt_book_reopen', params: {'p_id': b.id});
      try {
        await cancel();
      } finally {
        final note = [
          if (oldNote.isNotEmpty) oldNote,
          '(first closed by $who, $when; closed again after slip ${b.fmt(n)} was cancelled)'
        ].join(' ');
        await _db.rpc('receipt_book_close', params: {'p_id': b.id, 'p_note': note});
      }
    });
  }

  Future<void> _bookAction(_Book b, String a) async {
    switch (a) {
      case 'cancel':
        return _cancelSlip(b);
      case 'close':
        final r = await _askClose(b);
        if (r == null) return;
        return _run('Book closed', () async {
          if (r.blank) {
            for (final n in unaccountedSlips(b.start, b.end, b.usedSet, b.cancelMap.keys.toSet())) {
              await _db.rpc('receipt_slip_cancel', params: {'p_book': b.id, 'p_serial': n, 'p_reason': 'Returned blank'});
            }
          }
          await _db.rpc('receipt_book_close', params: {'p_id': b.id, 'p_note': r.note});
        });
      case 'reopen':
        return _run('Book reopened', () async {
          await _db.rpc('receipt_book_reopen', params: {'p_id': b.id});
        });
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Remove book ${b.range}?'),
            content: const Text('Only for a book issued by mistake. None of its slips is used yet.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        return _run('Book removed', () async {
          await _db.rpc('receipt_book_delete', params: {'p_id': b.id});
        });
    }
  }

  Future<void> _slipTap(_Book b, int n) async {
    final c = b.cancelMap[n];
    final manualRow = b.checkOf('unrecorded', n);
    final uses = b.used.where((u) => (u['serial'] as num).toInt() == n).toList();
    await _ensureCustNames(uses.map((u) => u['customer_id']));
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Slip ${b.fmt(n)}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (c != null) ...[
              const Text('Cancelled', style: TextStyle(fontWeight: FontWeight.w800)),
              Text('${c['reason'] ?? ''}'),
              Text('By ${c['by'] ?? '—'} · ${_fmt(c['at'])}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Text(c['reviewed_at'] == null
                      ? 'Not reviewed yet'
                      : 'Reviewed by ${c['reviewed_by'] ?? '—'} · ${_fmt(c['reviewed_at'])}'
                          '${'${c['review_note'] ?? ''}'.isEmpty ? '' : ' — ${c['review_note']}'}',
                  style: TextStyle(fontSize: 12, color: c['reviewed_at'] == null ? Colors.orange.shade800 : AppTheme.success)),
            ] else if (manualRow != null && uses.isEmpty) ...[
              const Text('Used manually — not recorded under this number', style: TextStyle(fontWeight: FontWeight.w800)),
              Text('${manualRow['note'] ?? ''}'),
              Text('By ${manualRow['checked_by_name'] ?? '—'} · ${_fmt(manualRow['checked_at'])}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ] else if (uses.isEmpty && !_released.values.any((r) => '${r['serial']}' == '$n'))
              const Text('Not used yet.')
            else
              for (final u in uses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_shopOf(u).isEmpty ? '—' : _shopOf(u), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('Rs ${money((u['amount'] as num?) ?? 0)} · ${u['user_name'] ?? ''} · ${_fmt(u['at'])}',
                        style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                  ]),
                ),
            for (final r in _released.values.where((r) => '${r['serial']}' == '$n'))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lock_open, size: 16, color: Color(0xFF047857)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'An earlier use was released for re-use by ${r['by_name'] ?? 'admin'} · ${_fmt(r['at'])} — ${r['reason'] ?? ''}. '
                        'That entry keeps its CR# (search the number to see it).',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF047857))),
                  ),
                  if (_isAdmin)
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _run('Release undone', () async {
                          await _db.rpc('receipt_slip_unrelease', params: {'p_id': r['id']});
                        });
                      },
                      child: const Text('Undo'),
                    ),
                ]),
              ),
          ]),
        ),
        actions: [
          if (c == null && uses.isNotEmpty && _isAdmin)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final org = ref.read(currentUserProvider)?.orgId;
                if (org != null && await receiptFixForSerial(context, org, n, letters: b.prefix ?? '')) _load();
              },
              child: const Text('Correct / release CR#'),
            ),
          if (c == null && uses.isEmpty && manualRow == null && _canIssue)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _clearUnusedSlip(b, n);
              },
              child: const Text('Clear with a reason…'),
            ),
          if (c == null && uses.isEmpty && manualRow == null && _canIssue)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _cancelUnusedSlip(b, n);
              },
              child: const Text('Cancel this slip…'),
            ),
          if (manualRow != null && uses.isEmpty && _canIssue)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _run('Slip ${b.fmt(n)} is open again', () async {
                  await _db.rpc('receipt_slip_uncheck', params: {'p_id': manualRow['id']});
                });
              },
              child: const Text('Undo'),
            ),
          if (c != null && _canIssue)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _run('Slip ${b.fmt(n)} is usable again', () async {
                  await _db.rpc('receipt_slip_uncancel', params: {'p_id': c['id']});
                });
              },
              child: const Text('Undo cancel'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  String _fmt(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}');
    return t == null ? '' : DateFormat(orgTime('d MMM yyyy, h:mm a')).format(t.toLocal());
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final list = _books.where((b) {
      if (_status == 'open' && !b.open) return false;
      if (_status == 'closed' && b.open) return false;
      if (q.isNotEmpty && !matchesQuery('${b.holder} ${b.start} ${b.end} ${b.fmt(b.start)} ${b.row['label'] ?? ''}', q)) return false;
      return true;
    }).toList();
    final issuesTotal = _books.fold<int>(0, (s, b) => s + b.issues) + _outside.length;
    return Container(
      color: AppTheme.background,
      padding: context.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
          const Text('Receipt Books', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
          if (_canIssue)
            ElevatedButton.icon(
              onPressed: _busy || _loading ? null : _issue,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Issue book'),
            ),
        ]),
        const Text('Physical CR books issued to each salesperson, with every slip accounted for.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        if (!_loading && !_flowOn)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: const Text('Receipt books are switched off in Admin Settings, so the app does not check '
                'CR numbers against these books yet. You can still issue books now.',
                style: TextStyle(fontSize: 12.5)),
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final s in const ['open', 'closed', 'all'])
            ChoiceChip(
              label: Text(s == 'open'
                  ? 'Open (${_books.where((b) => b.open).length})'
                  : s == 'closed' ? 'Closed (${_books.where((b) => !b.open).length})' : 'All'),
              selected: _status == s,
              onSelected: (_) => setState(() => _status = s),
            ),
          FilterChip(
            avatar: const Icon(Icons.person_outline, size: 16),
            label: const Text('By salesperson'),
            selected: _byRep,
            onSelected: (v) => setState(() {
              _byRep = v;
              if (v) _status = 'all'; // closed books carry most issues: show them too
            }),
          ),
          SizedBox(
            width: context.isMobile ? double.infinity : 280,
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Search salesperson or slip…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (!_loading && issuesTotal > 0)
            Text('$issuesTotal issue${issuesTotal == 1 ? '' : 's'} to check',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Colors.deepOrange)),
        ]),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : ListView(children: [
                      if (_pendingCancels.isNotEmpty) _reviewCard(),
                      if (_outside.isNotEmpty) _outsideCard(),
                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(40),
                          child: Center(child: Text(
                              _books.isEmpty ? 'No receipt books issued yet.' : 'No books here.',
                              style: const TextStyle(color: AppTheme.textSecondary))),
                        ),
                      if (_byRep) ..._repGroups(list) else for (final b in list) _bookCard(b),
                    ]),
        ),
      ]),
    );
  }

  // ── By salesperson ─────────────────────────────────────────────────────────

  /// The books grouped under each salesperson, most issues first.
  List<Widget> _repGroups(List<_Book> list) {
    final by = <String, List<_Book>>{};
    for (final b in list) {
      (by[b.holderId.isEmpty ? b.holder : b.holderId] ??= []).add(b);
    }
    final reps = by.values.toList()
      ..sort((a, b) {
        final ia = a.fold<int>(0, (s, x) => s + x.issues), ib = b.fold<int>(0, (s, x) => s + x.issues);
        return ib != ia ? ib.compareTo(ia) : a.first.holder.compareTo(b.first.holder);
      });
    return [for (final books in reps) _repCard(books)];
  }

  Widget _repCard(List<_Book> books) {
    final name = books.first.holder.isEmpty ? '—' : books.first.holder;
    final issues = books.fold<int>(0, (s, b) => s + b.issues);
    final open = books.where((b) => b.open).length;
    final sorted = [...books]
      ..sort((a, b) {
        if (a.open != b.open) return a.open ? -1 : 1;
        return '${b.row['issued_at']}'.compareTo('${a.row['issued_at']}');
      });
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: issues > 0 ? Colors.deepOrange.withOpacity(0.5) : AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          title: Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
            Text('${books.length} book${books.length == 1 ? '' : 's'} · $open open',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            if (issues > 0) _tag('$issues to check', Colors.deepOrange),
            if (issues > 0 && _canIssue)
              TextButton.icon(
                onPressed: _busy ? null : () => _resolveRep(name, sorted),
                icon: const Icon(Icons.task_alt, size: 16),
                label: const Text('Resolve issues…'),
              ),
          ]),
          children: [for (final b in sorted) _bookCard(b)],
        ),
      ),
    );
  }

  Widget _groupTile(_Group g, StateSetter setD) {
    final active = g.action != 'leave';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${g.title} (${g.slips.length})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          DropdownButton<String>(
            value: g.action,
            isDense: true,
            items: [
              const DropdownMenuItem(value: 'leave', child: Text('Leave as is', style: TextStyle(fontSize: 12.5))),
              for (final a in g.actions) DropdownMenuItem(value: a.$1, child: Text(a.$2, style: const TextStyle(fontSize: 12.5))),
            ],
            onChanged: (v) => setD(() => g.action = v ?? 'leave'),
          ),
        ]),
        if (active) ...[
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final n in g.slips)
              FilterChip(
                label: Text(g.book.fmt(n), style: const TextStyle(fontSize: 11.5)),
                selected: g.picked.contains(n),
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setD(() => v ? g.picked.add(n) : g.picked.remove(n)),
              ),
          ]),
          Row(children: [
            TextButton(onPressed: () => setD(() => g.picked = {...g.slips}), child: const Text('All')),
            TextButton(onPressed: () => setD(() => g.picked = {}), child: const Text('None')),
          ]),
        ],
      ]),
    );
  }

  /// One dialog for ALL of a salesperson's books: for each kind of issue choose what
  /// it is (returned blank / used manually / verified), pick the slips, give one
  /// reason, and apply. Slips left as they are stay flagged.
  Future<void> _resolveRep(String holder, List<_Book> books) async {
    final groups = <_Group>[];
    for (final b in books) {
      if (b.missingAtClose.isNotEmpty) {
        groups.add(_Group(b, 'missing', 'Missing at close', b.missingAtClose,
            const [('blank', 'Came back blank — void them'), ('manual', 'Were used — clear with the reason')]));
      }
      if (b.skipped.isNotEmpty) {
        groups.add(_Group(b, 'skipped', 'Skipped', b.skipped,
            const [('void', 'Voided / torn / blank — cancel them'), ('manual', 'Were used — clear with the reason')]));
      }
      if (b.openRepeated.isNotEmpty) {
        groups.add(_Group(b, 'repeated', 'Used more than once', b.openRepeated, const [('check', 'Verified — mark as checked')]));
      }
      if (b.openOutOfOrder.isNotEmpty) {
        groups.add(_Group(b, 'ooo', 'Out of order', b.openOutOfOrder, const [('check', 'Verified — mark as checked')]));
      }
    }
    if (groups.isEmpty) {
      _snack('Nothing to resolve for $holder.');
      return;
    }
    final noteCtrl = TextEditingController();
    String? err;
    int count() => groups.where((g) => g.action != 'leave').fold<int>(0, (s, g) => s + g.picked.length);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('Resolve issues — $holder'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'For each kind of issue choose what it is. Pick the slips it applies to, write one reason, and apply. '
                  'Anything left as is stays flagged. Slips written by someone else are fixed by correcting the CR# on the collection.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 10),
              for (final b in books)
                if (groups.any((g) => g.book == b)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 6),
                    child: Text('${b.range} · ${b.open ? 'open' : 'closed'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                  ),
                  for (final g in groups.where((g) => g.book == b)) _groupTile(g, setD),
                ],
              const SizedBox(height: 6),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(
                    labelText: 'Reason / what was checked (required)',
                    hintText: 'e.g. Book returned, blank slips seen · Genuine, written out of sequence'),
              ),
              if (err != null)
                Padding(padding: const EdgeInsets.only(top: 8),
                    child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          ElevatedButton(
            onPressed: () {
              if (count() == 0) return setD(() => err = 'Choose what to do for at least one kind of issue, with at least one slip.');
              if (noteCtrl.text.trim().isEmpty) return setD(() => err = 'Write the reason / what was checked.');
              Navigator.pop(ctx, true);
            },
            child: Text('Apply (${count()} slip${count() == 1 ? '' : 's'})'),
          ),
        ],
      )),
    );
    if (ok != true) return;
    await _applyResolve(holder, groups, noteCtrl.text.trim());
  }

  Future<void> _applyResolve(String holder, List<_Group> groups, String note) async {
    setState(() => _busy = true);
    var slips = 0;
    final failed = <String>[];
    final byBook = <_Book, List<_Group>>{};
    for (final g in groups) {
      if (g.action == 'leave' || g.picked.isEmpty) continue;
      (byBook[g.book] ??= []).add(g);
    }
    for (final e in byBook.entries) {
      final b = e.key;
      try {
        // Checks and "used manually" never need the book to be open.
        final checks = <Map<String, dynamic>>[];
        final cancels = <(int, String)>[];
        for (final g in e.value) {
          final picked = g.picked.toList()..sort();
          if (g.action == 'check') {
            for (final n in picked) {
              checks.add({'serial': n, 'kind': g.kind == 'repeated' ? 'repeated' : 'out_of_order'});
            }
          } else if (g.action == 'manual') {
            for (final n in picked) {
              await _db.rpc('receipt_slip_clear', params: {
                'p_book': b.id,
                'p_serial': n,
                'p_reason': note,
                'p_by': ref.read(currentUserProvider)?.name,
              });
              slips++;
            }
          } else if (g.action == 'blank') {
            for (final n in picked) {
              cancels.add((n, 'Returned blank — $note'));
            }
          } else if (g.action == 'void') {
            for (final n in picked) {
              cancels.add((n, note));
            }
          }
        }
        if (checks.isNotEmpty) {
          await _db.rpc('receipt_slip_check', params: {'p_book': b.id, 'p_items': checks, 'p_note': note});
          slips += checks.length;
        }
        if (cancels.isNotEmpty) {
          await _cancelMany(b, cancels);
          slips += cancels.length;
        }
      } catch (err) {
        failed.add('${b.range}: ${friendlyError('failed', err)}');
      }
    }
    await _load();
    ref.invalidate(receiptSlipPendingProvider);
    if (mounted) {
      _snack(failed.isEmpty
          ? 'Resolved $slips slip${slips == 1 ? '' : 's'} for $holder'
          : 'Resolved $slips for $holder, but: ${failed.join(' · ')}');
      setState(() => _busy = false);
    }
  }

  /// Cancel several unused slips of one book. A closed book is reopened for the
  /// cancelling and closed again (the server refuses to cancel in a closed book);
  /// its close note keeps who closed it first and when.
  Future<void> _cancelMany(_Book b, List<(int, String)> items) async {
    Future<void> all() async {
      for (final it in items) {
        await _db.rpc('receipt_slip_cancel', params: {'p_book': b.id, 'p_serial': it.$1, 'p_reason': it.$2});
      }
    }

    if (b.open) return all();
    final oldNote = '${b.row['close_note'] ?? ''}'.trim();
    final who = '${b.row['closed_by_name'] ?? '—'}';
    final when = _fmt(b.row['closed_at']);
    await _db.rpc('receipt_book_reopen', params: {'p_id': b.id});
    try {
      await all();
    } finally {
      final note = [
        if (oldNote.isNotEmpty) oldNote,
        '(first closed by $who, $when; closed again after ${items.length} slip${items.length == 1 ? '' : 's'} were cancelled)'
      ].join(' ');
      await _db.rpc('receipt_book_close', params: {'p_id': b.id, 'p_note': note});
    }
  }

  /// Cancelled slips not reviewed yet: (book, cancel row), newest first.
  List<(_Book, Map<String, dynamic>)> get _pendingCancels {
    final out = <(_Book, Map<String, dynamic>)>[];
    for (final b in _books) {
      for (final c in b.cancelled) {
        if (c['reviewed_at'] == null) out.add((b, c));
      }
    }
    out.sort((a, b) => '${b.$2['at']}'.compareTo('${a.$2['at']}'));
    return out;
  }

  Future<void> _review(List<String> ids) async {
    final note = await _askText(
        ids.length == 1 ? 'Review cancelled slip' : 'Review ${ids.length} cancelled slips',
        'Note (optional)', hint: 'e.g. torn slip seen');
    if (note == null) return;
    await _run(ids.length == 1 ? 'Reviewed' : '${ids.length} reviewed', () async {
      await _db.rpc('receipt_slip_review', params: {'p_ids': ids, 'p_note': note});
    });
  }

  Widget _reviewCard() {
    final list = _pendingCancels;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withOpacity(0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
          const Icon(Icons.rate_review_outlined, color: Colors.orange, size: 20),
          Text('Cancelled slips to review (${list.length})',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          if (list.length > 1)
            TextButton.icon(
              onPressed: _busy ? null : () => _review([for (final e in list) '${e.$2['id']}']),
              icon: const Icon(Icons.done_all, size: 16),
              label: const Text('Review all'),
            ),
        ]),
        const SizedBox(height: 4),
        for (final e in list.take(50))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Slip ${e.$1.fmt((e.$2['serial'] as num).toInt())} · ${e.$1.holder} · book ${e.$1.range}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  Text('${e.$2['reason'] ?? ''} — by ${e.$2['by'] ?? '—'}, ${_fmt(e.$2['at'])}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _review(['${e.$2['id']}']),
                child: const Text('Review'),
              ),
            ]),
          ),
        if (list.length > 50)
          Text('…and ${list.length - 50} more', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ]),
    );
  }

  Widget _outsideCard() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.danger.withOpacity(0.5)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.report_gmailerrorred, color: AppTheme.danger),
          title: Text('${_outside.length} collection${_outside.length == 1 ? '' : 's'} with a CR# from no book',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
          subtitle: const Text('Entered by book holders since their first book. Usually a typo, or slips from a book never issued.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          children: [
            for (final v in _outside)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('CR# ${(v['receipt_number'] ?? '').toString().isEmpty ? '(blank)' : v['receipt_number']} · '
                    'Rs ${money((v['amount'] as num?) ?? 0)}'),
                subtitle: Text('${v['user_name'] ?? ''} · ${(v['customers'] as Map?)?['shop_name'] ?? ''} · ${_fmt(v['timestamp'])}'),
                trailing: _isAdmin && v['id'] != null
                    ? TextButton(
                        onPressed: () async {
                          if (await receiptFixDialog(context, v)) _load();
                        },
                        child: const Text('Correct / release'),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _bookCard(_Book b) {
    final used = b.usedSet.length;
    final cancelled = b.cancelMap.length;
    final pUsed = used / b.size, pCan = cancelled / b.size;
    final label = '${b.row['label'] ?? ''}'.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: b.issues > 0 ? Colors.deepOrange.withOpacity(0.45) : AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(b.range, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            if (label.isNotEmpty) Text(RegExp(r'^\d').hasMatch(label) ? 'Book $label' : label, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            _tag(b.open ? 'Open' : 'Closed', b.open ? AppTheme.success : AppTheme.textSecondary),
            if (b.issues > 0) _tag('${b.issues} to check', Colors.deepOrange),
          ]),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 2),
            Text('${b.holder} · issued ${_fmt(b.row['issued_at'])}${'${b.row['issued_by_name'] ?? ''}'.isEmpty ? '' : ' by ${b.row['issued_by_name']}'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 7,
                child: Row(children: [
                  if (pUsed > 0) Expanded(flex: (pUsed * 1000).round().clamp(1, 1000), child: Container(color: AppTheme.success)),
                  if (pCan > 0) Expanded(flex: (pCan * 1000).round().clamp(1, 1000), child: Container(color: Colors.grey)),
                  if (1 - pUsed - pCan > 0.0005)
                    Expanded(flex: ((1 - pUsed - pCan) * 1000).round().clamp(1, 1000), child: Container(color: AppTheme.border)),
                ]),
              ),
            ),
            const SizedBox(height: 4),
            Text('$used used${b.manualCount > 0 ? ' · ${b.manualCount} used manually' : ''} · $cancelled cancelled · ${b.unused} not used yet',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
          trailing: _canIssue
              ? PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (a) => _bookAction(b, a),
                  itemBuilder: (_) => [
                    if (b.open) const PopupMenuItem(value: 'cancel', child: Text('Cancel a slip')),
                    if (b.open) const PopupMenuItem(value: 'close', child: Text('Close book')),
                    if (!b.open) const PopupMenuItem(value: 'reopen', child: Text('Reopen book')),
                    if (b.used.isEmpty) const PopupMenuItem(value: 'delete', child: Text('Remove (issued by mistake)')),
                  ],
                )
              : null,
          children: [
            if (!b.open && '${b.row['close_note'] ?? ''}'.isNotEmpty)
              Align(alignment: Alignment.centerLeft,
                  child: Text('Closed by ${b.row['closed_by_name'] ?? '—'}: ${b.row['close_note']}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            if (b.skipped.isNotEmpty) _flag('Skipped', 'Not used, but higher slips are — a collection may not be entered.', Colors.amber.shade800, b.skipped),
            if (b.missingAtClose.isNotEmpty) _flag('Missing at close', 'Never used or cancelled before the book was closed.', AppTheme.danger, b.missingAtClose),
            if (b.openRepeated.isNotEmpty) _flag('Used more than once', 'The same slip is on two or more collections.', AppTheme.danger, b.openRepeated),
            if (b.openOutOfOrder.isNotEmpty) _flag('Out of order', 'Used after a higher slip — the book order was broken.', Colors.deepOrange, b.openOutOfOrder),
            // Without the receipt-book check, reused / jumped slips can't be
            // stopped in the app — so they can be looked into and marked checked.
            if (_canIssue && !_flowOn && (b.openRepeated.isNotEmpty || b.openOutOfOrder.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _markChecked(b),
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: const Text('Mark as checked', style: TextStyle(fontSize: 12.5)),
                  ),
                ),
              ),
            if (b.checkedRows.isNotEmpty) _checkedList(b),
            if (b.byOthers.isNotEmpty)
              _flag('Used by someone else', b.byOthers.map((u) => '${u['serial']} by ${u['user_name'] ?? '—'}').toSet().join(', '),
                  AppTheme.danger, [for (final u in b.byOthers) (u['serial'] as num).toInt()]),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft,
                child: Wrap(spacing: 12, children: [
                  _legend(AppTheme.success, 'Used'),
                _legend(const Color(0xFF0D9488), 'Used manually'),
                  _legend(Colors.grey, 'Cancelled'),
                  _legend(Colors.amber.shade700, 'Skipped / missing'),
                  _legend(AppTheme.border, 'Not used yet'),
                ])),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (var n = b.start; n <= b.end; n++) _slipCell(b, n),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slipCell(_Book b, int n) {
    final used = b.usedSet.contains(n);
    final can = b.cancelMap.containsKey(n);
    final man = !used && !can && b.manual.contains(n);
    final miss = b.skipped.contains(n) || b.missingAtClose.contains(n);
    final bad = b.openRepeated.contains(n) || b.openOutOfOrder.contains(n);
    const manualColor = Color(0xFF0D9488);
    final Color bg = used ? AppTheme.success.withOpacity(0.15)
        : man ? manualColor.withOpacity(0.15)
        : can ? Colors.grey.withOpacity(0.18)
        : miss ? Colors.amber.withOpacity(0.25) : Colors.white;
    final Color bd = bad ? AppTheme.danger : used ? AppTheme.success.withOpacity(0.5)
        : man ? manualColor.withOpacity(0.7)
        : can ? Colors.grey : miss ? Colors.amber.shade700 : AppTheme.border;
    return InkWell(
      onTap: () => _slipTap(b, n),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: bd, width: bad ? 1.6 : 1),
        ),
        child: Text('$n', style: TextStyle(
            fontSize: 11, decoration: can ? TextDecoration.lineThrough : null,
            fontWeight: bad ? FontWeight.w800 : FontWeight.w500)),
      ),
    );
  }

  Future<void> _markChecked(_Book b) async {
    final items = <(int, String)>[
      for (final n in b.openRepeated) (n, 'repeated'),
      for (final n in b.openOutOfOrder) (n, 'out_of_order'),
    ];
    final picked = {for (var i = 0; i < items.length; i++) i};
    await _ensureCustNames(b.used.map((u) => u['customer_id']));
    if (!mounted) return;
    final noteCtrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text('Mark as checked · ${b.holder}'),
        content: SizedBox(
          width: 480,
          height: 420,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Tick the slips you have looked into. They stop counting as issues and stay listed as checked, '
                'with your note and name.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Row(children: [
              TextButton(onPressed: () => setD(() => picked.addAll(List.generate(items.length, (i) => i))), child: const Text('Tick all')),
              TextButton(onPressed: () => setD(picked.clear), child: const Text('Clear')),
              const Spacer(),
              Text('${picked.length} of ${items.length}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final (n, kind) = items[i];
                  final uses = [for (final u in b.used) if ((u['serial'] as num).toInt() == n) u];
                  return CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: picked.contains(i),
                    onChanged: (v) => setD(() => v == true ? picked.add(i) : picked.remove(i)),
                    title: Text('$n · ${kind == 'repeated' ? 'Used more than once' : 'Out of order'}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        [for (final u in uses) '${_fmt(u['at'])} · ${_shopOf(u).isEmpty ? '—' : _shopOf(u)} · Rs ${u['amount'] ?? '—'}'].join('\n'),
                        style: const TextStyle(fontSize: 11.5)),
                  );
                },
              ),
            ),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                  labelText: 'What was checked',
                  hintText: 'e.g. Genuine payments — old slip numbers written on new receipts'),
            ),
            if (err != null)
              Padding(padding: const EdgeInsets.only(top: 6),
                  child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Back')),
          ElevatedButton(
            onPressed: () {
              if (picked.isEmpty) return setD(() => err = 'Tick at least one slip.');
              if (noteCtrl.text.trim().isEmpty) return setD(() => err = 'Write what was checked.');
              Navigator.of(ctx, rootNavigator: true).pop(true);
            },
            child: Text('Mark ${picked.length} as checked'),
          ),
        ],
      )),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = await _db.rpc('receipt_slip_check', params: {
        'p_book': b.id,
        'p_items': [for (final i in picked) {'serial': items[i].$1, 'kind': items[i].$2}],
        'p_note': noteCtrl.text.trim(),
      });
      _snack('Marked $n slip${n == 1 ? '' : 's'} as checked');
      await _load();
    } catch (e) {
      _snack(friendlyError('Could not mark as checked', e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _checkedList(_Book b) {
    final rows = b.checkedRows;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 4),
            dense: true,
            title: Text('Checked (${rows.length}): ${rows.map((r) => r['serial']).toSet().take(30).join(', ')}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            children: [
              for (final r in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.check_circle_outline, size: 18, color: AppTheme.success),
                  title: Text('${r['serial']} · ${r['kind'] == 'repeated' ? 'Used more than once' : r['kind'] == 'unrecorded' ? 'Used manually' : 'Out of order'}',
                      style: const TextStyle(fontSize: 12.5)),
                  subtitle: Text('${r['note'] ?? ''} — ${r['checked_by_name'] ?? '—'}, ${_fmt(r['checked_at'])}',
                      style: const TextStyle(fontSize: 11.5)),
                  trailing: _canIssue
                      ? IconButton(
                          tooltip: 'Undo',
                          icon: const Icon(Icons.undo, size: 18),
                          onPressed: _busy
                              ? null
                              : () async {
                                  setState(() => _busy = true);
                                  try {
                                    await _db.rpc('receipt_slip_uncheck', params: {'p_id': r['id']});
                                    await _load();
                                  } catch (e) {
                                    _snack(friendlyError('Could not undo', e));
                                  }
                                  if (mounted) setState(() => _busy = false);
                                },
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _flag(String title, String help, Color color, List<int> nums) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$title (${nums.toSet().length}): ${nums.toSet().take(40).join(', ')}${nums.toSet().length > 40 ? ' …' : ''}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: color)),
            Text(help, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
        ),
      );

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c.withOpacity(0.5), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]);

  Widget _tag(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
        child: Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );
}
