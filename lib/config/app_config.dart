class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = 'https://netineta.com';
  static const siteBuyUrl = 'https://netineta.com/';
  static const accountUrl = 'https://netineta.com/account.html?source=app';

  // Auto-update (Windows): the GitHub repo whose Releases hold the installer.
  // Keep appVersion in sync with pubspec.yaml (and the installer version) when
  // cutting a release; the updater compares it to the latest release tag.
  static const appVersion = '0.2.11';
  static const updateRepo = 'boykorrpvz-ship-it/netinetapc';
}
