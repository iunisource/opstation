import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

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

/// "32282 83 84" → 32282, 32283, 32284 (same rules as the app and SQL).
List<int> _slips(String raw) {
  final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
  final out = <int>[];
  int? prev;
  for (final t in toks) {
    if (t.length > 15) continue;
    final n = int.parse(t);
    if (prev == null || t.length >= prev.toString().length) {
      out.add(n);
      prev = n;
    } else {
      var p10 = 1;
      for (var i = 0; i < t.length; i++) {
        p10 *= 10;
      }
      prev = (prev - (prev % p10)) + n;
      out.add(prev);
    }
  }
  return out;
}

class _Book {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> used;      // {serial, user_id, user_name, at, amount, …}
  final List<Map<String, dynamic>> cancelled; // {id, serial, reason, by, at}
  _Book(this.row, this.used, this.cancelled);

  String get id => row['id'] as String;
  int get start => (row['start_no'] as num).toInt();
  int get end => (row['end_no'] as num).toInt();
  int get size => end - start + 1;
  bool get open => row['status'] == 'open';
  String get holderId => '${row['user_id'] ?? ''}';
  String get holder => '${row['user_name'] ?? ''}';

  late final Set<int> usedSet = {for (final u in used) (u['serial'] as num).toInt()};
  late final Map<int, Map<String, dynamic>> cancelMap = {
    for (final c in cancelled) (c['serial'] as num).toInt(): c,
  };
  int get unused => size - usedSet.length - cancelMap.keys.where((n) => !usedSet.contains(n)).length;
  int? get highestUsed => usedSet.isEmpty ? null : usedSet.reduce((a, b) => a > b ? a : b);

  /// Not used and not cancelled, below the highest used slip.
  late final List<int> skipped = () {
    final hi = highestUsed;
    if (hi == null || !open) return <int>[]; // a closed book lists them under "Missing at close"
    return [for (var n = start; n < hi; n++) if (!usedSet.contains(n) && !cancelMap.containsKey(n)) n];
  }();

  /// Unused slips of a CLOSED book are missing too.
  late final List<int> missingAtClose = open
      ? <int>[]
      : [for (var n = start; n <= end; n++) if (!usedSet.contains(n) && !cancelMap.containsKey(n)) n];

  late final List<int> repeated = () {
    final c = <int, int>{};
    for (final u in used) {
      final n = (u['serial'] as num).toInt();
      c[n] = (c[n] ?? 0) + 1;
    }
    return (c.entries.where((e) => e.value > 1).map((e) => e.key).toList()..sort());
  }();

  late final List<int> outOfOrder = () {
    final seq = [...used]..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
    final out = <int>{};
    var maxSoFar = -1;
    for (final u in seq) {
      final n = (u['serial'] as num).toInt();
      if (n < maxSoFar) out.add(n);
      if (n > maxSoFar) maxSoFar = n;
    }
    return out.toList()..sort();
  }();

  /// Slips of this book written by someone other than the holder.
  late final List<Map<String, dynamic>> byOthers =
      used.where((u) => '${u['user_id'] ?? ''}' != holderId).toList();

  int get issues => skipped.length + missingAtClose.length + repeated.length + outOfOrder.length + byOthers.length;
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
  String _status = 'open'; // open | closed | all
  String _query = '';
  bool _busy = false;

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
            final slips = _slips('${v['receipt_number'] ?? ''}');
            final bad = slips.where((n) => !books.any((b) => n >= b.start && n <= b.end)).toList();
            if (slips.isEmpty || bad.isNotEmpty) outside.add({...v, 'bad': bad});
          }
          if (page.length < 1000 || f > 100000) break;
        }
      }
      if (!mounted) return;
      setState(() {
        _flowOn = on;
        _canIssue = isAdmin || (me != null && issuers.contains(me.id));
        _books = books;
        _team = team;
        _outside = outside;
        _loading = false;
      });
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
                      'Open now: ${_books.where((x) => x.open && x.holderId == userId).map((x) => '${x.start}–${x.end}').join(', ')}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              const SizedBox(height: 10),
              Row(children: [
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
                  child: Text('$count slips', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
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
                for (final x in _books) {
                  if (x.start <= b && x.end >= a) {
                    return setLocal(() => err = 'Serials ${x.start}–${x.end} are already issued to '
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
                              if (open.isNotEmpty) 'Open: ${open.map((x) => '${x.start}–${x.end}').join(', ')}',
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
    final serialTxt = await _askText('Cancel a slip — ${b.start}–${b.end}', 'Slip number', required: true);
    if (serialTxt == null) return;
    final n = int.tryParse(serialTxt);
    if (n == null || n < b.start || n > b.end) {
      _snack('Slip $serialTxt is not in this book (${b.start}–${b.end}).');
      return;
    }
    final reason = await _askText('Cancel slip $n', 'Reason', hint: 'e.g. slip torn', required: true);
    if (reason == null) return;
    await _run('Slip $n cancelled', () async {
      await _db.rpc('receipt_slip_cancel', params: {'p_book': b.id, 'p_serial': n, 'p_reason': reason});
    });
  }

  Future<void> _bookAction(_Book b, String a) async {
    switch (a) {
      case 'cancel':
        return _cancelSlip(b);
      case 'close':
        final note = await _askText('Close book ${b.start}–${b.end}?', 'Note (optional)',
            body: b.unused > 0
                ? '${b.unused} slip${b.unused == 1 ? ' is' : 's are'} not used yet — they will show as missing.\n'
                : null);
        if (note == null) return;
        return _run('Book closed', () async {
          await _db.rpc('receipt_book_close', params: {'p_id': b.id, 'p_note': note});
        });
      case 'reopen':
        return _run('Book reopened', () async {
          await _db.rpc('receipt_book_reopen', params: {'p_id': b.id});
        });
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Remove book ${b.start}–${b.end}?'),
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
    final uses = b.used.where((u) => (u['serial'] as num).toInt() == n).toList();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Slip $n'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (c != null) ...[
              const Text('Cancelled', style: TextStyle(fontWeight: FontWeight.w800)),
              Text('${c['reason'] ?? ''}'),
              Text('By ${c['by'] ?? '—'} · ${_fmt(c['at'])}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ] else if (uses.isEmpty)
              const Text('Not used yet.')
            else
              for (final u in uses)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('Rs ${money((u['amount'] as num?) ?? 0)} · ${u['user_name'] ?? ''} · ${_fmt(u['at'])}'),
                ),
          ]),
        ),
        actions: [
          if (c != null && _canIssue)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _run('Slip $n is usable again', () async {
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
    return t == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(t.toLocal());
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final list = _books.where((b) {
      if (_status == 'open' && !b.open) return false;
      if (_status == 'closed' && b.open) return false;
      if (q.isNotEmpty && !matchesQuery('${b.holder} ${b.start} ${b.end} ${b.row['label'] ?? ''}', q)) return false;
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
                      if (_outside.isNotEmpty) _outsideCard(),
                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(40),
                          child: Center(child: Text(
                              _books.isEmpty ? 'No receipt books issued yet.' : 'No books here.',
                              style: const TextStyle(color: AppTheme.textSecondary))),
                        ),
                      for (final b in list) _bookCard(b),
                    ]),
        ),
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
            Text('${b.start}–${b.end}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
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
            Text('$used used · $cancelled cancelled · ${b.unused} not used yet',
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
            if (b.repeated.isNotEmpty) _flag('Used more than once', 'The same slip is on two or more collections.', AppTheme.danger, b.repeated),
            if (b.outOfOrder.isNotEmpty) _flag('Out of order', 'Used after a higher slip — the book order was broken.', Colors.deepOrange, b.outOfOrder),
            if (b.byOthers.isNotEmpty)
              _flag('Used by someone else', b.byOthers.map((u) => '${u['serial']} by ${u['user_name'] ?? '—'}').toSet().join(', '),
                  AppTheme.danger, [for (final u in b.byOthers) (u['serial'] as num).toInt()]),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerLeft,
                child: Wrap(spacing: 12, children: [
                  _legend(AppTheme.success, 'Used'),
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
    final miss = b.skipped.contains(n) || b.missingAtClose.contains(n);
    final bad = b.repeated.contains(n) || b.outOfOrder.contains(n);
    final Color bg = used ? AppTheme.success.withOpacity(0.15)
        : can ? Colors.grey.withOpacity(0.18)
        : miss ? Colors.amber.withOpacity(0.25) : Colors.white;
    final Color bd = bad ? AppTheme.danger : used ? AppTheme.success.withOpacity(0.5)
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
