/// Word lists for query understanding (`QueryAnalyzer`). English only.
library;

import '../../../domain/models.dart';

/// Nouns for things that are recognised by how they *look*: people, animals,
/// vehicles, food, places, scenes, objects. When the head noun of a query is
/// one of these, the query is visual and text in images may only support a
/// visual match ("restaurant menu" is a menu, not any screenshot that says
/// "restaurants").
const Set<String> kVisualNouns = {
  // people (presence only; the app never identifies anyone)
  'man', 'men', 'woman', 'women', 'person', 'people', 'boy', 'boys', 'girl', 'girls', 'child', 'children',
  'kid', 'kids', 'baby', 'babies', 'toddler', 'family', 'families', 'couple', 'guy', 'guys', 'lady', 'ladies',
  'crowd', 'selfie', 'selfies', 'portrait', 'portraits', 'face', 'faces', 'friends', 'group', 'team',
  // animals
  'dog', 'dogs', 'puppy', 'puppies', 'cat', 'cats', 'kitten', 'kittens', 'bird', 'birds', 'horse', 'horses',
  'cow', 'cows', 'sheep', 'goat', 'pig', 'fish', 'duck', 'ducks', 'rabbit', 'hamster', 'parrot', 'animal',
  'animals', 'elephant', 'giraffe', 'lion', 'tiger', 'bear', 'monkey', 'zebra', 'deer', 'squirrel', 'butterfly',
  'insect', 'spider', 'snake', 'turtle', 'pet', 'pets',
  // vehicles
  'car', 'cars', 'truck', 'trucks', 'bus', 'buses', 'bike', 'bikes', 'bicycle', 'bicycles', 'motorcycle',
  'motorbike', 'scooter', 'boat', 'boats', 'ship', 'yacht', 'plane', 'planes', 'airplane', 'airplanes',
  'aeroplane', 'train', 'trains', 'tram', 'taxi', 'van', 'tractor', 'helicopter',
  // food and drink
  'food', 'meal', 'meals', 'dish', 'dishes', 'plate', 'pizza', 'pizzas', 'burger', 'burgers', 'hamburger',
  'cake', 'cakes', 'cupcake', 'dessert', 'desserts', 'salad', 'sushi', 'pasta', 'noodles', 'soup', 'steak',
  'sandwich', 'bread', 'croissant', 'breakfast', 'lunch', 'brunch', 'coffee', 'tea', 'drink', 'drinks',
  'cocktail', 'cocktails', 'wine', 'beer', 'fruit', 'fruits', 'vegetables', 'ice', 'chocolate', 'cookies',
  'menu', 'menus',
  // places, scenes, nature
  'beach', 'beaches', 'sea', 'ocean', 'lake', 'river', 'waterfall', 'mountain', 'mountains', 'hill', 'hills',
  'snow', 'forest', 'woods', 'tree', 'trees', 'flower', 'flowers', 'garden', 'park', 'field', 'desert',
  'sunset', 'sunsets', 'sunrise', 'sky', 'clouds', 'rainbow', 'moon', 'stars', 'landscape', 'view', 'city',
  'skyline', 'street', 'streets', 'road', 'building', 'buildings', 'house', 'houses', 'church', 'castle',
  'bridge', 'tower', 'skyscraper', 'stadium', 'airport', 'station', 'kitchen', 'bedroom', 'room', 'office',
  'restaurant', 'cafe', 'bar', 'pool', 'night', 'fireworks', 'christmas', 'tree', 'snowman',
  // events
  'wedding', 'party', 'concert', 'festival', 'graduation', 'birthday', 'game', 'match',
  // objects
  'whiteboard', 'blackboard', 'book', 'books', 'laptop', 'computer', 'keyboard', 'phone', 'guitar', 'piano',
  'shoes', 'dress', 'shirt', 'jacket', 'jackets', 'hat', 'bag', 'watch', 'glasses', 'sofa', 'chair', 'table',
  'bed', 'lamp', 'painting', 'sculpture', 'statue', 'toy', 'toys', 'ball', 'balloon', 'balloons', 'gift',
  'flag', 'sign', 'poster', 'drawing', 'tattoo', 'ring', 'necklace',
};

/// Head nouns that refer to people; such queries also need a detected face
/// (when face counting ran) so a screenshot saying "MEN" never matches.
const Set<String> kPeopleNouns = {
  'man', 'men', 'woman', 'women', 'person', 'people', 'boy', 'boys', 'girl', 'girls', 'child', 'children',
  'kid', 'kids', 'baby', 'babies', 'toddler', 'family', 'families', 'couple', 'guy', 'guys', 'lady', 'ladies',
  'crowd', 'selfie', 'selfies', 'portrait', 'portraits', 'face', 'faces', 'friends',
};

/// Irregular inflections, both directions, for "the word is printed in the
/// image" checks (typographic guard) and OCR support.
const Map<String, List<String>> kWordForms = {
  'man': ['men'], 'men': ['man'], 'woman': ['women'], 'women': ['woman'], 'child': ['children'],
  'children': ['child'], 'person': ['people'], 'people': ['person'], 'mouse': ['mice'],
  'foot': ['feet'], 'tooth': ['teeth'], 'goose': ['geese'], 'knife': ['knives'], 'leaf': ['leaves'],
};

/// Nouns that name a kind of screen; they set a screen-type hint and are not
/// themselves searched as text.
const Map<String, ScreenType> kScreenNouns = {
  'map': ScreenType.map, 'maps': ScreenType.map, 'directions': ScreenType.map, 'route': ScreenType.map,
  'chat': ScreenType.chat, 'chats': ScreenType.chat, 'conversation': ScreenType.chat,
  'conversations': ScreenType.chat, 'messages': ScreenType.chat, 'message': ScreenType.chat,
  'texts': ScreenType.chat, 'sms': ScreenType.chat, 'dm': ScreenType.chat, 'dms': ScreenType.chat,
  'thread': ScreenType.chat,
  'website': ScreenType.web, 'webpage': ScreenType.web, 'article': ScreenType.web, 'page': ScreenType.web,
  'browser': ScreenType.web,
  'post': ScreenType.social, 'posts': ScreenType.social, 'tweet': ScreenType.social, 'feed': ScreenType.social,
  'settings': ScreenType.settings,
  'email': ScreenType.email, 'emails': ScreenType.email, 'mail': ScreenType.email, 'inbox': ScreenType.email,
  'shop': ScreenType.shop, 'store': ScreenType.shop, 'product': ScreenType.shop, 'cart': ScreenType.shop,
};

/// Nouns whose answer is written text (identifiers, credentials, contact
/// data). A query about them is a text-in-image query.
const Set<String> kTextNouns = {
  'iban', 'bic', 'swift', 'password', 'passwords', 'passcode', 'pin', 'code', 'codes', 'number', 'numbers',
  'address', 'addresses', 'phone', 'email', 'username', 'login', 'wifi', 'ssid', 'reference', 'tracking',
  'order', 'invoice', 'receipt', 'receipts', 'ticket', 'tickets', 'boarding', 'booking', 'reservation',
  'confirmation', 'appointment', 'total', 'price', 'amount', 'balance', 'account', 'details', 'quote',
  'text', 'words', 'says', 'saying', 'written', 'recipe', 'payslip', 'id', 'error', 'id', 'serial',
};

/// Words linking a head noun to its complement ("map *to* the hotel",
/// "menu *of* the restaurant"): the head is before them.
const Set<String> kLinkWords = {
  'of', 'to', 'from', 'at', 'in', 'on', 'with', 'for', 'near', 'by', 'about', 'showing', 'where', 'that',
};

/// Words kept inside the visual phrase sent to the image model.
const Set<String> kPhraseConnectors = {'a', 'an', 'the', 'of', 'at', 'on', 'in', 'with', 'and', 'by', 'over', 'under', 'near'};
