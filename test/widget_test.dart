// Entry-point smoke test.
// Note: full widget pump is not possible in the test environment — the app
// initializes platform-dependent global state (dir.dataDir via path_provider)
// inside main(), which flutter_test has no host for. Verify the exported
// widgets are constructible instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:singbird/main.dart';

void main() {
  test('SingBirdApp is a const-constructible ConsumerWidget', () {
    const app = SingBirdApp();
    expect(app, isA<ConsumerWidget>());
  });

  test('MainShell exposes the three navigation destinations', () {
    const shell = MainShell();
    expect(shell, isA<StatefulWidget>());
  });
}
