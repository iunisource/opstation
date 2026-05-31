import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class _Quote {
  final String text;
  final String author;
  final String source;
  final String topic;
  const _Quote(this.text, this.author, this.source, this.topic);
}

// One quote per day (deterministic by date). Topics: Motivation, Discipline,
// Empathy, Team Work, Growth, Honesty. "Attributed" / "Traditional" are used
// where the precise source is commonly cited but not definitively documented.
// Edit freely — the homepage picks one per day by index.
const List<_Quote> _quotes = [
  // Motivation
  _Quote("It always seems impossible until it's done.", 'Nelson Mandela', 'Attributed', 'Motivation'),
  _Quote('The only way to do great work is to love what you do.', 'Steve Jobs', 'Stanford Commencement Address, 2005', 'Motivation'),
  _Quote("Believe you can and you're halfway there.", 'Theodore Roosevelt', 'Attributed', 'Motivation'),
  _Quote("Whether you think you can, or you think you can't — you're right.", 'Henry Ford', 'Attributed', 'Motivation'),
  _Quote('Start where you are. Use what you have. Do what you can.', 'Arthur Ashe', 'Attributed', 'Motivation'),
  // Discipline
  _Quote('We are what we repeatedly do. Excellence, then, is not an act, but a habit.', 'Will Durant', 'The Story of Philosophy', 'Discipline'),
  _Quote('Discipline is the bridge between goals and accomplishment.', 'Jim Rohn', 'Attributed', 'Discipline'),
  _Quote('Motivation is what gets you started. Habit is what keeps you going.', 'Jim Rohn', 'Attributed', 'Discipline'),
  _Quote('The successful warrior is the average man, with laser-like focus.', 'Bruce Lee', 'Attributed', 'Discipline'),
  _Quote('Discipline equals freedom.', 'Jocko Willink', 'Discipline Equals Freedom: Field Manual', 'Discipline'),
  // Empathy
  _Quote("Could a greater miracle take place than for us to look through each other's eyes for an instant?", 'Henry David Thoreau', 'Walden', 'Empathy'),
  _Quote('No one cares how much you know, until they know how much you care.', 'Theodore Roosevelt', 'Attributed', 'Empathy'),
  _Quote('Empathy is seeing with the eyes of another, listening with the ears of another, and feeling with the heart of another.', 'Alfred Adler', 'Attributed', 'Empathy'),
  _Quote('We rise by lifting others.', 'Robert Ingersoll', 'Attributed', 'Empathy'),
  // Team Work
  _Quote('Talent wins games, but teamwork and intelligence win championships.', 'Michael Jordan', 'Attributed', 'Team Work'),
  _Quote('Alone we can do so little; together we can do so much.', 'Helen Keller', 'Attributed', 'Team Work'),
  _Quote('Coming together is a beginning, staying together is progress, and working together is success.', 'Henry Ford', 'Attributed', 'Team Work'),
  _Quote('If you want to go fast, go alone. If you want to go far, go together.', 'African proverb', 'Traditional', 'Team Work'),
  _Quote('None of us is as smart as all of us.', 'Ken Blanchard', 'Attributed', 'Team Work'),
  // Growth
  _Quote('Growth is the only evidence of life.', 'John Henry Newman', 'Apologia Pro Vita Sua', 'Growth'),
  _Quote('Be not afraid of growing slowly, be afraid only of standing still.', 'Chinese proverb', 'Traditional', 'Growth'),
  _Quote('Without continual growth and progress, such words as improvement, achievement, and success have no meaning.', 'Benjamin Franklin', 'Attributed', 'Growth'),
  _Quote('Strength and growth come only through continuous effort and struggle.', 'Napoleon Hill', 'Attributed', 'Growth'),
  _Quote('The beautiful thing about learning is that no one can take it away from you.', 'B.B. King', 'Attributed', 'Growth'),
  // Honesty
  _Quote('Honesty is the first chapter in the book of wisdom.', 'Thomas Jefferson', 'Letter to Nathaniel Macon, 1819', 'Honesty'),
  _Quote('No legacy is so rich as honesty.', 'William Shakespeare', "All's Well That Ends Well", 'Honesty'),
  _Quote('Whoever is careless with the truth in small matters cannot be trusted with important matters.', 'Albert Einstein', 'Attributed', 'Honesty'),
  _Quote('Honesty is more than not lying. It is truth-telling, truth-speaking, truth-living, and truth-loving.', 'James E. Faust', 'Attributed', 'Honesty'),
  _Quote('The truth is rarely pure and never simple.', 'Oscar Wilde', 'The Importance of Being Earnest', 'Honesty'),
];

class ErpHomeScreen extends ConsumerWidget {
  const ErpHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final firstName = (user?.name ?? '').trim().split(' ').first;
    final now = DateTime.now();
    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    // Deterministic: same quote for everyone on a given calendar day, advancing daily.
    final dayIndex = DateTime(now.year, now.month, now.day)
        .difference(DateTime(2020, 1, 1))
        .inDays;
    final q = _quotes[dayIndex.abs() % _quotes.length];

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '$greeting${firstName.isEmpty ? '' : ', $firstName'}',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Pick a section from the menu above to get to work. Here is a thought for today.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 32),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Container(
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          q.topic.toUpperCase(),
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Icon(Icons.format_quote_rounded,
                          size: 44, color: AppTheme.primary.withOpacity(0.18)),
                    ]),
                    const SizedBox(height: 20),
                    Text(
                      '“${q.text}”',
                      style: const TextStyle(
                        fontSize: 24,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '— ${q.author}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary,
                      ),
                    ),
                    if (q.source.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        q.source,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
