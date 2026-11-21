/// The key a place name is remembered under: a spot rounded to 3 decimals (about 100 m). A report names an
/// AREA ("Johar Town, Lahore"), so every point within the same ~100 m cell shares one name and one lookup:
/// a trip's start and end at the same depot, or shops on the same street, no longer ask the slow free
/// lookup again each time.
String placeKey(double lat, double lng) => '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';

/// The key names were saved under before (4 decimals, about 10 m). Names already saved that way are still read.
String placeKeyExact(double lat, double lng) => '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
