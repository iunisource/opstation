import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../orders/presentation/order_create_modal.dart';
import '../services/npl_providers.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _date(dynamic v) {
  final d = DateTime.tryParse('$v');
  return d == null ? '' : '${d.day} ${_months[d.month - 1]}';
}

String _q(num n) {
  final d = n.toDouble();
  return d % 1 == 0 ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
}

/// Drawer -> Product launch. One active launch opens straight to its route-wise
/// progress; several show a list first.
class NplLaunchesScreen extends ConsumerWidget {
  const NplLaunchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(nplMyLaunchesProvider);
    return async.when(
      loading: () => Scaffold(
          appBar: AppBar(title: const Text('Product launch')),
          body: const Center(child: CircularProgressIndicator())),
      error: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Product launch')),
          body: const Center(child: Text('Could not load. Check your connection.'))),
      data: (list) {
        if (list.length == 1) {
          return Scaffold(
            backgroundColor: const Color(0xFFF6F7F9),
            appBar: AppBar(title: const Text('Product launch')),
            body: NplLaunchBody(launchId: '${list.first['id']}'),
          );
        }
        return Scaffold(
          backgroundColor: const Color(0xFFF6F7F9),
          appBar: AppBar(title: const Text('Product launch')),
          body: list.isEmpty
              ? Center(
                  child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.rocket_launch_outlined, size: 40, color: AppColors.textSecondaryLight),
                    const SizedBox(height: 10),
                    Text('No active launch on your routes right now.',
                        textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondaryLight)),
                  ]),
                ))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final l in list) _launchCard(context, l),
                ]),
        );
      },
    );
  }

  Widget _launchCard(BuildContext context, Map<String, dynamic> l) {
    final total = (l['total'] as num?)?.toInt() ?? 0;
    final ordered = (l['ordered'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
                  backgroundColor: const Color(0xFFF6F7F9),
                  appBar: AppBar(title: Text('${l['name']}')),
                  body: NplLaunchBody(launchId: '${l['id']}'),
                ))),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.borderLight)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['name']}', style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
            Text('${l['product_name'] ?? ''}',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                  value: total > 0 ? ordered / total : 0, minHeight: 7, backgroundColor: AppColors.borderLight),
            ),
            const SizedBox(height: 6),
            Text('$ordered of $total outlets ordered',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

/// Route-wise progress of one launch: tick = the outlet has an invoiced order.
class NplLaunchBody extends ConsumerStatefulWidget {
  final String launchId;
  const NplLaunchBody({super.key, required this.launchId});
  @override
  ConsumerState<NplLaunchBody> createState() => _NplLaunchBodyState();
}

class _NplLaunchBodyState extends ConsumerState<NplLaunchBody> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _launch;
  List<Map<String, dynamic>> _routes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client
          .rpc('npl_my_launch_detail', params: {'p_launch': widget.launchId});
      final m = Map<String, dynamic>.from(r as Map);
      if (!mounted) return;
      setState(() {
        _launch = Map<String, dynamic>.from(m['launch'] as Map);
        _routes = [for (final e in (m['routes'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load. Check your connection.'; });
    }
  }

  List<Map<String, dynamic>> _outletsOf(Map<String, dynamic> route) =>
      [for (final o in (route['outlets'] as List? ?? const [])) Map<String, dynamic>.from(o as Map)];

  Future<void> _setNote(Map<String, dynamic> o, String? outcome, String? reason) async {
    try {
      await Supabase.instance.client.rpc('npl_set_outlet_note', params: {
        'p_launch': widget.launchId,
        'p_customer': o['customer_id'],
        'p_outcome': outcome,
        'p_reason': reason,
      });
      ref.invalidate(nplOutletIndexProvider);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not save. Check your connection.')));
      }
    }
  }

  Future<String?> _askReason(String title) async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Reason (optional)', hintText: 'e.g. stock available'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }

  Future<void> _outletSheet(Map<String, dynamic> o) async {
    final outcome = o['outcome'] as String?;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${o['shop_name']}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
          ),
          ListTile(
            leading: const Icon(Icons.add_shopping_cart),
            title: const Text('Place order'),
            onTap: () {
              Navigator.pop(ctx);
              OrderCreateModal.show(context,
                  customerId: '${o['customer_id']}',
                  customerName: '${o['shop_name']}',
                  customerCode: o['code'] as String?);
            },
          ),
          ListTile(
            leading: const Icon(Icons.thumb_down_alt_outlined),
            title: const Text('Declined'),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await _askReason('Why did they decline?');
              if (r != null) await _setNote(o, 'declined', r);
            },
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Will order later'),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await _askReason('Will order later');
              if (r != null) await _setNote(o, 'later', r);
            },
          ),
          if (outcome != null)
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Clear note'),
              onTap: () {
                Navigator.pop(ctx);
                _setNote(o, null, null);
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _launch == null) {
      return Center(child: Text(_error ?? 'Not found', style: TextStyle(color: AppColors.textSecondaryLight)));
    }
    final l = _launch!;
    // distinct outlets across routes
    final seen = <String>{};
    final all = <Map<String, dynamic>>[];
    for (final r in _routes) {
      for (final o in _outletsOf(r)) {
        if (seen.add('${o['customer_id']}')) all.add(o);
      }
    }
    final total = all.length;
    final ordered = all.where((o) => ((o['orders'] as num?) ?? 0) > 0).length;
    final repeat = all.where((o) => ((o['orders'] as num?) ?? 0) >= 2).length;
    final qty = all.fold<double>(0, (s, o) => s + ((o['qty'] as num?)?.toDouble() ?? 0));
    final schemes = [for (final s in (l['schemes'] as List? ?? const [])) '$s'];

    Widget box(String big, String small) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(big, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white)),
              Text(small, style: const TextStyle(fontSize: 10.5, color: Colors.white70)),
            ]),
          ),
        );

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(nplMyLaunchesProvider);
        ref.invalidate(nplOutletIndexProvider);
        await _load();
      },
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['product_name'] ?? l['name']}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
            Text(
                '${_date(l['start_date'])} to ${l['end_date'] == null ? 'open' : _date(l['end_date'])}'
                '${schemes.isEmpty ? '' : '  |  Offer: ${schemes.join(', ')}'}',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 10),
            Row(children: [
              box('$ordered / $total', 'outlets ordered'),
              const SizedBox(width: 8),
              box(_q(qty), 'qty sold'),
              const SizedBox(width: 8),
              box('$repeat', 'repeat'),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        for (final r in _routes) _routeCard(r),
        const SizedBox(height: 6),
        Text('A tick appears once the order is invoiced.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppColors.textSecondaryLight)),
      ]),
    );
  }

  Widget _routeCard(Map<String, dynamic> r) {
    final outlets = _outletsOf(r);
    final done = outlets.where((o) => ((o['orders'] as num?) ?? 0) > 0).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderLight)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Row(children: [
            Expanded(
                child: Text('${r['name']}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
            Text('$done / ${outlets.length}',
                style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
        ),
        for (final o in outlets) ...[
          const Divider(height: 1),
          _outletRow(o),
        ],
      ]),
    );
  }

  Widget _outletRow(Map<String, dynamic> o) {
    final orders = ((o['orders'] as num?) ?? 0).toInt();
    final qty = (o['qty'] as num?) ?? 0;
    final outcome = o['outcome'] as String?;
    final reason = (o['reason'] as String?)?.trim() ?? '';
    final done = orders > 0;
    String sub;
    String right;
    Color rightColor = AppColors.textSecondaryLight;
    if (done) {
      sub = o['last_date'] == null ? 'Ordered' : 'Last order ${_date(o['last_date'])}';
      right = orders >= 2 ? '${_q(qty)} | repeat' : _q(qty);
      rightColor = AppColors.success;
    } else if (outcome == 'declined') {
      sub = reason.isEmpty ? 'Declined' : 'Declined: $reason';
      right = 'Declined';
    } else if (outcome == 'later') {
      sub = reason.isEmpty ? 'Will order later' : 'Later: $reason';
      right = 'Later';
    } else {
      sub = 'Not ordered yet';
      right = 'Pending';
    }
    return InkWell(
      onTap: () => _outletSheet(o),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? AppColors.success : Colors.transparent,
              border: Border.all(color: done ? AppColors.success : AppColors.borderLight, width: 2),
            ),
            child: done ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${o['shop_name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: AppColors.textSecondaryLight)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: rightColor)),
        ]),
      ),
    );
  }
}
