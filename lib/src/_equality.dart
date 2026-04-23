/// Internal equality helpers for value types.
///
/// Kept in one place so we don't drag in `package:collection` for the
/// ~15 lines of logic shared across ~13 value types.
library;

/// Element-wise equality for two lists, tolerating null on either side.
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Element-wise equality for two maps, tolerating null on either side.
///
/// Shallow comparison — map values must themselves implement `==` if
/// deep equality is wanted.
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
