/// Rule-based screenshot understanding from the OCR layout: screen type
/// (chat, map, web page, shop, social feed, settings, receipt, email, menu)
/// and, for chats, the conversation title, group flag and message text.
///
/// Deterministic and explainable: each type has text cues (words that the
/// interface itself shows, e.g. an input bar saying "Message", chips saying
/// "Restaurants · Hotels") and layout cues (where lines sit). Content words
/// alone never decide the type: a chat that mentions restaurants is still a
/// chat because of its header, bubbles and input bar.
///
/// Calibrated on real ML Kit output for the evaluation corpus
/// (tool/eval/, test/features/indexing/screen_analyzer_test.dart).
library;

import 'dart:math' as math;

import '../../domain/models.dart';

class ScreenAnalyzer {
  const ScreenAnalyzer();

  /// Status bar and gesture/navigation bar bands (fractions of the height).
  static const double statusBarBottom = 0.042;
  static const double navBarTop = 0.965;

  /// Chat header band below the status bar.
  static const double headerBottom = 0.155;

  /// Input bar band at the bottom.
  static const double inputTop = 0.83;

  /// Minimum cue score for a type to be assigned.
  static const double minScore = 3;

  /// Whether [analyze] applies: screenshots, and photos that are clearly
  /// saved phone screens (tall, text-rich: screenshots forwarded by others).
  static bool applies(GalleryImage image, List<OcrLine> lines) {
    if (lines.isEmpty) return false;
    if (image.kind == ImageKind.screenshot) return true;
    final w = image.width, h = image.height;
    if (w <= 0 || h <= 0) return false;
    final aspect = math.max(w, h) / math.min(w, h);
    return aspect >= 1.9 && lines.length >= 8;
  }

  ScreenInfo analyze(GalleryImage image, List<OcrLine> allLines) {
    final app = sourceAppFromFilename(image.filename);
    if (!applies(image, allLines)) {
      return ScreenInfo(type: ScreenType.unknown, sourceApp: app);
    }
    final lines = [
      for (final l in allLines)
        if (l.centerY > statusBarBottom && l.centerY < navBarTop) l,
    ];
    if (lines.isEmpty) return ScreenInfo(type: ScreenType.other, sourceApp: app);

    final scores = scoreTypes(lines);
    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final second = ranked.length > 1 ? ranked[1].value : 0.0;
    if (best.value < minScore) {
      return ScreenInfo(type: ScreenType.other, sourceApp: app, confidence: 0);
    }
    final confidence = (math.min(1.0, best.value / 8) * (best.value - second) / best.value).clamp(0.0, 1.0);
    if (best.key != ScreenType.chat) {
      return ScreenInfo(type: best.key, confidence: confidence, sourceApp: app);
    }
    final chat = parseChat(lines);
    return ScreenInfo(
      type: ScreenType.chat,
      confidence: confidence,
      sourceApp: app,
      chatTitle: chat.title,
      isGroupChat: chat.isGroup,
      chatBody: chat.body,
    );
  }

  // ------------------------------------------------------------ app label

  static final RegExp _appSuffix =
      RegExp(r'^screenshot[_\- ]\d{8}[_\- ]\d{6}(?:\d{3})?[_\- ](.+?)(?:\.\w{2,4})?$', caseSensitive: false);

  /// Samsung (and some other OEMs) append the foreground app's label to the
  /// screenshot file name: `Screenshot_20261102_184512_Messages.jpg`.
  static String? sourceAppFromFilename(String? filename) {
    if (filename == null) return null;
    final m = _appSuffix.firstMatch(filename.trim());
    if (m == null) return null;
    final label = m[1]!.replaceAll(RegExp(r'[_]+'), ' ').trim();
    if (label.isEmpty || RegExp(r'^\d+$').hasMatch(label)) return null;
    return label;
  }

  // --------------------------------------------------------------- scoring

  static final RegExp _chatInput = RegExp(
      r'^(message|messages?\.\.\.|message…|aa|text message|rcs message|sms message|chat message|type a message|'
      r'write a message|send a message|imessage|signal message|message \S+|reply\.\.\.|reply…)$',
      caseSensitive: false);
  static final RegExp _chatStatus = RegExp(
      r'^(online|offline|typing\s*(…|\.\.\.)?|last seen .*|active (now|today|\d+\s*(m|min|h|hr|d)\w* ago)|'
      r'seen .*|tap here for .*|\d+ (members|participants)|.*, you$|you, .*)$',
      caseSensitive: false);
  static final RegExp _time = RegExp(r'^(\d{1,2}[:.]\d{2})(\s?[ap]\.?m\.?)?(\s*[✓✔√v/]{1,2})?$', caseSensitive: false);
  static final RegExp _endsWithTime = RegExp(r'\b\d{1,2}[:.]\d{2}(\s?[ap]m)?\s*[✓✔√]{0,2}$', caseSensitive: false);
  static final RegExp _dateSeparator = RegExp(
      r'^(today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday|'
      r'\d{1,2} (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*( \d{4})?|'
      r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w* \d{1,2}(, \d{4})?)'
      r'([ ,·•]+\d{1,2}[:.]\d{2}(\s?[ap]m)?)?$',
      caseSensitive: false);
  static final RegExp _url = RegExp(
      r'(https?://|www\.|^[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(com|org|net|io|co|fr|de|uk|tn|edu|gov|info|news|it|es|nl|eu)(/|\b))',
      caseSensitive: false);
  static final RegExp _price = RegExp(r'([$€£]\s?\d+([.,]\d{2})?|\d+([.,]\d{2})\s?[$€£]|\b\d+[.,]\d{2}\b)');

  static const _mapWords = {
    'restaurants', 'hotels', 'gas', 'coffee', 'groceries', 'parking', 'takeout', 'shopping',
    'things to do', 'pharmacies', 'atms', 'bars', 'transit', 'explore', 'go', 'saved', 'contribute',
    'updates', 'directions', 'start', 'your location', 'route', 'steps', 'fastest route', 'avoid tolls',
    'search here', 'search along route', 'nearby', 'open now', 'closes soon', 'overview', 'reviews',
  };
  static const _shopWords = {
    'add to bag', 'add to cart', 'add to basket', 'buy now', 'checkout', 'in stock', 'size', 'sizes',
    'free delivery', 'free shipping', 'cart', 'bag', 'wishlist', 'filter', 'sort', 'new in', 'sale',
    'women', 'men', 'kids', 'order placed', 'order number', 'track order', 'items',
  };
  static const _socialWords = {
    'follow', 'following', 'followers', 'reply', 'replies', 'repost', 'reposts', 'retweet', 'retweets',
    'share', 'comments', 'add a comment', 'add a comment...', 'add a comment…', 'like', 'likes', 'sponsored',
    'suggested for you', 'for you', 'home', 'reels', 'post', 'what\'s happening?',
  };
  static const _settingsWords = {
    'settings', 'wi-fi', 'wifi', 'bluetooth', 'network', 'network & internet', 'connected', 'display',
    'battery', 'notifications', 'about phone', 'airplane mode', 'mobile data', 'saved networks', 'share wi-fi',
    'connected devices', 'apps', 'storage', 'sound', 'sound & vibration', 'privacy', 'security', 'location',
    'add network', 'network preferences', 'on', 'off', 'use wi-fi', 'scan qr code', 'hotspot', 'internet',
  };
  static const _receiptWords = {
    'total', 'subtotal', 'sub-total', 'vat', 'tax', 'amount due', 'order confirmation', 'receipt', 'invoice',
    'paid', 'payment', 'payment method', 'order total', 'grand total', 'balance', 'iban', 'bic', 'account number',
    'sort code', 'boarding pass', 'gate', 'seat', 'net pay', 'gross pay',
  };
  static const _emailWords = {
    'inbox', 'primary', 'promotions', 'social', 'updates', 'compose', 'reply', 'reply all', 'forward',
    'to me', 'subject', 'starred', 'sent', 'drafts', 'all inboxes', 'unread',
  };

  static String _norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  static int _countCues(Iterable<OcrLine> lines, Set<String> cues) {
    final found = <String>{};
    for (final l in lines) {
      final t = _norm(l.text).replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}.…?]+$', unicode: true), '');
      if (cues.contains(t)) found.add(t);
      // Chip rows are read as one line: "Restaurants Hotels Gas Coffee".
      if (t.contains(' ') && t.split(' ').length <= 6) {
        for (final w in t.split(RegExp(r'\s+[·•|]?\s*'))) {
          if (cues.contains(w)) found.add(w);
        }
      }
    }
    return found.length;
  }

  /// Cue score per type (exposed for the debug view and tests).
  static Map<ScreenType, double> scoreTypes(List<OcrLine> lines) {
    final header = [for (final l in lines) if (l.top < headerBottom) l];
    final bottom = [for (final l in lines) if (l.top > inputTop) l];
    final body = [for (final l in lines) if (l.top >= headerBottom && l.top <= inputTop) l];

    // ---- chat
    var chat = 0.0;
    if (bottom.any((l) => _chatInput.hasMatch(_norm(l.text)))) chat += 3.5;
    if (header.any((l) => _chatStatus.hasMatch(_norm(l.text)))) chat += 2;
    final times = body.where((l) => _time.hasMatch(_norm(l.text)) || _endsWithTime.hasMatch(_norm(l.text))).length;
    if (times >= 2) chat += 1;
    if (times >= 4) chat += 0.5;
    final textLines = [for (final l in body) if (l.text.length >= 3 && !_time.hasMatch(_norm(l.text))) l];
    final leftBubbles = textLines.where((l) => l.left < 0.22 && l.right < 0.8).length;
    final rightBubbles = textLines.where((l) => l.right > 0.78 && l.left > 0.25).length;
    if (leftBubbles >= 1 && rightBubbles >= 1) chat += 1;
    if (leftBubbles >= 2 && rightBubbles >= 2) chat += 1;
    if (body.any((l) => _dateSeparator.hasMatch(_norm(l.text)) && (l.centerX - 0.5).abs() < 0.12)) chat += 0.5;

    // ---- map
    var map = _countCues(lines, _mapWords) * 1.0;
    if (lines.any((l) => _norm(l.text) == 'search here' || _norm(l.text).startsWith('search here'))) map += 3;
    if (lines.any((l) => RegExp(r'^\d+\s?(min|hr|h)\b').hasMatch(_norm(l.text)))) map += 0.5;
    if (lines.any((l) => RegExp(r'\(\d+([.,]\d)?\s?(km|mi)\)|\b\d+([.,]\d)?\s?(km|mi)\b').hasMatch(_norm(l.text)))) {
      map += 0.5;
    }
    final ratings = lines.where((l) => RegExp(r'\b[1-5][.,]\d\s?★|★').hasMatch(l.text)).length;
    if (ratings >= 2) map += 0.5;

    // ---- web
    var web = 0.0;
    if (lines.any((l) => l.top < 0.16 && _url.hasMatch(_norm(l.text)))) web += 3.5;
    if (lines.any((l) => l.top >= 0.16 && _url.hasMatch(_norm(l.text)))) web += 0.5;

    // ---- shop
    final prices = lines.where((l) => _price.hasMatch(l.text)).length;
    var shop = _countCues(lines, _shopWords) * 0.8 + (prices >= 3 ? 1 : 0);

    // ---- social
    var social = _countCues(lines, _socialWords) * 0.8;
    if (lines.any((l) => RegExp(r'^liked by\b|view all \d+ comments|^\d[\d,.]*k? likes$').hasMatch(_norm(l.text)))) {
      social += 3;
    }

    // ---- settings
    var settings = _countCues(lines, _settingsWords) * 0.7;
    if (header.any((l) => const {'settings', 'wi-fi', 'wifi', 'bluetooth', 'internet', 'network & internet'}
        .contains(_norm(l.text)))) {
      settings += 1.5;
    }

    // ---- receipt / document
    var receipt = _countCues(lines, _receiptWords) * 1.0 + (prices >= 3 ? 0.5 : 0);

    // ---- email
    var email = _countCues(lines, _emailWords) * 0.9;
    if (lines.any((l) => RegExp(r'^(from|to|cc):?\s').hasMatch(_norm(l.text)))) email += 1;

    // ---- menu (food delivery / restaurant menu pages)
    var menu = 0.0;
    if (lines.any((l) => const {'menu', 'our menu', 'full menu', 'popular', 'starters', 'mains', 'desserts', 'drinks'}
        .contains(_norm(l.text)))) {
      menu += 1.5;
    }
    final dishPrices = lines.where((l) => _price.hasMatch(l.text) && l.left > 0.5).length;
    if (prices >= 4) menu += 1;
    if (dishPrices >= 3) menu += 0.5;
    if (lines.any((l) => RegExp(r'\b(delivery fee|min\. order|minimum order|add to order|kcal|vegetarian|vegan|spicy)\b')
        .hasMatch(_norm(l.text)))) {
      menu += 1;
    }
    if (receipt >= 3) menu -= 1;

    // Interface cues outrank content: once a chat input bar or header status
    // is seen, content words from messages must not turn it into a map/shop.
    if (chat >= 4.5) {
      map *= 0.4;
      shop *= 0.4;
      social *= 0.4;
      receipt *= 0.5;
      email *= 0.4;
      menu *= 0.4;
      settings *= 0.5;
      web *= 0.6;
    }
    return {
      ScreenType.chat: chat,
      ScreenType.map: map,
      ScreenType.web: web,
      ScreenType.shop: shop,
      ScreenType.social: social,
      ScreenType.settings: settings,
      ScreenType.receipt: receipt,
      ScreenType.email: email,
      ScreenType.menu: menu,
    };
  }

  // ------------------------------------------------------------------ chat

  static final RegExp _trailingSymbols = RegExp(r'[^\p{L}\p{N})]+$', unicode: true);
  static final RegExp _leadingSymbols = RegExp(r'^[^\p{L}\p{N}+(]+', unicode: true);

  /// Title, group flag and body text of a chat screenshot. [lines] exclude
  /// the status and navigation bars.
  static ({String? title, bool isGroup, String body}) parseChat(List<OcrLine> lines) {
    final header = [
      for (final l in lines)
        if (l.top < headerBottom && _isTitleCandidate(l.text)) l,
    ];
    OcrLine? title;
    for (final l in header) {
      if (title == null || l.height > title.height * 1.08 || (l.height >= title.height * 0.92 && l.top < title.top)) {
        title = l;
      }
    }
    final titleText = title == null ? null : cleanTitle(title.text);

    var isGroup = false;
    for (final l in lines) {
      if (l.top >= headerBottom || identical(l, title)) continue;
      final t = _norm(l.text);
      if (RegExp(r'\b\d+ (members|participants)\b').hasMatch(t) ||
          (t.split(',').length >= 3) ||
          RegExp(r'^you,|, you$').hasMatch(t)) {
        isGroup = true;
      }
    }

    final headerBottomY = [
      for (final l in lines)
        if (l.top < headerBottom) l.bottom,
    ].fold<double>(0.06, math.max);
    final inputY = [
      for (final l in lines)
        if (l.top > inputTop && _chatInput.hasMatch(_norm(l.text))) l.top,
    ].fold<double>(1.0, math.min);
    final bodyLines = [
      for (final l in lines)
        if (l.top >= headerBottomY - 0.002 &&
            l.bottom <= inputY + 0.002 &&
            !_time.hasMatch(_norm(l.text)) &&
            !_dateSeparator.hasMatch(_norm(l.text)))
          l,
    ];
    // Short lines alone above incoming messages are sender names in groups.
    final senders = <String>{};
    for (final l in bodyLines) {
      final t = l.text.trim();
      final m = RegExp(r'^([\p{Lu}][\p{L}\-]+)(?:\s[\p{Lu}][\p{L}\-]*)?:?$', unicode: true).firstMatch(t);
      if (m != null && l.left < 0.3 && t.length <= 20) senders.add(m[1]!.toLowerCase());
      final prefix = RegExp(r'^([\p{Lu}][\p{L}\-]+):\s', unicode: true).firstMatch(t);
      if (prefix != null && l.left < 0.3) senders.add(prefix[1]!.toLowerCase());
    }
    if (senders.length >= 2) isGroup = true;
    return (title: titleText, isGroup: isGroup, body: bodyLines.map((l) => l.text).join('\n'));
  }

  static bool _isTitleCandidate(String raw) {
    final t = _norm(raw);
    if (t.length < 2) return false;
    if (!RegExp(r'[\p{L}\d]', unicode: true).hasMatch(t)) return false;
    if (_chatStatus.hasMatch(t) || _time.hasMatch(t) || _dateSeparator.hasMatch(t)) return false;
    if (RegExp(r'^\d{1,3}%$|^[<←‹]').hasMatch(t)) return false;
    return true;
  }

  /// Title text without decoration (emoji, arrows, counters).
  static String cleanTitle(String raw) {
    var t = raw.trim().replaceAll(_trailingSymbols, '').replaceAll(_leadingSymbols, '').trim();
    // A back arrow read as a character before the name ("< Jamie", "← Jamie").
    t = t.replaceFirst(RegExp(r'^[<←‹]\s*'), '');
    return t;
  }
}
