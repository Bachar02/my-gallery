import 'dart:math' as math;
import 'dart:typed_data';

/// Returns an L2-normalised copy of [v]. Throws [StateError] for a zero or
/// non-finite vector (a broken model output must not reach the index).
Float32List l2Normalized(List<double> v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = math.sqrt(sum);
  if (!norm.isFinite || norm == 0) {
    throw StateError('Embedding has zero or non-finite norm');
  }
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] / norm;
  }
  return out;
}

double dot(List<double> a, List<double> b) {
  assert(a.length == b.length);
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// Cosine similarity (does not assume normalised inputs).
double cosine(List<double> a, List<double> b) {
  final d = math.sqrt(dot(a, a) * dot(b, b));
  return d == 0 ? 0 : dot(a, b) / d;
}
