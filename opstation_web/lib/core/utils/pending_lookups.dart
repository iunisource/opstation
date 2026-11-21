/// Runs one lookup per key at a time: asked again while it is still running, the caller gets the SAME
/// answer instead of starting a second one. When it finishes (with an answer or an error) the key is
/// free again.
///
/// The clean-up uses a block body on purpose. An arrow body (`() => _pending.remove(key)`) would return
/// the pending lookup itself, and `whenComplete` waits for a returned future: the lookup would wait for
/// itself and never finish. That is what made every first place-name lookup run out its whole time
/// limit, so reports waited 10+ seconds and showed only coordinates.
class PendingLookups<T> {
  final Map<String, Future<T>> _pending = {};

  bool isRunning(String key) => _pending.containsKey(key);

  Future<T> run(String key, Future<T> Function() job) {
    final running = _pending[key];
    if (running != null) return running;
    final f = job().whenComplete(() {
      _pending.remove(key);
    });
    _pending[key] = f;
    return f;
  }
}
