class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = 'https://netineta.com';
  static const siteBuyUrl = 'https://netineta.com/';
  static const accountUrl = 'https://netineta.com/account.html?source=app';

  // Auto-update (Windows): the GitHub repo whose Releases hold the installer.
  // appVersion is resolved at startup from the BUILT binary (PackageInfo reads
  // the exe's version resource, which flutter fills from pubspec.yaml) — see
  // main(). That makes a pubspec-vs-code version mismatch impossible: the
  // v0.2.12 release shipped with this constant still saying 0.2.11, so every
  // install immediately "found" the same update again, forever.
  // The literal below is only a fallback if PackageInfo somehow fails.
  static String appVersion = '0.2.15';
  static const updateRepo = 'boykorrpvz-ship-it/netinetapc';
}
