import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/interfaces.dart';
import 'siglip_image_preprocessor.dart';
import 'siglip_tokenizer.dart';
import 'vector_ops.dart';

/// Bundled model files (built by tool/install_assets.py). Sizes are checked
/// by `test/ml/siglip_assets_test.dart` and used to detect stale or truncated
/// copies in the app-support directory.
abstract final class SiglipAssets {
  static const String dir = 'assets/models/siglip_b16/';
  static const String vision = '${dir}siglip_b16_vision_int8.onnx';
  static const int visionBytes = 115852766;
  static const String text = '${dir}siglip_b16_text_int8.onnx';
  static const int textBytes = 111622590;
  static const String vocab = '${dir}spiece_vocab.tsv';
}

/// Google SigLIP base (patch 16, 224 px; Apache-2.0) image and text encoders
/// on ONNX Runtime (CPU), int8 transformer weights (tool/quantize_siglip.py).
///
/// * Image: thumbnail bytes -> [SiglipImagePreprocessor] (background
///   isolate) -> vision encoder -> 768-d L2-normalised embedding.
/// * Text: [SiglipTokenizer] (64 tokens) -> text encoder -> 768-d embedding.
///
/// ONNX Runtime needs file paths, so the models are copied once from the APK
/// assets to the app-support directory (not the cache, which Android may
/// clear). Inference runs on the plugin's background thread; calls are
/// serialised so at most one inference is in flight.
class SiglipModel implements SemanticModel {
  SiglipModel({
    AssetBundle? bundle,
    Future<Directory> Function()? modelDirectory,
    this.visionThreads = 4,
    this.textThreads = 2,
  })  : _bundle = bundle ?? rootBundle,
        _modelDirectory = modelDirectory ?? _defaultModelDirectory;

  static const String kModelId = 'siglip_b16';
  static const int kDimension = 768;

  final AssetBundle _bundle;
  final Future<Directory> Function() _modelDirectory;
  final int visionThreads;
  final int textThreads;

  SiglipTokenizer? _tokenizer;
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
      final vocab = await _bundle.loadString(SiglipAssets.vocab, cache: false);
      final tokenizer = await _buildTokenizer(vocab);
      final dir = await _modelDirectory();
      await _removeStale(dir.parent);
      final visionPath = await _materialize(dir, SiglipAssets.vision, SiglipAssets.visionBytes);
      final textPath = await _materialize(dir, SiglipAssets.text, SiglipAssets.textBytes);

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
      debugPrint('SiglipModel loaded in ${sw.elapsedMilliseconds} ms');
      return true;
    } catch (e) {
      lastLoadError = e.toString();
      debugPrint('SiglipModel unavailable, text-only search: ${e.runtimeType}');
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

  /// Model copies of earlier app versions (other model ids) are deleted so
  /// they do not keep using storage.
  static Future<void> _removeStale(Directory modelsRoot) async {
    try {
      if (!await modelsRoot.exists()) return;
      await for (final e in modelsRoot.list(followLinks: false)) {
        if (e is Directory && p.basename(e.path) != kModelId) await e.delete(recursive: true);
      }
    } catch (_) {
      // Best effort.
    }
  }

  // Static so the isolate closures capture nothing but their argument.
  static Future<SiglipTokenizer> _buildTokenizer(String vocab) =>
      Isolate.run(() => SiglipTokenizer.fromVocab(vocab));

  static Future<Float32List> _prepareImage(Uint8List bytes) =>
      Isolate.run(() => SiglipImagePreprocessor.tensorFromEncoded(bytes));

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
          () => OrtValue.fromList(tensor, const [1, 3, SiglipImagePreprocessor.size, SiglipImagePreprocessor.size]),
          'pooler_output',
        ));
  }

  @override
  Future<Float32List> embedText(String text) async {
    _ensureLoaded();
    final ids = _tokenizer!.encode(text);
    return _serial(() => _run(
          _text!,
          'input_ids',
          () => OrtValue.fromList(ids, const [1, SiglipTokenizer.contextLength]),
          'pooler_output',
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
      final out = outputs[outputName];
      if (out == null) throw StateError('Model output $outputName missing: ${outputs.keys}');
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
    if (!_loaded) throw StateError('SiglipModel.load() has not completed successfully');
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
