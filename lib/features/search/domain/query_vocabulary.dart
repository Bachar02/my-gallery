/// Word lists used by the rule-based query parser. English only.
library;

/// Words that never become OCR keywords: articles, pronouns, prepositions,
/// auxiliaries, and the verbs/nouns people use to ask for a picture
/// ("find", "show me", "picture of", "I took", "someone sent me").
const Set<String> kStopWords = {
  // articles, determiners, conjunctions
  'a', 'an', 'the', 'this', 'that', 'these', 'those', 'some', 'any', 'all', 'each',
  'every', 'and', 'or', 'but', 'nor', 'so', 'than', 'then', 'there', 'here',
  'another', 'other', 'such', 'both', 'either', 'neither', 'same', 'own', 'only',
  'just', 'also', 'too', 'very', 'really', 'quite', 'maybe', 'perhaps', 'like',
  // pronouns
  'i', 'me', 'my', 'mine', 'myself', 'we', 'us', 'our', 'ours', 'you', 'your',
  'yours', 'he', 'him', 'his', 'she', 'her', 'hers', 'it', 'its', 'they', 'them',
  'their', 'theirs', 'someone', 'somebody', 'anyone', 'anybody', 'everyone',
  'something', 'anything', 'one', 'ones', 'who', 'whom', 'whose', 'which', 'what',
  'where', 'when', 'why', 'how', 'whatever', 'whoever',
  // prepositions
  'of', 'in', 'on', 'at', 'to', 'for', 'from', 'with', 'without', 'by', 'about',
  'into', 'onto', 'over', 'under', 'between', 'during', 'before', 'after', 'since',
  'until', 'around', 'near', 'inside', 'within', 'via', 'per', 'up', 'down', 'out',
  'off', 'back', 'regarding', 'containing', 'showing', 'shows', 'featuring',
  'includes', 'including', 'has', 'having',
  // auxiliaries and modal verbs
  'is', 'are', 'was', 'were', 'be', 'been', 'being', 'am', 'do', 'does', 'did',
  'have', 'had', 'will', 'would', 'can', 'could', 'should', 'shall', 'might',
  'must', 'may', 'not', 'no', 'don', 'didn', 'isn', 'wasn', 've', 'll', 're', 'd',
  'dont', 'didnt', 'doesnt', 'cant', 'couldnt', 'wont', 'wouldnt', 'isnt', 'wasnt',
  'im', 'ive', 'thats', 'theres', 'whats', 'wheres',
  // request verbs and politeness
  'find', 'show', 'search', 'look', 'looking', 'get', 'give', 'bring', 'pull',
  'display', 'open', 'see', 'view', 'want', 'need', 'please', 'help', 'locate',
  'retrieve', 'fetch', 'grab', 'remember', 'think', 'know', 'guess', 'let',
  'try', 'trying', 'again',
  // capture / transfer verbs
  'took', 'take', 'taken', 'taking', 'snapped', 'shot', 'captured', 'saved', 'save',
  'made', 'make', 'got', 'sent', 'send', 'sending', 'received', 'receive',
  'shared', 'share', 'forwarded', 'posted', 'downloaded', 'uploaded',
  // generic picture nouns (handled as kind, never as OCR keywords)
  'photo', 'photos', 'picture', 'pictures', 'pic', 'pics', 'image', 'images',
  'snap', 'snaps', 'shots', 'screen', 'screens', 'gallery', 'camera', 'thing',
  'things', 'stuff', 'kind', 'sort', 'type', 'version', 'copy',
};

/// Words that describe *what kind of content* is wanted rather than text that
/// appears in it ("the conversation where...", "the chat with..."). They are
/// not OCR keywords but are kept in the semantic (CLIP) text.
const Set<String> kContextNouns = {
  'conversation', 'conversations', 'chat', 'chats', 'message', 'messages',
  'text', 'texts', 'thread', 'dm', 'dms', 'sms', 'email', 'emails', 'mail',
  'post', 'tweet', 'notification', 'notifications',
};

/// Verbs describing talk that are dropped entirely ("where we discussed").
const Set<String> kContextVerbs = {
  'discussed', 'discuss', 'discussing', 'discussion', 'talked', 'talk', 'talking',
  'said', 'says', 'say', 'saying', 'mentioned', 'mention', 'mentions', 'wrote',
  'write', 'written', 'told', 'tell', 'asked', 'ask', 'chatted', 'texted', 'replied',
};

/// Number words accepted in relative dates ("two weeks ago").
const Map<String, int> kNumberWords = {
  'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6,
  'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
  'couple': 2, 'a couple of': 2, 'couple of': 2, 'few': 3, 'a few': 3, 'several': 4,
};

const List<String> kMonthNames = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
];

const List<String> kWeekdayNames = [
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
];
