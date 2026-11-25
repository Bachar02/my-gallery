import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../domain/interfaces.dart';
import '../../../domain/models.dart';
import '../domain/intent_expansion.dart';
import '../domain/query_analyzer.dart';
import '../domain/query_lexicon.dart';
import '../domain/search_tuning.dart';
import '../domain/text_matching.dart';
import '../domain/visual_calibration.dart';
import 'rule_based_query_parser.dart';

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
    this._analyzer = const QueryAnalyzer(),
  }) : _clock = clock ?? DateTime.now;

  final IndexStore _store;
  final QueryParser _parser;
  final SemanticModel _model;
  final DateTime Function() _clock;
  final IntentExpander _expander;
  final QueryAnalyzer _analyzer;

  VisualCalibration get _cal => VisualCalibration.forModel(_model.modelId);

  @override
  Future<SearchResponse> search(String query, {SearchFilters filters = SearchFilters.none}) async {
    final sw = Stopwatch()..start();
    final parsed = _parser.parse(query, now: _clock());
    final plan = _analyzer.analyze(_capped(query), parsed);
    final effective = SearchFilters(
      dateRange: filters.dateRange ?? parsed.dateRange,
      kinds: filters.kinds.isNotEmpty ? filters.kinds : {if (parsed.kind != null) parsed.kind!},
    );
    final shown = ParsedQuery(
      raw: parsed.raw,
      semanticText: plan.visualPhrase,
      keywords: parsed.keywords,
      phrases: parsed.phrases,
      dateRange: effective.dateRange,
      kind: effective.kinds.length == 1 ? effective.kinds.first : null,
    );
    // semanticSearchUsed reports whether visual search is AVAILABLE (model
    // loaded and images embedded), not whether this particular query used
    // it; the UI uses it to say "text-only search".
    final stats = await _store.stats();
    final semanticAvailable = await _semanticAvailable(stats);
    final intent = switch (plan.intent) {
      QueryIntent.visual => SearchIntent.visual,
      QueryIntent.text => SearchIntent.text,
      QueryIntent.conversation => SearchIntent.conversation,
      QueryIntent.hybrid => SearchIntent.hybrid,
      QueryIntent.filterOnly => SearchIntent.filterOnly,
      QueryIntent.empty => SearchIntent.none,
    };
    final planDetails = [
      ScoreDetail('intent', plan.intent.name),
      if (plan.head != null) ScoreDetail('head noun', plan.head!),
      if (plan.modifiers.isNotEmpty) ScoreDetail('modifiers', plan.modifiers.join(', ')),
      if (plan.visualPhrase.isNotEmpty) ScoreDetail('visual phrase', plan.visualPhrase),
      if (plan.textTerms.isNotEmpty) ScoreDetail('text terms', plan.textTerms.join(', ')),
      if (plan.screenType != null) ScoreDetail('screen type', plan.screenType!.name),
      if (plan.person != null) ScoreDetail('person', plan.person!),
      ScoreDetail('visual model', semanticAvailable ? _model.modelId : 'unavailable'),
    ];
    SearchResponse respond(List<SearchResult> results, {String? mentionsLabel}) => SearchResponse(
        query: shown,
        results: results,
        elapsed: sw.elapsed,
        semanticSearchUsed: semanticAvailable,
        intent: intent,
        mentionsLabel: mentionsLabel,
        details: planDetails);

    switch (plan.intent) {
      case QueryIntent.empty:
        return respond(const []);
      case QueryIntent.filterOnly:
        return respond(await _browse(effective));
      case QueryIntent.conversation:
        final (primary, mentions) = await _conversation(plan, effective);
        return respond([...primary, ...mentions], mentionsLabel: 'Mentions ${_display(plan.person!, query)}');
      case QueryIntent.visual when semanticAvailable:
        return respond(await _visual(plan, effective, stats));
      case QueryIntent.hybrid when plan.screenType != null || plan.wantsScreenshot && plan.head != null &&
          kVisualNouns.contains(plan.head):
        return respond(await _screens(plan, effective, stats, semanticAvailable));
      // Text-only mode (no model or no embeddings yet): a visual query can
      // only be answered from recognised text; the UI says so.
      case QueryIntent.visual:
      case QueryIntent.text:
      case QueryIntent.hybrid:
        final visualFuture = semanticAvailable ? _visualHits(shown, effective, stats) : Future.value(null);
        final textFuture = _textHits(shown, effective);
        final visual = await visualFuture;
        final text = await textFuture;
        final results = await _rank(shown, effective, text, visual, stats, const [],
            textCentric: true, intentDetail: plan.intent.name);
        return respond(results);
    }
  }

  /// The person's name as the user typed it ("Jamie" for "jamie").
  static String _display(String name, String raw) {
    final m = RegExp(RegExp.escape(name), caseSensitive: false).firstMatch(raw);
    final typed = m?[0] ?? name;
    return typed[0].toUpperCase() + typed.substring(1);
  }

  static String _capped(String q) => q.length > RuleBasedQueryParser.maxQueryChars
      ? q.substring(0, RuleBasedQueryParser.maxQueryChars)
      : q;

  Future<bool> _semanticAvailable(IndexStats stats) async {
    if (stats.imagesWithEmbedding == 0) return false;
    try {
      return _model.isLoaded || await _model.load();
    } catch (_) {
      return false;
    }
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
      final onlyScreenshots = f.kinds.length == 1 && f.kinds.first == ImageKind.screenshot;
      final vector = await _queryVector(q.semanticText, screenshot: onlyScreenshots);
      return await _store.searchVector(vector, modelId: _model.modelId, filters: f, limit: SearchTuning.vectorLimit);
    } catch (e) {
      debugPrint('Visual search unavailable: $e');
      return null;
    }
  }

  /// Captions fed to the text encoder for [phrase]: the calibrated prompt
  /// ensemble (image-text models are trained on captions, and averaging
  /// several phrasings is more robust than any single one).
  @visibleForTesting
  static List<String> visualPrompts(String phrase, VisualCalibration cal, {required bool screenshot}) => [
        for (final t in screenshot ? cal.screenPrompts : cal.photoPrompts) t.replaceAll('{}', phrase),
      ];

  /// Mean of the prompt embeddings, L2-normalised.
  Future<Float32List> _queryVector(String phrase, {required bool screenshot}) async {
    final prompts = visualPrompts(phrase, _cal, screenshot: screenshot);
    Float32List? sum;
    for (final p in prompts) {
      final v = await _model.embedText(p);
      sum ??= Float32List(v.length);
      for (var i = 0; i < v.length; i++) {
        sum[i] += v[i];
      }
    }
    final out = sum!;
    var n = 0.0;
    for (final x in out) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n > 0) {
      for (var i = 0; i < out.length; i++) {
        out[i] /= n;
      }
    }
    return out;
  }

  // --------------------------------------------------------------- ranking

  Future<List<SearchResult>> _rank(
    ParsedQuery q,
    SearchFilters f,
    _TextRetrieval text,
    List<VectorHit>? visual,
    IndexStats stats,
    List<String> people, {
    required bool textCentric,
    String intentDetail = 'text',
  }) async {
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
        if (h.similarity < _cal.floor) continue;
        if (h.similarity < best - _cal.margin) continue;
        final c = cand(h.imageId);
        c.visualSimilarity = h.similarity;
        c.visualScore = _cal.strength(h.similarity);
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
      _verify(c, q.keywords);
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
    // When some image contains every query word literally, an image that
    // matches only through expansions must match at least
    // [SearchTuning.minExpansionsWithFullLiteral] different expansion terms or
    // one decisive term: one "flight" in a chat is not a boarding pass, but
    // gate + flight + departure is, and a lone IBAN is still bank details.
    final fullLiteral = verified.any((c) => c.textAccepted && _coversAllTerms(c, weights.keys, literalOnly: true));
    if (fullLiteral) {
      for (final c in verified) {
        if (!c.textAccepted || c.literal.values.any((m) => m.exact)) continue;
        final exact = [for (final e in c.expansions.entries) if (e.value.exact) e.key];
        if (exact.any((e) => e.decisive)) continue;
        if (exact.length < SearchTuning.minExpansionsWithFullLiteral) c.textAccepted = false;
      }
    }
    // Text-centric intents (password, bank details, ticket...) with no text
    // evidence anywhere: CLIP scores text-like screenshots ~0.2 for these, so
    // a visual-only result needs the strong floor.
    // Text and unknown-noun queries are answered by recognised text; a
    // visual-only result must be a clear visual match (visual queries take
    // the visual route instead).
    final anyText = verified.any((c) => c.textAccepted);
    final strictVisual = strongText || textCentric || !anyText;
    final accepted = <_Candidate>[];
    for (final c in verified) {
      if (!c.textAccepted) {
        final sim = c.visualSimilarity;
        if (sim == null) continue;
        if (strictVisual && sim < _cal.strictFloor) continue;
      }
      c.score = (c.textAccepted ? SearchTuning.textWeight * c.textScore : 0) +
          (c.visualSimilarity != null ? SearchTuning.visualWeight * c.visualScore : 0);
      accepted.add(c);
    }
    accepted.sort((a, b) => b.score.compareTo(a.score));

    final kept = _collapse(accepted, (c) => c.record!);
    return [
      for (final c in kept.take(SearchTuning.maxResults))
        SearchResult(image: c.record!.image, score: c.score, reasons: _reasons(c, q, f), details: [
          ScoreDetail('route', intentDetail),
          ScoreDetail('text score', c.textScore.toStringAsFixed(3)),
          ScoreDetail('text accepted', '${c.textAccepted}'),
          if (c.visualSimilarity != null) ScoreDetail('visual cosine', c.visualSimilarity!.toStringAsFixed(3)),
          if (!c.textAccepted) ScoreDetail('visual-only floor', _cal.strictFloor.toStringAsFixed(3)),
          ScoreDetail('final', c.score.toStringAsFixed(3)),
        ]),
    ];
  }

  /// Every literal term/phrase matched as a whole word, or covered by an
  /// exactly matched expansion of a concept containing it.
  static bool _coversAllTerms(_Candidate c, Iterable<String> keys, {bool literalOnly = false}) {
    for (final k in keys) {
      if (c.literal[k]?.exact ?? false) continue;
      if (literalOnly) return false;
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
  void _verify(_Candidate c, List<String> terms) {
    final r = c.record!;
    final ocrWords = TextMatching.words(r.ocrText);
    final nameWords = TextMatching.words(_filenameStem(r.image.filename));
    // The store matches prefixes, so "passes" does not find "PASS". Credit
    // whole-word singular/plural matches it missed, at the base strength.
    for (final t in terms) {
      if (c.literal.containsKey(t)) continue;
      if (TextMatching.hasWord(ocrWords, t) || TextMatching.hasWord(nameWords, t)) {
        c.literal[t] = _TermMatch(SearchTuning.termStrengthFloor, null);
      }
    }
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

  // ---------------------------------------------------------------- visual

  /// Visual queries: the image model decides. Candidates come only from the
  /// vector index; recognised text can raise the score of an image that
  /// already matches visually, never add one.
  ///
  /// Adjusted cosine = cosine - penalties:
  ///  * UI screenshot for a query that did not ask for screenshots;
  ///  * the head noun printed in the image of a people query or a screenshot
  ///    (CLIP-family models read text: "MEN" looks like "a man").
  /// People queries also need a detected face when faces were counted, and
  /// never return UI screenshots unless asked to.
  /// Kept: adjusted >= floor and >= best adjusted - margin.
  Future<List<SearchResult>> _visual(QueryPlan plan, SearchFilters f, IndexStats stats) async {
    final phrase = plan.visualPhrase.isNotEmpty ? plan.visualPhrase : (plan.head ?? '');
    if (phrase.isEmpty) return const [];
    final List<VectorHit> hits;
    try {
      final vector = await _queryVector(phrase, screenshot: plan.wantsScreenshot);
      hits = await _store.searchVector(vector, modelId: _model.modelId, filters: f, limit: SearchTuning.vectorLimit);
    } catch (e) {
      debugPrint('Visual search unavailable: ${e.runtimeType}');
      return const [];
    }
    final cal = _cal;
    // Penalties only lower a cosine, so a hit below the floor stays below
    // it: only plausible candidates are loaded.
    final floor = plan.peopleSubject ? cal.peopleFloor : cal.floor;
    final plausible = [for (final h in hits) if (h.similarity >= floor) h]
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
    final top = plausible.take(SearchTuning.verifyTopK).toList();
    final records = await Future.wait(top.map((h) => _store.get(h.imageId)));
    final forms = plan.headForms;
    final support = {...forms, ...plan.modifiers};
    final scored = <_VisualCandidate>[];
    for (var i = 0; i < top.length; i++) {
      final r = records[i];
      if (r == null) continue;
      final cos = top[i].similarity;
      var adjusted = cos;
      final details = <ScoreDetail>[
        const ScoreDetail('route', 'visual'),
        ScoreDetail('visual cosine', cos.toStringAsFixed(3)),
      ];
      final words = TextMatching.words(r.ocrText);
      final printed = forms.any((w) => TextMatching.hasWord(words, w));
      final isScreen = r.image.kind == ImageKind.screenshot || r.screen.type != ScreenType.unknown;
      if (isScreen && !plan.wantsScreenshot) {
        if (plan.peopleSubject) continue;
        adjusted -= cal.screenshotPenalty;
        details.add(ScoreDetail('screenshot penalty', '-${cal.screenshotPenalty}'));
      }
      if (printed && (plan.peopleSubject || isScreen)) {
        adjusted -= cal.typographicPenalty;
        details.add(ScoreDetail('word printed in image', '-${cal.typographicPenalty}'));
      }
      if (plan.peopleSubject && r.image.kind == ImageKind.photo && r.faceCount != null) {
        details.add(ScoreDetail('faces', '${r.faceCount}'));
        if (r.faceCount == 0) continue;
      }
      final supported = [
        if (!isScreen)
          for (final w in support)
            if (TextMatching.hasWord(words, w)) w,
      ];
      scored.add(_VisualCandidate(r, cos, adjusted, details, supported));
    }
    if (scored.isEmpty) return const [];
    final best = scored.map((e) => e.adjusted).reduce(math.max);
    double score(_VisualCandidate e) =>
        cal.strength(e.adjusted) + (e.supported.isNotEmpty ? SearchTuning.ocrSupportBoost : 0);
    final accepted = [
      for (final e in scored)
        if (e.adjusted >= floor && e.adjusted >= best - cal.margin) e,
    ]..sort((a, b) => score(b).compareTo(score(a)));
    final kept = _collapse(accepted, (e) => e.record);
    final q = ParsedQuery(raw: '', semanticText: phrase, keywords: const [], dateRange: f.dateRange);
    return [
      for (final e in kept.take(SearchTuning.maxResults))
        SearchResult(
          image: e.record.image,
          score: score(e),
          reasons: [
            MatchReason(
              signal: MatchSignal.visualContent,
              description: 'Looks like “$phrase”',
              matchedTerms: [phrase],
              strength: cal.strength(e.adjusted),
            ),
            if (e.supported.isNotEmpty)
              MatchReason(
                signal: MatchSignal.textInImage,
                description: 'Also contains the text ${_quoteList(e.supported)}',
                matchedTerms: e.supported,
                snippet: TextMatching.snippet(e.record.ocrText, e.supported, radius: SearchTuning.snippetRadius),
              ),
            ..._filterReasons(e.record.image, q, f),
          ],
          details: [
            ...e.details,
            ScoreDetail('adjusted cosine', e.adjusted.toStringAsFixed(3)),
            ScoreDetail('floor / margin', '$floor / ${cal.margin} (best ${best.toStringAsFixed(3)})'),
            if (e.supported.isNotEmpty) ScoreDetail('ocr support', '+${SearchTuning.ocrSupportBoost}'),
            ScoreDetail('final', score(e).toStringAsFixed(3)),
          ],
        ),
    ];
  }

  // ---------------------------------------------------------- conversation

  /// Conversation queries: chat screenshots whose *title* names the person
  /// (whole word, so "Jamie Fox" counts and "Jamieson" does not). Other
  /// screenshots whose text mentions the person, and group chats named
  /// after them, form the separate "mentions" group. Topic words ("about the
  /// wifi") must appear in the messages. A person is only ever matched from
  /// text, never from how anyone looks.
  Future<(List<SearchResult>, List<SearchResult>)> _conversation(QueryPlan plan, SearchFilters f) async {
    final name = plan.person!;
    final folded = TextMatching.normalize(name);
    final chats = await _store.screenInfos(types: const {ScreenType.chat}, filters: f);
    final topicTerms = plan.textTerms;
    final topicExpansions = _expander.expand(topicTerms);
    bool topicIn(String text) {
      if (topicTerms.isEmpty) return true;
      final words = TextMatching.words(text);
      final norm = TextMatching.normalize(text);
      if (topicTerms.any((t) => TextMatching.hasWord(words, t))) return true;
      return topicExpansions
          .any((e) => e.isPhrase ? TextMatching.containsPhrase(norm, e.text) : TextMatching.hasWord(words, e.text));
    }

    final primaryIds = <String>[];
    final groupIds = <String>[];
    for (final e in chats.entries) {
      final title = e.value.chatTitle;
      // The exact folded word: "Jamie Fox" and "Jamie 🌻" yes, "Jamieson" no.
      if (title == null || !TextMatching.words(title).contains(folded)) continue;
      if (!topicIn(e.value.chatBody)) continue;
      (e.value.isGroupChat ? groupIds : primaryIds).add(e.key);
    }
    final hits = await _store.searchText(terms: [name], filters: f, limit: SearchTuning.textLimitPerTerm);
    final mentionIds = <String>[...groupIds];
    for (final h in hits) {
      if (!primaryIds.contains(h.imageId) && !mentionIds.contains(h.imageId)) mentionIds.add(h.imageId);
    }
    final primaryRecords = (await Future.wait(primaryIds.map(_store.get))).whereType<IndexRecord>().toList();
    final mentionRecords = (await Future.wait(mentionIds.take(SearchTuning.verifyTopK).map(_store.get)))
        .whereType<IndexRecord>()
        .where((r) => TextMatching.words(r.ocrText).contains(folded) && topicIn(r.ocrText))
        .toList();
    int newest(IndexRecord a, IndexRecord b) => b.image.createdAt.compareTo(a.image.createdAt);
    primaryRecords.sort(newest);
    mentionRecords.sort(newest);
    final shownName = name[0].toUpperCase() + name.substring(1);
    final topicWords = [...topicTerms, ...topicExpansions.map((e) => e.text)];
    final q = ParsedQuery(raw: '', semanticText: '', keywords: const [], dateRange: f.dateRange);
    final primary = [
      for (final r in _collapse(primaryRecords, (r) => r))
        SearchResult(
          image: r.image,
          score: 1,
          reasons: [
            MatchReason(
              signal: MatchSignal.conversation,
              description: 'Conversation with “${r.screen.chatTitle}”',
              matchedTerms: [name],
              snippet: topicTerms.isEmpty
                  ? null
                  : TextMatching.snippet(r.screen.chatBody, topicWords, radius: SearchTuning.snippetRadius),
            ),
            ..._filterReasons(r.image, q, f),
          ],
          details: [
            const ScoreDetail('route', 'conversation'),
            ScoreDetail('chat title', r.screen.chatTitle ?? ''),
            ScoreDetail('screen type', '${r.screen.type.name} (${r.screen.confidence.toStringAsFixed(2)})'),
            if (r.screen.sourceApp != null) ScoreDetail('app', r.screen.sourceApp!),
            if (topicTerms.isNotEmpty) ScoreDetail('topic', topicTerms.join(', ')),
          ],
        ),
    ];
    final mentions = [
      for (final r in _collapse(mentionRecords, (r) => r).take(SearchTuning.maxMentions))
        SearchResult(
          image: r.image,
          score: 0.5,
          group: ResultGroup.mentions,
          reasons: [
            MatchReason(
              signal: MatchSignal.textInImage,
              description: groupIds.contains(r.image.id)
                  ? 'Group chat “${r.screen.chatTitle}”'
                  : r.screen.isChat
                      ? 'Mentions “$shownName” in a chat with “${r.screen.chatTitle ?? 'someone else'}”'
                      : 'Mentions “$shownName”',
              matchedTerms: [name],
              snippet: TextMatching.snippet(r.ocrText, [name], radius: SearchTuning.snippetRadius),
            ),
            ..._filterReasons(r.image, q, f),
          ],
          details: [
            const ScoreDetail('route', 'conversation / mentions'),
            ScoreDetail('screen type', r.screen.type.name),
            if (r.screen.chatTitle != null) ScoreDetail('chat title', r.screen.chatTitle!),
          ],
        ),
    ];
    return (primary, mentions);
  }

  // --------------------------------------------------------------- screens

  /// Hybrid queries about a kind of screen ("screenshot of the map to the
  /// hotel", "wifi settings screenshot") or a screenshot of a visual thing
  /// ("screenshot of men's jackets").
  ///  * With a screen-type hint: screenshots of that type, the text terms
  ///    must appear (whole word or a related term), ranked by text coverage
  ///    and then visual similarity.
  ///  * Without one: a screenshot needs text evidence for the head noun or a
  ///    modifier AND a visual match, or a clear visual match on its own.
  Future<List<SearchResult>> _screens(QueryPlan plan, SearchFilters f, IndexStats stats, bool semantic) async {
    final type = plan.screenType;
    final terms = [for (final t in plan.textTerms) if (!kScreenNouns.containsKey(t)) t];
    final expansions = _expander.expand(terms);
    final visual = <String, double>{};
    if (semantic && plan.visualPhrase.isNotEmpty) {
      try {
        final vector = await _queryVector(plan.visualPhrase, screenshot: true);
        for (final h in await _store.searchVector(vector,
            modelId: _model.modelId, filters: f, limit: SearchTuning.vectorLimit)) {
          visual[h.imageId] = h.similarity;
        }
      } catch (e) {
        debugPrint('Visual search unavailable: ${e.runtimeType}');
      }
    }
    final ids = <String>{};
    if (type != null) {
      ids.addAll((await _store.screenInfos(types: {type}, filters: f)).keys);
    } else {
      for (final t in terms) {
        for (final h in await _store.searchText(terms: [t], filters: f, limit: SearchTuning.textLimitPerTerm)) {
          ids.add(h.imageId);
        }
      }
      for (final e in visual.entries) {
        if (e.value >= _cal.strictFloor) ids.add(e.key);
      }
    }
    final records =
        (await Future.wait(ids.take(SearchTuning.verifyTopK * 2).map(_store.get))).whereType<IndexRecord>().toList();
    final cal = _cal;
    final scored = <_ScreenCandidate>[];
    for (final r in records) {
      final isScreen = r.image.kind == ImageKind.screenshot || r.screen.type != ScreenType.unknown;
      if (type == null && !isScreen) continue;
      final words = TextMatching.words(r.ocrText);
      final norm = TextMatching.normalize(r.ocrText);
      final matched = <String>[];
      var covered = 0.0;
      for (final t in terms) {
        if (words.contains(TextMatching.normalize(t))) {
          covered += 1;
          matched.add(t);
          continue;
        }
        // Only a plural/singular form ("Hotels" chip for "hotel"): weaker,
        // interface chips often carry the plural.
        if (TextMatching.hasWord(words, t)) {
          covered += SearchTuning.inflectedOnlyWeight;
          matched.add(t);
          continue;
        }
        final related = [
          for (final e in expansions)
            if (e.concept.split(' ').contains(t) &&
                (e.isPhrase ? TextMatching.containsPhrase(norm, e.text) : TextMatching.hasWord(words, e.text)))
              e.text,
        ];
        if (related.isNotEmpty) {
          covered += SearchTuning.expansionWeight;
          matched.add(related.first);
        }
      }
      final coverage = terms.isEmpty ? 1.0 : covered / terms.length;
      final cos = visual[r.image.id] ?? 0;
      if (type == null) {
        final agree = coverage > 0 && cos >= cal.floor - cal.screenshotPenalty;
        if (!agree && cos < cal.strictFloor) continue;
      } else if (coverage <= 0) {
        continue;
      }
      scored.add(_ScreenCandidate(r, coverage, cos, matched));
    }
    if (scored.isEmpty) return const [];
    final bestCoverage = scored.map((e) => e.coverage).reduce(math.max);
    double score(_ScreenCandidate e) => e.coverage + 0.5 * SearchTuning.visualWeight * cal.strength(e.cos);
    final ranked = [
      for (final e in scored)
        if (e.coverage >= SearchTuning.screenRelativeCut * bestCoverage) e,
    ]..sort((a, b) {
        final c = score(b).compareTo(score(a));
        return c != 0 ? c : b.record.image.createdAt.compareTo(a.record.image.createdAt);
      });
    final kept = _collapse(ranked, (e) => e.record);
    final q = ParsedQuery(raw: '', semanticText: '', keywords: const [], dateRange: f.dateRange);
    return [
      for (final e in kept.take(SearchTuning.maxResults))
        SearchResult(
          image: e.record.image,
          score: score(e),
          reasons: [
            if (type != null) MatchReason(signal: MatchSignal.screenType, description: _screenLabel(type)),
            if (e.matched.isNotEmpty)
              MatchReason(
                signal: MatchSignal.textInImage,
                description: 'Contains the text ${_quoteList(e.matched)}',
                matchedTerms: e.matched,
                snippet: TextMatching.snippet(e.record.ocrText, e.matched, radius: SearchTuning.snippetRadius),
              ),
            if (e.cos >= cal.floor)
              MatchReason(
                signal: MatchSignal.visualContent,
                description: 'Looks like “${plan.visualPhrase}”',
                strength: cal.strength(e.cos),
              ),
            ..._filterReasons(e.record.image, q, f),
          ],
          details: [
            const ScoreDetail('route', 'screens'),
            ScoreDetail('screen type', '${e.record.screen.type.name} (${e.record.screen.confidence.toStringAsFixed(2)})'),
            ScoreDetail('text coverage', e.coverage.toStringAsFixed(2)),
            if (visual.isNotEmpty) ScoreDetail('visual cosine', e.cos.toStringAsFixed(3)),
            ScoreDetail('final', score(e).toStringAsFixed(3)),
          ],
        ),
    ];
  }

  static String _screenLabel(ScreenType t) => switch (t) {
        ScreenType.chat => 'Chat screenshot',
        ScreenType.map => 'Map screenshot',
        ScreenType.web => 'Web page screenshot',
        ScreenType.shop => 'Shopping screenshot',
        ScreenType.social => 'Social media screenshot',
        ScreenType.settings => 'Settings screenshot',
        ScreenType.receipt => 'Receipt or document screenshot',
        ScreenType.email => 'Email screenshot',
        ScreenType.menu => 'Menu screenshot',
        ScreenType.other || ScreenType.unknown => 'Screenshot',
      };

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

class _VisualCandidate {
  _VisualCandidate(this.record, this.cos, this.adjusted, this.details, this.supported);
  final IndexRecord record;
  final double cos;
  final double adjusted;
  final List<ScoreDetail> details;

  /// Head noun / modifiers also found as text in the (photo) image.
  final List<String> supported;
}

class _ScreenCandidate {
  _ScreenCandidate(this.record, this.coverage, this.cos, this.matched);
  final IndexRecord record;
  final double coverage;
  final double cos;
  final List<String> matched;
}
