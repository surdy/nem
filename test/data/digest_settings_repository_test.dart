import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nem/src/data/database.dart';
import 'package:nem/src/data/digest_settings_repository.dart';
import 'package:nem/src/data/task_repository.dart';
import 'package:nem/src/domain/digest.dart';

void main() {
  late NemDatabase db;
  late DigestSettingsRepository repository;

  setUp(() {
    db = NemDatabase(NativeDatabase.memory());
    repository = DigestSettingsRepository(db);
  });

  tearDown(() => db.close());

  test('is off at eight until something is stored', () async {
    expect(await repository.read(), DigestSettings.defaults);
  });

  test('round-trips what was written', () async {
    const settings = DigestSettings(
      isEnabled: true,
      time: DigestTime(hour: 19, minute: 30),
    );

    await repository.write(settings);

    expect(await repository.read(), settings);
  });

  test('overwrites rather than accumulating rows', () async {
    await repository.write(
      const DigestSettings(
        isEnabled: true,
        time: DigestTime(hour: 7, minute: 0),
      ),
    );
    await repository.write(
      const DigestSettings(
        isEnabled: false,
        time: DigestTime(hour: 21, minute: 15),
      ),
    );

    final stored = await repository.read();
    expect(stored.isEnabled, isFalse);
    expect(stored.time, const DigestTime(hour: 21, minute: 15));
  });

  test('falls back rather than throwing on an unreadable time', () async {
    // This is read on the launch path; a digest that quietly reverts to its
    // default beats an app that will not start.
    await db.customStatement(
      "INSERT INTO sync_state (key, value) VALUES ('digest_time', 'noon')",
    );

    final stored = await repository.read();
    expect(stored.time, DigestSettings.defaults.time);
  });

  test('shares sync_state with the device id without disturbing it', () async {
    final deviceId = await TaskRepository(db).deviceId();

    await repository.write(
      const DigestSettings(
        isEnabled: true,
        time: DigestTime(hour: 6, minute: 45),
      ),
    );

    expect(await TaskRepository(db).deviceId(), deviceId);
    expect(
      (await repository.read()).time,
      const DigestTime(hour: 6, minute: 45),
    );
  });
}
