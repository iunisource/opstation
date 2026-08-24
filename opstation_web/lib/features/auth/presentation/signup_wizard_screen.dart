import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../billing/presentation/plan_cards.dart';

/// Full-screen, self-guiding organisation sign-up.
///
/// Replaces the cramped modal with a dedicated page: a branded left rail that
/// reassures the prospect, and a two-step wizard on the right (about you →
/// about your business) with inline validation, progress, and a clear success
/// state. Submits an org-provisioning request to the `signup-request` function;
/// the actual provisioning is done by a super-admin.
class SignupWizardScreen extends StatefulWidget {
  const SignupWizardScreen({super.key});
  @override
  State<SignupWizardScreen> createState() => _SignupWizardScreenState();
}

class _SignupWizardScreenState extends State<SignupWizardScreen> {
  static const _ink = Color(0xFF0F1729);

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _contact = TextEditingController();
  final _org = TextEditingController();
  final _note = TextEditingController();
  String? _industry;
  String _costing = 'fifo';
  List<Map<String, dynamic>> _plans = [];
  String _planId = 'plan_standard';

  int _step = 0; // 0 = about you, 1 = about business
  bool _submitting = false;
  bool _done = false;
  String? _error;

  // Branded provisioning loader (cycles while the workspace is created).
  Timer? _loaderTimer;
  int _loaderStep = 0;
  static const _loaderLines = [
    'Setting up your backend…',
    'Building your office environment…',
    'Wiring up your books & ledgers…',
    'Unlocking your modules…',
    'Almost ready!',
  ];

  void _startLoader() {
    _loaderStep = 0;
    _loaderTimer?.cancel();
    _loaderTimer = Timer.periodic(const Duration(milliseconds: 1400), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _loaderStep = (_loaderStep + 1) % _loaderLines.length);
    });
  }

  void _stopLoader() { _loaderTimer?.cancel(); _loaderTimer = null; }

  static const _industries = [
    'Manufacturing',
    'Retail',
    'Wholesale & Distribution',
    'Automotive & Parts',
    'Textiles & Apparel',
    'Food & Beverage',
    'Pharmaceuticals & Healthcare',
    'Construction & Building Materials',
    'Electronics & Hardware',
    'Chemicals',
    'Logistics & Transport',
    'Agriculture',
    'Energy & Utilities',
    'Services',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    // Re-evaluate the Continue/Submit enabled state as the user types.
    for (final c in [_name, _email, _contact, _org]) {
      c.addListener(() => setState(() {}));
    }
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    try {
      final rows = await Supabase.instance.client
          .from('subscription_plans')
          .select('id, name, amount, tagline, badge, highlight, features, module_keys')
          .eq('is_active', true)
          .order('sort_order');
      if (!mounted) return;
      final list = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _plans = list;
        // default to the highlighted (recommended) plan, else the first.
        final hi = list.where((p) => (p['highlight'] as bool?) ?? false).toList();
        _planId = (hi.isNotEmpty ? hi.first['id'] : (list.isNotEmpty ? list.first['id'] : 'plan_standard')) as String;
      });
    } catch (_) {/* plans are optional for signup; falls back to default plan */}
  }

  @override
  void dispose() {
    _stopLoader();
    for (final c in [_name, _email, _contact, _org, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
  bool get _step1Valid => _name.text.trim().isNotEmpty && _looksLikeEmail(_email.text.trim());
  bool get _step2Valid => _org.text.trim().isNotEmpty;

  void _next() {
    if (!_step1Valid) {
      setState(() => _error = 'Please enter your name and a valid email to continue.');
      return;
    }
    setState(() { _error = null; _step = 1; });
  }

  Future<void> _submit() async {
    if (!_step2Valid) {
      setState(() => _error = 'Your organization name is required.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    _startLoader();
    const errMap = {
      'email_exists': 'An account with this email already exists — try signing in instead.',
      'bad_email': 'Please enter a valid email address.',
      'missing_fields': 'Please enter your business name and email.',
    };
    try {
      final res = await Supabase.instance.client.functions.invoke('signup-trial', body: {
        'name': _name.text.trim(),
        'orgName': _org.text.trim(),
        'contact': _contact.text.trim(),
        'email': _email.text.trim(),
        'costingMethod': _costing,
        'planId': _planId,
      });
      final data = res.data is Map ? res.data as Map : const {};
      if (res.status == 200 && data['ok'] == true) {
        _stopLoader();
        if (!mounted) return;
        setState(() { _submitting = false; _done = true; });
        return;
      }
      _stopLoader();
      final code = data['error'] as String?;
      setState(() {
        _submitting = false;
        _error = errMap[code] ?? 'Could not create your workspace. Please try again or contact support.';
      });
    } on FunctionException catch (e) {
      _stopLoader();
      final det = e.details;
      final code = det is Map ? det['error'] as String? : null;
      setState(() {
        _submitting = false;
        _error = errMap[code] ?? 'Could not create your workspace. Please try again or contact support.';
      });
    } catch (e) {
      _stopLoader();
      setState(() {
        _submitting = false;
        _error = 'Could not create your workspace: ${e.toString().split("\n").first}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(children: [
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final form = _done ? _successView() : _formView();
        if (!wide) {
          return SafeArea(
            child: Column(children: [
              _compactTopBar(),
              Expanded(child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: form)),
              )),
            ]),
          );
        }
        return Row(children: [
          Expanded(flex: 5, child: _brandRail()),
          Expanded(
            flex: 6,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form),
                ),
              ),
            ),
          ),
        ]);
      }),
      if (_submitting) _loaderOverlay(),
      ]),
    );
  }

  // ── branded provisioning loader ────────────────────────────────────────────
  Widget _loaderOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.white.withOpacity(0.94),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 72, height: 72,
              child: Stack(alignment: Alignment.center, children: [
                const SizedBox(
                  width: 72, height: 72,
                  child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.primary),
                ),
                Container(
                  width: 48, height: 48, alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(13)),
                  child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
                ),
              ]),
            ),
            const SizedBox(height: 26),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: Text(
                _loaderLines[_loaderStep],
                key: ValueKey(_loaderStep),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _ink),
              ),
            ),
            const SizedBox(height: 8),
            Text('Creating your Opstation workspace — this only takes a few seconds.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary.withOpacity(0.9))),
          ]),
        ),
      ),
    );
  }

  // ── branded left rail (wide screens) ──────────────────────────────────────
  Widget _brandRail() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF244C97), Color(0xFF142C58), Color(0xFF0B1220)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _goHome,
                child: Tooltip(
                  message: 'Back to sign in',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 42, height: 42, alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: Colors.white.withOpacity(0.22)),
                      ),
                      child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20)),
                    ),
                    const SizedBox(width: 12),
                    const Text('Opstation', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),
            ),
            const Spacer(),
            const Text('Create your\nOpstation workspace.',
                style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.5)),
            const SizedBox(height: 14),
            Text('Tell us about your business and your workspace is created instantly — we email your login details right away. Free for 14 days.',
                style: TextStyle(color: Colors.white.withOpacity(0.82), fontSize: 15, height: 1.5)),
            const SizedBox(height: 32),
            _railPoint('Instant setup — your workspace is ready in seconds'),
            _railPoint('A dedicated workspace for your whole operation'),
            _railPoint('14-day free trial · no credit card required'),
            const Spacer(),
            Text('© 2026 Opstation · All rights reserved',
                style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _railPoint(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.check_circle, color: Color(0xFF6EA0FF), size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(t, style: TextStyle(color: Colors.white.withOpacity(0.92), fontSize: 14.5, height: 1.4))),
        ]),
      );

  // Logo tap target: return to the sign-in screen (same as "Back to sign in").
  void _goHome() => Navigator.of(context).maybePop();

  Widget _compactTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Row(children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _goHome,
            child: Tooltip(
              message: 'Back to sign in',
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 34, height: 34, alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(9)),
                  child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                const SizedBox(width: 10),
                const Text('Opstation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
              ]),
            ),
          ),
        ),
        const Spacer(),
        TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back to sign in')),
      ]),
    );
  }

  // ── the form / wizard ─────────────────────────────────────────────────────
  Widget _formView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      // "Back to sign in" for wide screens (compact bar has its own)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Back to sign in'),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: AppTheme.textSecondary),
        ),
      ),
      const SizedBox(height: 18),
      Text(_step == 0 ? 'Get started' : 'About your business',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _ink)),
      const SizedBox(height: 6),
      Text(_step == 0
          ? 'A couple of details about you, then your business.'
          : 'Last step — tell us what you run so we tailor your setup.',
          style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
      const SizedBox(height: 20),
      _stepper(),
      const SizedBox(height: 24),
      if (_step == 0) ..._stepOne() else ..._stepTwo(),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline, color: AppTheme.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13))),
        ]),
      ],
      const SizedBox(height: 24),
      _actions(),
      const SizedBox(height: 18),
      Center(child: Text('No credit card required. We never share your details.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withOpacity(0.9)))),
    ]);
  }

  Widget _stepper() {
    Widget seg(int i, String label) {
      final active = _step == i;
      final done = _step > i;
      final color = (active || done) ? AppTheme.primary : AppTheme.border;
      return Expanded(child: Row(children: [
        Container(
          width: 24, height: 24, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: (active || done) ? AppTheme.primary : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5),
          ),
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text('${i + 1}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: active ? Colors.white : AppTheme.textSecondary)),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 12.5, fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? _ink : AppTheme.textSecondary)),
      ]));
    }
    return Row(children: [
      seg(0, 'You'),
      Container(width: 28, height: 1.5, color: _step > 0 ? AppTheme.primary : AppTheme.border),
      const SizedBox(width: 8),
      seg(1, 'Business'),
    ]);
  }

  List<Widget> _stepOne() => [
    _field(controller: _name, label: 'Your name', required: true, hint: 'e.g. James Carter', icon: Icons.person_outline),
    const SizedBox(height: 16),
    _field(controller: _email, label: 'Work email', required: true, hint: 'you@company.com',
        icon: Icons.mail_outline, keyboardType: TextInputType.emailAddress,
        help: 'We\'ll send your setup details here.'),
    const SizedBox(height: 16),
    _field(controller: _contact, label: 'Contact number', hint: 'Optional — for a quicker setup call',
        icon: Icons.phone_outlined, keyboardType: TextInputType.phone),
  ];

  List<Widget> _stepTwo() => [
    _field(controller: _org, label: 'Organization name', required: true, hint: 'e.g. Summit Distributors',
        icon: Icons.business_outlined),
    const SizedBox(height: 16),
    const Text('Industry', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
    const SizedBox(height: 6),
    DropdownButtonFormField<String>(
      value: _industry,
      isExpanded: true,
      decoration: _dec('Select your industry', Icons.category_outlined),
      items: [for (final i in _industries) DropdownMenuItem(value: i, child: Text(i))],
      onChanged: (v) => setState(() => _industry = v),
    ),
    const SizedBox(height: 16),
    Row(children: const [
      Text('Inventory costing method', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
      Text(' *', style: TextStyle(fontSize: 13, color: AppTheme.danger, fontWeight: FontWeight.w700)),
    ]),
    const SizedBox(height: 6),
    DropdownButtonFormField<String>(
      value: _costing,
      isExpanded: true,
      decoration: _dec('Select costing method', Icons.calculate_outlined),
      items: const [
        DropdownMenuItem(value: 'fifo', child: Text('FIFO (First In, First Out)')),
        DropdownMenuItem(value: 'lifo', child: Text('LIFO (Last In, First Out)')),
        DropdownMenuItem(value: 'avco', child: Text('Weighted Average')),
      ],
      onChanged: (v) => setState(() => _costing = v ?? 'fifo'),
    ),
    const Padding(
      padding: EdgeInsets.only(top: 5, left: 2),
      child: Text('This sets how stock cost is calculated. It is fixed once you start transacting, so choose carefully.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    ),
    const SizedBox(height: 22),
    const Text('Choose your plan', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _ink)),
    const SizedBox(height: 2),
    const Text('Start free for 14 days — no card needed. Switch or upgrade anytime.',
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
    const SizedBox(height: 12),
    if (_plans.isEmpty)
      const Padding(padding: EdgeInsets.all(12), child: Center(child: Text('Loading plans…', style: TextStyle(color: AppTheme.textSecondary))))
    else
      PlanCards(
        plans: _plans,
        activeId: _planId,
        onSelect: (p) => setState(() => _planId = p['id'] as String),
        ctaLabel: (p) => (p['id'] as String) == _planId ? 'Selected' : 'Choose',
        ctaDisabled: (p) => false,
      ),
    const SizedBox(height: 18),
    _field(controller: _note, label: 'Anything we should know?', hint: 'Optional — branches, users, what you need first',
        icon: Icons.notes_outlined, maxLines: 3),
  ];

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? help,
    IconData? icon,
    bool required = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
        if (required) const Text(' *', style: TextStyle(fontSize: 13, color: AppTheme.danger, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: _dec(hint ?? '', icon),
      ),
      if (help != null) Padding(
        padding: const EdgeInsets.only(top: 5, left: 2),
        child: Text(help, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary.withOpacity(0.9))),
      ),
    ]);
  }

  InputDecoration _dec(String hint, IconData? icon) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.7), fontSize: 14),
        prefixIcon: icon != null ? Icon(icon, size: 18, color: AppTheme.textSecondary) : null,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        filled: true,
        fillColor: const Color(0xFFFAFBFC),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
      );

  Widget _actions() {
    final primaryEnabled = _step == 0 ? _step1Valid : _step2Valid;
    return Row(children: [
      if (_step == 1)
        OutlinedButton(
          onPressed: _submitting ? null : () => setState(() { _step = 0; _error = null; }),
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            side: const BorderSide(color: AppTheme.border),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
          child: const Text('Back'),
        ),
      if (_step == 1) const SizedBox(width: 12),
      Expanded(
        child: ElevatedButton(
          onPressed: (!primaryEnabled || _submitting) ? null : (_step == 0 ? _next : _submit),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: AppTheme.primary.withOpacity(0.35),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
            elevation: 0,
          ),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_step == 0 ? 'Continue' : 'Create workspace',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Icon(_step == 0 ? Icons.arrow_forward : Icons.check, size: 18),
                ]),
        ),
      ),
    ]);
  }

  // ── success ────────────────────────────────────────────────────────────────
  Widget _successView() {
    final org = _org.text.trim();
    final email = _email.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 64, height: 64, alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.green.withOpacity(0.10), shape: BoxShape.circle),
        child: const Icon(Icons.check_circle, color: Colors.green, size: 40),
      ),
      const SizedBox(height: 22),
      const Text('Check your email', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _ink)),
      const SizedBox(height: 10),
      Text(
        '${org.isEmpty ? 'Your workspace' : org} is ready! We\'ve emailed your login '
        'details${email.isEmpty ? '' : ' to $email'} with a temporary password. '
        'You\'ll set your own password the first time you sign in. Your free trial runs for 14 days.',
        style: const TextStyle(fontSize: 15, color: AppTheme.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 28),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16), elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
          child: const Text('Back to sign in', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }
}
