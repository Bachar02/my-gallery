/// Licence entries for bundled models and native libraries that are not
/// Dart packages (so Flutter does not list them automatically).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _modelLicenseAssets = [
  'assets/models/siglip_b16/NOTICE.txt',
  'assets/models/siglip_b16/LICENSE_APACHE_2.0.txt',
];

const onnxRuntimeLicense = '''MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';

const mlKitTerms = '''Google ML Kit (on-device text recognition and face detection)

Use of ML Kit is subject to the ML Kit Terms of Service:
https://developers.google.com/ml-kit/terms

Text recognition and face detection run entirely on this device with bundled
models. Face detection only counts faces; it does not identify anyone.''';

bool _registered = false;

/// Registers the extra licence entries. Safe to call more than once; never
/// throws — a missing asset is skipped.
void registerAppLicenses({AssetBundle? bundle}) {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() => appLicenses(bundle ?? rootBundle));
}

/// The extra licence entries (exposed for testing).
Stream<LicenseEntry> appLicenses(AssetBundle bundle) async* {
  final modelTexts = <String>[];
  for (final asset in _modelLicenseAssets) {
    try {
      final text = (await bundle.loadString(asset)).trim();
      if (text.isNotEmpty) modelTexts.add(text);
    } catch (e) {
      debugPrint('Licence asset not found: $asset');
    }
  }
  if (modelTexts.isNotEmpty) {
    yield LicenseEntryWithLineBreaks(const ['SigLIP (Google)'], modelTexts.join('\n\n'));
  }
  yield const LicenseEntryWithLineBreaks(['ONNX Runtime'], onnxRuntimeLicense);
  yield const LicenseEntryWithLineBreaks(['Google ML Kit'], mlKitTerms);
}
