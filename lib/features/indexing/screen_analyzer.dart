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
      r'^(messages?|aa|text message|rcs message|sms message|chat message|type a message|write a message|'
      r'send a message|imessage|signal message|message \S+|reply)[ .…,]*$',
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

  // Strong cues: phrases the interface itself shows, matched as whole words
  // anywhere in a line ("Trip receipt", "4 Boarding pass", "Add to bag").
  // Each is evidence on its own.
  static const Map<ScreenType, List<String>> _strong = {
    ScreenType.map: [
      'search here', 'your location', 'search along route', 'choose destination', 'fastest route',
      'avoid tolls', 'restaurants nearby', 'directions',
    ],
    ScreenType.shop: [
      'add to bag', 'add to cart', 'add to basket', 'buy now', 'checkout', 'proceed to checkout',
      'order placed', 'track order', 'track your order', 'free returns', 'in stock', 'your bag', 'your cart',
    ],
    ScreenType.social: [
      'liked by', 'add a comment', 'view all', 'reposted', 'suggested for you', 'followers', "what's happening",
    ],
    ScreenType.settings: [
      'battery saver', 'adaptive battery', 'airplane mode', 'mobile data', 'use wi-fi', 'saved networks',
      'share wi-fi', 'about phone', 'android version', 'screen timeout', 'dark theme', 'brightness level',
      'scan qr code', 'network & internet', 'connected devices', 'model name', 'build number', 'add network',
      'network name', 'battery usage',
    ],
    ScreenType.receipt: [
      'receipt', 'invoice', 'boarding pass', 'payslip', 'subtotal', 'amount due', 'total due', 'order total',
      'iban', 'account number', 'sort code', 'net pay', 'gross pay', 'transfer', 'bill', 'statement',
      'booking reference', 'ticket',
    ],
    ScreenType.email: [
      'search in mail', 'compose', 'reply all', 'to me', 'inbox', 'primary', 'promotions', 'unsubscribe',
    ],
    ScreenType.menu: ['our menu', 'full menu', 'delivery fee', 'add to order', 'minimum order', 'min. order'],
  };

  // Weak cues: words that count only as a whole line or a chip of a short
  // chip row ("Restaurants Hotels Gas").
  static const Map<ScreenType, Set<String>> _weak = {
    ScreenType.map: {
      'restaurants', 'hotels', 'gas', 'coffee', 'groceries', 'parking', 'takeout', 'shopping', 'things to do',
      'pharmacies', 'atms', 'bars', 'transit', 'explore', 'go', 'saved', 'contribute', 'updates', 'start',
      'route', 'steps', 'nearby', 'open now', 'overview', 'reviews',
    },
    ScreenType.shop: {
      'size', 'sizes', 'cart', 'bag', 'wishlist', 'filter', 'sort', 'new in', 'sale', 'women', 'men', 'kids',
      'items', 'delivery', 'returns', 's', 'm', 'l', 'xl',
    },
    ScreenType.social: {
      'follow', 'following', 'reply', 'replies', 'repost', 'reposts', 'retweet', 'share', 'comments', 'like',
      'likes', 'sponsored', 'for you', 'home', 'reels', 'post', 'search', 'notifications',
    },
    ScreenType.settings: {
      'settings', 'wi-fi', 'wifi', 'bluetooth', 'network', 'connected', 'display', 'battery', 'notifications',
      'apps', 'storage', 'sound', 'sound & vibration', 'privacy', 'security', 'location', 'on', 'off',
      'hotspot', 'internet', 'password', 'brightness', 'wallpaper',
    },
    ScreenType.receipt: {
      'total', 'vat', 'tax', 'paid', 'payment', 'payment method', 'balance', 'bic', 'gate', 'seat', 'fare',
      'tip', 'date', 'passenger', 'amount', 'reference', 'due', 'from', 'to',
    },
    ScreenType.email: {'mail', 'meet', 'reply', 'forward', 'subject', 'starred', 'sent', 'drafts', 'unread'},
    ScreenType.menu: {
      'menu', 'popular', 'starters', 'mains', 'desserts', 'drinks', 'sides', 'reviews', 'info', 'vegetarian',
      'vegan',
    },
  };

  static const _settingsTitles = {
    'settings', 'wi-fi', 'wifi', 'bluetooth', 'internet', 'network & internet', 'battery', 'display',
    'about phone', 'sound', 'storage', 'apps', 'notifications', 'connected devices', 'share wi-fi', 'security',
    'privacy', 'location',
  };

  static String _norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Line text without leading icons read as characters ("¢ Battery") and
  /// trailing punctuation.
  static String _clean(String s) => _norm(s)
      .replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}.…?%)]+$', unicode: true), '')
      .replaceFirst(RegExp(r'^[<←‹›¢©®]\s*'), '');

  static final Map<String, RegExp> _phraseRe = {};
  static bool _containsPhrase(String text, String phrase) => (_phraseRe[phrase] ??=
          RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape(phrase)}(?![\\p{L}\\p{N}])', unicode: true))
      .hasMatch(text);

  /// Cue score per type (exposed for the debug view and tests).
  static Map<ScreenType, double> scoreTypes(List<OcrLine> lines) {
    final header = [for (final l in lines) if (l.top < headerBottom) l];
    final bottom = [for (final l in lines) if (l.top > inputTop) l];
    final body = [for (final l in lines) if (l.top >= headerBottom && l.top <= inputTop) l];
    final cleaned = [for (final l in lines) _clean(l.text)];
    final scores = {for (final t in _strong.keys) t: 0.0};

    // Strong phrases: each distinct phrase counts once.
    _strong.forEach((type, phrases) {
      var found = 0;
      for (final ph in phrases) {
        if (cleaned.any((t) => _containsPhrase(t, ph))) found++;
      }
      scores[type] = scores[type]! + 2.5 * math.min(found, 2) + 0.5 * math.max(0, found - 2);
    });
    // Weak words.
    _weak.forEach((type, words) {
      final found = <String>{};
      for (final t in cleaned) {
        if (words.contains(t)) found.add(t);
        final chips = t.split(RegExp(r'\s*[·•|]\s*|\s{2,}|\s'));
        if (chips.length > 1 && chips.length <= 6) {
          for (final c in chips) {
            if (words.contains(c)) found.add(c);
          }
        }
      }
      scores[type] = scores[type]! + 0.7 * found.length;
    });

    // ---- chat: interface cues first; layout cues only count with them.
    var chatInterface = 0.0;
    if (bottom.any((l) => _chatInput.hasMatch(_clean(l.text)))) chatInterface += 3.5;
    if (header.any((l) => _chatStatus.hasMatch(_clean(l.text)))) chatInterface += 2;
    var chat = chatInterface;
    if (chatInterface > 0) {
      final times = body.where((l) => _time.hasMatch(_norm(l.text)) || _endsWithTime.hasMatch(_norm(l.text))).length;
      if (times >= 2) chat += 1;
      final textLines = [for (final l in body) if (l.text.length >= 3 && !_time.hasMatch(_norm(l.text))) l];
      final leftBubbles = textLines.where((l) => l.left < 0.22 && l.right < 0.8).length;
      final rightBubbles = textLines.where((l) => l.right > 0.78 && l.left > 0.25).length;
      if (leftBubbles >= 1 && rightBubbles >= 1) chat += 1;
      if (leftBubbles >= 2 && rightBubbles >= 2) chat += 1;
      if (body.any((l) => _dateSeparator.hasMatch(_norm(l.text)) && (l.centerX - 0.5).abs() < 0.12)) chat += 0.5;
    }
    scores[ScreenType.chat] = chat;

    // ---- map
    if (lines.any((l) => RegExp(r'^\d+\s?(min|hr|h)\b').hasMatch(_norm(l.text)))) {
      scores[ScreenType.map] = scores[ScreenType.map]! + 0.5;
    }
    if (lines.any((l) => RegExp(r'\b\d+([.,]\d)?\s?(km|mi)\b').hasMatch(_norm(l.text)))) {
      scores[ScreenType.map] = scores[ScreenType.map]! + 0.5;
    }

    // ---- web: a URL in the top bar.
    var web = 0.0;
    if (lines.any((l) => l.top < 0.16 && _url.hasMatch(_norm(l.text)))) web += 3.5;
    if (lines.any((l) => l.top >= 0.16 && _url.hasMatch(_norm(l.text)))) web += 0.5;
    scores[ScreenType.web] = web;

    // ---- social: several @handles (posts) or like/comment counters.
    final handles = lines.where((l) => RegExp(r'@[\w.]{2,}').hasMatch(l.text)).length;
    if (handles >= 2) scores[ScreenType.social] = scores[ScreenType.social]! + 3;
    if (lines.any((l) => RegExp(r'^\d[\d,.]*k? likes$|view all \d+ comments').hasMatch(_norm(l.text)))) {
      scores[ScreenType.social] = scores[ScreenType.social]! + 2;
    }

    // ---- settings: the page title is a settings page.
    if (header.any((l) => _settingsTitles.contains(_clean(l.text)))) {
      scores[ScreenType.settings] = scores[ScreenType.settings]! + 2;
    }

    // ---- email: an opened message shows "to me" under the sender.
    if (cleaned.any((t) => t.startsWith('to me'))) scores[ScreenType.email] = scores[ScreenType.email]! + 1;

    // ---- receipt / document: label-value rows (label left, value right on
    // the same line height).
    var pairs = 0;
    for (final a in lines) {
      if (a.left > 0.2 || a.right > 0.5) continue;
      if (lines.any((b) => b.left > 0.55 && b.right > 0.8 && (b.centerY - a.centerY).abs() < 0.008)) pairs++;
    }
    final prices = lines.where((l) => _price.hasMatch(l.text)).length;
    if (pairs >= 3) scores[ScreenType.receipt] = scores[ScreenType.receipt]! + 1.5;
    if (prices >= 3) scores[ScreenType.receipt] = scores[ScreenType.receipt]! + 0.5;

    // ---- menu: dishes with descriptions and prices.
    final dishPrices = lines.where((l) => RegExp(r'^[$€£]\s?\d+([.,]\d{2})?$|^\d+([.,]\d{2})\s?[$€£]$').hasMatch(_norm(l.text))).length;
    if (dishPrices >= 3) scores[ScreenType.menu] = scores[ScreenType.menu]! + 1.5;
    if (lines.any((l) => RegExp(r'\b\d{1,2}\s?[-–]\s?\d{1,2} min\b').hasMatch(_norm(l.text)))) {
      scores[ScreenType.menu] = scores[ScreenType.menu]! + 1;
    }
    if (scores[ScreenType.receipt]! >= 4 && dishPrices < 3) {
      scores[ScreenType.menu] = scores[ScreenType.menu]! - 1;
    }

    // Interface cues outrank content: once a chat input bar or status line
    // is seen, content words from messages must not turn it into a map/shop.
    if (chatInterface >= 3.5) {
      for (final t in scores.keys.toList()) {
        if (t != ScreenType.chat) scores[t] = scores[t]! * 0.4;
      }
    }
    return scores;
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
    // Avatar initials ("F", "+F") are not titles: at least two letters, or
    // a phone number.
    final letters = RegExp(r'\p{L}', unicode: true).allMatches(t).length;
    if (letters < 2 && RegExp(r'\d').allMatches(t).length < 6) return false;
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
