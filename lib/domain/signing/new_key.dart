import '../../core/format/format.dart';
import '../../core/system/host.dart';
import '../profiles/key_properties.dart';
import 'keystore.dart';

/// The file written next to a new keystore, as Flutter's signing guide
/// names it.
const keyPropertiesFileName = 'key.properties';

/// Google Play needs an app's signing key to be valid past this day.
final playKeyDeadline = DateTime.utc(2033, 10, 22);

/// What the New key sheet asks for.
///
/// It holds passwords: it lives in the sheet's memory only, it's never
/// saved, and [toString] leaves them out.
class NewKeyForm {
  const NewKeyForm({
    this.folder = '',
    this.fileName = 'upload-keystore.jks',
    this.alias = 'upload',
    this.type = KeystoreType.pkcs12,
    this.storePassword = '',
    this.confirmStorePassword = '',
    this.keyUsesStorePassword = true,
    this.keyPassword = '',
    this.confirmKeyPassword = '',
    this.commonName = '',
    this.organizationalUnit = '',
    this.organization = '',
    this.city = '',
    this.state = '',
    this.countryCode = '',
    this.validityYears = '25',
  });

  final String folder;
  final String fileName;
  final String alias;
  final KeystoreType type;
  final String storePassword;
  final String confirmStorePassword;

  /// Only read for JKS: a PKCS12 key always uses the keystore password.
  final bool keyUsesStorePassword;
  final String keyPassword;
  final String confirmKeyPassword;
  final String commonName;
  final String organizationalUnit;
  final String organization;
  final String city;
  final String state;
  final String countryCode;

  /// As typed: [newKeyProblems] says when it isn't a number of years.
  final String validityYears;

  /// Only JKS can give the key a password of its own.
  bool get hasOwnKeyPassword =>
      type == KeystoreType.jks && !keyUsesStorePassword;

  String keystorePath(Host host) =>
      host.path.join(folder.trim(), fileName.trim());

  String keyPropertiesPath(Host host) =>
      host.path.join(folder.trim(), keyPropertiesFileName);

  /// keytool's `-dname`: the certificate fields filled in, escaped.
  String get distinguishedName => [
    for (final (attribute, value) in [
      ('CN', commonName),
      ('OU', organizationalUnit),
      ('O', organization),
      ('L', city),
      ('ST', state),
      ('C', countryCode.toUpperCase()),
    ])
      if (value.trim().isNotEmpty)
        '$attribute=${escapeDistinguishedNameValue(value.trim())}',
  ].join(', ');

  /// What to make, once [newKeyProblems] finds nothing.
  NewKeyRequest toRequest(Host host, DateTime today) => NewKeyRequest(
    keystorePath: keystorePath(host),
    keyPropertiesPath: keyPropertiesPath(host),
    alias: alias.trim(),
    type: type,
    storePassword: storePassword,
    keyPassword: hasOwnKeyPassword ? keyPassword : storePassword,
    distinguishedName: distinguishedName,
    validityDays: validityDays(today, int.parse(validityYears.trim())),
  );

  NewKeyForm copyWith({
    String? folder,
    String? fileName,
    String? alias,
    KeystoreType? type,
    String? storePassword,
    String? confirmStorePassword,
    bool? keyUsesStorePassword,
    String? keyPassword,
    String? confirmKeyPassword,
    String? commonName,
    String? organizationalUnit,
    String? organization,
    String? city,
    String? state,
    String? countryCode,
    String? validityYears,
  }) => NewKeyForm(
    folder: folder ?? this.folder,
    fileName: fileName ?? this.fileName,
    alias: alias ?? this.alias,
    type: type ?? this.type,
    storePassword: storePassword ?? this.storePassword,
    confirmStorePassword: confirmStorePassword ?? this.confirmStorePassword,
    keyUsesStorePassword: keyUsesStorePassword ?? this.keyUsesStorePassword,
    keyPassword: keyPassword ?? this.keyPassword,
    confirmKeyPassword: confirmKeyPassword ?? this.confirmKeyPassword,
    commonName: commonName ?? this.commonName,
    organizationalUnit: organizationalUnit ?? this.organizationalUnit,
    organization: organization ?? this.organization,
    city: city ?? this.city,
    state: state ?? this.state,
    countryCode: countryCode ?? this.countryCode,
    validityYears: validityYears ?? this.validityYears,
  );

  List<Object> get _fields => [
    folder,
    fileName,
    alias,
    type,
    storePassword,
    confirmStorePassword,
    keyUsesStorePassword,
    keyPassword,
    confirmKeyPassword,
    commonName,
    organizationalUnit,
    organization,
    city,
    state,
    countryCode,
    validityYears,
  ];

  @override
  bool operator ==(Object other) {
    if (other is! NewKeyForm) return false;
    final mine = _fields;
    final theirs = other._fields;
    for (var i = 0; i < mine.length; i++) {
      if (mine[i] != theirs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_fields);

  @override
  String toString() =>
      'NewKeyForm(folder: $folder, fileName: $fileName, alias: $alias, '
      'type: ${type.label})';
}

/// The fields of the New key sheet that a problem can be about, in its
/// order.
enum NewKeyField {
  folder,
  fileName,
  alias,
  storePassword,
  confirmStorePassword,
  keyPassword,
  confirmKeyPassword,
  commonName,
  countryCode,
  validity,
}

/// One thing that stops the key from being made, and the field it's about.
class NewKeyProblem {
  const NewKeyProblem(this.field, this.message, {this.missingFolder});

  final NewKeyField field;
  final String message;

  /// The folder that doesn't exist, when that's the problem: the sheet
  /// offers to create it.
  final String? missingFolder;

  @override
  bool operator ==(Object other) =>
      other is NewKeyProblem &&
      other.field == field &&
      other.message == message &&
      other.missingFolder == missingFolder;

  @override
  int get hashCode => Object.hash(field, message, missingFolder);

  @override
  String toString() => '${field.name}: $message';
}

/// What stops [form] from making a key, at most one problem per field, in
/// the sheet's order. [today] is the day the key would start.
List<NewKeyProblem> newKeyProblems(
  NewKeyForm form, {
  required Host host,
  required FileProbe probe,
  required DateTime today,
}) {
  final folder = form.folder.trim();
  final name = form.fileName.trim();
  final country = form.countryCode.trim();
  final years = int.tryParse(form.validityYears.trim());
  final folderExists =
      folder.isNotEmpty &&
      host.path.isAbsolute(folder) &&
      probe.directoryExists(folder);
  final certificate = [
    form.commonName,
    form.organizationalUnit,
    form.organization,
    form.city,
    form.state,
    form.countryCode,
  ].any((value) => value.trim().isNotEmpty);

  return [
    if (folder.isEmpty)
      const NewKeyProblem(NewKeyField.folder, 'Choose a folder.')
    else if (!host.path.isAbsolute(folder))
      const NewKeyProblem(NewKeyField.folder, 'Choose the folder\'s full path.')
    else if (!folderExists)
      NewKeyProblem(
        NewKeyField.folder,
        'The folder does not exist.',
        missingFolder: folder,
      )
    else if (probe.fileExists(form.keyPropertiesPath(host)))
      const NewKeyProblem(
        NewKeyField.folder,
        '$keyPropertiesFileName is already in this folder, and it\'s never '
        'overwritten: choose another folder.',
      ),
    if (name.isEmpty)
      const NewKeyProblem(NewKeyField.fileName, 'Name the keystore file.')
    else if (name.contains('/') || name.contains(r'\'))
      const NewKeyProblem(
        NewKeyField.fileName,
        'Only a file name, without folders.',
      )
    else if (name == keyPropertiesFileName)
      const NewKeyProblem(
        NewKeyField.fileName,
        '$keyPropertiesFileName is written next to it: choose another name.',
      )
    else if (folderExists && probe.fileExists(form.keystorePath(host)))
      NewKeyProblem(
        NewKeyField.fileName,
        '$name is already in this folder. keytool would add the key to it: '
        'choose another name or folder.',
      ),
    if (form.alias.trim().isEmpty)
      const NewKeyProblem(NewKeyField.alias, 'Enter an alias.'),
    if (form.storePassword.length < _minimumPassword)
      const NewKeyProblem(NewKeyField.storePassword, _passwordTooShort),
    if (form.confirmStorePassword != form.storePassword)
      const NewKeyProblem(
        NewKeyField.confirmStorePassword,
        'Doesn\'t match the keystore password.',
      ),
    if (form.hasOwnKeyPassword) ...[
      if (form.keyPassword.length < _minimumPassword)
        const NewKeyProblem(NewKeyField.keyPassword, _passwordTooShort),
      if (form.confirmKeyPassword != form.keyPassword)
        const NewKeyProblem(
          NewKeyField.confirmKeyPassword,
          'Doesn\'t match the key password.',
        ),
    ],
    if (!certificate)
      const NewKeyProblem(
        NewKeyField.commonName,
        'Fill in at least one certificate field.',
      ),
    if (country.isNotEmpty && !_countryCode.hasMatch(country))
      const NewKeyProblem(NewKeyField.countryCode, 'Two letters, like US.'),
    if (years == null || years < 1 || years > 100)
      const NewKeyProblem(
        NewKeyField.validity,
        'A whole number of years, from 1 to 100.',
      )
    else if (!validUntil(today, years).isAfter(playKeyDeadline))
      NewKeyProblem(
        NewKeyField.validity,
        'Ends ${formatDate(validUntil(today, years))}. Google Play needs a '
        'key valid past ${formatDate(playKeyDeadline)}.',
      ),
  ];
}

/// keytool refuses a shorter password.
const _minimumPassword = 6;
const _passwordTooShort = 'At least $_minimumPassword characters.';
final _countryCode = RegExp(r'^[A-Za-z]{2}$');

/// The day a key made [today] for [years] stops being valid.
DateTime validUntil(DateTime today, int years) =>
    DateTime.utc(today.year + years, today.month, today.day);

/// keytool's `-validity`: the days from [today] to [validUntil].
int validityDays(DateTime today, int years) => validUntil(
  today,
  years,
).difference(DateTime.utc(today.year, today.month, today.day)).inDays;

/// [value] escaped for keytool's `-dname`: a backslash before `,` `+` `=`
/// `"` `\` `<` `>` `;`, and before a `#` that starts it. keytool refuses
/// any other escaped character, such as `\&`.
String escapeDistinguishedNameValue(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (_special.contains(char) || (i == 0 && char == '#')) out.write(r'\');
    out.write(char);
  }
  return out.toString();
}

const _special = {',', '+', '=', '"', r'\', '<', '>', ';'};

/// A key to make: the keystore and the `key.properties` next to it.
///
/// It holds passwords: it lives in memory only, for the task that makes
/// the key, and [toString] leaves them out.
class NewKeyRequest {
  const NewKeyRequest({
    required this.keystorePath,
    required this.keyPropertiesPath,
    required this.alias,
    required this.type,
    required this.storePassword,
    required this.keyPassword,
    required this.distinguishedName,
    required this.validityDays,
  });

  final String keystorePath;
  final String keyPropertiesPath;
  final String alias;
  final KeystoreType type;
  final String storePassword;

  /// The keystore password, unless a JKS key has one of its own.
  final String keyPassword;
  final String distinguishedName;
  final int validityDays;

  Map<String, String> get environment => {
    keystorePasswordVariable: storePassword,
    keyPasswordVariable: keyPassword,
  };

  List<String> get secrets => {storePassword, keyPassword}.toList();

  /// What [formatKeyProperties] writes: the keystore by its absolute path,
  /// since Gradle reads a relative one from `android/app/`.
  KeyProperties get keyProperties => KeyProperties(
    storePassword: storePassword,
    keyPassword: keyPassword,
    keyAlias: alias,
    storeFile: keystorePath,
  );

  @override
  String toString() =>
      'NewKeyRequest(keystorePath: $keystorePath, alias: $alias, '
      'type: ${type.label})';
}

/// `chmod` arguments that leave [path] to its owner only: read and write,
/// nothing for anyone else.
List<String> ownerOnlyArguments(String path) => ['600', path];
