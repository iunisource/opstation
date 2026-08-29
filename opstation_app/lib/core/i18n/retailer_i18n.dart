import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Retailer-facing localisation (English / Urdu).
///
/// Deliberately NOT flutter_localizations + ARB codegen: the scope is the
/// retailer surfaces only, and dragging gen-l10n into the build for ~40 strings
/// would add a codegen step to every build for the whole app. A plain map keyed
/// by locale is enough, stays readable, and costs nothing at build time. If
/// localisation ever spreads to staff screens, that is the point to migrate.
///
/// Urdu is RIGHT-TO-LEFT. Screens that use these strings must be wrapped in the
/// [RetailerLocaleScope] below, which supplies the correct Directionality —
/// otherwise Urdu renders left-aligned and reads wrong.

const _kLocaleKey = 'retailer_locale';

class RetailerLocale {
  static const en = 'en';
  static const ur = 'ur';
}

class RetailerLocaleController extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLocaleKey) ?? RetailerLocale.en;
  }

  Future<void> set(String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocaleKey, locale);
    state = AsyncData(locale);
  }

  Future<void> toggle() async {
    final cur = state.valueOrNull ?? RetailerLocale.en;
    await set(cur == RetailerLocale.en ? RetailerLocale.ur : RetailerLocale.en);
  }
}

final retailerLocaleProvider =
    AsyncNotifierProvider<RetailerLocaleController, String>(
        RetailerLocaleController.new);

/// Wraps retailer screens: supplies Directionality (RTL for Urdu) and exposes
/// the string table via [T.of].
class RetailerLocaleScope extends ConsumerWidget {
  final Widget child;
  const RetailerLocaleScope({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(retailerLocaleProvider).valueOrNull ?? RetailerLocale.en;
    return Directionality(
      textDirection:
          loc == RetailerLocale.ur ? TextDirection.rtl : TextDirection.ltr,
      child: _LocaleInherited(locale: loc, child: child),
    );
  }
}

class _LocaleInherited extends InheritedWidget {
  final String locale;
  const _LocaleInherited({required this.locale, required super.child});

  @override
  bool updateShouldNotify(_LocaleInherited old) => old.locale != locale;
}

/// String lookup. `T.of(context).signIn`
class T {
  final String locale;
  const T._(this.locale);

  static T of(BuildContext context) {
    final i = context.dependOnInheritedWidgetOfExactType<_LocaleInherited>();
    return T._(i?.locale ?? RetailerLocale.en);
  }

  bool get isUrdu => locale == RetailerLocale.ur;

  String _s(String en, String ur) => locale == RetailerLocale.ur ? ur : en;

  // ── Role picker ───────────────────────────────────────────────────────
  String get whoAreYou => _s('Who is signing in?', 'کون سائن اِن کر رہا ہے؟');
  String get staff => _s('Staff', 'اسٹاف');
  String get staffSub => _s('Sales, delivery, office', 'سیلز، ڈیلیوری، دفتر');
  String get retailer => _s('Retailer', 'دکاندار');
  String get retailerSub => _s('Place orders for your shop', 'اپنی دکان کے لیے آرڈر دیں');
  String get notYou => _s('Not you? Change', 'آپ نہیں؟ تبدیل کریں');

  // ── Retailer login ────────────────────────────────────────────────────
  String get retailerSignIn => _s('Retailer Sign In', 'دکاندار سائن اِن');
  String get yourCode => _s('Your code', 'آپ کا کوڈ');
  String get codeHint => _s('e.g. 767', 'مثلاً 767');
  String get password => _s('Password', 'پاس ورڈ');
  String get signIn => _s('Sign In', 'سائن اِن');
  String get enterCodeAndPassword =>
      _s('Enter your code and password', 'اپنا کوڈ اور پاس ورڈ درج کریں');
  String get noRetailerForCode =>
      _s('No retailer account found for that code.', 'اس کوڈ کے لیے کوئی اکاؤنٹ نہیں ملا۔');
  String get invalidCodeOrPassword =>
      _s('Invalid code or password.', 'کوڈ یا پاس ورڈ غلط ہے۔');
  String get askAdminForCode => _s(
      'Your code is on your shop account. Ask our team if you do not have it.',
      'آپ کا کوڈ آپ کے شاپ اکاؤنٹ پر ہے۔ اگر نہیں ہے تو ہماری ٹیم سے پوچھیں۔');

  // ── Password change ───────────────────────────────────────────────────
  String get setNewPassword => _s('Set a new password', 'نیا پاس ورڈ بنائیں');
  String get setNewPasswordSub => _s(
      'For your security, please change the password you were given.',
      'اپنی حفاظت کے لیے، دیا گیا پاس ورڈ تبدیل کریں۔');
  String get newPassword => _s('New password', 'نیا پاس ورڈ');
  String get confirmPassword => _s('Confirm password', 'پاس ورڈ کی تصدیق');
  String get passwordsDoNotMatch =>
      _s('Passwords do not match.', 'پاس ورڈ آپس میں نہیں ملتے۔');
  String get passwordTooShort =>
      _s('Use at least 6 characters.', 'کم از کم 6 حروف استعمال کریں۔');
  String get save => _s('Save', 'محفوظ کریں');

  // ── Common ────────────────────────────────────────────────────────────
  String get cancel => _s('Cancel', 'منسوخ');
  String get logout => _s('Log out', 'لاگ آؤٹ');
  String get somethingWentWrong =>
      _s('Something went wrong. Please try again.', 'کچھ غلط ہو گیا۔ دوبارہ کوشش کریں۔');
  String get retry => _s('Try again', 'دوبارہ کوشش کریں');
  String get close => _s('Close', 'بند کریں');

  // ── Nav ───────────────────────────────────────────────────────────────
  String get home => _s('Home', 'ہوم');
  String get orders => _s('Orders', 'آرڈرز');
  String get complaints => _s('Complaints', 'شکایات');
  String get files => _s('Files', 'فائلیں');
  String get updates => _s('Updates', 'اطلاعات');

  // ── Home ──────────────────────────────────────────────────────────────
  String get outstanding => _s('Outstanding balance', 'واجب الادا رقم');
  String get showAging => _s('Show aging', 'ایجنگ دیکھیں');
  String get hideAging => _s('Hide aging', 'ایجنگ چھپائیں');
  String get creditLimit => _s('Credit limit', 'کریڈٹ کی حد');
  String get noDues => _s('No dues. Thank you!', 'کوئی واجبات نہیں۔ شکریہ!');
  String get placeOrder => _s('Place Order', 'آرڈر دیں');
  String get overLimitTitle => _s('Over credit limit', 'کریڈٹ کی حد سے زیادہ');
  String get overLimitBody => _s(
      'Your account is over its credit limit. New orders may not be approved until payment is received.',
      'آپ کا اکاؤنٹ کریڈٹ کی حد سے تجاوز کر چکا ہے۔ ادائیگی تک نئے آرڈر منظور نہیں ہو سکتے۔');
  String get bucketCur => _s('0–30 days', '0–30 دن');
  String get bucket1 => _s('31–60 days', '31–60 دن');
  String get bucket2 => _s('61–90 days', '61–90 دن');
  String get bucket3 => _s('91–120 days', '91–120 دن');
  String get bucket4 => _s('Over 120 days', '120 دن سے زیادہ');

  // ── Orders ────────────────────────────────────────────────────────────
  String get noOrders => _s('No orders yet.', 'ابھی کوئی آرڈر نہیں۔');
  String get orderingSoon =>
      _s('Ordering is coming next.', 'آرڈر کی سہولت جلد آ رہی ہے۔');

  // ── Complaints ────────────────────────────────────────────────────────
  String get newComplaint => _s('New complaint', 'نئی شکایت');
  String get subject => _s('Subject', 'موضوع');
  String get subjectHint =>
      _s('e.g. Delivery is late', 'مثلاً ڈیلیوری دیر سے آئی');
  String get details => _s('Details (optional)', 'تفصیل (اختیاری)');
  String get send => _s('Send', 'بھیجیں');
  String get subjectRequired => _s('Please write a subject.', 'براہ کرم موضوع لکھیں۔');
  String get complaintSent =>
      _s('Complaint sent. We will get back to you.', 'شکایت بھیج دی گئی۔ ہم رابطہ کریں گے۔');
  String get noComplaints => _s('No complaints raised.', 'کوئی شکایت درج نہیں۔');
  String get resolved => _s('Resolved', 'حل ہو گیا');
  String get open_ => _s('Open', 'زیر التوا');

  // ── Files / Updates ───────────────────────────────────────────────────
  String get noFiles => _s('No files shared with you yet.', 'ابھی کوئی فائل شیئر نہیں کی گئی۔');
  String get noUpdates => _s('No updates.', 'کوئی اطلاع نہیں۔');
  String get couldNotOpen => _s('Could not open the file.', 'فائل نہیں کھل سکی۔');

  // ── Ordering ──────────────────────────────────────────────────────────
  String get searchProducts => _s('Search products…', 'پروڈکٹ تلاش کریں…');
  String get noProducts => _s(
      'No products available to you yet. Please contact our team.',
      'ابھی آپ کے لیے کوئی پروڈکٹ دستیاب نہیں۔ ہماری ٹیم سے رابطہ کریں۔');
  String get noMatches => _s('No products match your search.', 'تلاش سے کوئی پروڈکٹ نہیں ملا۔');
  String get cart => _s('Cart', 'ٹوکری');
  String get reviewOrder => _s('Review order', 'آرڈر دیکھیں');
  String get items => _s('items', 'اشیاء');
  String get item => _s('item', 'شے');
  String get total => _s('Total', 'کل');
  String get confirmOrder => _s('Confirm Order', 'آرڈر کی تصدیق کریں');
  String get cartEmpty => _s('Your cart is empty.', 'آپ کی ٹوکری خالی ہے۔');
  String get orderPlaced =>
      _s('Order placed. Our team will confirm it shortly.',
         'آرڈر موصول ہو گیا۔ ہماری ٹیم جلد تصدیق کرے گی۔');
  String get orderFailed =>
      _s('Could not place the order. Please try again.', 'آرڈر نہیں بھیجا جا سکا۔ دوبارہ کوشش کریں۔');
  String get branch => _s('Branch', 'برانچ');
  String get chooseBranch => _s('Choose a branch', 'برانچ منتخب کریں');
  String get remove => _s('Remove', 'ہٹا دیں');
  String get priceNote => _s(
      'Prices are indicative. Your order is confirmed by our team.',
      'قیمتیں تخمینی ہیں۔ آرڈر کی تصدیق ہماری ٹیم کرے گی۔');
  String get brands => _s('Brands', 'برانڈز');
  String get chooseBrand => _s('Choose a brand', 'برانڈ منتخب کریں');
  String get allBrands => _s('All brands', 'تمام برانڈز');
  String get products => _s('products', 'پروڈکٹس');
  String get quantity => _s('Quantity', 'مقدار');
  String get done => _s('Done', 'مکمل');

  // ── Order detail ──────────────────────────────────────────────────────
  String get orderSummary => _s('Order summary', 'آرڈر کی تفصیل');
  String get orderContents => _s('Items in this order', 'اس آرڈر کی اشیاء');
  String get unitPrice => _s('Unit price', 'فی یونٹ قیمت');

  // ── Ledger ────────────────────────────────────────────────────────────
  String get ledger => _s('Ledger', 'کھاتہ');
  String get ledgerUnavailable =>
      _s('Ledger is not available for your account.', 'آپ کے اکاؤنٹ کے لیے کھاتہ دستیاب نہیں۔');
  String get ledgerEmpty => _s('No ledger entries yet.', 'ابھی کوئی اندراج نہیں۔');
  String get totalDebit => _s('Total Debit', 'کل ڈیبٹ');
  String get totalCredit => _s('Total Credit', 'کل کریڈٹ');
  String get balance => _s('Balance', 'بقایا');
  String get balanceShort => _s('Bal', 'بقایا');

  // ── Schemes / Offers ──────────────────────────────────────────────────
  String get offers => _s('Offers', 'آفرز');
  String get offersOnOrder => _s('Offers on this order', 'اس آرڈر پر آفرز');
  String get availableOffers => _s('Available offers', 'دستیاب آفرز');
  String get checkingOffers => _s('Checking offers…', 'آفرز دیکھی جا رہی ہیں…');
  String get noOffers =>
      _s('No offers available for your current cart.', 'آپ کی موجودہ ٹوکری کے لیے کوئی آفر نہیں۔');
  String get offersNote => _s(
      'Offers are confirmed by our team when your order is processed.',
      'آفرز کی تصدیق آرڈر پروسیس ہونے پر ہماری ٹیم کرے گی۔');
  String get free => _s('Free', 'مفت');
  String get discount => _s('Discount', 'رعایت');
  String get specialPrice => _s('Special price', 'خصوصی قیمت');
  String get qualified => _s('In your cart', 'آپ کی ٹوکری میں');
  String _qtyStr(num n) {
    final d = n.toDouble();
    return d % 1 == 0 ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  String addMore(num n, String product) => _s(
      'Add ${_qtyStr(n)} more of $product', '$product مزید ${_qtyStr(n)} شامل کریں');
  String addAny(num n) => _s('Add ${_qtyStr(n)}+ of any item to unlock',
      'کوئی بھی چیز ${_qtyStr(n)}+ شامل کریں تاکہ آفر کھلے');
}

/// Small EN/اردو toggle. Placed on the login screens deliberately: a shopkeeper
/// who cannot read English needs the language switch BEFORE signing in, not
/// buried in a settings menu behind the login wall.
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = ref.watch(retailerLocaleProvider).valueOrNull ?? RetailerLocale.en;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      segments: const [
        ButtonSegment(value: RetailerLocale.en, label: Text('English')),
        ButtonSegment(value: RetailerLocale.ur, label: Text('اردو')),
      ],
      selected: {loc},
      onSelectionChanged: (s) =>
          ref.read(retailerLocaleProvider.notifier).set(s.first),
    );
  }
}
