import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:opstation_web/core/widgets/brand_logo.dart';
import 'package:opstation_web/core/widgets/erp_pill.dart';
import '../retailer_auth_controller.dart';
import '../../../core/theme/app_theme.dart';

/// Retailer portal login. Retailers sign in with their CODE + password
/// (the code maps to a synthetic email behind the scenes). Lives at /r/login.
///
/// Wide screens: a shop photo with the headline on the left, the form on the right.
/// Phones: the photo as a band on top, the form under it.
class RetailerLoginScreen extends ConsumerStatefulWidget {
  const RetailerLoginScreen({super.key});
  @override
  ConsumerState<RetailerLoginScreen> createState() =>
      _RetailerLoginScreenState();
}

class _RetailerLoginScreenState extends ConsumerState<RetailerLoginScreen> {
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _obscure = true;

  static const _ink = Color(0xFF111827);
  static const _navy = Color(0xFF070D1F);

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passCtrl.dispose();
    _codeFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_codeCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      _err('Enter your code and password');
      return;
    }
    await ref.read(retailerAuthControllerProvider.notifier).signIn(
          code: _codeCtrl.text,
          password: _passCtrl.text,
        );
    if (!mounted) return;
    final err = ref.read(retailerAuthControllerProvider).error;
    if (err != null) _err(err.toString().replaceFirst('Exception: ', ''));
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppTheme.danger,
      behavior: SnackBarBehavior.floating,
    ));
  }

  OutlineInputBorder _border([Color? c]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c ?? AppTheme.border),
      );

  void _back() => context.go('/login');

  // ------------------------------ left: the shop ------------------------------
  Widget _photo({required bool wide, double topInset = 0}) {
    return LayoutBuilder(builder: (context, box) => _photoBody(wide: wide, topInset: topInset, boxH: box.maxHeight, boxW: box.maxWidth));
  }

  Widget _photoBody({required bool wide, required double topInset, required double boxH, required double boxW}) {
    // A short window (a phone turned sideways) keeps the headline but drops the extras that would not fit.
    final tall = boxH >= 600;
    final tiny = boxW < 340; // very narrow phones: logo and name only
    return Stack(fit: StackFit.expand, children: [
      Image.network(
        'retailer_shop.jpg',
        fit: BoxFit.cover,
        alignment: wide ? const Alignment(0.15, -0.2) : const Alignment(0.25, -0.7), // phones: keep the face in view
        errorBuilder: (_, __, ___) => const ColoredBox(color: _navy),
      ),
      // Darkens the bottom and the left so the headline reads over the shelves.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [_navy.withOpacity(0.92), _navy.withOpacity(0.35), _navy.withOpacity(0.0)],
            stops: const [0, 0.5, 0.85],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [_navy.withOpacity(0.55), _navy.withOpacity(0.0)],
            stops: const [0, 0.55],
          ),
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(wide ? 48 : 20, (wide ? 36 : 14) + topInset, wide ? 48 : 20, wide ? 40 : 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            // The logo and name take you back to the main sign-in.
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _back,
                child: Tooltip(
                  message: 'Back to sign in',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    BrandLogo(size: wide ? 40 : 34),
                    const SizedBox(width: 10),
                    const Text('Opstation',
                        style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                    if (!tiny) ...[const SizedBox(width: 10), const ErpPill()],
                  ]),
                ),
              ),
            ),
            if (!tiny) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text('· Retailer Portal',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 14, fontWeight: FontWeight.w500)),
              ),
            ],
          ]),
          const Spacer(),
          if (wide) ...[
            Text('Your orders and',
                style: TextStyle(color: Colors.white, fontSize: tall ? 44 : 34, fontWeight: FontWeight.w800, height: 1.08, letterSpacing: -1.2)),
            Text('statement, anytime.',
                style: TextStyle(color: const Color(0xFF6E9BFF), fontSize: tall ? 44 : 34, fontWeight: FontWeight.w800, height: 1.08, letterSpacing: -1.2)),
            if (tall) ...[
            const SizedBox(height: 14),
            Text('See deliveries, download invoices and check what is due.',
                style: TextStyle(color: Colors.white.withOpacity(0.88), fontSize: 17, height: 1.4)),
            const SizedBox(height: 22),
            Wrap(spacing: 8, runSpacing: 8, children: const [
              _Chip(Icons.inventory_2_outlined, 'Orders'),
              _Chip(Icons.local_shipping_outlined, 'Deliveries'),
              _Chip(Icons.receipt_long_outlined, 'Invoices'),
            ]),
            const SizedBox(height: 22),
            ],
            Row(children: [
              Icon(Icons.lock_outline, size: 14, color: Colors.white.withOpacity(0.65)),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Secured & encrypted · © 2026 Opstation',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12.5)),
              ),
            ]),
          ] else
            Text('Your orders and statement, anytime.',
                style: TextStyle(color: Colors.white, fontSize: boxW < 360 ? 19 : 22, fontWeight: FontWeight.w800, height: 1.15)),
        ]),
      ),
    ]);
  }

  // ------------------------------ right: the form ------------------------------
  Widget _form(bool isLoading, {bool compact = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sign in',
            style: TextStyle(fontSize: compact ? 26 : 30, fontWeight: FontWeight.w800, color: _ink, letterSpacing: -0.5)),
        const SizedBox(height: 6),
        const Text('Use the code and password you were given.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        SizedBox(height: compact ? 18 : 26),
        const Text('Code', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
        const SizedBox(height: 6),
        TextField(
          controller: _codeCtrl,
          focusNode: _codeFocus,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          autocorrect: false,
          onSubmitted: (_) => _passFocus.requestFocus(),
          style: const TextStyle(fontSize: 14, color: _ink),
          decoration: InputDecoration(
            hintText: 'e.g. 767',
            prefixIcon: const Icon(Icons.badge_outlined, size: 18, color: AppTheme.textSecondary),
            contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            filled: true,
            fillColor: const Color(0xFFFAFBFC),
            border: _border(),
            enabledBorder: _border(),
            focusedBorder: _border(AppTheme.primary).copyWith(borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
          ),
        ),
        SizedBox(height: compact ? 14 : 18),
        const Text('Password', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
        const SizedBox(height: 6),
        TextField(
          controller: _passCtrl,
          focusNode: _passFocus,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _submit(),
          style: const TextStyle(fontSize: 14, color: _ink),
          decoration: InputDecoration(
            hintText: '••••••••',
            prefixIcon: const Icon(Icons.lock_outline, size: 18, color: AppTheme.textSecondary),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: AppTheme.textSecondary),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            filled: true,
            fillColor: const Color(0xFFFAFBFC),
            border: _border(),
            enabledBorder: _border(),
            focusedBorder: _border(AppTheme.primary).copyWith(borderSide: const BorderSide(color: AppTheme.primary, width: 1.5)),
          ),
        ),
        SizedBox(height: compact ? 20 : 24),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: isLoading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              disabledBackgroundColor: AppTheme.primary.withOpacity(0.5),
            ),
            child: isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('Sign in', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    SizedBox(width: 8),
                    Icon(Icons.arrow_forward, size: 18),
                  ]),
          ),
        ),
        SizedBox(height: compact ? 14 : 22),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Not a retailer? ', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            TextButton(
              onPressed: _back,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Staff sign in', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _backLink() => TextButton.icon(
        onPressed: _back,
        icon: const Icon(Icons.arrow_back, size: 16),
        label: const Text('Back to Opstation'),
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(retailerAuthControllerProvider).isLoading;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        if (wide) {
          return Row(children: [
            Expanded(flex: 13, child: _photo(wide: true)),
            Expanded(
              flex: 9,
              child: Stack(children: [
                Positioned(left: 28, top: 28, child: _backLink()),
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 80),
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: _form(isLoading)),
                  ),
                ),
              ]),
            ),
          ]);
        }
        // Phones: a short photo band under the status bar, then the form. The band is taller on tall screens so the picture is not cropped; it shrinks on short screens so the
        // sign-in button stays in reach, and the page scrolls (and closes the keyboard on drag) when it still does not fit.
        final top = MediaQuery.of(context).padding.top;
        final bandH = (c.maxHeight * 0.36).clamp(210.0, 340.0) + top;
        return SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: bandH, child: _photo(wide: false, topInset: top)),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _backLink(),
                      _form(isLoading, compact: true),
                    ]),
                  ),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(0.28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
      );
}
