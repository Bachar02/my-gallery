import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/interfaces.dart';
import 'clip_image_preprocessor.dart';
import 'clip_tokenizer.dart';
import 'vector_ops.dart';

/// Bundled model files. Sizes are checked by `test/ml/mobile_clip_assets_test.dart`
/// and used to detect stale or truncated copies in the app-support directory.
abstract final class MobileClipAssets {
  static const String dir = 'assets/models/mobileclip_s0/';
  static const String vision = '${dir}mobileclip_s0_vision_fp16w.onnx';
  static const int visionBytes = 22866566;
  static const String text = '${dir}mobileclip_s0_text_w8.onnx';
  static const int textBytes = 42896411;
  static const String merges = '${dir}bpe_merges.txt';
}

/// MobileCLIP-S0 image/text encoder running on ONNX Runtime (CPU).
///
/// * Image: thumbnail bytes -> [ClipImagePreprocessor] (background isolate)
///   -> vision encoder -> 512-d L2-normalised embedding.
/// * Text: [ClipTokenizer] (77 tokens) -> text encoder -> 512-d embedding.
///
/// ONNX Runtime needs file paths, so the models are copied once from the APK
/// assets to the app-support directory (not the cache, which Android may
/// clear). Inference runs on the plugin's background thread; calls are
/// serialised so at most one inference is in flight.
class MobileClipModel implements SemanticModel {
  MobileClipModel({
    AssetBundle? bundle,
    Future<Directory> Function()? modelDirectory,
    this.visionThreads = 2,
    this.textThreads = 2,
  })  : _bundle = bundle ?? rootBundle,
        _modelDirectory = modelDirectory ?? _defaultModelDirectory;

  static const String kModelId = 'mobileclip_s0';
  static const int kDimension = 512;

  final AssetBundle _bundle;
  final Future<Directory> Function() _modelDirectory;
  final int visionThreads;
  final int textThreads;

  ClipTokenizer? _tokenizer;
  OrtSession? _vision;
  OrtSession? _text;
  Future<bool>? _loading;
  Future<void> _queue = Future.value();
  bool _loaded = false;

  /// Why the last [load] failed, for diagnostics screens/logs.
  String? lastLoadError;

  @override
  String get modelId => kModelId;

  @override
  int get dimension => kDimension;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<bool> load() {
    if (_loaded) return Future.value(true);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<bool> _load() async {
    final sw = Stopwatch()..start();
    try {
      final mergesText = await _bundle.loadString(MobileClipAssets.merges, cache: false);
      final tokenizer = await _buildTokenizer(mergesText);
      final dir = await _modelDirectory();
      final visionPath = await _materialize(dir, MobileClipAssets.vision, MobileClipAssets.visionBytes);
      final textPath = await _materialize(dir, MobileClipAssets.text, MobileClipAssets.textBytes);

      final ort = OnnxRuntime();
      final vision = await ort.createSession(visionPath,
          options: OrtSessionOptions(intraOpNumThreads: visionThreads));
      final OrtSession text;
      try {
        text = await ort.createSession(textPath, options: OrtSessionOptions(intraOpNumThreads: textThreads));
      } catch (_) {
        await vision.close();
        rethrow;
      }
      if (!vision.inputNames.contains('pixel_values') || !text.inputNames.contains('input_ids')) {
        await vision.close();
        await text.close();
        throw StateError('Unexpected model inputs: ${vision.inputNames} / ${text.inputNames}');
      }
      _tokenizer = tokenizer;
      _vision = vision;
      _text = text;
      _loaded = true;
      lastLoadError = null;
      debugPrint('MobileClipModel loaded in ${sw.elapsedMilliseconds} ms');
      return true;
    } catch (e) {
      lastLoadError = e.toString();
      debugPrint('MobileClipModel unavailable, text-only search: $e');
      return false;
    }
  }

  /// Copies [asset] to [dir] unless an intact copy (same byte length) exists.
  /// Writes to a temp file and renames, so an interrupted copy is never used.
  Future<String> _materialize(Directory dir, String asset, int expectedBytes) async {
    final file = File(p.join(dir.path, p.basename(asset)));
    if (await file.exists() && await file.length() == expectedBytes) return file.path;
    await dir.create(recursive: true);
    final data = await _bundle.load(asset);
    if (data.lengthInBytes != expectedBytes) {
      throw StateError('Asset $asset has ${data.lengthInBytes} bytes, expected $expectedBytes');
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    return file.path;
  }

  // Static so the isolate closures capture nothing but their argument.
  static Future<ClipTokenizer> _buildTokenizer(String merges) =>
      Isolate.run(() => ClipTokenizer.fromMerges(merges));

  static Future<Float32List> _prepareImage(Uint8List bytes) =>
      Isolate.run(() => ClipImagePreprocessor.tensorFromEncoded(bytes));

  static Future<Directory> _defaultModelDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'models', kModelId));
  }

  @override
  Future<Float32List> embedImage(Uint8List encodedImage) async {
    _ensureLoaded();
    final tensor = await _prepareImage(encodedImage);
    return _serial(() => _run(
          _vision!,
          'pixel_values',
          () => OrtValue.fromList(tensor, const [1, 3, ClipImagePreprocessor.size, ClipImagePreprocessor.size]),
          'image_embeds',
        ));
  }

  @override
  Future<Float32List> embedText(String text) async {
    _ensureLoaded();
    final ids = _tokenizer!.encode(text);
    return _serial(() => _run(
          _text!,
          'input_ids',
          () => OrtValue.fromList(ids, const [1, ClipTokenizer.contextLength]),
          'text_embeds',
        ));
  }

  Future<Float32List> _run(
    OrtSession session,
    String inputName,
    Future<OrtValue> Function() makeInput,
    String outputName,
  ) async {
    final input = await makeInput();
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({inputName: input});
      final out = outputs[outputName] ?? outputs.values.first;
      final values = await out.asFlattenedList();
      if (values.length != kDimension) {
        throw StateError('Model returned ${values.length} values, expected $kDimension');
      }
      return l2Normalized([for (final v in values) (v as num).toDouble()]);
    } finally {
      await input.dispose();
      if (outputs != null) {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    }
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _ensureLoaded() {
    if (!_loaded) throw StateError('MobileClipModel.load() has not completed successfully');
  }

  @override
  Future<void> dispose() async {
    _loaded = false;
    await _queue;
    final v = _vision;
    final t = _text;
    _vision = null;
    _text = null;
    _tokenizer = null;
    await v?.close();
    await t?.close();
  }
}
