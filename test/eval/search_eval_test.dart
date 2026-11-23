// Search accuracy evaluation: the real HybridSearchEngine + SqliteIndexStore
// (in-memory, real FTS5) + RuleBasedQueryParser over a corpus of realistic OCR
// texts, with a deterministic fake visual model.
//
// The fake model is a bag-of-concepts embedding (one axis per visual concept),
// so visual scores are cleaner than real CLIP; this evaluation therefore
// mostly measures the text side (parser, FTS, verification, thresholds,
// intent expansion, person rule, date/kind filters). Visual thresholds are
// calibrated separately (docs/AI_PIPELINE.md section 5).
//
// Prints a per-query table and aggregate metrics; asserts regression floors
// at the values measured when this suite was written (docs/QA_REPORT.md).
// ignore_for_file: avoid_print

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_gallery/data/db/sqlite_index_store.dart';
import 'package:ai_gallery/domain/interfaces.dart';
import 'package:ai_gallery/domain/models.dart';
import 'package:ai_gallery/features/search/data/hybrid_search_engine.dart';
import 'package:ai_gallery/features/search/data/rule_based_query_parser.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _now = DateTime(2026, 11, 23, 15); // Monday

// ------------------------------------------------------------ fake model

const _concepts = [
  'red', 'car', 'beach', 'sea', 'dog', 'cat', 'mountain', 'snow', 'pizza', 'food', 'sunset', 'sky',
  'tree', 'city', 'street', 'bicycle', 'cake', 'birthday', 'flower', 'screenshot', 'document', 'chat',
];
const _dim = 32;
const _unknownAxis = _dim - 1;

String _stem(String w) => w.endsWith('s') && w.length > 3 ? w.substring(0, w.length - 1) : w;

Float32List _embed(Iterable<String> words) {
  final v = Float32List(_dim);
  var any = false;
  for (final w in words) {
    final i = _concepts.indexOf(_stem(w.toLowerCase()));
    if (i >= 0) {
      v[i] += 1;
      any = true;
    }
  }
  if (!any) v[_unknownAxis] = 1;
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  for (var i = 0; i < _dim; i++) {
    v[i] /= n;
  }
  return v;
}

class _ConceptModel implements SemanticModel {
  @override
  String get modelId => 'eval_concepts';
  @override
  int get dimension => _dim;
  @override
  bool get isLoaded => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<Float32List> embedImage(Uint8List encodedImage) => throw UnimplementedError();
  @override
  Future<Float32List> embedText(String text) async =>
      _embed(text.replaceFirst(RegExp(r'^a (photo|screenshot) of '), '').split(RegExp(r'\s+')));
  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------- corpus

class _Item {
  const _Item(this.id, this.kind, this.date, this.text, {this.visual = ''});
  final String id;
  final ImageKind kind;
  final DateTime date;
  final String text;

  /// Concepts the fake visual model "sees".
  final String visual;
}

const _s = ImageKind.screenshot;
const _p = ImageKind.photo;
DateTime _d(int y, int m, int d, [int h = 12]) => DateTime(y, m, d, h);

final List<_Item> _corpus = [
  // Chats
  _Item('chat_jamie', _s, _d(2026, 11, 2), 'Jamie\nonline\nAre we still on for dinner on Friday?\nYes! 7:30 at the usual place\n'
      'Perfect, I\'ll book a table for four\nGreat, see you then Jamie', visual: 'screenshot chat'),
  _Item('chat_sam_germany', _s, _d(2026, 10, 15), 'Sam\nonline\nSo for our trip to Germany, Berlin first or Munich?\n'
      'Berlin first, then the train to Munich on Thursday\nI found flights for 89 euros each\nBook them!', visual: 'screenshot chat'),
  _Item('chat_alex_bank', _s, _d(2026, 10, 20), 'Alex\nCan you send me the details for the rent?\nSure, here are my bank details:\n'
      'IBAN: DE89 3704 0044 0532 0130 00 BIC: COBADEFFXXX Account holder: Alex Morgan\nThanks, transferring now',
      visual: 'screenshot chat'),
  _Item('chat_mom_birthday', _s, _d(2026, 9, 8), 'Mom\nDon\'t forget grandma\'s birthday on Sunday!\nI ordered the cake already\n'
      'Can you bring flowers?', visual: 'screenshot chat'),
  _Item('chat_cabin_wifi', _s, _d(2026, 8, 12), 'Cabin weekend 🏕️\nPriya: what\'s the wifi at the cabin?\nLeo: network CabinNet, '
      'password pinecone2026\nPriya: thanks!', visual: 'screenshot chat'),
  _Item('chat_jamieson', _s, _d(2026, 11, 5), 'Jamieson Plumbing\nYour appointment is confirmed for Tuesday 9am\nReply STOP to opt out',
      visual: 'screenshot chat'),
  _Item('chat_lena_address', _s, _d(2026, 7, 1), 'Lena\nHere is my new address:\n14 Rosewood Avenue, Apt 3B\nBristol BS1 4DJ\n'
      'Come by any time!', visual: 'screenshot chat'),
  _Item('chat_group_football', _s, _d(2026, 11, 18), 'Sunday League ⚽\nMarco: game moved to 10:30\nTom: who has the ball?\n'
      'Marco: I do. Bring water', visual: 'screenshot chat'),
  // Receipts / invoices
  _Item('receipt_cafe', _s, _d(2026, 11, 1), 'Order confirmation\nOrder #48213-AX\n2x Flat white 7.80\n1x Croissant 3.20\n'
      '1x Orange juice 4.50\nSubtotal 15.50\nTotal 15.50\nPaid with Visa', visual: 'screenshot document'),
  _Item('receipt_grocery', _p, _d(2026, 11, 14), 'FRESHMART\nMilk 1.29\nBread 2.10\nApples 3.45\nTOTAL 6.84\nVISA ****1234\nThank you',
      visual: 'document'),
  _Item('invoice_pharmacy', _s, _d(2026, 6, 3), 'City Pharmacy\nInvoice no. 2291\nIbuprofen 400mg 5.99\nVAT 1.20\nAmount due 7.19',
      visual: 'screenshot document'),
  _Item('payslip', _s, _d(2026, 10, 31), 'Payslip October 2026\nGross pay 3,450.00\nTax 690.00\nNet pay 2,760.00\nEmployee ID 5521',
      visual: 'screenshot document'),
  // Tickets / travel
  _Item('boarding_pass_lh', _s, _d(2026, 10, 18), 'BOARDING PASS\nLufthansa LH 2471\nMUC → LHR\nGate G24  Seat 14C\nBoarding 07:15\n'
      'Departure 07:55', visual: 'screenshot document'),
  _Item('boarding_pass_easy', _s, _d(2025, 7, 2), 'easyJet\nBoarding pass\nBristol to Nice\nFlight EZY6123\nSeat 3A\nGate closes 06:10',
      visual: 'screenshot document'),
  _Item('train_ticket', _s, _d(2026, 10, 16), 'DB Ticket\nBerlin Hbf → München Hbf\nICE 1005\nCoach 7 Seat 61\nBooking reference QX7P2L',
      visual: 'screenshot document'),
  _Item('concert_ticket', _s, _d(2026, 5, 20), 'ADMIT ONE\nThe Lumineers — World Tour\nO2 Academy\nDoors 19:00\nRow F Seat 22',
      visual: 'screenshot document'),
  _Item('parking_ticket', _p, _d(2026, 11, 20), 'PENALTY CHARGE NOTICE\nParking contravention\nVehicle reg AB12 CDE\nAmount £70',
      visual: 'document car'),
  // Menus
  _Item('menu_bistro', _p, _d(2026, 7, 18), 'Les entrées\nSoupe à l\'oignon 8.50\nLes plats\nSteak frites 21.00\nLes desserts\n'
      'Crème brûlée 7.00', visual: 'food document'),
  _Item('menu_pizzeria', _p, _d(2026, 8, 9), 'PIZZERIA NAPOLI\nMENU\nMargherita 9\nDiavola 11\nQuattro formaggi 12\nTiramisu 6',
      visual: 'food document'),
  _Item('menu_cafe_board', _p, _d(2025, 12, 1), 'Coffee menu\nEspresso 2.20\nCappuccino 3.10\nChai latte 3.40', visual: 'document'),
  // Bank / passwords / addresses / misc documents
  _Item('bank_app_details', _s, _d(2026, 3, 3), 'Account details\nAccount number 41 22 98 77\nSort code 20-45-77\nBeneficiary Jane Fox',
      visual: 'screenshot document'),
  _Item('router_label', _p, _d(2026, 2, 14), 'Wi-Fi network: HOME-5G-81F2\nWi-Fi password: 7hX2-99kL-a0\nAdmin: 192.168.1.1',
      visual: 'document'),
  _Item('password_reset_email', _s, _d(2026, 11, 10), 'Reset your password\nWe received a request to reset the password for '
      'your account. This link expires in 24 hours.', visual: 'screenshot document'),
  _Item('delivery_tracking', _s, _d(2026, 11, 19), 'Your parcel is out for delivery\nTracking number 1Z999AA10123456784\n'
      'Expected today 2-4pm', visual: 'screenshot document'),
  _Item('doctor_appt', _s, _d(2026, 11, 12), 'Appointment confirmed\nDr. Patel, General Practice\nThursday 26 November, 10:20\n'
      'Please arrive 10 minutes early', visual: 'screenshot document'),
  _Item('recipe', _s, _d(2026, 4, 4), 'Banana bread\n3 ripe bananas\n250g flour\n1 tsp baking soda\nBake at 180°C for 60 minutes',
      visual: 'screenshot document food'),
  _Item('error_msg', _s, _d(2026, 11, 21), 'Error 504\nGateway Timeout\nThe server didn\'t respond in time.', visual: 'screenshot'),
  _Item('news_carpet', _s, _d(2026, 9, 30), 'Local news\nCarpet factory to close after 80 years\nWorkers fear for jobs',
      visual: 'screenshot document'),
  _Item('bankruptcy_article', _s, _d(2026, 8, 30), 'Retailer files for bankruptcy\nShares fell 40% on Monday',
      visual: 'screenshot document'),
  _Item('gym_schedule', _p, _d(2026, 1, 9), 'GYM TIMETABLE\nMon Spin 18:00\nWed Yoga 19:00\nFri HIIT 07:00', visual: 'document'),
  _Item('insurance_card', _p, _d(2026, 1, 20), 'HealthPlus Insurance\nMember ID HP-3392-110\nGroup 7781\nCall 0800 123 456',
      visual: 'document'),
  _Item('arabic_note', _s, _d(2026, 6, 6), 'مرحبا كيف حالك\nالعنوان: شارع الملك فهد', visual: 'screenshot'),
  _Item('emoji_chat', _s, _d(2026, 6, 7), 'Nina\n🎉🎉 Happy birthday!! 🎂\nThank you ❤️', visual: 'screenshot chat'),
  // Photos with little or no text
  _Item('photo_red_car', _p, _d(2026, 9, 3), '', visual: 'red car street'),
  _Item('photo_red_car2', _p, _d(2026, 9, 3, 12), 'AB12 CDE', visual: 'red car'),
  _Item('photo_blue_bike', _p, _d(2026, 9, 4), '', visual: 'bicycle street'),
  _Item('photo_beach', _p, _d(2026, 8, 2), '', visual: 'beach sea sky'),
  _Item('photo_dog', _p, _d(2026, 3, 10), '', visual: 'dog'),
  _Item('photo_cat', _p, _d(2026, 11, 20), '', visual: 'cat'),
  _Item('photo_mountain', _p, _d(2025, 12, 28), '', visual: 'mountain snow sky'),
  _Item('photo_pizza', _p, _d(2026, 10, 1), '', visual: 'pizza food'),
  _Item('photo_sunset', _p, _d(2026, 7, 20), '', visual: 'sunset sky sea'),
  _Item('photo_birthday_cake', _p, _d(2026, 9, 13), 'HAPPY BIRTHDAY GRANDMA', visual: 'cake birthday'),
  _Item('photo_flowers', _p, _d(2026, 5, 1), '', visual: 'flower'),
  _Item('photo_card_table', _p, _d(2026, 6, 15), 'Thank you card\nWith love', visual: 'document flower'),
];

// --------------------------------------------------------------- queries

class _Q {
  const _Q(this.query, this.relevant, {this.note = '', this.mustBeEmpty = false});
  final String query;
  final Set<String> relevant;
  final String note;
  final bool mustBeEmpty;
}

_Q _neg(String q, {String note = ''}) => _Q(q, const {}, note: note, mustBeEmpty: true);

final List<_Q> _queries = [
  // Product examples (PRD / fixtures)
  _Q('Find the screenshot of my conversation with Jamie', {'chat_jamie'}, note: 'product'),
  _Q('Find the conversation where we discussed our trip to Germany', {'chat_sam_germany'}, note: 'product'),
  _Q('Find the screenshot where someone sent me their bank details', {'chat_alex_bank', 'bank_app_details'}, note: 'product'),
  _Q('Show me the picture of the restaurant menu I took last summer', {'menu_bistro', 'menu_pizzeria'}, note: 'product'),
  _Q('Show me the picture of the red car', {'photo_red_car', 'photo_red_car2'}, note: 'product'),
  // Home example chips
  _Q('Screenshots from last week', {'chat_group_football', 'error_msg', 'delivery_tracking'}, note: 'chip'),
  _Q('Restaurant menu', {'menu_bistro', 'menu_pizzeria', 'menu_cafe_board'}, note: 'chip'),
  _Q('Wi-Fi password', {'chat_cabin_wifi', 'router_label'}, note: 'chip'),
  _Q('Receipt from this month', {'receipt_cafe', 'receipt_grocery'}, note: 'chip'),
  _Q('A red car', {'photo_red_car', 'photo_red_car2'}, note: 'chip'),
  _Q('Boarding pass', {'boarding_pass_lh', 'boarding_pass_easy'}, note: 'chip'),
  // Text recall
  _Q('IBAN', {'chat_alex_bank'}),
  _Q('order 48213', {'receipt_cafe'}),
  _Q('tracking number', {'delivery_tracking'}),
  _Q('doctor appointment', {'doctor_appt'}),
  _Q('Lena\'s address', {'chat_lena_address'}),
  _Q('banana bread recipe', {'recipe'}),
  _Q('train ticket to Munich', {'train_ticket'}),
  _Q('concert ticket', {'concert_ticket'}),
  _Q('payslip', {'payslip'}),
  _Q('insurance member id', {'insurance_card'}),
  _Q('gateway timeout error', {'error_msg'}),
  _Q('"out for delivery"', {'delivery_tracking'}, note: 'quoted phrase'),
  _Q('crème brûlée', {'menu_bistro'}, note: 'accents'),
  _Q('creme brulee', {'menu_bistro'}, note: 'accents folded'),
  // Dates
  _neg('receipts from last month', note: 'date; only a payslip exists in October'),
  _Q('boarding pass from summer 2025', {'boarding_pass_easy'}, note: 'date'),
  _Q('photos of the beach last summer', {'photo_beach'}, note: 'date+visual'),
  _neg('screenshots from yesterday', note: 'date; nothing on Nov 22'),
  _Q('chat from 3 weeks ago', {'chat_jamieson', 'chat_jamie'}, note: 'date window +-3 days'),
  // Plurals / typos
  _Q('boarding passes', {'boarding_pass_lh', 'boarding_pass_easy'}, note: 'plural'),
  _Q('receipts', {'receipt_cafe', 'receipt_grocery', 'invoice_pharmacy'}, note: 'plural'),
  _Q('recipt', {'receipt_cafe', 'receipt_grocery'}, note: 'typo'),
  _Q('pasword for the wifi', {'chat_cabin_wifi', 'router_label'}, note: 'typo'),
  _Q('borading pass', {'boarding_pass_lh', 'boarding_pass_easy'}, note: 'typo'),
  // Visual
  _Q('dog', {'photo_dog'}),
  _Q('birthday cake', {'photo_birthday_cake', 'chat_mom_birthday'}),
  _Q('sunset over the sea', {'photo_sunset', 'photo_beach'}),
  // Person rule
  _Q('message from Mom', {'chat_mom_birthday'}),
  _Q('what did Priya say about the wifi', {'chat_cabin_wifi'}),
  // Negatives: must return nothing
  _neg('conversation with Jamal', note: 'name not in any image'),
  _neg('zebra crossing in tokyo'),
  _neg('purple elephant'),
  _neg('my passport photo page'),
  _neg('chat with Jami', note: 'prefix of Jamie/Jamieson must not count'),
  _neg('the of and with', note: 'only stop words'),
  _neg('!!! ??? ...', note: 'only punctuation'),
  _neg('🙂🙂🙂', note: 'only emoji'),
  _neg('"lorem ipsum dolor"', note: 'quoted phrase not present'),
  _neg('car insurance quote', note: 'partial words exist elsewhere'),
];

void main() {
  late SqliteIndexStore store;
  late HybridSearchEngine engine;

  setUpAll(() async {
    store = SqliteIndexStore.inMemory();
    await store.open();
    await store.upsertAll([
      for (final (i, it) in _corpus.indexed)
        IndexRecord(
          image: GalleryImage(
            id: it.id,
            filename: (it.kind == ImageKind.screenshot
                    ? 'Screenshot_${it.date.year}${it.date.month.toString().padLeft(2, '0')}${it.date.day.toString().padLeft(2, '0')}-$i.png'
                    : 'IMG_${it.date.year}${it.date.month.toString().padLeft(2, '0')}${it.date.day.toString().padLeft(2, '0')}_$i.jpg'),
            relativePath: it.kind == ImageKind.screenshot ? 'Pictures/Screenshots/' : 'DCIM/Camera/',
            mimeType: 'image/jpeg',
            width: 1080,
            height: 2400,
            createdAt: it.date,
            modifiedAt: it.date,
            kind: it.kind,
          ),
          ocrText: it.text,
          embedding: _embed(it.visual.split(' ')),
          embeddingModel: 'eval_concepts',
          // Distinct hashes: no near-duplicate collapsing in this corpus.
          perceptualHash: (i + 1) * 0x0101010101,
          indexedAt: _now,
          pipelineVersion: 11,
        ),
    ]);
    engine = HybridSearchEngine(
      store: store,
      parser: RuleBasedQueryParser(),
      model: _ConceptModel(),
      clock: () => _now,
    );
  });

  tearDownAll(() => store.close());

  test('corpus and query set sizes', () {
    expect(_corpus.length, greaterThanOrEqualTo(40));
    expect(_queries.length, greaterThanOrEqualTo(30));
  });

  test('search accuracy report', () async {
    var precisionSum = 0.0, recallSum = 0.0;
    var positives = 0, hitAt1 = 0;
    var negatives = 0, negativesEmpty = 0;
    final misses = <String>[];
    final buf = StringBuffer()
      ..writeln('| query | expected | returned (top 5) | P@5 | recall | note |')
      ..writeln('|---|---|---|---|---|---|');
    for (final q in _queries) {
      final res = await engine.search(q.query);
      final ids = [for (final r in res.results) r.image.id];
      final top = ids.take(5).toList();
      if (q.mustBeEmpty || q.relevant.isEmpty) {
        negatives++;
        if (ids.isEmpty) {
          negativesEmpty++;
        } else {
          misses.add('NOT EMPTY: "${q.query}" -> $top');
        }
        buf.writeln('| ${q.query} | (none) | ${top.join(', ')} | - | ${ids.isEmpty ? 'ok' : 'FAIL'} | ${q.note} |');
        continue;
      }
      positives++;
      final k = math.min(5, math.max(1, top.length));
      final relevantInTop = top.where(q.relevant.contains).length;
      final p = top.isEmpty ? 0.0 : relevantInTop / k;
      final r = ids.where(q.relevant.contains).length / q.relevant.length;
      precisionSum += p;
      recallSum += r;
      if (top.isNotEmpty && q.relevant.contains(top.first)) hitAt1++;
      if (r < 1 || p < 1) misses.add('"${q.query}": expected ${q.relevant}, got $top (P@5 ${p.toStringAsFixed(2)}, R ${r.toStringAsFixed(2)})');
      buf.writeln('| ${q.query} | ${q.relevant.join(', ')} | ${top.join(', ')} | '
          '${p.toStringAsFixed(2)} | ${r.toStringAsFixed(2)} | ${q.note} |');
    }
    final meanP = precisionSum / positives;
    final meanR = recallSum / positives;
    print(buf);
    print('Positive queries: $positives, mean P@5 ${meanP.toStringAsFixed(3)}, mean recall ${meanR.toStringAsFixed(3)}, '
        'top-1 hit rate ${(hitAt1 / positives).toStringAsFixed(3)}');
    print('Empty-when-should-be-empty: $negativesEmpty / $negatives');
    print('Misses:\n  ${misses.join('\n  ')}');

    // Regression floors (measured values in docs/QA_REPORT.md).
    expect(meanP, greaterThanOrEqualTo(_floorPrecision));
    expect(meanR, greaterThanOrEqualTo(_floorRecall));
    expect(negativesEmpty, greaterThanOrEqualTo(_floorNegativesEmpty));
  });
}

// Set from the first measured run; raise them when search improves.
const double _floorPrecision = 0.80; // measured 0.835
const double _floorRecall = 0.90; // measured 0.934
const int _floorNegativesEmpty = 11; // measured 11 of 12
