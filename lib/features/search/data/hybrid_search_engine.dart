import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../domain/interfaces.dart';
import '../../../domain/models.dart';
import '../domain/intent_expansion.dart';
import '../domain/person_mentions.dart';
import '../domain/search_tuning.dart';
import '../domain/text_matching.dart';

/// Hybrid retrieval: OCR text (FTS) + visual similarity (CLIP), fused, with
/// reliability thresholds and human-readable match reasons.
///
/// Flow: parse -> merge UI filters (UI wins) -> per-term text search and, when
/// available, vector search -> verify the top candidates against their stored
/// record (exact words, snippets) -> score and threshold -> collapse
/// near-duplicates -> results with [MatchReason]s.
///
/// Scoring (see [SearchTuning] for constants and rationale):
///  * text = IDF-weighted coverage of the literal query terms, each term
///    scored by presence (and bm25 within that). A term is also covered at
///    reduced weight when an expansion of a concept containing it matched
///    ("IBAN" covers "bank details").
///  * visual = cosine above an absolute floor, within a margin of the best
///    visual hit, rescaled to 0..1.
///  * final = text * textWeight + visual * visualWeight.
/// A result needs text evidence (an exact word match and a text score close
/// enough to the best text score) or visual evidence. Without either the
/// response is empty: the engine never returns "least bad" images.
class HybridSearchEngine implements SearchEngine {
  HybridSearchEngine({
    required this._store,
    required this._parser,
    required this._model,
    DateTime Function()? clock,
    this._expander = const IntentExpander(),
  }) : _clock = clock ?? DateTime.now;

  final IndexStore _store;
  final QueryParser _parser;
  final SemanticModel _model;
  final DateTime Function() _clock;
  final IntentExpander _expander;

  @override
  Future<SearchResponse> search(String query, {SearchFilters filters = SearchFilters.none}) async {
    final sw = Stopwatch()..start();
    final parsed = _parser.parse(query, now: _clock());
    final effective = SearchFilters(
      dateRange: filters.dateRange ?? parsed.dateRange,
      kinds: filters.kinds.isNotEmpty ? filters.kinds : {if (parsed.kind != null) parsed.kind!},
    );
    // People named in the query are required literal text and are never
    // sent to the image model (it cannot know who "Jamie" is).
    final people = [for (final n in PersonMentions.detect(query)) if (parsed.keywords.contains(n)) n];
    final visualText = [
      for (final w in parsed.semanticText.split(' '))
        if (w.isNotEmpty && !people.contains(w)) w,
    ].join(' ');
    final shown = ParsedQuery(
      raw: parsed.raw,
      semanticText: visualText,
      keywords: parsed.keywords,
      phrases: parsed.phrases,
      dateRange: effective.dateRange,
      kind: effective.kinds.length == 1 ? effective.kinds.first : null,
    );
    SearchResponse respond(List<SearchResult> results, {bool semantic = false}) =>
        SearchResponse(query: shown, results: results, elapsed: sw.elapsed, semanticSearchUsed: semantic);

    if (!parsed.hasContent) {
      if (effective.isEmpty) return respond(const []);
      return respond(await _browse(effective));
    }

    final stats = await _store.stats();
    final visualFuture = _visualHits(shown, effective, stats);
    final textFuture = _textHits(shown, effective);
    final visual = await visualFuture;
    final text = await textFuture;

    final results = await _rank(shown, effective, text, visual, stats, people);
    return respond(results, semantic: visual != null);
  }

  // ------------------------------------------------------------- retrieval

  Future<_TextRetrieval> _textHits(ParsedQuery q, SearchFilters f) async {
    final expansions = _expander.expand(q.keywords);
    const limit = SearchTuning.textLimitPerTerm;
    final termHits = Future.wait([
      for (final t in q.keywords) _store.searchText(terms: [t], filters: f, limit: limit),
    ]);
    final phraseHits = Future.wait([
      for (final p in q.phrases) _store.searchText(terms: const [], phrases: [p], filters: f, limit: limit),
    ]);
    final expansionHits = Future.wait([
      for (final e in expansions)
        e.isPhrase
            ? _store.searchText(terms: const [], phrases: [e.text], filters: f, limit: limit)
            : _store.searchText(terms: [e.text], filters: f, limit: limit),
    ]);
    return _TextRetrieval(
      terms: {for (final (i, hits) in (await termHits).indexed) q.keywords[i]: hits},
      phrases: {for (final (i, hits) in (await phraseHits).indexed) q.phrases[i]: hits},
      expansions: {for (final (i, hits) in (await expansionHits).indexed) expansions[i]: hits},
    );
  }

  /// Null when visual search is unavailable (model not loaded, no
  /// embeddings, nothing descriptive in the query, or the model failed).
  Future<List<VectorHit>?> _visualHits(ParsedQuery q, SearchFilters f, IndexStats stats) async {
    if (q.semanticText.trim().isEmpty || stats.imagesWithEmbedding == 0) return null;
    try {
      if (!_model.isLoaded && !await _model.load()) return null;
      final vector = await _model.embedText(visualPrompt(q.semanticText, f));
      return await _store.searchVector(vector, modelId: _model.modelId, filters: f, limit: SearchTuning.vectorLimit);
    } catch (e) {
      debugPrint('Visual search unavailable: $e');
      return null;
    }
  }

  /// Text fed to the CLIP text encoder. CLIP was trained on captions, so a
  /// caption-like prompt works better than bare keywords.
  @visibleForTesting
  static String visualPrompt(String semanticText, SearchFilters f) {
    final onlyScreenshots = f.kinds.length == 1 && f.kinds.first == ImageKind.screenshot;
    return onlyScreenshots ? 'a screenshot of $semanticText' : 'a photo of $semanticText';
  }

  // --------------------------------------------------------------- ranking

  Future<List<SearchResult>> _rank(
    ParsedQuery q,
    SearchFilters f,
    _TextRetrieval text,
    List<VectorHit>? visual,
    IndexStats stats,
    List<String> people,
  ) async {
    final cands = <String, _Candidate>{};
    _Candidate cand(String id) => cands.putIfAbsent(id, () => _Candidate(id));

    // IDF weight per literal unit (term or phrase).
    final maxDf = [
      for (final h in [...text.terms.values, ...text.phrases.values, ...text.expansions.values]) h.length,
    ].fold<int>(1, math.max);
    final n = math.max(stats.indexedImages, maxDf * 2);
    double idf(int df) => math.log(1 + n / math.max(df, 1));

    final weights = <String, double>{};
    for (final e in text.terms.entries) {
      weights[e.key] = idf(e.value.length);
      _collect(e.value, (id, strength, hit) => cand(id).literal[e.key] = _TermMatch(strength, hit.snippet));
    }
    for (final e in text.phrases.entries) {
      weights['"${e.key}"'] = idf(e.value.length);
      _collect(e.value, (id, strength, hit) => cand(id).literal['"${e.key}"'] = _TermMatch(strength, hit.snippet));
    }
    for (final e in text.expansions.entries) {
      _collect(e.value, (id, strength, hit) => cand(id).expansions[e.key] = _TermMatch(strength, hit.snippet));
    }

    // Quoted phrases are required.
    Set<String>? allowed;
    for (final hits in text.phrases.values) {
      final ids = {for (final h in hits) h.imageId};
      allowed = allowed == null ? ids : allowed.intersection(ids);
    }

    // Visual evidence with absolute floor + margin to the best hit.
    if (visual != null && visual.isNotEmpty) {
      final best = visual.map((h) => h.similarity).reduce(math.max);
      for (final h in visual) {
        if (h.similarity < SearchTuning.visualFloor) continue;
        if (h.similarity < best - SearchTuning.visualMargin) continue;
        final c = cand(h.imageId);
        c.visualSimilarity = h.similarity;
        c.visualScore = ((h.similarity - SearchTuning.visualFloor) /
                (SearchTuning.visualFull - SearchTuning.visualFloor))
            .clamp(0.0, 1.0);
      }
    }

    // Named people are required: only images whose text contains the name.
    for (final name in people) {
      final ids = {for (final h in text.terms[name] ?? const <TextHit>[]) h.imageId};
      allowed = allowed == null ? ids : allowed.intersection(ids);
    }

    if (allowed != null) cands.removeWhere((id, _) => !allowed!.contains(id));
    if (cands.isEmpty) return const [];

    // Provisional ranking, then verify the top candidates on their records.
    final totalWeight = weights.values.fold<double>(0, (a, b) => a + b);
    for (final c in cands.values) {
      c.score = _score(c, q, weights, totalWeight);
    }
    final ordered = cands.values.toList()..sort((a, b) => b.score.compareTo(a.score));
    final top = ordered.take(SearchTuning.verifyTopK).toList();
    final records = await Future.wait(top.map((c) => _store.get(c.id)));
    final verified = <_Candidate>[];
    for (var i = 0; i < top.length; i++) {
      final r = records[i];
      if (r == null) continue; // deleted since it was indexed
      final c = top[i]..record = r;
      _verify(c);
      // The name must really be a word of the recognised text (not just a
      // prefix, not only the file name).
      if (people.any((n) => !(c.literal[n]?.inOcr ?? false))) continue;
      c.score = _score(c, q, weights, totalWeight);
      verified.add(c);
    }

    // Text evidence must contain at least one exact word and be close to the
    // best text score; visual evidence was thresholded above.
    final bestText = verified.where((c) => c.hasExactText).map((c) => c.textScore).fold<double>(0, math.max);
    for (final c in verified) {
      c.textAccepted =
          c.hasExactText && c.textScore > 0 && c.textScore >= SearchTuning.textRelativeCut * bestText;
    }
    // When some image covers every query term in its text (literally or via
    // an expansion such as IBAN for "bank details"), an image with visual
    // evidence only must be clearly similar, not just above the floor.
    final strongText = verified.any((c) => c.textAccepted && _coversAllTerms(c, weights.keys));
    final accepted = <_Candidate>[];
    for (final c in verified) {
      if (!c.textAccepted) {
        final sim = c.visualSimilarity;
        if (sim == null) continue;
        if (strongText && sim < SearchTuning.visualOnlyFloorWithStrongText) continue;
      }
      c.score = (c.textAccepted ? SearchTuning.textWeight * c.textScore : 0) +
          (c.visualSimilarity != null ? SearchTuning.visualWeight * c.visualScore : 0);
      accepted.add(c);
    }
    accepted.sort((a, b) => b.score.compareTo(a.score));

    final kept = _collapse(accepted, (c) => c.record!);
    return [
      for (final c in kept.take(SearchTuning.maxResults))
        SearchResult(image: c.record!.image, score: c.score, reasons: _reasons(c, q, f)),
    ];
  }

  /// Every literal term/phrase matched as a whole word, or covered by an
  /// exactly matched expansion of a concept containing it.
  static bool _coversAllTerms(_Candidate c, Iterable<String> keys) {
    for (final k in keys) {
      if (c.literal[k]?.exact ?? false) continue;
      final viaExpansion =
          c.expansions.entries.any((x) => x.value.exact && x.key.concept.split(' ').contains(k));
      if (!viaExpansion) return false;
    }
    return keys.isNotEmpty;
  }

  static void _collect(List<TextHit> hits, void Function(String id, double strength, TextHit hit) add) {
    if (hits.isEmpty) return;
    final best = hits.map((h) => h.score).reduce(math.max);
    for (final h in hits) {
      final rel = best > 0 ? (h.score / best).clamp(0.0, 1.0) : 1.0;
      add(h.imageId, SearchTuning.termStrengthFloor + (1 - SearchTuning.termStrengthFloor) * rel, h);
    }
  }

  /// IDF-weighted coverage of literal terms/phrases; a term not found
  /// literally may be covered by a matched expansion of a concept that
  /// contains it, at [SearchTuning.expansionWeight].
  double _score(_Candidate c, ParsedQuery q, Map<String, double> weights, double totalWeight) {
    var covered = 0.0;
    for (final e in weights.entries) {
      var s = c.literal[e.key]?.strength ?? 0.0;
      for (final x in c.expansions.entries) {
        if (x.key.concept.split(' ').contains(e.key)) {
          s = math.max(s, SearchTuning.expansionWeight * x.value.strength);
        }
      }
      covered += e.value * s;
    }
    c.textScore = totalWeight > 0 ? covered / totalWeight : 0;
    return SearchTuning.textWeight * c.textScore + SearchTuning.visualWeight * c.visualScore;
  }

  /// Checks text matches against the stored OCR text / filename: whole-word
  /// (or plural) matches keep full strength, prefix-only matches are weakened.
  void _verify(_Candidate c) {
    final r = c.record!;
    final ocrWords = TextMatching.words(r.ocrText);
    final nameWords = TextMatching.words(_filenameStem(r.image.filename));
    final ocrNorm = TextMatching.normalize(r.ocrText);
    c.hasExactText = false;
    void check(String key, _TermMatch m, {required bool isPhrase}) {
      final term = isPhrase ? key.replaceAll('"', '') : key;
      if (isPhrase) {
        m.inOcr = TextMatching.containsPhrase(ocrNorm, term);
        m.exact = true; // the store matched it verbatim
      } else {
        m.inOcr = TextMatching.hasWord(ocrWords, term);
        m.inFilename = !m.inOcr && TextMatching.hasWord(nameWords, term);
        m.exact = m.inOcr || m.inFilename;
      }
      if (!m.exact) m.strength *= SearchTuning.prefixOnlyPenalty;
      if (m.exact) c.hasExactText = true;
    }

    for (final e in c.literal.entries) {
      check(e.key, e.value, isPhrase: e.key.startsWith('"'));
    }
    for (final e in c.expansions.entries) {
      check(e.key.text, e.value, isPhrase: e.key.isPhrase);
    }
  }

  static String _filenameStem(String? name) {
    if (name == null) return '';
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name).replaceAll(RegExp(r'[_\-.]+'), ' ');
  }

  // --------------------------------------------------------------- browse

  Future<List<SearchResult>> _browse(SearchFilters f) async {
    final images = await _store.browse(filters: f, limit: SearchTuning.maxResults * 2);
    if (images.isEmpty) return const [];
    final records = await Future.wait(images.map((i) => _store.get(i.id)));
    final entries = <({GalleryImage image, IndexRecord? record})>[
      for (var i = 0; i < images.length; i++) (image: images[i], record: records[i]),
    ];
    final kept = _collapse(entries, (e) => e.record);
    final shown = kept.take(SearchTuning.maxResults).toList();
    final q = ParsedQuery(raw: '', semanticText: '', keywords: const [], dateRange: f.dateRange);
    return [
      for (final (i, e) in shown.indexed)
        SearchResult(
          image: e.image,
          score: 1 - i / shown.length,
          reasons: _filterReasons(e.image, q, f),
        ),
    ];
  }

  // ------------------------------------------------------- near-duplicates

  /// Keeps the first (best) of each group of near-duplicates: dHash within
  /// [SearchTuning.nearDuplicateBits] AND (taken within the burst window OR
  /// identical recognised text).
  static List<T> _collapse<T>(List<T> ranked, IndexRecord? Function(T) recordOf) {
    final kept = <T>[];
    final keptRecords = <IndexRecord>[];
    for (final item in ranked) {
      final r = recordOf(item);
      if (r != null && r.perceptualHash != null && keptRecords.any((k) => isNearDuplicate(k, r))) continue;
      kept.add(item);
      if (r != null) keptRecords.add(r);
    }
    return kept;
  }

  @visibleForTesting
  static bool isNearDuplicate(IndexRecord a, IndexRecord b) {
    final ha = a.perceptualHash;
    final hb = b.perceptualHash;
    if (ha == null || hb == null) return false;
    if (_hamming(ha, hb) > SearchTuning.nearDuplicateBits) return false;
    final dt = a.image.createdAt.difference(b.image.createdAt).abs();
    if (dt <= SearchTuning.burstWindow) return true;
    final ta = TextMatching.normalize(a.ocrText);
    return ta.isNotEmpty && ta == TextMatching.normalize(b.ocrText);
  }

  static int _hamming(int a, int b) {
    var x = a ^ b;
    var count = 0;
    while (x != 0) {
      x &= x - 1;
      count++;
    }
    return count;
  }

  // --------------------------------------------------------------- reasons

  List<MatchReason> _reasons(_Candidate c, ParsedQuery q, SearchFilters f) {
    final reasons = <MatchReason>[];
    final r = c.record!;
    if (c.textAccepted) {
      final inOcr = [
        for (final e in c.literal.entries)
          if (e.value.exact && e.value.inOcr) e.key.replaceAll('"', ''),
      ];
      final inName = [
        for (final e in c.literal.entries)
          if (e.value.exact && e.value.inFilename) e.key,
      ];
      if (inOcr.isNotEmpty) {
        reasons.add(MatchReason(
          signal: MatchSignal.textInImage,
          description: 'Contains the text ${_quoteList(inOcr)}',
          matchedTerms: inOcr,
          snippet: TextMatching.snippet(r.ocrText, inOcr, radius: SearchTuning.snippetRadius) ??
              _storeSnippet(c, inOcr),
          strength: c.textScore.clamp(0.0, 1.0),
        ));
      }
      if (inName.isNotEmpty) {
        reasons.add(MatchReason(
          signal: MatchSignal.filename,
          description: 'File name contains ${_quoteList(inName)}',
          matchedTerms: inName,
        ));
      }
      final byConcept = <String, List<String>>{};
      for (final e in c.expansions.entries) {
        if (e.value.exact && e.value.inOcr) (byConcept[e.key.concept] ??= []).add(e.key.text);
      }
      for (final e in byConcept.entries) {
        reasons.add(MatchReason(
          signal: MatchSignal.textInImage,
          description: 'Mentions ${_quoteList(e.value)} (related to “${e.key}”)',
          matchedTerms: e.value,
          snippet: inOcr.isEmpty ? TextMatching.snippet(r.ocrText, e.value, radius: SearchTuning.snippetRadius) : null,
        ));
      }
    }
    if (c.visualSimilarity != null) {
      reasons.add(MatchReason(
        signal: MatchSignal.visualContent,
        description: 'Visually similar to “${q.semanticText}”',
        matchedTerms: [q.semanticText],
        strength: c.visualScore,
      ));
    }
    reasons.addAll(_filterReasons(r.image, q, f));
    return reasons;
  }

  static String? _storeSnippet(_Candidate c, List<String> terms) {
    for (final t in terms) {
      final s = c.literal[t]?.storeSnippet ?? c.literal['"$t"']?.storeSnippet;
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  List<MatchReason> _filterReasons(GalleryImage image, ParsedQuery q, SearchFilters f) => [
        if (f.dateRange != null && f.dateRange!.contains(image.createdAt))
          MatchReason(signal: MatchSignal.date, description: describeDateRange(f.dateRange!)),
        if (f.kinds.length == 1 && image.kind == ImageKind.screenshot)
          const MatchReason(signal: MatchSignal.imageType, description: 'Screenshot'),
        if (f.kinds.length == 1 && image.kind == ImageKind.photo)
          const MatchReason(signal: MatchSignal.imageType, description: 'Photo'),
      ];

  /// "Taken in Summer 2025", "Taken yesterday", "Taken in the last 30 days".
  @visibleForTesting
  static String describeDateRange(DateRange r) {
    final label = r.label.trim();
    if (label.isEmpty) return 'Taken in the selected period';
    final lower = label[0].toLowerCase() + label.substring(1);
    if (RegExp(r'^(today|yesterday|this |last (week|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)$)',
                caseSensitive: false)
            .hasMatch(lower) ||
        RegExp(r'^(about|around|a few|a couple) ').hasMatch(lower) ||
        RegExp(r'^\d+ days ago$').hasMatch(lower)) {
      return 'Taken $lower';
    }
    if (RegExp(r'^(last|past) ').hasMatch(lower)) return 'Taken in the $lower';
    return 'Taken in $label';
  }

  static String _quoteList(List<String> terms) {
    final q = terms.map((t) => '“$t”').toList();
    if (q.length == 1) return q.first;
    return '${q.sublist(0, q.length - 1).join(', ')} and ${q.last}';
  }
}

class _TextRetrieval {
  _TextRetrieval({required this.terms, required this.phrases, required this.expansions});
  final Map<String, List<TextHit>> terms;
  final Map<String, List<TextHit>> phrases;
  final Map<Expansion, List<TextHit>> expansions;
}

class _TermMatch {
  _TermMatch(this.strength, this.storeSnippet);
  double strength;
  final String? storeSnippet;
  bool exact = false;
  bool inOcr = false;
  bool inFilename = false;
}

class _Candidate {
  _Candidate(this.id);
  final String id;

  /// Literal query terms, and quoted phrases keyed as `"phrase"`.
  final Map<String, _TermMatch> literal = {};
  final Map<Expansion, _TermMatch> expansions = {};
  double? visualSimilarity;
  double visualScore = 0;
  double textScore = 0;
  double score = 0;
  bool hasExactText = false;
  bool textAccepted = false;
  IndexRecord? record;
}
