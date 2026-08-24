/// Broad, forgiving text search shared across the app.
///
/// Word-by-word (AND) matching: every whitespace-separated term in [query] must
/// appear somewhere in the target text — order and adjacency don't matter, and
/// it's case-insensitive. An empty query matches everything.
///
/// Example: query "alfa suzuki air" matches "ALA 104 - ALFA Air Filter Suzuki
/// Cultus" because all three words are present.
library;

/// Split a raw query into lower-cased search terms.
List<String> searchTerms(String query) => query
    .trim()
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((t) => t.isNotEmpty)
    .toList();

/// True if every term in [terms] appears somewhere in [haystack].
bool matchesTerms(String haystack, List<String> terms) {
  if (terms.isEmpty) return true;
  final h = haystack.toLowerCase();
  return terms.every(h.contains);
}

/// Convenience: true if [haystack] matches every word in the raw [query].
/// Pass the fields you want searchable joined by spaces, e.g.
///   matchesQuery('${p.name} ${p.sku} ${p.group}', query)
bool matchesQuery(String haystack, String query) =>
    matchesTerms(haystack, searchTerms(query));
