import 'package:apk_forge/domain/profiles/key_properties.dart';
import 'package:apk_forge/domain/signing/keystore.dart';
import 'package:apk_forge/domain/signing/new_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

final _today = DateTime(2026, 10, 21);

/// A form with nothing wrong, in `/keys`.
const _ready = NewKeyForm(
  folder: '/keys',
  storePassword: 'hunter22',
  confirmStorePassword: 'hunter22',
  commonName: 'Jane Doe',
  organization: 'Example Inc.',
  countryCode: 'us',
);

List<NewKeyProblem> _problems(NewKeyForm form, {FakeFileProbe? probe}) =>
    newKeyProblems(
      form,
      host: macHost,
      probe: probe ?? FakeFileProbe(directories: {'/keys'}),
      today: _today,
    );

void main() {
  group('newKeyProblems', () {
    test('a form filled in has none', () {
      expect(_problems(_ready), isEmpty);
    });

    test('says what each field lacks, one problem per field', () {
      final cases = <NewKeyForm, NewKeyProblem>{
        _ready.copyWith(folder: ' '): const NewKeyProblem(
          NewKeyField.folder,
          'Choose a folder.',
        ),
        _ready.copyWith(folder: 'keys'): const NewKeyProblem(
          NewKeyField.folder,
          'Choose the folder\'s full path.',
        ),
        _ready.copyWith(folder: '/gone'): const NewKeyProblem(
          NewKeyField.folder,
          'The folder does not exist.',
          missingFolder: '/gone',
        ),
        _ready.copyWith(fileName: ''): const NewKeyProblem(
          NewKeyField.fileName,
          'Name the keystore file.',
        ),
        _ready.copyWith(fileName: 'sub/upload.jks'): const NewKeyProblem(
          NewKeyField.fileName,
          'Only a file name, without folders.',
        ),
        _ready.copyWith(fileName: 'key.properties'): const NewKeyProblem(
          NewKeyField.fileName,
          'key.properties is written next to it: choose another name.',
        ),
        _ready.copyWith(alias: ' '): const NewKeyProblem(
          NewKeyField.alias,
          'Enter an alias.',
        ),
        _ready.copyWith(
          storePassword: 'abc12',
          confirmStorePassword: 'abc12',
        ): const NewKeyProblem(
          NewKeyField.storePassword,
          'At least 6 characters.',
        ),
        _ready.copyWith(confirmStorePassword: 'hunter2'): const NewKeyProblem(
          NewKeyField.confirmStorePassword,
          'Doesn\'t match the keystore password.',
        ),
        _ready.copyWith(
          commonName: '',
          organization: '',
          countryCode: '',
        ): const NewKeyProblem(
          NewKeyField.commonName,
          'Fill in at least one certificate field.',
        ),
        _ready.copyWith(countryCode: 'USA'): const NewKeyProblem(
          NewKeyField.countryCode,
          'Two letters, like US.',
        ),
        _ready.copyWith(validityYears: '25.5'): const NewKeyProblem(
          NewKeyField.validity,
          'A whole number of years, from 1 to 100.',
        ),
        _ready.copyWith(validityYears: '0'): const NewKeyProblem(
          NewKeyField.validity,
          'A whole number of years, from 1 to 100.',
        ),
        _ready.copyWith(validityYears: '7'): const NewKeyProblem(
          NewKeyField.validity,
          'Ends 2033-10-21. Google Play needs a key valid past 2033-10-22.',
        ),
      };
      for (final MapEntry(key: form, value: problem) in cases.entries) {
        expect(_problems(form), [problem], reason: '$problem');
      }
    });

    test('a key valid past 2033-10-22 is enough for Google Play', () {
      expect(_problems(_ready.copyWith(validityYears: '8')), isEmpty);
    });

    test('never points keytool at a keystore or key.properties already '
        'there', () {
      final probe = FakeFileProbe(
        directories: {'/keys'},
        files: {'/keys/upload-keystore.jks', '/keys/key.properties'},
      );

      expect(_problems(_ready, probe: probe), [
        const NewKeyProblem(
          NewKeyField.folder,
          'key.properties is already in this folder, and it\'s never '
          'overwritten: choose another folder.',
        ),
        const NewKeyProblem(
          NewKeyField.fileName,
          'upload-keystore.jks is already in this folder. keytool would add '
          'the key to it: choose another name or folder.',
        ),
      ]);
    });

    test('a JKS key with a password of its own checks that one too', () {
      final jks = _ready.copyWith(
        type: KeystoreType.jks,
        keyUsesStorePassword: false,
        keyPassword: 'abc',
        confirmKeyPassword: 'abd',
      );

      expect(_problems(jks), [
        const NewKeyProblem(NewKeyField.keyPassword, 'At least 6 characters.'),
        const NewKeyProblem(
          NewKeyField.confirmKeyPassword,
          'Doesn\'t match the key password.',
        ),
      ]);
      // PKCS12 has no password of its own for the key, whatever was typed.
      expect(_problems(jks.copyWith(type: KeystoreType.pkcs12)), isEmpty);
    });
  });

  group('distinguishedName', () {
    test('the fields filled in, in order, with the country in capitals', () {
      expect(
        _ready
            .copyWith(city: ' ', organizationalUnit: 'Mobile')
            .distinguishedName,
        'CN=Jane Doe, OU=Mobile, O=Example Inc., C=US',
      );
    });

    test('escapes what keytool would read as syntax, and nothing else', () {
      // keytool read this back as CN="Jane + Joe = x", OU="R&D <core>",
      // O="Acme \"Labs\"; Ltd, Co.", L="C:\\Users", ST="#1 State"
      // (checked with JDK 21 on 2026-10-21); it refuses `\&`.
      expect(
        const NewKeyForm(
          commonName: 'Jane + Joe = x',
          organizationalUnit: 'R&D <core>',
          organization: 'Acme "Labs"; Ltd, Co.',
          city: r'C:\Users',
          state: '#1 State',
        ).distinguishedName,
        r'CN=Jane \+ Joe \= x, OU=R&D \<core\>, '
        r'O=Acme \"Labs\"\; Ltd\, Co., L=C:\\Users, ST=\#1 State',
      );
    });
  });

  group('validity', () {
    test('25 years from 2026-10-21 is 9131 days, as keytool counts them', () {
      expect(validityDays(_today, 25), 9131);
      expect(validUntil(_today, 25), DateTime.utc(2051, 10, 21));
    });

    test('a key made on February 29 ends on March 1', () {
      expect(validUntil(DateTime(2028, 2, 29), 1), DateTime.utc(2029, 3, 1));
    });
  });

  group('toRequest', () {
    test('PKCS12: the key uses the keystore password', () {
      final request = _ready.toRequest(macHost, _today);

      expect(request.keystorePath, '/keys/upload-keystore.jks');
      expect(request.keyPropertiesPath, '/keys/key.properties');
      expect(request.alias, 'upload');
      expect(request.keyPassword, 'hunter22');
      expect(request.validityDays, 9131);
      expect(request.secrets, ['hunter22']);
      expect(request.environment, {
        keystorePasswordVariable: 'hunter22',
        keyPasswordVariable: 'hunter22',
      });
    });

    test('JKS: the key\'s own password, when it has one', () {
      final request = _ready
          .copyWith(
            type: KeystoreType.jks,
            keyUsesStorePassword: false,
            keyPassword: 'swordfish',
            confirmKeyPassword: 'swordfish',
          )
          .toRequest(macHost, _today);

      expect(request.keyPassword, 'swordfish');
      expect(request.secrets, ['hunter22', 'swordfish']);
    });

    test('key.properties points to the keystore by its absolute path', () {
      final keys = _ready.toRequest(macHost, _today).keyProperties;

      expect(keys.storeFile, '/keys/upload-keystore.jks');
      expect(keys.keyAlias, 'upload');
      expect(keys.missing, isEmpty);
    });

    test('leaves the passwords out of toString', () {
      final form = _ready.copyWith(
        type: KeystoreType.jks,
        keyUsesStorePassword: false,
        keyPassword: 'swordfish',
        confirmKeyPassword: 'swordfish',
      );
      final text = '$form ${form.toRequest(macHost, _today)}';

      expect(text, isNot(contains('hunter22')));
      expect(text, isNot(contains('swordfish')));
    });
  });

  group('formatKeyProperties', () {
    test('writes what Flutter\'s guide writes, in its order', () {
      expect(
        formatKeyProperties(
          const KeyProperties(
            storePassword: 'hunter22',
            keyPassword: 'hunter22',
            keyAlias: 'upload',
            storeFile: '/keys/upload-keystore.jks',
          ),
        ).split('\n'),
        [
          '# Made by APK Forge. Keep this file and its keystore out of git.',
          'storePassword=hunter22',
          'keyPassword=hunter22',
          'keyAlias=upload',
          'storeFile=/keys/upload-keystore.jks',
          '',
        ],
      );
    });

    test('reads back exactly what was written, whatever the characters', () {
      const keys = KeyProperties(
        storePassword: r' a\b=c:d#e!f',
        keyPassword: 'contraseña ✓\ttab',
        keyAlias: 'up load',
        storeFile: r'C:\Users\Jane\keys\upload.jks',
      );

      final written = formatKeyProperties(keys);
      final read = parseKeyProperties(written);

      expect(read.storePassword, keys.storePassword);
      expect(read.keyPassword, keys.keyPassword);
      expect(read.keyAlias, keys.keyAlias);
      expect(read.storeFile, keys.storeFile);
      // Gradle reads the file as Latin-1: everything else is escaped.
      expect(written.codeUnits.every((unit) => unit < 0x80), isTrue);
    });
  });

  test('the owner-only mode: read and write for the owner alone', () {
    expect(ownerOnlyArguments('/keys/key.properties'), [
      '600',
      '/keys/key.properties',
    ]);
  });
}
