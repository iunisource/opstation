import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart' show selectedBranchProvider;
import '../../../core/navigation/recent_screens.dart';
import '../../../core/permissions/permission_registry.dart';
import '../../auth/auth_controller.dart';

class _Quote {
  final String text;
  final String author;
  final String source;
  final String topic;
  const _Quote(this.text, this.author, this.source, this.topic);
}

// One quote per day (same for everyone, advancing daily); the arrows let the
// user read more. Quotes whose author isn't reliably documented show no name.
const List<_Quote> _quotes = [
  // Motivation
  _Quote("It always seems impossible until it's done.", '', '', 'Motivation'),
  _Quote('The only way to do great work is to love what you do.', 'Steve Jobs', 'Stanford Commencement Address, 2005', 'Motivation'),
  _Quote("Believe you can and you're halfway there.", '', '', 'Motivation'),
  _Quote("Whether you think you can, or you think you can't — you're right.", '', '', 'Motivation'),
  _Quote('Start where you are. Use what you have. Do what you can.', 'Arthur Ashe', '', 'Motivation'),
  // Discipline
  _Quote('We are what we repeatedly do. Excellence, then, is not an act, but a habit.', 'Will Durant', 'The Story of Philosophy', 'Discipline'),
  _Quote('Discipline is the bridge between goals and accomplishment.', 'Jim Rohn', '', 'Discipline'),
  _Quote('Motivation is what gets you started. Habit is what keeps you going.', 'Jim Rohn', '', 'Discipline'),
  _Quote('The successful warrior is the average man, with laser-like focus.', '', '', 'Discipline'),
  _Quote('Discipline equals freedom.', 'Jocko Willink', 'Discipline Equals Freedom: Field Manual', 'Discipline'),
  // Empathy
  _Quote("Could a greater miracle take place than for us to look through each other's eyes for an instant?", 'Henry David Thoreau', 'Walden', 'Empathy'),
  _Quote('No one cares how much you know, until they know how much you care.', '', '', 'Empathy'),
  _Quote('Empathy is seeing with the eyes of another, listening with the ears of another, and feeling with the heart of another.', '', '', 'Empathy'),
  _Quote('We rise by lifting others.', '', '', 'Empathy'),
  // Team Work
  _Quote('Talent wins games, but teamwork and intelligence win championships.', 'Michael Jordan', '', 'Team Work'),
  _Quote('Alone we can do so little; together we can do so much.', 'Helen Keller', '', 'Team Work'),
  _Quote('Coming together is a beginning, staying together is progress, and working together is success.', '', '', 'Team Work'),
  _Quote('If you want to go fast, go alone. If you want to go far, go together.', 'African proverb', 'Traditional', 'Team Work'),
  _Quote('None of us is as smart as all of us.', 'Ken Blanchard', '', 'Team Work'),
  // Growth
  _Quote('Growth is the only evidence of life.', 'John Henry Newman', 'Apologia Pro Vita Sua', 'Growth'),
  _Quote('Be not afraid of growing slowly, be afraid only of standing still.', 'Chinese proverb', 'Traditional', 'Growth'),
  _Quote('Without continual growth and progress, such words as improvement, achievement, and success have no meaning.', '', '', 'Growth'),
  _Quote('Strength and growth come only through continuous effort and struggle.', 'Napoleon Hill', '', 'Growth'),
  _Quote('The beautiful thing about learning is that no one can take it away from you.', 'B.B. King', '', 'Growth'),
  // Honesty
  _Quote('Honesty is the first chapter in the book of wisdom.', 'Thomas Jefferson', 'Letter to Nathaniel Macon, 1819', 'Honesty'),
  _Quote('No legacy is so rich as honesty.', 'William Shakespeare', "All's Well That Ends Well", 'Honesty'),
  _Quote('Whoever is careless with the truth in small matters cannot be trusted with important matters.', '', '', 'Honesty'),
  _Quote('Honesty is more than not lying. It is truth-telling, truth-speaking, truth-living, and truth-loving.', 'James E. Faust', '', 'Honesty'),
  _Quote('The truth is rarely pure and never simple.', 'Oscar Wilde', 'The Importance of Being Earnest', 'Honesty'),  // More (topics rotate so consecutive days differ)
  _Quote('The secret of getting ahead is getting started.', '', '', 'Motivation'),
  _Quote('Great things are done by a series of small things brought together.', 'Vincent van Gogh', 'Letter to Theo, 1882', 'Growth'),
  _Quote('Indeed, with hardship comes ease.', 'Qur\'an', 'Surah Ash-Sharh 94:6', 'Patience'),
  _Quote('Quality means doing it right when no one is looking.', '', '', 'Honesty'),
  _Quote('The best time to plant a tree was twenty years ago. The second best time is now.', 'Chinese proverb', 'Traditional', 'Motivation'),
  _Quote('Unity, Faith, Discipline.', 'Muhammad Ali Jinnah', '', 'Discipline'),
  _Quote('A good leader takes a little more than his share of the blame and a little less than his share of the credit.', 'Arnold H. Glasow', '', 'Leadership'),
  _Quote('The customer\'s perception is your reality.', '', '', 'Customers'),
  _Quote('Knowing is not enough; we must apply. Willing is not enough; we must do.', 'Johann Wolfgang von Goethe', 'Wilhelm Meister\'s Journeyman Years', 'Hard Work'),
  _Quote('Gratitude turns what we have into enough.', '', '', 'Gratitude'),
  _Quote('And that there is not for man except that for which he strives.', 'Qur\'an', 'Surah An-Najm 53:39', 'Hard Work'),
  _Quote('The journey of a thousand miles begins with a single step.', 'Lao Tzu', 'Tao Te Ching', 'Motivation'),
  _Quote('Well begun is half done.', 'Proverb', 'Traditional', 'Discipline'),
  _Quote('Be kind, for everyone you meet is fighting a hard battle.', '', '', 'Empathy'),
  _Quote('Many hands make light work.', 'Proverb', 'Traditional', 'Team Work'),
  _Quote('He who has a why to live can bear almost any how.', 'Friedrich Nietzsche', 'Twilight of the Idols', 'Patience'),
  _Quote('Genius is one percent inspiration and ninety-nine percent perspiration.', 'Thomas Edison', '', 'Hard Work'),
  _Quote('Small daily improvements over time lead to stunning results.', '', '', 'Growth'),
  _Quote('Your word is your bond.', 'Proverb', 'Traditional', 'Honesty'),
  _Quote('People don\'t care how much you know until they know how much you care.', '', '', 'Customers'),
  _Quote('Leadership is not about being in charge. It is about taking care of those in your charge.', '', '', 'Leadership'),
  _Quote('Focus on the step in front of you, not the whole staircase.', '', '', 'Focus'),
  _Quote('The man who moves a mountain begins by carrying away small stones.', 'Proverb', 'Traditional', 'Patience'),
  _Quote('Opportunities multiply as they are seized.', '', '', 'Motivation'),
  _Quote('Do the hard jobs first. The easy jobs will take care of themselves.', '', '', 'Discipline'),
  _Quote('Kind words can be short and easy to speak, but their echoes are truly endless.', '', '', 'Empathy'),
  _Quote('Teamwork divides the task and multiplies the success.', '', '', 'Team Work'),
  _Quote('The harder I work, the luckier I get.', '', '', 'Hard Work'),
  _Quote('Feeling gratitude and not expressing it is like wrapping a present and not giving it.', '', '', 'Gratitude'),
  _Quote('Where focus goes, energy flows.', '', '', 'Focus'),
  _Quote('A satisfied customer is the best business strategy of all.', '', '', 'Customers'),
  _Quote('Before you are a leader, success is all about growing yourself. When you become a leader, success is all about growing others.', 'Jack Welch', 'Winning', 'Leadership'),
  _Quote('It is not that we have a short time to live, but that we waste a lot of it.', 'Seneca', 'On the Shortness of Life', 'Discipline'),
  _Quote('Patience is not the ability to wait, but the ability to keep a good attitude while waiting.', '', '', 'Patience'),
  _Quote('An honest answer is the sign of true friendship.', 'Proverb', 'Traditional', 'Honesty'),
  _Quote('Don\'t watch the clock; do what it does. Keep going.', '', '', 'Motivation'),
  _Quote('Every expert was once a beginner.', '', '', 'Growth'),
  _Quote('Listen with the intent to understand, not the intent to reply.', '', '', 'Empathy'),
  _Quote('Individually, we are one drop. Together, we are an ocean.', '', '', 'Team Work'),
  _Quote('There is no substitute for hard work.', '', '', 'Hard Work'),
  _Quote('Starve your distractions, feed your focus.', '', '', 'Focus'),
  _Quote('It is not the employer who pays the wages. It is the customer.', '', '', 'Customers'),
  _Quote('The greatest leader is not the one who does the greatest things, but the one who gets people to do the greatest things.', '', '', 'Leadership'),
  _Quote('Gratitude is not only the greatest of virtues, but the parent of all the others.', 'Cicero', 'Pro Plancio', 'Gratitude'),
  _Quote('Success is the sum of small efforts, repeated day in and day out.', '', '', 'Discipline'),
  _Quote('Rivers know this: there is no hurry. We shall get there some day.', '', '', 'Patience'),
  _Quote('Integrity is doing the right thing, even when no one is watching.', '', '', 'Honesty'),
  _Quote('Act as if what you do makes a difference. It does.', '', '', 'Motivation'),
  _Quote('Mistakes are proof that you are trying.', '', '', 'Growth'),
  _Quote('Treat people the way you want to be treated.', '', '', 'Empathy'),
  _Quote('A team is not a group of people who work together. A team is a group of people who trust each other.', '', '', 'Team Work'),
  _Quote('Dreams don\'t work unless you do.', '', '', 'Hard Work'),
  _Quote('The main thing is to keep the main thing the main thing.', 'Stephen R. Covey', '', 'Focus'),
  _Quote('Make a customer, not a sale.', '', '', 'Customers'),
  _Quote('Lead by example, not by force.', '', '', 'Leadership'),
  _Quote('Count your blessings, not your problems.', '', '', 'Gratitude'),
  _Quote('Don\'t count the days, make the days count.', '', '', 'Discipline'),
  _Quote('Slow progress is still progress.', '', '', 'Patience'),
  _Quote('Truth never damages a cause that is just.', '', '', 'Honesty'),
  _Quote('The future depends on what you do today.', '', '', 'Motivation'),
  _Quote('Learn from yesterday, live for today, hope for tomorrow.', '', '', 'Growth'),
  _Quote('A little consideration, a little thought for others, makes all the difference.', '', '', 'Empathy'),
  _Quote('Great things in business are never done by one person. They\'re done by a team of people.', 'Steve Jobs', '', 'Team Work'),
  _Quote('Hard work beats talent when talent doesn\'t work hard.', '', '', 'Hard Work'),
  _Quote('You can do anything, but not everything.', '', '', 'Focus'),
  _Quote('Your most loyal customer is the one you treated well when something went wrong.', '', '', 'Customers'),
  _Quote('A leader is one who knows the way, goes the way, and shows the way.', '', '', 'Leadership'),
  _Quote('Be thankful for what you have; you\'ll end up having more.', '', '', 'Gratitude'),
  _Quote('Patience and persistence turn ordinary effort into extraordinary results.', '', '', 'Patience'),
  _Quote('Honesty saves everyone\'s time.', '', '', 'Honesty'),
  _Quote('Doubt kills more dreams than failure ever will.', '', '', 'Motivation'),
];

class ErpHomeScreen extends ConsumerStatefulWidget {
  const ErpHomeScreen({super.key});
  @override
  ConsumerState<ErpHomeScreen> createState() => _ErpHomeScreenState();
}

class _ErpHomeScreenState extends ConsumerState<ErpHomeScreen> {
  late int _qi;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _qi = DateTime(now.year, now.month, now.day).difference(DateTime(2020, 1, 1)).inDays.abs() % _quotes.length;
  }

  void _step(int d) => setState(() => _qi = (_qi + d) % _quotes.length);

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return 'Opened ${d.inMinutes} min ago';
    if (d.inHours < 24 && DateTime.now().day == t.day) return 'Opened ${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
    final y = DateTime.now().subtract(const Duration(days: 1));
    if (t.year == y.year && t.month == y.month && t.day == y.day) return 'Yesterday';
    return DateFormat('d MMM').format(t);
  }

  static const _tones = [
    Color(0xFFEEF4FF), Color(0xFFECFDF5), Color(0xFFFFF7ED), Color(0xFFF5F3FF),
    Color(0xFFFEF2F2), Color(0xFFF0F9FF), Color(0xFFFEFCE8), Color(0xFFF1F5F9),
  ];

  PermModule? _moduleOf(String path) {
    for (final m in kPermissionRegistry) {
      for (final it in m.items) {
        if (it.route == path) return m;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final branch = ref.watch(selectedBranchProvider);
    final firstName = (user?.name ?? '').trim().split(' ').first;
    final now = DateTime.now();
    final greeting = now.hour < 12 ? 'Good morning' : now.hour < 17 ? 'Good afternoon' : 'Good evening';
    final narrow = MediaQuery.of(context).size.width < 700;
    final q = _quotes[_qi];
    final recent = RecentScreens.read(user?.id).take(4).toList();
    final place = [
      if ((user?.orgName ?? '').isNotEmpty) user!.orgName!,
      if ((branch?['name'] as String? ?? '').isNotEmpty) branch!['name'] as String,
    ].join(' · ');

    final headerParts = <Widget>[
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('$greeting${firstName.isEmpty ? '' : ', $firstName'}',
              style: TextStyle(fontSize: narrow ? 24 : 30, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const SizedBox(height: 4),
          Text(DateFormat('EEEE, d MMMM y').format(now), style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
        ]),
        if (place.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: AppTheme.border)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.apartment_rounded, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(place, style: const TextStyle(fontSize: 12.5, color: Color(0xFF334155))),
            ]),
          ),
    ];
    // Greeting on the left, company · branch on the right (stacked on phones).
    final header = narrow
        ? Wrap(runSpacing: 10, spacing: 16, children: headerParts)
        : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: headerParts.first),
            if (headerParts.length > 1) headerParts[1],
          ]);

    final hero = Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(narrow ? 22 : 52, narrow ? 26 : 40, narrow ? 22 : 52, narrow ? 22 : 30),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.border),
        gradient: const RadialGradient(center: Alignment.topLeft, radius: 1.6, colors: [Color(0xFFEEF4FF), Colors.white], stops: [0, 0.55]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('THOUGHT FOR TODAY  ·  ${q.topic.toUpperCase()}',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: AppTheme.primary)),
        const SizedBox(height: 10),
        Text('“', style: TextStyle(fontFamily: 'Georgia', fontFamilyFallback: const ['Times New Roman', 'serif'], fontSize: narrow ? 56 : 80, height: 0.6, color: AppTheme.primary.withOpacity(0.18))),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Column(key: ValueKey(_qi), crossAxisAlignment: CrossAxisAlignment.start, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Text(q.text,
                  style: TextStyle(fontFamily: 'Georgia', fontFamilyFallback: const ['Times New Roman', 'serif'],
                      fontSize: narrow ? 22 : 32, height: 1.38, color: const Color(0xFF0F172A))),
            ),
            if (q.author.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('— ${q.author.toUpperCase()}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: AppTheme.primary)),
              if (q.source.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 3),
                    child: Text(q.source, style: const TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8), fontStyle: FontStyle.italic))),
            ],
          ]),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _roundBtn(Icons.chevron_left_rounded, 'Previous thought', () => _step(-1)),
            const SizedBox(width: 8),
            _roundBtn(Icons.chevron_right_rounded, 'Next thought', () => _step(1)),
          ]),
        ),
      ]),
    );

    final jump = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('Jump back in', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        SizedBox(width: 8),
        Flexible(child: Text('screens you opened recently', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))),
      ]),
      const SizedBox(height: 12),
      if (recent.isEmpty)
        const Text('Screens you open will show up here, so you can get back to them in one click.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))
      else
        LayoutBuilder(builder: (ctx, c) {
          final cols = c.maxWidth >= 1000 ? 4 : c.maxWidth >= 640 ? 2 : 1;
          final w = (c.maxWidth - 12 * (cols - 1)) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < recent.length; i++) SizedBox(width: w, child: _recentTile(recent[i], i)),
          ]);
        }),
    ]);

    return Container(
      color: AppTheme.background,
      child: LayoutBuilder(builder: (ctx, box) {
        // Breathing room above the greeting, and the quote card sitting near
        // the middle of the screen with "Jump back in" under it.
        final h = box.maxHeight.isFinite ? box.maxHeight : 800.0;
        // Greeting sits right under the top bar; the quote card well below it.
        final top = narrow ? 16.0 : 22.0;
        final gap = narrow ? 24.0 : (h * 0.14).clamp(36.0, 160.0);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(narrow ? 16 : 36, top, narrow ? 16 : 36, 36),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1240),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                header,
                SizedBox(height: gap),
                hero,
                const SizedBox(height: 36),
                jump,
              ]),
            ),
          ),
        );
      }),
    );
  }

  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: AppTheme.border)),
            child: Icon(icon, size: 20, color: const Color(0xFF475569)),
          ),
        ),
      );

  Widget _recentTile(RecentScreen r, int i) {
    final item = kRouteToPerm[r.path];
    final mod = _moduleOf(r.path);
    return InkWell(
      onTap: () => context.go(r.path),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(color: _tones[i % _tones.length], borderRadius: BorderRadius.circular(10)),
            child: Icon(mod?.icon ?? Icons.description_outlined, size: 19, color: AppTheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item?.label ?? r.path, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(_ago(r.at), style: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
            ]),
          ),
        ]),
      ),
    );
  }
}
