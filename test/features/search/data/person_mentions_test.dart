import 'package:ai_gallery/features/search/domain/person_mentions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = <String, List<String>>{
    'Find the screenshot of my conversation with Jamie': ['jamie'],
    'conversation with jamie': ['jamie'],
    'the message from alex about rent': ['alex'],
    'what I sent to Sam': ['sam'],
    "Jamie's address": ['jamie'],
    "jamie's number": ['jamie'],
    'the screenshot Jamie sent': ['jamie'],
    'what sam said about the flight': ['sam'],
    'chats between me and Priya': ['priya'],
    'texts from Mom': ['mom'],
    'photo with Jamie': ['jamie'],
    'photos from Paris': [],
    'Screenshot from Alex': ['alex'],
    'chat about flights from Berlin': [],
    'messages with June': ['june'],
    // Places and things are not people.
    'Find the conversation where we discussed our trip to Germany': [],
    'Show me the picture of the red car': [],
    'Find the screenshot where someone sent me their bank details': [],
    'restaurant menu I took last summer': [],
    "today's receipt": [],
    'the restaurant\'s menu': [],
    'screenshot sent yesterday': [],
    'conversation with someone about the trip': [],
    '"chat with Jamie"': [],
  };
  cases.forEach((query, expected) {
    test('${expected.isEmpty ? 'no person' : expected.join(', ')} in "$query"', () {
      expect(PersonMentions.detect(query), expected);
    });
  });

  test('lower-case "with x" needs a communication word right before it', () {
    expect(PersonMentions.detect('chat with jamie'), ['jamie']);
    expect(PersonMentions.detect('pizza with olives'), isEmpty);
    expect(PersonMentions.detect('message from Alex'), ['alex']);
  });
}
