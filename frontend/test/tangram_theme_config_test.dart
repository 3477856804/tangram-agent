import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/flai/providers/ai_provider.dart';
import 'package:tangram/flai/providers/storage_provider.dart';
import 'package:tangram/flai/tangram_config.dart';

class _UnusedAiProvider implements AiProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Tangram leaves Flai theme resolution to the selected app mode', () {
    final config = buildTangramConfig(
      aiProvider: _UnusedAiProvider(),
      storageProvider: InMemoryStorageProvider(),
    );

    expect(config.theme, isNull);
  });
}
