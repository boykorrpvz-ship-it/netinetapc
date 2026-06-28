// ignore_for_file: prefer_const_constructors, prefer_const_constructors_in_immutables

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/account_snapshot.dart';
import '../models/order_access.dart';
import '../models/stored_vpn_profile.dart';
import '../models/subscription.dart';
import '../models/vpn_product.dart';
import '../services/ironvpn_api.dart';
import '../services/desktop_integration.dart';
import '../services/ip_info_service.dart';
import '../services/profile_store.dart';
import '../services/update_service.dart';
import '../services/vpn_controller.dart';
import 'theme.dart';

// When true, forces the desktop main view (control + power panes) without a
// logged-in account. Used only for visual inspection; ships as false.
const bool _kForceMainPreview = false;

ThemeData _productTheme(BuildContext context, VpnProduct product) {
  final base = Theme.of(context);
  final accent = AppColors.accentFor(product);
  final foreground = AppColors.isDark ? const Color(0xFF04130D) : Colors.white;

  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      secondary: accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: foreground,
        minimumSize: const Size.fromHeight(54),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.tile),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: accent.withValues(alpha: 0.55), width: 1.4),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.tile),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? foreground
            : AppColors.inkSoft,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent
            : AppColors.glassBorderStrong,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: accent,
        backgroundColor: accent.withValues(alpha: 0.12),
      ),
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.darkTheme,
    required this.onDarkThemeChanged,
    super.key,
  });

  final bool darkTheme;
  final ValueChanged<bool> onDarkThemeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _store = ProfileStore();
  final _api = const IronVpnApi();
  final _vpn = VpnController();
  final _appLinks = AppLinks();
  final _loginEmailController = TextEditingController();
  final _loginPasswordController = TextEditingController();

  final Map<VpnProduct, OrderAccess?> _access = {
    VpnProduct.vless: null,
    VpnProduct.amneziaWg: null,
  };
  final Map<VpnProduct, Subscription?> _subscriptions = {
    VpnProduct.vless: null,
    VpnProduct.amneziaWg: null,
  };
  final Map<VpnProduct, StoredVpnProfile?> _profiles = {
    VpnProduct.vless: null,
    VpnProduct.amneziaWg: null,
  };
  StreamSubscription<Uri>? _linkSub;
  Timer? _accessTimer;
  VpnProduct _selectedProduct = VpnProduct.vless;
  // The product whose tunnel is actually up. Keeps the UI from flipping to a
  // different product after the app is backgrounded and resumed.
  VpnProduct? _connectedProduct;
  VpnState _state = VpnState.disconnected;
  bool _routeRussianDirect = true;
  // Desktop settings (Windows).
  bool _autostart = false;
  bool _autoConnect = false;
  bool _killSwitch = false;
  bool _autoReconnect = true;
  bool _busy = true;
  bool _initialLoadComplete = false;
  bool _showLoginScreen = false;
  String? _accountToken;
  String? _accountEmail;
  String? _message;
  int? _desktopPingMs;
  bool _desktopPinging = false;
  // When the current tunnel came up; drives the live session timer. Null while
  // not connected. _sessionTicker rebuilds once a second to advance the clock.
  DateTime? _connectedSince;
  Timer? _sessionTicker;
  // Live throughput + current IP (desktop telemetry).
  Timer? _statsTimer;
  Timer? _connMonitor;
  final IpInfoService _ipService = IpInfoService();
  final UpdateService _updateService = UpdateService();
  bool _updatePromptShown = false;
  IpInfo? _ipInfo;
  int _downBps = 0;
  int _upBps = 0;
  int _sessionDown = 0;
  int _sessionUp = 0;
  int? _lastRx;
  int? _lastTx;
  int? _baseRx;
  int? _baseTx;
  DateTime? _lastStatsAt;
  // True between a user-initiated connect and disconnect; lets the monitor
  // auto-reconnect after an unexpected drop without fighting manual actions.
  bool _userWantsConnected = false;
  // Transient warning shown as a toast floating over the VPN-type selector
  // (e.g. "disconnect first before switching type"). Auto-dismisses.
  String? _typeToast;
  Timer? _typeToastTimer;
  int _vpnAccessVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _listenLinks();
    if (Platform.isWindows) {
      _refreshIpInfo();
      // Watches for unexpected tunnel drops and reconnects when enabled.
      _connMonitor = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _monitorConnection(),
      );
      // Check GitHub Releases for a newer build shortly after launch.
      Future<void>.delayed(const Duration(seconds: 3), _checkForUpdate);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accessTimer?.cancel();
    _typeToastTimer?.cancel();
    _sessionTicker?.cancel();
    _statsTimer?.cancel();
    _connMonitor?.cancel();
    _linkSub?.cancel();
    _loginEmailController.dispose();
    _loginPasswordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncVpnState();
      if (_accountToken != null) {
        _syncAccount(silent: true);
      } else {
        _refreshSubscription(_selectedProduct, silent: true);
      }
    }
  }

  Future<void> _load() async {
    final selectedProduct = await _store.loadSelectedProduct();
    final routeRussianDirect = await _store.loadRouteRussianServicesDirect();
    final autostart = await _store.loadAutostart();
    final autoConnect = await _store.loadAutoConnect();
    final killSwitch = await _store.loadKillSwitch();
    final autoReconnect = await _store.loadAutoReconnect();
    final state = await _vpn.status();
    final accountToken = await _store.loadAccountToken();
    final accountEmail = await _store.loadAccountEmail();

    for (final product in VpnProduct.values) {
      _access[product] = await _store.loadOrderAccess(product);
      _profiles[product] = await _store.loadVpnProfile(product);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedProduct = selectedProduct;
      _routeRussianDirect = routeRussianDirect;
      _autostart = autostart;
      _autoConnect = autoConnect;
      _killSwitch = killSwitch;
      _autoReconnect = autoReconnect;
      _state = state;
      _accountToken = accountToken;
      _accountEmail = accountEmail;
      _connectedProduct = state == VpnState.connected ? selectedProduct : null;
    });

    await _refreshAllPending(silent: true);

    if (accountToken != null) {
      await _syncAccount(silent: true);
    }

    if (mounted) {
      setState(() {
        _busy = false;
        _initialLoadComplete = true;
      });
    }
    _startAccessMonitoring();
    _maybeAutoConnectOnLaunch();
  }

  // Auto-connect right after launch when enabled and there's an active profile
  // and nothing is connected yet (e.g. started via Windows logon autostart).
  Future<void> _maybeAutoConnectOnLaunch() async {
    if (!Platform.isWindows || !_autoConnect) {
      return;
    }
    if (_state == VpnState.connected || _state == VpnState.connecting) {
      return;
    }
    if (!_isActive(_selectedProduct)) {
      return;
    }
    await _connect();
  }

  Future<void> _setAutostart(bool value) async {
    setState(() => _autostart = value);
    await _store.saveAutostart(value);
    await DesktopIntegration.setAutostart(value);
  }

  Future<void> _setAutoConnect(bool value) async {
    setState(() => _autoConnect = value);
    await _store.saveAutoConnect(value);
  }

  Future<void> _setKillSwitch(bool value) async {
    setState(() => _killSwitch = value);
    await _store.saveKillSwitch(value);
  }

  Future<void> _setAutoReconnect(bool value) async {
    setState(() => _autoReconnect = value);
    await _store.saveAutoReconnect(value);
  }

  Future<void> _openLogsFolder() => DesktopIntegration.openLogsFolder();

  Future<void> _checkForUpdate() async {
    if (!Platform.isWindows || _updatePromptShown || !mounted) {
      return;
    }
    final info = await _updateService.checkForUpdate();
    if (info == null || !mounted) {
      return;
    }
    _updatePromptShown = true;
    await _showUpdateDialog(info);
  }

  Future<void> _showUpdateDialog(UpdateInfo info) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        var downloading = false;
        double progress = 0;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Доступно обновление ${info.version}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Текущая версия: ${AppConfig.appVersion}'),
                  if (info.notes != null) ...[
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: SingleChildScrollView(
                        child: Text(info.notes!),
                      ),
                    ),
                  ],
                  if (downloading) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                    ),
                    const SizedBox(height: 8),
                    Text('Скачивание… ${(progress * 100).round()}%'),
                  ],
                ],
              ),
              actions: downloading
                  ? const []
                  : [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Позже'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          setDialogState(() => downloading = true);
                          final file =
                              await _updateService.downloadInstaller(
                            info.downloadUrl,
                            onProgress: (p) {
                              if (dialogContext.mounted) {
                                setDialogState(() => progress = p);
                              }
                            },
                          );
                          if (file == null) {
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                            _showMessage('Не удалось скачать обновление.');
                            return;
                          }
                          final launched =
                              await _updateService.launchInstaller(file);
                          if (!launched) {
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                            _showMessage('Не удалось запустить установщик.');
                            return;
                          }
                          // Quit so the installer can replace the running app.
                          await Future<void>.delayed(
                              const Duration(milliseconds: 600));
                          exit(0);
                        },
                        child: const Text('Обновить'),
                      ),
                    ],
            );
          },
        );
      },
    );
  }

  void _startAccessMonitoring() {
    _accessTimer?.cancel();
    _accessTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _enforceAccessExpiry();
      if (_accountToken != null) {
        _syncAccount(silent: true);
      } else if (_access[VpnProduct.vless] != null) {
        _refreshSubscription(VpnProduct.vless, silent: true);
      }
    });
  }

  Future<void> _claimTrial({bool silent = false}) async {
    if (_accountToken != null) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }

    try {
      final installId =
          await _vpn.stableDeviceId() ?? await _store.loadOrCreateInstallId();
      _writeDesktopDebugLog('claimTrial -> device_id=$installId');
      final platformName = Platform.isAndroid
          ? 'Android'
          : Platform.isIOS
              ? 'iPhone'
              : 'App';
      final shortId =
          installId.length > 6 ? installId.substring(0, 6) : installId;
      final subscription = await _api.claimTrial(
        installId: installId,
        deviceName: '$platformName Trial $shortId',
      );
      _writeDesktopDebugLog(
        'claimTrial result active=${subscription.isActive} '
        'isTrial=${subscription.isTrial} expires=${subscription.expiresAt}',
      );
      await _applySubscription(subscription);

      if (!mounted) {
        return;
      }

      setState(() {
        _selectedProduct = VpnProduct.vless;
        _showLoginScreen = false;
        if (!silent) {
          _message = subscription.isActive
              ? 'Пробный доступ активирован на 24 часа.'
              : 'Пробный доступ на этом устройстве уже завершён.';
        }
      });
    } on IronVpnApiException catch (error) {
      if (!silent) {
        _showMessage(error.message);
      }
    } catch (_) {
      if (!silent) {
        _showMessage('Не удалось активировать пробный доступ.');
      }
    } finally {
      if (mounted && !silent) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _applySubscription(Subscription subscription) async {
    final payload = subscription.accessPayload;
    final token = subscription.accessToken;
    if (payload == null || token == null || token.isEmpty) {
      return;
    }

    final access = OrderAccess(
      orderId: subscription.orderId,
      accessToken: token,
      product: subscription.product,
    );
    await _store.saveOrderAccess(access);
    _access[subscription.product] = access;
    _subscriptions[subscription.product] = subscription;

    if (subscription.isActive) {
      final profile = StoredVpnProfile.fromSubscription(subscription);
      await _store.saveVpnProfile(profile);
      // NB: do NOT persist the selected product here. This runs for every
      // active product on sync, so the last one (AmneziaWG) would overwrite the
      // user's choice — making a VLESS session reopen as "AWG". Selection is
      // owned by _connect / _selectProduct / _handleIncomingLink only.
      _profiles[subscription.product] = profile;
    } else {
      await _store.clearVpnProfile(subscription.product);
      _profiles[subscription.product] = null;
    }
  }

  Future<void> _login() async {
    final email = _loginEmailController.text.trim();
    final password = _loginPasswordController.text;

    if (email.isEmpty || password.length < 8) {
      _showMessage('Введите email и пароль не короче 8 символов.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final snapshot = await _api.login(email: email, password: password);
      final token = snapshot.token;
      if (token == null || token.isEmpty) {
        throw const IronVpnApiException('Сервер не вернул сессию аккаунта', 0);
      }

      await _store.saveAccount(token: token, email: snapshot.email);
      _accountToken = token;
      _accountEmail = snapshot.email;
      await _applyAccountSnapshot(snapshot);
      _loginPasswordController.clear();

      if (mounted) {
        setState(() {
          _showLoginScreen = false;
          _message = _hasAnyActive()
              ? 'Подписки загружены. Подключение готово.'
              : 'Вход выполнен. Активных подписок пока нет.';
        });
      }
    } on IronVpnApiException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('Не удалось войти в аккаунт.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _syncAccount({bool silent = false}) async {
    final token = _accountToken ?? await _store.loadAccountToken();
    if (token == null || token.isEmpty) {
      return;
    }
    final accessVersion = _vpnAccessVersion;

    if (!silent && mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }

    try {
      final snapshot = await _api.fetchAccount(token);
      if (_accountToken != token || accessVersion != _vpnAccessVersion) {
        return;
      }
      _accountToken = token;
      _accountEmail = snapshot.email;
      await _store.saveAccount(token: token, email: snapshot.email);
      await _applyAccountSnapshot(snapshot);

      if (!silent && mounted) {
        setState(() {
          _message = _hasAnyActive()
              ? 'Данные аккаунта обновлены.'
              : 'Активных подписок пока нет.';
        });
      }
    } on IronVpnApiException catch (error) {
      if (error.statusCode == 401) {
        await _purgeLocalAccountAccess();
        if (mounted) {
          setState(() {
            _showLoginScreen = true;
            _message = silent ? null : 'Сессия завершена. Войдите снова.';
          });
        }
      }
      if (!silent && error.statusCode != 401) {
        _showMessage(error.message);
      }
    } catch (_) {
      if (!silent) {
        _showMessage('Не удалось обновить данные аккаунта.');
      }
    } finally {
      if (mounted && !silent) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _applyAccountSnapshot(AccountSnapshot snapshot) async {
    for (final product in VpnProduct.values) {
      final subscription = snapshot.activeFor(product);
      if (subscription != null) {
        await _applySubscription(subscription);
        continue;
      }

      final current = _subscriptions[product];
      if (current != null && !current.isTrial) {
        await _store.clearVpnProfile(product);
        _profiles[product] = null;
        _subscriptions[product] = current;
      }
    }

    final selectedStillActive =
        _subscriptions[_selectedProduct]?.isActive == true;
    if (!selectedStillActive && _connectedProduct == null) {
      VpnProduct? activeProduct;
      for (final product in VpnProduct.values) {
        if (_subscriptions[product]?.isActive == true) {
          activeProduct = product;
          break;
        }
      }
      if (activeProduct != null) {
        _selectedProduct = activeProduct;
        await _store.saveSelectedProduct(activeProduct);
      }
    }
  }

  Future<void> _logout() async {
    if (mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }

    await _purgeLocalAccountAccess();

    if (mounted) {
      setState(() {
        _busy = false;
        _showLoginScreen = true;
        _message = 'Вы вышли из аккаунта. Локальный доступ удалён.';
      });
    }
  }

  Future<void> _purgeLocalAccountAccess() async {
    _vpnAccessVersion += 1;
    _accountToken = null;
    _accountEmail = null;

    try {
      await _vpn.stop();
    } catch (_) {
      // Local credentials still must be removed if the VPN engine is stopping.
    }
    await Future.wait([
      _store.clearAccount(),
      _store.clearAllVpnAccess(),
    ]);
    await _store.saveSelectedProduct(VpnProduct.vless);

    for (final product in VpnProduct.values) {
      _access[product] = null;
      _subscriptions[product] = null;
      _profiles[product] = null;
    }

    _selectedProduct = VpnProduct.vless;
    _state = VpnState.disconnected;
  }

  Future<void> _showPasswordRecovery() async {
    final emailController = TextEditingController(
      text: _loginEmailController.text.trim(),
    );
    final codeController = TextEditingController();
    final passwordController = TextEditingController();
    var codeSent = false;
    var dialogBusy = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      barrierDismissible: !dialogBusy,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                setDialogState(() => dialogError = 'Введите email аккаунта.');
                return;
              }

              if (codeSent &&
                  (codeController.text.trim().length != 6 ||
                      passwordController.text.length < 8)) {
                setDialogState(() {
                  dialogError =
                      'Введите шестизначный код и новый пароль от 8 символов.';
                });
                return;
              }

              setDialogState(() {
                dialogBusy = true;
                dialogError = null;
              });

              try {
                if (!codeSent) {
                  await _api.requestPasswordReset(email);
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      codeSent = true;
                      dialogBusy = false;
                    });
                  }
                  return;
                }

                final snapshot = await _api.resetPassword(
                  email: email,
                  password: passwordController.text,
                  code: codeController.text.trim(),
                );
                final token = snapshot.token;
                if (token == null || token.isEmpty) {
                  throw const IronVpnApiException(
                    'Сервер не вернул сессию аккаунта.',
                    0,
                  );
                }

                await _store.saveAccount(token: token, email: snapshot.email);
                _accountToken = token;
                _accountEmail = snapshot.email;
                await _applyAccountSnapshot(snapshot);
                _loginEmailController.text = snapshot.email;
                _loginPasswordController.clear();

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (mounted) {
                  setState(() {
                    _message = _hasAnyActive()
                        ? 'Пароль изменён. Подписки загружены.'
                        : 'Пароль изменён. Вход выполнен.';
                  });
                }
              } on IronVpnApiException catch (error) {
                if (dialogContext.mounted) {
                  setDialogState(() {
                    dialogBusy = false;
                    dialogError = error.message;
                  });
                }
              } catch (_) {
                if (dialogContext.mounted) {
                  setDialogState(() {
                    dialogBusy = false;
                    dialogError = 'Не удалось изменить пароль.';
                  });
                }
              }
            }

            return AlertDialog(
              title: Text(codeSent ? 'Введите код' : 'Восстановление пароля'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: emailController,
                      enabled: !dialogBusy && !codeSent,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (codeSent) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: codeController,
                        enabled: !dialogBusy,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Код из письма',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: passwordController,
                        enabled: !dialogBusy,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Новый пароль',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (dialogError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        dialogError!,
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: dialogBusy
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: Text('Отмена'),
                ),
                FilledButton(
                  onPressed: dialogBusy ? null : submit,
                  child: Text(
                    dialogBusy
                        ? 'Подождите...'
                        : codeSent
                            ? 'Изменить пароль'
                            : 'Получить код',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    emailController.dispose();
    codeController.dispose();
    passwordController.dispose();
  }

  Future<void> _openAccountSite() async {
    await launchUrl(
      Uri.parse(AppConfig.accountUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  void _openLoginScreen() {
    if (!mounted) {
      return;
    }
    setState(() {
      _showLoginScreen = true;
      _message = null;
    });
  }

  Future<void> _enforceAccessExpiry() async {
    final selectedActive = _isActive(_selectedProduct);
    if (!selectedActive &&
        (_state == VpnState.connected || _state == VpnState.connecting)) {
      await _vpn.stop();
      _state = VpnState.disconnected;
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _listenLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        await _handleIncomingLink(initial);
      }

      _linkSub = _appLinks.uriLinkStream.listen(_handleIncomingLink);
    } catch (_) {
      // Deep links are optional. Stored access remains available locally.
    }
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    final access = OrderAccess.fromUri(uri);
    if (access == null) {
      return;
    }

    await _store.saveOrderAccess(access);
    await _store.saveSelectedProduct(access.product);

    if (!mounted) {
      return;
    }

    setState(() {
      _access[access.product] = access;
      _selectedProduct = access.product;
      _message = 'Доступ привязан. Проверяю статус.';
    });
    await _refreshSubscription(access.product);
  }

  void _selectProduct(VpnProduct product) {
    if (_busy || product == _selectedProduct) {
      return;
    }

    if (_state == VpnState.connected ||
        _state == VpnState.connecting ||
        _state == VpnState.disconnecting) {
      _showTypeToast(
        'Сначала отключите подключение, затем выберите другой тип.',
      );
      return;
    }

    // Switching is a local UI action: show the already-cached state for the
    // chosen product instantly, then persist and refresh in the background so
    // the selector never blocks on the network (which made it feel glitchy).
    setState(() {
      _selectedProduct = product;
      _state = VpnState.disconnected;
      _message = null;
    });

    unawaited(_store.saveSelectedProduct(product).catchError((_) {}));
    unawaited(_refreshSubscription(product, silent: true));
  }

  Future<void> _refreshAllPending({required bool silent}) async {
    for (final product in VpnProduct.values) {
      if (_access[product] != null && !_isActive(product)) {
        await _refreshSubscription(product, silent: silent);
      }
    }
  }

  Future<void> _refreshSubscription(
    VpnProduct product, {
    bool silent = false,
  }) async {
    final accessVersion = _vpnAccessVersion;
    final access = await _store.loadOrderAccess(product) ?? _access[product];
    if (access == null) {
      return;
    }

    if (!silent && mounted) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }

    try {
      final hadAnyActive = _hasAnyActive();
      final subscription = await _api.fetchSubscription(access);
      if (accessVersion != _vpnAccessVersion) {
        return;
      }

      if (_accountToken == null && !subscription.isTrial) {
        await _store.clearOrderAccess(product);
        await _store.clearVpnProfile(product);
        if (!mounted || accessVersion != _vpnAccessVersion) {
          return;
        }
        setState(() {
          _access[product] = null;
          _subscriptions[product] = null;
          _profiles[product] = null;
          _state = VpnState.disconnected;
          _showLoginScreen = true;
          if (!silent) {
            _message = 'Войдите в аккаунт, чтобы использовать подписку.';
          }
        });
        return;
      }

      StoredVpnProfile? profile = _profiles[product];

      if (subscription.isActive) {
        profile = StoredVpnProfile.fromSubscription(subscription);
        await _store.saveVpnProfile(profile);
        await _store.clearPendingPaymentUrl(product);
      } else {
        profile = null;
        await _store.clearVpnProfile(product);
      }

      final selectedHasStoredAccess = _access[_selectedProduct] != null ||
          _profiles[_selectedProduct] != null;
      final shouldSelectProduct = subscription.isActive &&
          _connectedProduct == null &&
          (product == _selectedProduct || !selectedHasStoredAccess) &&
          (!hadAnyActive || !_isActive(_selectedProduct));

      if (shouldSelectProduct) {
        await _store.saveSelectedProduct(product);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _access[product] = access;
        _subscriptions[product] = subscription;
        _profiles[product] = profile;
        if (shouldSelectProduct) {
          _selectedProduct = product;
        }
        if (!silent) {
          _message = subscription.isActive
              ? '${product.title}: доступ есть, конфиг настроен.'
              : subscription.isTrial
                  ? 'Пробный доступ завершён. Войдите в аккаунт.'
                  : '${product.title}: активная подписка не найдена.';
        }
      });
    } on IronVpnApiException catch (error) {
      if (!silent) {
        _showMessage(error.message);
      }
    } catch (_) {
      if (!silent) {
        _showMessage('Не удалось обновить подписку.');
      }
    } finally {
      if (mounted && !silent) {
        setState(() => _busy = false);
      }
    }
  }

  // Re-issues the selected product's config (new server endpoint) and
  // re-imports it. Works for both VLESS and AmneziaWG.
  Future<void> _replaceConfig() async {
    if (_busy) {
      return;
    }
    final product = _selectedProduct;
    final access = _access[product];
    if (access == null) {
      _showMessage('Нет активного конфига для обновления.');
      return;
    }
    if (_state == VpnState.connected ||
        _state == VpnState.connecting ||
        _state == VpnState.disconnecting) {
      _showTypeToast(
        'Сначала отключите подключение, затем обновите конфигурацию.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final subscription = await _api.refreshConfig(access);
      if (!mounted) {
        return;
      }
      await _applySubscription(subscription);
      if (!mounted) {
        return;
      }
      setState(() {
        _message =
            'Конфигурация обновлена. Если были подключены — подключитесь заново.';
      });
    } on IronVpnApiException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('Не удалось обновить конфигурацию. Попробуйте позже.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openSettings() async {
    final sheetSelected = _selectedProduct;
    var sheetDarkTheme = widget.darkTheme;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> runAndRefresh(Future<void> Function() action) async {
                await action();
                if (mounted) {
                  setSheetState(() {});
                }
              }

              return Theme(
                data: _productTheme(context, sheetSelected),
                child: _SettingsPage(
                  selected: sheetSelected,
                  activeProducts: {
                    for (final item in VpnProduct.values) item: _isActive(item),
                  },
                  routeRussianDirect: _routeRussianDirect,
                  busy: _busy,
                  accountEmail: _accountEmail,
                  darkTheme: sheetDarkTheme,
                  onDarkThemeChanged: (value) {
                    setSheetState(() => sheetDarkTheme = value);
                    widget.onDarkThemeChanged(value);
                  },
                  onRouteChanged: (value) async {
                    final operation = _toggleRussianDirect(value);
                    if (mounted) {
                      setSheetState(() {});
                    }
                    await operation;
                    if (mounted) {
                      setSheetState(() {});
                    }
                  },
                  autostart: _autostart,
                  autoConnect: _autoConnect,
                  killSwitch: _killSwitch,
                  autoReconnect: _autoReconnect,
                  onAutostartChanged: (value) =>
                      runAndRefresh(() => _setAutostart(value)),
                  onAutoConnectChanged: (value) =>
                      runAndRefresh(() => _setAutoConnect(value)),
                  onKillSwitchChanged: (value) =>
                      runAndRefresh(() => _setKillSwitch(value)),
                  onAutoReconnectChanged: (value) =>
                      runAndRefresh(() => _setAutoReconnect(value)),
                  onOpenLogs: _openLogsFolder,
                  onSyncAccount: () => runAndRefresh(() => _syncAccount()),
                  onOpenAccount: _openAccountSite,
                  onLogin: () {
                    Navigator.of(sheetContext).pop();
                    _openLoginScreen();
                  },
                  onLogout: () => runAndRefresh(_logout),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _connect() async {
    if (_busy) {
      return;
    }

    final profile = _profiles[_selectedProduct];
    final subscription = _subscriptions[_selectedProduct];
    final canUseCachedWindowsProfile = Platform.isWindows &&
        profile != null &&
        _access[_selectedProduct] != null &&
        (subscription == null || subscription.isActive);
    _writeDesktopDebugLog(
      'connect product=${_selectedProduct.apiValue} '
      'profile=${profile != null} access=${_access[_selectedProduct] != null} '
      'subscription=${subscription?.status}/${subscription?.isActive} '
      'account=${_accountToken != null} cached=$canUseCachedWindowsProfile',
    );

    if (profile == null ||
        (!canUseCachedWindowsProfile &&
            (subscription == null || !subscription.isActive))) {
      _showMessage('Доступ закончился. Войдите в аккаунт.');
      return;
    }

    _userWantsConnected = true;
    setState(() {
      _busy = true;
      _state = VpnState.connecting;
      _message = null;
    });

    await _store.saveSelectedProduct(_selectedProduct);

    final prepared = await _vpn.prepare();
    if (!prepared) {
      setState(() {
        _busy = false;
        _state = VpnState.disconnected;
        _message = 'Разрешите подключение в системном окне.';
      });
      return;
    }

    final nextState = await _vpn.start(
      profile: profile,
      routeRussianServicesDirect: _routeRussianDirect,
      killSwitch: _killSwitch,
    );
    _writeDesktopDebugLog('connect result=$nextState');

    setState(() {
      _busy = false;
      _state = nextState;
      _connectedProduct =
          nextState == VpnState.connected ? profile.product : null;
      if (nextState == VpnState.unsupported) {
        _message = '${profile.product.title}: движок ещё не подключён.';
      } else if (nextState == VpnState.error) {
        _message = 'Ошибка запуска.';
      } else if (nextState == VpnState.disconnected) {
        _message = 'Не удалось запустить. Попробуйте ещё раз.';
      }
    });
  }

  Future<void> _disconnect() async {
    if (_busy) {
      return;
    }

    _userWantsConnected = false;
    setState(() {
      _busy = true;
      _state = VpnState.disconnecting;
      _message = null;
    });

    final nextState = await _vpn.stop();

    setState(() {
      _busy = false;
      _state = nextState;
      if (nextState != VpnState.connecting && nextState != VpnState.connected) {
        _connectedProduct = null;
      }
    });
  }

  Future<void> _syncVpnState() async {
    final state = await _vpn.status();
    if (!mounted) {
      return;
    }

    setState(() {
      _state = state;
      // Keep the selected product in sync with the live tunnel so resuming the
      // app never shows the wrong product as connected.
      if (state == VpnState.connected && _connectedProduct != null) {
        _selectedProduct = _connectedProduct!;
      } else if (state == VpnState.disconnected) {
        _connectedProduct = null;
      }
    });
  }

  Future<void> _toggleRussianDirect(bool value) async {
    if (_busy || value == _routeRussianDirect) {
      return;
    }

    final previousValue = _routeRussianDirect;
    final shouldReconnect =
        _state == VpnState.connected && _isActive(_selectedProduct);
    final profile = _profiles[_selectedProduct];

    if (mounted) {
      setState(() {
        _busy = true;
        _routeRussianDirect = value;
        if (shouldReconnect) {
          _state = VpnState.connecting;
        }
        _message = null;
      });
    }

    var nextState = shouldReconnect ? VpnState.connecting : _state;
    var applied = true;

    try {
      await _store.saveRouteRussianServicesDirect(value);

      if (shouldReconnect && profile != null) {
        await _vpn.stop();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        nextState = await _vpn.start(
          profile: profile,
          routeRussianServicesDirect: value,
          killSwitch: _killSwitch,
        );

        if (nextState != VpnState.connected) {
          applied = false;
          await _store.saveRouteRussianServicesDirect(previousValue);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          nextState = await _vpn.start(
            profile: profile,
            routeRussianServicesDirect: previousValue,
            killSwitch: _killSwitch,
          );
        }
      }
    } catch (_) {
      applied = false;
      await _store.saveRouteRussianServicesDirect(previousValue);
      nextState = await _vpn.status();
    }

    if (mounted) {
      setState(() {
        _busy = false;
        _routeRussianDirect = applied ? value : previousValue;
        _state = nextState;
        if (!applied || (shouldReconnect && nextState != VpnState.connected)) {
          _message =
              '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0440\u0438\u043c\u0435\u043d\u0438\u0442\u044c \u0440\u0435\u0436\u0438\u043c. \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u0435\u0441\u044c \u0435\u0449\u0435 \u0440\u0430\u0437.';
        }
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    _writeDesktopDebugLog('message: $message');
    setState(() {
      _busy = false;
      _message = message;
    });
  }

  void _writeDesktopDebugLog(String message) {
    if (!Platform.isWindows) {
      return;
    }
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.trim().isEmpty) {
        return;
      }
      final dir = Directory('$appData\\netineta\\sing-box');
      dir.createSync(recursive: true);
      final now = DateTime.now().toIso8601String();
      File('${dir.path}\\netineta-app.log').writeAsStringSync(
        '[$now] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  // Shows a transient toast floating over the VPN-type selector. It clears
  // itself after a few seconds, or immediately when tapped (_dismissTypeToast).
  void _showTypeToast(String message) {
    if (!mounted) {
      return;
    }
    _typeToastTimer?.cancel();
    setState(() => _typeToast = message);
    _typeToastTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) {
        setState(() => _typeToast = null);
      }
    });
  }

  void _dismissTypeToast() {
    _typeToastTimer?.cancel();
    if (mounted) {
      setState(() => _typeToast = null);
    }
  }

  bool _isActive(VpnProduct product) {
    if (_subscriptions[product]?.isActive == true &&
        _profiles[product] != null) {
      return true;
    }

    // Windows can start from a cached paid profile when the site is temporarily
    // unreachable, for example while testing PC AWG after disabling router AWG.
    return Platform.isWindows &&
        _profiles[product] != null &&
        _access[product] != null;
  }

  bool _hasAnyActive() {
    return VpnProduct.values.any(_isActive);
  }

  bool _isPending(VpnProduct product) {
    final status = _subscriptions[product]?.status;
    return _access[product] != null &&
        !_isActive(product) &&
        status != 'canceled' &&
        status != 'payment_error';
  }

  // Keeps the live session timer in sync with the connection state. Called once
  // per build, so it reacts to every _state change without having to touch each
  // assignment site. While connected, a 1s ticker rebuilds to advance the clock.
  void _updateSessionClock() {
    final connected = _state == VpnState.connected;
    if (connected && _connectedSince == null) {
      _connectedSince = DateTime.now();
      // Reset throughput counters for the new session.
      _lastRx = null;
      _lastTx = null;
      _baseRx = null;
      _baseTx = null;
      _lastStatsAt = null;
      _downBps = 0;
      _upBps = 0;
      _sessionDown = 0;
      _sessionUp = 0;
      _sessionTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
      _statsTimer ??=
          Timer.periodic(const Duration(seconds: 2), (_) => _pollStats());
      // Show the VPN exit IP once routing is up. AmneziaWG can take a moment to
      // route/resolve, so retry until it answers.
      Future<void>.delayed(
        const Duration(milliseconds: 1200),
        _refreshIpInfoWithRetry,
      );
    } else if (!connected && _connectedSince != null) {
      _connectedSince = null;
      _sessionTicker?.cancel();
      _sessionTicker = null;
      _statsTimer?.cancel();
      _statsTimer = null;
      _downBps = 0;
      _upBps = 0;
      // Back to the real IP.
      _refreshIpInfo();
    }
  }

  Future<void> _refreshIpInfo() async {
    if (!Platform.isWindows) {
      return;
    }
    final info = await _ipService.fetch();
    if (!mounted) {
      return;
    }
    setState(() => _ipInfo = info);
  }

  // Used right after a connect: the tunnel's routing/DNS may not be ready
  // immediately (especially AmneziaWG), so retry until the lookup answers.
  Future<void> _refreshIpInfoWithRetry() async {
    if (!Platform.isWindows) {
      return;
    }
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!mounted || _state != VpnState.connected) {
        return;
      }
      final info = await _ipService.fetch();
      if (!mounted) {
        return;
      }
      if (info != null) {
        setState(() => _ipInfo = info);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _pollStats() async {
    final bytes = await _vpn.tunnelBytes(_connectedProduct);
    if (!mounted || bytes == null) {
      return;
    }
    final (rx, tx) = bytes;
    final now = DateTime.now();
    _baseRx ??= rx;
    _baseTx ??= tx;
    if (_lastRx != null && _lastTx != null && _lastStatsAt != null) {
      final dt = now.difference(_lastStatsAt!).inMilliseconds / 1000.0;
      if (dt > 0) {
        final down = ((rx - _lastRx!) / dt).round();
        final up = ((tx - _lastTx!) / dt).round();
        _downBps = down < 0 ? 0 : down;
        _upBps = up < 0 ? 0 : up;
      }
    }
    _lastRx = rx;
    _lastTx = tx;
    _lastStatsAt = now;
    final sd = rx - _baseRx!;
    final su = tx - _baseTx!;
    if (sd >= 0) _sessionDown = sd;
    if (su >= 0) _sessionUp = su;
    setState(() {});
  }

  // Reconnects after an unexpected tunnel drop while the user wants to stay
  // connected and auto-reconnect is enabled.
  Future<void> _monitorConnection() async {
    if (!Platform.isWindows) {
      return;
    }
    if (!_userWantsConnected || !_autoReconnect || _busy) {
      return;
    }
    if (_state == VpnState.connecting || _state == VpnState.disconnecting) {
      return;
    }
    final status = await _vpn.status();
    if (!mounted) {
      return;
    }
    if (status == VpnState.connected) {
      if (_state != VpnState.connected) {
        setState(() => _state = VpnState.connected);
      }
      return;
    }
    _writeDesktopDebugLog('auto-reconnect: tunnel down, reconnecting');
    await _connect();
  }

  Future<void> _testDesktopPing() async {
    final profile = _profiles[_selectedProduct];
    if (profile == null) {
      _showMessage('Нет профиля для теста пинга.');
      return;
    }

    setState(() {
      _desktopPinging = true;
      _message = null;
    });

    final pingMs = await _vpn.testLatency(profile);
    if (!mounted) {
      return;
    }

    setState(() {
      _desktopPingMs = pingMs;
      _desktopPinging = false;
      if (pingMs == null) {
        _message = 'Сервер не ответил на быстрый TCP-тест.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _updateSessionClock();
    final connected = _state == VpnState.connected;
    final hasAnyActive = _hasAnyActive();
    final active = _isActive(_selectedProduct);
    final subscription = _subscriptions[_selectedProduct];
    final trialUsed = _subscriptions[VpnProduct.vless]?.isTrial == true;
    final initialLoading = !_initialLoadComplete;

    if (Platform.isWindows) {
      return Theme(
        data: _productTheme(context, _selectedProduct),
        child: _DesktopAppFrame(
          product: _selectedProduct,
          state: _state,
          busy: _busy,
          initialLoading: initialLoading,
          showAccess: !hasAnyActive || _showLoginScreen,
          accountEmail: _accountEmail,
          message: _message,
          trialUsed: trialUsed,
          routeRussianDirect: _routeRussianDirect,
          desktopPingMs: _desktopPingMs,
          desktopPinging: _desktopPinging,
          connectedSince: _connectedSince,
          telemetry: _DesktopTelemetry(
            ip: _ipInfo,
            connected: connected,
            downBps: _downBps,
            upBps: _upBps,
            sessionDown: _sessionDown,
            sessionUp: _sessionUp,
          ),
          access: Map<VpnProduct, OrderAccess?>.unmodifiable(_access),
          subscriptions:
              Map<VpnProduct, Subscription?>.unmodifiable(_subscriptions),
          profiles: Map<VpnProduct, StoredVpnProfile?>.unmodifiable(_profiles),
          activeProducts: {
            for (final item in VpnProduct.values) item: _isActive(item),
          },
          pendingProducts: {
            for (final item in VpnProduct.values) item: _isPending(item),
          },
          emailController: _loginEmailController,
          passwordController: _loginPasswordController,
          onSelected: _busy ? null : _selectProduct,
          onConnect: _connect,
          onDisconnect: _disconnect,
          onRefreshSelected: () => _refreshSubscription(_selectedProduct),
          onReplaceConfig: _replaceConfig,
          onRouteChanged: _busy ? null : _toggleRussianDirect,
          onSettings: _openSettings,
          onOpenLogin: _openLoginScreen,
          onLogin: _login,
          onForgotPassword: _showPasswordRecovery,
          onTrial: () => _claimTrial(),
          onOpenAccount: _openAccountSite,
          onRefreshAccount: () => _syncAccount(),
          onLogout: _logout,
          onBackFromAccess: hasAnyActive
              ? () => setState(() => _showLoginScreen = false)
              : null,
          onTestPing: _testDesktopPing,
        ),
      );
    }

    return Theme(
      data: _productTheme(context, _selectedProduct),
      child: Scaffold(
        body: _AppBackground(
          product: _selectedProduct,
          child: SafeArea(
            child: initialLoading
                ? _InitialLoadingView(
                    product: _selectedProduct,
                    state: _state,
                  )
                : hasAnyActive && !_showLoginScreen
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Header(
                              product: _selectedProduct,
                              state: _state,
                              onSettings: _openSettings,
                            ),
                            const SizedBox(height: 18),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final compact = constraints.maxHeight < 680;

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          _ModeSelector(
                                            selected: _selectedProduct,
                                            activeProducts: {
                                              for (final item
                                                  in VpnProduct.values)
                                                item: _isActive(item),
                                            },
                                            pendingProducts: {
                                              for (final item
                                                  in VpnProduct.values)
                                                item: _isPending(item),
                                            },
                                            compact: compact,
                                            onSelected:
                                                _busy ? null : _selectProduct,
                                          ),
                                          if (_typeToast != null)
                                            Positioned.fill(
                                              child: _TypeToast(
                                                message: _typeToast!,
                                                product: _selectedProduct,
                                                onDismiss: _dismissTypeToast,
                                              ),
                                            ),
                                        ],
                                      ),
                                      SizedBox(height: compact ? 10 : 16),
                                      _RoundConnectButton(
                                        busy: _busy,
                                        enabled: active,
                                        connected: connected,
                                        connecting:
                                            _state == VpnState.connecting,
                                        product: _selectedProduct,
                                        compact: compact,
                                        onConnect: _connect,
                                        onDisconnect: _disconnect,
                                      ),
                                      SizedBox(height: compact ? 10 : 14),
                                      Expanded(
                                        child: ScrollConfiguration(
                                          behavior:
                                              const _NoStretchScrollBehavior(),
                                          child: SingleChildScrollView(
                                            physics:
                                                const NeverScrollableScrollPhysics(),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                _SubscriptionPanel(
                                                  product: _selectedProduct,
                                                  subscription: subscription,
                                                  hasAccess: _access[
                                                          _selectedProduct] !=
                                                      null,
                                                  busy: _busy,
                                                  compact: compact,
                                                  onRefresh: () =>
                                                      _refreshSubscription(
                                                    _selectedProduct,
                                                  ),
                                                  onReplaceConfig:
                                                      _replaceConfig,
                                                ),
                                                if (_message != null) ...[
                                                  SizedBox(
                                                      height:
                                                          compact ? 10 : 14),
                                                  _MessagePanel(
                                                    product: _selectedProduct,
                                                    message: _message!,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_accountEmail == null) ...[
                                        SizedBox(height: compact ? 10 : 14),
                                        FilledButton.icon(
                                          onPressed:
                                              _busy ? null : _openLoginScreen,
                                          icon: const Icon(Icons.login_rounded),
                                          label: const Text('Войти в аккаунт'),
                                        ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      )
                    : ScrollConfiguration(
                        behavior: const _NoStretchScrollBehavior(),
                        child: ListView(
                          physics: const ClampingScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                          children: [
                            _Header(
                              product: _selectedProduct,
                              state: _state,
                              onSettings: null,
                            ),
                            const SizedBox(height: 20),
                            _AccessGate(
                              busy: _busy,
                              accountEmail: _accountEmail,
                              trialUsed: trialUsed,
                              emailController: _loginEmailController,
                              passwordController: _loginPasswordController,
                              onLogin: _login,
                              onForgotPassword: _showPasswordRecovery,
                              onTrial: () => _claimTrial(),
                              onOpenAccount: _openAccountSite,
                              onRefreshAccount: () => _syncAccount(),
                              onLogout: _logout,
                              onBack: hasAnyActive
                                  ? () =>
                                      setState(() => _showLoginScreen = false)
                                  : null,
                            ),
                            if (_message != null) ...[
                              const SizedBox(height: 16),
                              _MessagePanel(
                                product: _selectedProduct,
                                message: _message!,
                              ),
                            ],
                          ],
                        ),
                      ),
          ),
        ),
      ),
    );
  }
}

class _DesktopAppFrame extends StatelessWidget {
  const _DesktopAppFrame({
    required this.product,
    required this.state,
    required this.busy,
    required this.initialLoading,
    required this.showAccess,
    required this.accountEmail,
    required this.message,
    required this.trialUsed,
    required this.routeRussianDirect,
    required this.desktopPingMs,
    required this.desktopPinging,
    required this.connectedSince,
    required this.telemetry,
    required this.access,
    required this.subscriptions,
    required this.profiles,
    required this.activeProducts,
    required this.pendingProducts,
    required this.emailController,
    required this.passwordController,
    required this.onSelected,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRefreshSelected,
    required this.onReplaceConfig,
    required this.onRouteChanged,
    required this.onSettings,
    required this.onOpenLogin,
    required this.onLogin,
    required this.onForgotPassword,
    required this.onTrial,
    required this.onOpenAccount,
    required this.onRefreshAccount,
    required this.onLogout,
    required this.onBackFromAccess,
    required this.onTestPing,
  });

  final VpnProduct product;
  final VpnState state;
  final bool busy;
  final bool initialLoading;
  final bool showAccess;
  final String? accountEmail;
  final String? message;
  final bool trialUsed;
  final bool routeRussianDirect;
  final int? desktopPingMs;
  final bool desktopPinging;
  final DateTime? connectedSince;
  final _DesktopTelemetry telemetry;
  final Map<VpnProduct, OrderAccess?> access;
  final Map<VpnProduct, Subscription?> subscriptions;
  final Map<VpnProduct, StoredVpnProfile?> profiles;
  final Map<VpnProduct, bool> activeProducts;
  final Map<VpnProduct, bool> pendingProducts;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final ValueChanged<VpnProduct>? onSelected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRefreshSelected;
  final VoidCallback onReplaceConfig;
  final ValueChanged<bool>? onRouteChanged;
  final VoidCallback onSettings;
  final VoidCallback onOpenLogin;
  final VoidCallback onLogin;
  final VoidCallback onForgotPassword;
  final VoidCallback onTrial;
  final VoidCallback onOpenAccount;
  final VoidCallback onRefreshAccount;
  final VoidCallback onLogout;
  final VoidCallback? onBackFromAccess;
  final VoidCallback onTestPing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080A0D),
      body: LayoutBuilder(
        builder: (context, constraints) {
          const baseWidth = 980.0;
          const baseHeight = 620.0;
          final rawScale = math.min(
            constraints.maxWidth / baseWidth,
            constraints.maxHeight / baseHeight,
          );
          // Snap near-1.0 to exactly 1.0 so sub-pixel rounding of the client
          // area never triggers a resample; never upscale (keeps the window at
          // its native size).
          final scale = rawScale >= 0.995 ? 1.0 : math.min(1.0, rawScale);

          return Center(
            child: Transform.scale(
              scale: scale,
              child: SizedBox(
                width: baseWidth,
                height: baseHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.zero,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppGradients.backgroundFor(product),
                    ),
                    child: Row(
                      children: [
                        if (showAccess && !_kForceMainPreview)
                          Expanded(
                            child: _DesktopAccessPanel(
                              product: product,
                              busy: busy,
                              accountEmail: accountEmail,
                              trialUsed: trialUsed,
                              emailController: emailController,
                              passwordController: passwordController,
                              message: message,
                              onLogin: onLogin,
                              onForgotPassword: onForgotPassword,
                              onTrial: onTrial,
                              onOpenAccount: onOpenAccount,
                              onRefreshAccount: onRefreshAccount,
                              onLogout: onLogout,
                              onBack: onBackFromAccess,
                            ),
                          )
                        else ...[
                          _DesktopControlPane(
                            product: product,
                            busy: busy,
                            accountEmail: accountEmail,
                            routeRussianDirect: routeRussianDirect,
                            access: access,
                            subscriptions: subscriptions,
                            profiles: profiles,
                            activeProducts: activeProducts,
                            pendingProducts: pendingProducts,
                            onSelected: onSelected,
                            onRefreshSelected: onRefreshSelected,
                            onReplaceConfig: onReplaceConfig,
                            onRouteChanged: onRouteChanged,
                            onSettings: onSettings,
                          ),
                          Expanded(
                            child: _DesktopPowerPane(
                              product: product,
                              state: state,
                              busy: busy,
                              message: message,
                              profile: profiles[product],
                              subscription: subscriptions[product],
                              active: activeProducts[product] == true,
                              desktopPingMs: desktopPingMs,
                              desktopPinging: desktopPinging,
                              connectedSince: connectedSince,
                              telemetry: telemetry,
                              onConnect: onConnect,
                              onDisconnect: onDisconnect,
                              onTestPing: onTestPing,
                              onSettings: onSettings,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DesktopNavRail extends StatelessWidget {
  const _DesktopNavRail({
    required this.product,
    required this.accountEmail,
    required this.onSettings,
    required this.onLogin,
    required this.onLogout,
  });

  final VpnProduct product;
  final String? accountEmail;
  final VoidCallback onSettings;
  final VoidCallback onLogin;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return Container(
      width: 62,
      color: const Color(0xE6000000),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        children: [
          _DesktopRailButton(
            icon: Icons.arrow_forward_rounded,
            selected: false,
            accent: accent,
            onPressed: () {},
          ),
          const SizedBox(height: 18),
          _DesktopRailButton(
            icon: Icons.add_box_outlined,
            selected: false,
            accent: accent,
            onPressed: onLogin,
          ),
          const SizedBox(height: 14),
          _DesktopRailButton(
            icon: Icons.language_rounded,
            selected: true,
            accent: accent,
            onPressed: onLogin,
          ),
          const SizedBox(height: 14),
          _DesktopRailButton(
            icon: Icons.settings_outlined,
            selected: false,
            accent: accent,
            onPressed: onSettings,
          ),
          const SizedBox(height: 14),
          _DesktopRailButton(
            icon: Icons.monitor_heart_outlined,
            selected: false,
            accent: accent,
            onPressed: onSettings,
          ),
          const Spacer(),
          if (accountEmail != null)
            _DesktopRailButton(
              icon: Icons.logout_rounded,
              selected: false,
              accent: accent,
              onPressed: onLogout,
            )
          else
            _DesktopRailButton(
              icon: Icons.login_rounded,
              selected: false,
              accent: accent,
              onPressed: onLogin,
            ),
          const SizedBox(height: 14),
          Icon(Icons.info_rounded, size: 18, color: AppColors.inkSoft),
        ],
      ),
    );
  }
}

class _DesktopRailButton extends StatelessWidget {
  const _DesktopRailButton({
    required this.icon,
    required this.selected,
    required this.accent,
    required this.onPressed,
  });

  final IconData icon;
  final bool selected;
  final Color accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        backgroundColor:
            selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
        foregroundColor: selected ? accent : AppColors.inkSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

class _DesktopAccessPanel extends StatelessWidget {
  const _DesktopAccessPanel({
    required this.product,
    required this.busy,
    required this.accountEmail,
    required this.trialUsed,
    required this.emailController,
    required this.passwordController,
    required this.message,
    required this.onLogin,
    required this.onForgotPassword,
    required this.onTrial,
    required this.onOpenAccount,
    required this.onRefreshAccount,
    required this.onLogout,
    required this.onBack,
  });

  final VpnProduct product;
  final bool busy;
  final String? accountEmail;
  final bool trialUsed;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final String? message;
  final VoidCallback onLogin;
  final VoidCallback onForgotPassword;
  final VoidCallback onTrial;
  final VoidCallback onOpenAccount;
  final VoidCallback onRefreshAccount;
  final VoidCallback onLogout;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          // Reserve room at the bottom for the floating message so the card
          // never has to scroll under it.
          padding: EdgeInsets.fromLTRB(24, 18, 24, message != null ? 84 : 18),
          child: Center(
            child: SizedBox(
              width: 500,
              child: LayoutBuilder(
                builder: (context, constraints) => ScrollConfiguration(
                  behavior: const _NoStretchScrollBehavior(),
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'netineta',
                            style: TextStyle(
                              color: AppColors.ink,
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _AccessGate(
                            busy: busy,
                            accountEmail: accountEmail,
                            trialUsed: trialUsed,
                            emailController: emailController,
                            passwordController: passwordController,
                            onLogin: onLogin,
                            onForgotPassword: onForgotPassword,
                            onTrial: onTrial,
                            onOpenAccount: onOpenAccount,
                            onRefreshAccount: onRefreshAccount,
                            onLogout: onLogout,
                            onBack: onBack,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (message != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 16,
            child: _MessagePanel(product: product, message: message!),
          ),
      ],
    );
  }
}

class _DesktopControlPane extends StatelessWidget {
  const _DesktopControlPane({
    required this.product,
    required this.busy,
    required this.accountEmail,
    required this.routeRussianDirect,
    required this.access,
    required this.subscriptions,
    required this.profiles,
    required this.activeProducts,
    required this.pendingProducts,
    required this.onSelected,
    required this.onRefreshSelected,
    required this.onReplaceConfig,
    required this.onRouteChanged,
    required this.onSettings,
  });

  final VpnProduct product;
  final bool busy;
  final String? accountEmail;
  final bool routeRussianDirect;
  final Map<VpnProduct, OrderAccess?> access;
  final Map<VpnProduct, Subscription?> subscriptions;
  final Map<VpnProduct, StoredVpnProfile?> profiles;
  final Map<VpnProduct, bool> activeProducts;
  final Map<VpnProduct, bool> pendingProducts;
  final ValueChanged<VpnProduct>? onSelected;
  final VoidCallback onRefreshSelected;
  final VoidCallback onReplaceConfig;
  final ValueChanged<bool>? onRouteChanged;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final subscription = subscriptions[product];
    final profile = profiles[product];
    final active = activeProducts[product] == true;

    return Container(
      width: 410,
      padding: const EdgeInsets.fromLTRB(28, 24, 24, 24),
      decoration: const BoxDecoration(
        color: Color(0xB0000000),
        border: Border(right: BorderSide(color: Color(0x16FFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/app_logo_mark.png',
                width: 42,
                height: 42,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'netineta',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      accountEmail ?? 'Аккаунт не подключен',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            accountEmail == null ? AppColors.inkMuted : accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              _DesktopRoundIconButton(
                icon: Icons.settings_rounded,
                tooltip: 'Настройки',
                onPressed: onSettings,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Тип VPN',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DesktopTypeCard(
                  product: VpnProduct.vless,
                  selected: product == VpnProduct.vless,
                  active: activeProducts[VpnProduct.vless] == true,
                  pending: pendingProducts[VpnProduct.vless] == true,
                  subscription: subscriptions[VpnProduct.vless],
                  onTap: () => onSelected?.call(VpnProduct.vless),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DesktopTypeCard(
                  product: VpnProduct.amneziaWg,
                  selected: product == VpnProduct.amneziaWg,
                  active: activeProducts[VpnProduct.amneziaWg] == true,
                  pending: pendingProducts[VpnProduct.amneziaWg] == true,
                  subscription: subscriptions[VpnProduct.amneziaWg],
                  onTap: () => onSelected?.call(VpnProduct.amneziaWg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _DesktopSubscriptionCard(
            product: product,
            active: active,
            subscription: subscription,
            profile: profile,
            onRefresh: busy ? null : onRefreshSelected,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onReplaceConfig,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Обновить конфиг'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DesktopTypeCard extends StatelessWidget {
  const _DesktopTypeCard({
    required this.product,
    required this.selected,
    required this.active,
    required this.pending,
    required this.subscription,
    required this.onTap,
  });

  final VpnProduct product;
  final bool selected;
  final bool active;
  final bool pending;
  final Subscription? subscription;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final status = active
        ? 'Подписка активна'
        : pending
            ? 'Ожидает'
            : 'Нет доступа';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 112,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.16)
                : const Color(0x18FFFFFF),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? accent : const Color(0x20FFFFFF),
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.16),
                      blurRadius: 22,
                      spreadRadius: -10,
                      offset: const Offset(0, 14),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _DesktopProductBadge(product: product, small: true),
                  const Spacer(),
                  Icon(
                    active ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 18,
                    color: active ? accent : AppColors.inkMuted,
                  ),
                ],
              ),
              const Spacer(),
              Text(
                _desktopProductTitle(product),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? accent : AppColors.inkMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopSubscriptionCard extends StatelessWidget {
  const _DesktopSubscriptionCard({
    required this.product,
    required this.active,
    required this.subscription,
    required this.profile,
    required this.onRefresh,
  });

  final VpnProduct product;
  final bool active;
  final Subscription? subscription;
  final StoredVpnProfile? profile;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final expires = _desktopDate(subscription?.expiresAt);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x20FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  active ? 'Подписка активна' : 'Нет доступа',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _DesktopRoundIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Обновить данные',
                onPressed: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Действует до',
            style: TextStyle(
              color: AppColors.inkSoft,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            expires.isEmpty ? '—' : expires,
            style: TextStyle(
              color: active ? accent : AppColors.inkMuted,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0x0AFFFFFF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Column(
              children: [
                _DesktopInfoRow(
                  icon: Icons.badge_rounded,
                  accent: accent,
                  label: 'Профиль',
                  value: profile?.name ?? 'Не создан',
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 9),
                  child: Divider(height: 1, thickness: 1, color: Color(0x12FFFFFF)),
                ),
                _DesktopInfoRow(
                  icon: product == VpnProduct.vless
                      ? Icons.shield_rounded
                      : Icons.bolt_rounded,
                  accent: accent,
                  label: 'Тип',
                  value: product == VpnProduct.vless
                      ? 'VLESS Reality'
                      : 'AmneziaWG',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopRouteCard extends StatelessWidget {
  const _DesktopRouteCard({
    required this.product,
    required this.value,
    required this.onChanged,
  });

  final VpnProduct product;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: Row(
        children: [
          Icon(Icons.route_rounded, color: accent, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'РФ-сервисы напрямую',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Банки, маркетплейсы и локальные сайты без VPN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.inkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _DesktopInfoRow extends StatelessWidget {
  const _DesktopInfoRow({
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color accent;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, size: 17, color: accent),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: AppColors.inkMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DesktopRoundIconButton extends StatelessWidget {
  const _DesktopRoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size(42, 42),
        backgroundColor: const Color(0x14FFFFFF),
        foregroundColor: AppColors.ink,
        disabledForegroundColor: AppColors.inkMuted,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class _DesktopServerPane extends StatelessWidget {
  const _DesktopServerPane({
    required this.product,
    required this.busy,
    required this.routeRussianDirect,
    required this.access,
    required this.subscriptions,
    required this.profiles,
    required this.activeProducts,
    required this.pendingProducts,
    required this.onSelected,
    required this.onRefreshSelected,
    required this.onReplaceConfig,
    required this.onRouteChanged,
  });

  final VpnProduct product;
  final bool busy;
  final bool routeRussianDirect;
  final Map<VpnProduct, OrderAccess?> access;
  final Map<VpnProduct, Subscription?> subscriptions;
  final Map<VpnProduct, StoredVpnProfile?> profiles;
  final Map<VpnProduct, bool> activeProducts;
  final Map<VpnProduct, bool> pendingProducts;
  final ValueChanged<VpnProduct>? onSelected;
  final VoidCallback onRefreshSelected;
  final VoidCallback onReplaceConfig;
  final ValueChanged<bool>? onRouteChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 470,
      color: const Color(0xA9000000),
      padding: const EdgeInsets.fromLTRB(28, 24, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Серверы',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 25,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _DesktopSearchBox(),
          const SizedBox(height: 14),
          Expanded(
            child: ScrollConfiguration(
              behavior: const _NoStretchScrollBehavior(),
              child: ListView(
                physics: const ClampingScrollPhysics(),
                children: [
                  _DesktopServerGroup(
                    title: 'Список серверов',
                    subtitle: 'Автовыбор лучшего маршрута',
                    child: _DesktopServerTile(
                      product: VpnProduct.vless,
                      selected: product == VpnProduct.vless,
                      active: activeProducts[VpnProduct.vless] == true,
                      pending: pendingProducts[VpnProduct.vless] == true,
                      profile: profiles[VpnProduct.vless],
                      subscription: subscriptions[VpnProduct.vless],
                      onTap: () => onSelected?.call(VpnProduct.vless),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _DesktopServerGroup(
                    title: 'VPN',
                    subtitle: _desktopRenewText(subscriptions[product]),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Обновить данные',
                          onPressed: busy ? null : onRefreshSelected,
                          icon: const Icon(Icons.refresh_rounded, size: 19),
                        ),
                        IconButton(
                          tooltip: 'Заменить конфиг',
                          onPressed: busy ? null : onReplaceConfig,
                          icon: const Icon(Icons.sync_rounded, size: 19),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _DesktopServerTile(
                          product: VpnProduct.vless,
                          selected: product == VpnProduct.vless,
                          active: activeProducts[VpnProduct.vless] == true,
                          pending: pendingProducts[VpnProduct.vless] == true,
                          profile: profiles[VpnProduct.vless],
                          subscription: subscriptions[VpnProduct.vless],
                          onTap: () => onSelected?.call(VpnProduct.vless),
                        ),
                        const Divider(height: 1, color: Color(0x1FFFFFFF)),
                        _DesktopServerTile(
                          product: VpnProduct.amneziaWg,
                          selected: product == VpnProduct.amneziaWg,
                          active: activeProducts[VpnProduct.amneziaWg] == true,
                          pending:
                              pendingProducts[VpnProduct.amneziaWg] == true,
                          profile: profiles[VpnProduct.amneziaWg],
                          subscription: subscriptions[VpnProduct.amneziaWg],
                          onTap: () => onSelected?.call(VpnProduct.amneziaWg),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _DesktopServerGroup(
                    title: 'Маршрутизация',
                    subtitle: 'Озон, банки и РФ-сервисы напрямую',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.route_rounded,
                            color: AppColors.accentFor(product),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'РФ-сервисы напрямую',
                              style: TextStyle(
                                color: AppColors.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Switch(
                            value: routeRussianDirect,
                            onChanged: onRouteChanged,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopSearchBox extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: TextField(
        enabled: false,
        style: TextStyle(color: AppColors.ink),
        decoration: InputDecoration(
          hintText: 'Введите текст для поиска',
          hintStyle: TextStyle(color: AppColors.inkMuted),
          suffixIcon: Icon(Icons.search_rounded, color: AppColors.inkSoft),
          filled: true,
          fillColor: const Color(0x1FFFFFFF),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: AppColors.glassBorderStrong),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: AppColors.glassBorderStrong),
          ),
        ),
      ),
    );
  }
}

class _DesktopServerGroup extends StatelessWidget {
  const _DesktopServerGroup({
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF262827),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 13, right: 8),
            color: const Color(0x263F3F3F),
            child: Row(
              children: [
                Icon(Icons.expand_more_rounded,
                    color: AppColors.inkMuted, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.inkMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                trailing ??
                    Icon(Icons.more_horiz_rounded,
                        color: AppColors.inkSoft, size: 22),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DesktopServerTile extends StatelessWidget {
  const _DesktopServerTile({
    required this.product,
    required this.selected,
    required this.active,
    required this.pending,
    required this.profile,
    required this.subscription,
    required this.onTap,
  });

  final VpnProduct product;
  final bool selected;
  final bool active;
  final bool pending;
  final StoredVpnProfile? profile;
  final Subscription? subscription;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final name = profile?.name ?? _desktopProductTitle(product);
    final status = active
        ? 'Подписка активна'
        : pending
            ? 'Ожидает активации'
            : 'Нет доступа';

    return Material(
      color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? accent : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Row(
            children: [
              _DesktopProductBadge(product: product, small: true),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${product.shortTitle} / ${product == VpnProduct.vless ? 'TCP / REALITY' : 'AWG 2.0'} · $status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.inkMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (subscription?.expiresAt != null)
                Text(
                  _desktopDate(subscription!.expiresAt),
                  style: TextStyle(
                    color: AppColors.inkSoft,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  color: AppColors.inkMuted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopPowerPane extends StatelessWidget {
  const _DesktopPowerPane({
    required this.product,
    required this.state,
    required this.busy,
    required this.message,
    required this.profile,
    required this.subscription,
    required this.active,
    required this.desktopPingMs,
    required this.desktopPinging,
    this.connectedSince,
    this.telemetry = const _DesktopTelemetry(),
    required this.onConnect,
    required this.onDisconnect,
    required this.onTestPing,
    required this.onSettings,
  });

  final VpnProduct product;
  final VpnState state;
  final bool busy;
  final String? message;
  final StoredVpnProfile? profile;
  final Subscription? subscription;
  final bool active;
  final int? desktopPingMs;
  final bool desktopPinging;
  final DateTime? connectedSince;
  final _DesktopTelemetry telemetry;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onTestPing;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final connected = state == VpnState.connected;
    final accent = AppColors.accentFor(product);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.4),
          radius: 1.2,
          colors: [
            accent.withValues(alpha: 0.16),
            const Color(0xFF171922),
            const Color(0xFF101218),
          ],
          stops: const [0, 0.46, 1],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Rings and the animated power button live in one fixed, centered
          // field, so the button is always dead-centre of the rings regardless
          // of how tall the info block below grows.
          LayoutBuilder(
            builder: (context, constraints) => ScrollConfiguration(
              behavior: const _NoStretchScrollBehavior(),
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                SizedBox(
                  width: 260,
                  height: 260,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _DesktopSweepPainter(accent: accent),
                        ),
                      ),
                      _RoundConnectButton(
                        busy: busy,
                        enabled: active,
                        connected: connected,
                        connecting: state == VpnState.connecting,
                        product: product,
                        compact: true,
                        showLabel: false,
                        onConnect: onConnect,
                        onDisconnect: onDisconnect,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 290,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        profile?.name ?? _desktopProductTitle(product),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        connected
                            ? 'Подключено'
                            : active
                                ? 'Готово к подключению'
                                : 'Нет доступа',
                        style: TextStyle(
                          color: connected ? accent : AppColors.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Fixed-height telemetry strip: reserves constant space so
                      // the layout — and the power button above — never shifts
                      // when these lines appear/disappear on connect/disconnect.
                      SizedBox(
                        height: 90,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (connected && connectedSince != null)
                              Text(
                                _formatSessionDuration(
                                  DateTime.now().difference(connectedSince!),
                                ),
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            if (telemetry.ip != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      connected
                                          ? Icons.lock_rounded
                                          : Icons.lock_open_rounded,
                                      size: 13,
                                      color: connected
                                          ? accent
                                          : AppColors.inkMuted,
                                    ),
                                    const SizedBox(width: 5),
                                    Flexible(
                                      child: Text(
                                        telemetry.ip!.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: connected
                                              ? AppColors.inkSoft
                                              : AppColors.inkMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (connected)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.south_rounded,
                                            size: 13, color: accent),
                                        const SizedBox(width: 3),
                                        Text(
                                          _formatSpeed(telemetry.downBps),
                                          style: TextStyle(
                                            color: AppColors.ink,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 14),
                                        Icon(Icons.north_rounded,
                                            size: 13, color: accent),
                                        const SizedBox(width: 3),
                                        Text(
                                          _formatSpeed(telemetry.upBps),
                                          style: TextStyle(
                                            color: AppColors.ink,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'За сессию  ↓ ${_formatBytes(telemetry.sessionDown)}  ↑ ${_formatBytes(telemetry.sessionUp)}',
                                      style: TextStyle(
                                        color: AppColors.inkMuted,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (subscription?.expiresAt != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Доступ до ${_desktopDate(subscription!.expiresAt)}',
                          style: TextStyle(
                            color: AppColors.inkMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: desktopPinging ? null : onTestPing,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(210, 42),
                          backgroundColor: accent.withValues(alpha: 0.92),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        child: Text(
                          desktopPinging
                              ? 'Проверяем...'
                              : desktopPingMs == null
                                  ? 'Тест пинга'
                                  : 'Пинг $desktopPingMs мс',
                        ),
                      ),
                      const SizedBox(height: 18),
                      _DesktopConnectionMode(product: product),
                    ],
                  ),
                ),
              ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // The message sits as a bottom overlay so showing it (e.g. an error)
          // never grows the centered column and shifts the button/info.
          if (message != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 20,
              child: _MessagePanel(product: product, message: message!),
            ),
        ],
      ),
    );
  }
}

class _DesktopProductBadge extends StatelessWidget {
  const _DesktopProductBadge({required this.product, this.small = false});

  final VpnProduct product;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return Container(
      width: small ? 26 : 48,
      height: small ? 26 : 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent.withValues(alpha: 0.16),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      alignment: Alignment.center,
      child: Icon(
        product == VpnProduct.vless ? Icons.shield_rounded : Icons.bolt_rounded,
        color: accent,
        size: small ? 15 : 25,
      ),
    );
  }
}

class _DesktopFlag extends StatelessWidget {
  const _DesktopFlag({required this.product});

  final VpnProduct product;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFFFFFFF),
      ),
      alignment: Alignment.center,
      child: const Text('🇷🇺', style: TextStyle(fontSize: 24)),
    );
  }
}

class _DesktopConnectionMode extends StatelessWidget {
  const _DesktopConnectionMode({required this.product});

  final VpnProduct product;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: accent.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, color: accent, size: 18),
          const SizedBox(width: 8),
          Text(
            product == VpnProduct.vless ? 'TUN · VLESS Reality' : 'AWG 2.0',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTunSwitch extends StatelessWidget {
  const _DesktopTunSwitch({required this.product});

  final VpnProduct product;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DesktopModeChip(label: 'Proxy', selected: false, accent: accent),
            _DesktopModeChip(label: 'TUN', selected: true, accent: accent),
          ],
        ),
      ),
    );
  }
}

class _DesktopModeChip extends StatelessWidget {
  const _DesktopModeChip({
    required this.label,
    required this.selected,
    required this.accent,
  });

  final String label;
  final bool selected;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : AppColors.inkSoft,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _DesktopSweepPainter extends CustomPainter {
  const _DesktopSweepPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // Full, evenly-spaced concentric circles centered in the field that also
    // holds the power button — symmetric, so nothing looks off to one side.
    final center = size.center(Offset.zero);
    final base = size.shortestSide;
    canvas.drawCircle(
        center, base * 0.34, paint..color = accent.withValues(alpha: 0.22));
    canvas.drawCircle(
        center, base * 0.42, paint..color = accent.withValues(alpha: 0.14));
    canvas.drawCircle(
        center, base * 0.49, paint..color = accent.withValues(alpha: 0.08));
  }

  @override
  bool shouldRepaint(covariant _DesktopSweepPainter oldDelegate) {
    return oldDelegate.accent != accent;
  }
}

String _desktopProductTitle(VpnProduct product) {
  return switch (product) {
    VpnProduct.vless => 'Обычный',
    VpnProduct.amneziaWg => 'AmneziaWG',
  };
}

// Live session length as H:MM:SS (or MM:SS under an hour).
String _formatSessionDuration(Duration d) {
  if (d.isNegative) {
    d = Duration.zero;
  }
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes Б';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} КБ';
  }
  final mb = kb / 1024;
  if (mb < 1024) {
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} МБ';
  }
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 2 : 1)} ГБ';
}

String _formatSpeed(int bytesPerSec) => '${_formatBytes(bytesPerSec)}/с';

// Live connection telemetry shown on the desktop power pane.
class _DesktopTelemetry {
  const _DesktopTelemetry({
    this.ip,
    this.connected = false,
    this.downBps = 0,
    this.upBps = 0,
    this.sessionDown = 0,
    this.sessionUp = 0,
  });

  final IpInfo? ip;
  final bool connected;
  final int downBps;
  final int upBps;
  final int sessionDown;
  final int sessionUp;
}

String _desktopRenewText(Subscription? subscription) {
  if (subscription?.expiresAt == null) {
    return 'Данные подписки обновляются вручную';
  }
  return 'Истекает: ${_desktopDate(subscription!.expiresAt)}';
}

String _desktopDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) {
    final day = parsed.day.toString().padLeft(2, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    return '$day.$month.${parsed.year}';
  }
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(raw);
  if (match != null) {
    return '${match.group(3)}.${match.group(2)}.${match.group(1)}';
  }
  return raw;
}

class _NoStretchScrollBehavior extends ScrollBehavior {
  const _NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }
}

class _InitialLoadingView extends StatelessWidget {
  const _InitialLoadingView({
    required this.product,
    required this.state,
  });

  final VpnProduct product;
  final VpnState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            product: product,
            state: state,
            onSettings: null,
          ),
          const Spacer(),
          Center(
            child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: AppColors.accentFor(product),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _AppBackground extends StatelessWidget {
  const _AppBackground({
    required this.product,
    required this.child,
  });

  final VpnProduct product;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: AppGradients.backgroundFor(product),
        ),
        child: child,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.product,
    required this.state,
    required this.onSettings,
  });

  final VpnProduct product;
  final VpnState state;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.glassStrong,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.glassBorder),
            boxShadow: AppShadows.tile,
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Image.asset(
              'assets/app_logo_mark.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'netineta',
                style: TextStyle(
                  fontSize: 24,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: AppColors.ink,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Стабильное соединение',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
          ),
        ),
        if (onSettings == null)
          _StatusChip(product: product, state: state)
        else
          IconButton.filledTonal(
            onPressed: onSettings,
            icon: Icon(Icons.tune_rounded),
            tooltip: 'Настройки',
          ),
      ],
    );
  }
}

// Product type is chosen on the home screen; kept here for possible reuse.
// ignore: unused_element
class _ProductSwitcher extends StatelessWidget {
  const _ProductSwitcher({
    required this.title,
    required this.selected,
    required this.activeProducts,
    required this.pendingProducts,
    required this.subscriptions,
    required this.onSelected,
    required this.onRefresh,
  });

  final String title;
  final VpnProduct selected;
  final Map<VpnProduct, bool> activeProducts;
  final Map<VpnProduct, bool> pendingProducts;
  final Map<VpnProduct, Subscription?> subscriptions;
  final ValueChanged<VpnProduct>? onSelected;
  final ValueChanged<VpnProduct>? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 12),
        for (final product in VpnProduct.values) ...[
          _ProductCard(
            product: product,
            selected: selected == product,
            active: activeProducts[product] == true,
            pending: pendingProducts[product] == true,
            subscription: subscriptions[product],
            onTap: onSelected == null ? null : () => onSelected!(product),
            onRefresh: onRefresh == null ? null : () => onRefresh!(product),
          ),
          if (product != VpnProduct.values.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.selected,
    required this.active,
    required this.pending,
    required this.subscription,
    required this.onTap,
    required this.onRefresh,
  });

  final VpnProduct product;
  final bool selected;
  final bool active;
  final bool pending;
  final Subscription? subscription;
  final VoidCallback? onTap;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final status = active
        ? 'Доступ активирован'
        : pending
            ? 'Проверяется'
            : 'Нет доступа';
    final accent = AppColors.accentFor(product);
    final expiry =
        subscription?.isTrial == true && subscription?.expiresMs != null
            ? _formatTrialExpiry(subscription!.expiresMs!)
            : subscription?.expiresAt?.isNotEmpty == true
                ? subscription!.expiresAt!
                : null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.card,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    accent.withValues(alpha: AppColors.isDark ? 0.15 : 0.08),
                    AppColors.glassStrong,
                  )
                : AppColors.glass,
            borderRadius: AppRadii.card,
            border: Border.all(
              color: selected ? accent : AppColors.glassBorder,
              width: selected ? 2 : 1,
            ),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [accent, AppColors.accentDeepFor(product)],
                  ),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.32),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Icon(
                  product == VpnProduct.vless
                      ? Icons.shield_rounded
                      : Icons.bolt_rounded,
                  color:
                      AppColors.isDark ? const Color(0xFF04130D) : Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            product.title,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: AppColors.ink,
                            ),
                          ),
                        ),
                        _MiniChip(label: status, color: accent),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      product.description,
                      style: TextStyle(
                        color: AppColors.inkSoft,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 1,
                      color: AppColors.glassBorder,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                active
                                    ? subscription?.isTrial == true
                                        ? 'Пробный доступ до'
                                        : 'Действует до'
                                    : pending
                                        ? 'Статус подписки'
                                        : 'Подписка',
                                style: TextStyle(
                                  color: AppColors.inkMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                active && expiry != null
                                    ? expiry
                                    : pending
                                        ? 'Проверяется'
                                        : 'Нет доступа',
                                style: TextStyle(
                                  color: active ? accent : AppColors.inkSoft,
                                  fontSize: active ? 18 : 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: onRefresh,
                          tooltip: 'Обновить подписку',
                          icon: Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.selected,
    required this.activeProducts,
    required this.pendingProducts,
    required this.compact,
    required this.onSelected,
  });

  final VpnProduct selected;
  final Map<VpnProduct, bool> activeProducts;
  final Map<VpnProduct, bool> pendingProducts;
  final bool compact;
  final ValueChanged<VpnProduct>? onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.glass,
        borderRadius: AppRadii.tile,
        border: Border.all(color: AppColors.glassBorder),
        boxShadow: AppShadows.tile,
      ),
      child: Row(
        children: [
          for (final product in VpnProduct.values)
            Expanded(
              child: _ModeSegmentButton(
                product: product,
                selected: selected == product,
                active: activeProducts[product] == true,
                pending: pendingProducts[product] == true,
                compact: compact,
                onTap: onSelected == null ? null : () => onSelected!(product),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeSegmentButton extends StatelessWidget {
  const _ModeSegmentButton({
    required this.product,
    required this.selected,
    required this.active,
    required this.pending,
    required this.compact,
    required this.onTap,
  });

  final VpnProduct product;
  final bool selected;
  final bool active;
  final bool pending;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final label = product == VpnProduct.vless ? 'Обычный' : 'AWG';
    final status = active
        ? 'активен'
        : pending
            ? 'проверка'
            : 'нет';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: compact ? 8 : 11,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.glassStrong : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
            boxShadow: selected ? AppShadows.tile : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.check_circle_rounded
                    : Icons.lock_outline_rounded,
                size: compact ? 17 : 19,
                color: selected ? accent : AppColors.inkMuted,
              ),
              SizedBox(height: compact ? 3 : 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? accent : AppColors.ink,
                ),
              ),
              SizedBox(height: compact ? 1 : 2),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big on/off button.
///
/// Performance: the old version stacked three large-blur (up to 84px) shadows
/// that repainted constantly. This version uses a single soft shadow plus one
/// cheap [RadialGradient] pulse ring, all isolated behind a [RepaintBoundary]
/// so only this widget repaints while it animates. The pulse controller only
/// runs while connected, so an idle screen costs nothing.
// Futuristic "link-up" ring: a faint track plus a bright sweeping arc that
// fades into transparency, rotated continuously while connecting.
class _ConnectingRingPainter extends CustomPainter {
  _ConnectingRingPainter({
    required this.color,
    required this.track,
    required this.strokeWidth,
  });

  final Color color;
  final Color track;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = track,
    );

    // The comet fades in from transparent (tail) to opaque (head). The extra
    // transparent stop past the head keeps the SweepGradient's wrap-around seam
    // transparent, so the round cap at the arc's start has nothing opaque to
    // latch onto — otherwise it rendered as a stray dot at the tail.
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color,
          color,
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.58, 0.66, 0.82],
        transform: const GradientRotation(-1.5708),
      ).createShader(rect);
    canvas.drawArc(rect, -1.5708, 3.9, false, sweep);
  }

  @override
  bool shouldRepaint(covariant _ConnectingRingPainter old) =>
      old.color != color ||
      old.track != track ||
      old.strokeWidth != strokeWidth;
}

class _RoundConnectButton extends StatefulWidget {
  const _RoundConnectButton({
    required this.busy,
    required this.enabled,
    required this.connected,
    required this.connecting,
    required this.product,
    required this.compact,
    this.showLabel = true,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool busy;
  final bool enabled;
  final bool connected;
  final bool connecting;
  final VpnProduct product;
  final bool compact;
  // When false, only the animated orb is rendered (no state caption beneath).
  // The desktop pane shows its own status text, so it hides this one.
  final bool showLabel;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  State<_RoundConnectButton> createState() => _RoundConnectButtonState();
}

class _RoundConnectButtonState extends State<_RoundConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    if (widget.connected) {
      _pulse.repeat(reverse: true);
    }
    if (widget.connecting) {
      _spin.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _RoundConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connected && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.connected && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
    if (widget.connecting && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.connecting && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(widget.product);
    final accentDeep = AppColors.accentDeepFor(widget.product);
    final canTap = !widget.busy && widget.enabled;
    final size = widget.compact ? 152.0 : 178.0;
    final iconSize = widget.compact ? 60.0 : 70.0;
    final stateLabel = widget.connecting
        ? 'Подключение…'
        : widget.connected
            ? '${widget.product.shortTitle} включён'
            : widget.enabled
                ? 'Нажмите для подключения'
                : 'Недоступно';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: SizedBox(
            width: size + 56,
            height: size + 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.connected)
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) {
                      final t = Curves.easeOut.transform(_pulse.value);
                      return Container(
                        width: size + 20 + 36 * t,
                        height: size + 20 + 36 * t,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              accent.withValues(alpha: 0.22 * (1 - t)),
                              accent.withValues(alpha: 0),
                            ],
                            stops: const [0.6, 1.0],
                          ),
                        ),
                      );
                    },
                  ),
                if (widget.connecting)
                  RotationTransition(
                    turns: _spin,
                    child: CustomPaint(
                      size: Size.square(size + 24),
                      painter: _ConnectingRingPainter(
                        color: accent,
                        track: accent.withValues(alpha: 0.12),
                        strokeWidth: widget.compact ? 4.5 : 5.5,
                      ),
                    ),
                  ),
                Semantics(
                  button: true,
                  enabled: canTap,
                  label: widget.connected ? 'Отключить' : 'Подключить',
                  child: GestureDetector(
                    onTap: canTap
                        ? (widget.connected
                            ? widget.onDisconnect
                            : widget.onConnect)
                        : null,
                    onTapDown:
                        canTap ? (_) => setState(() => _pressed = true) : null,
                    onTapUp:
                        canTap ? (_) => setState(() => _pressed = false) : null,
                    onTapCancel:
                        canTap ? () => setState(() => _pressed = false) : null,
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 120),
                      scale: _pressed ? 0.94 : 1,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOut,
                        width: size,
                        height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: widget.connected
                              ? LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [accent, accentDeep],
                                )
                              : null,
                          color: widget.connected
                              ? null
                              : widget.enabled
                                  ? AppColors.glassStrong
                                  : AppColors.glass,
                          border: Border.all(
                            color: widget.connected
                                ? AppColors.glassBorderStrong
                                : AppColors.glassBorder,
                            width: widget.connected ? 0 : 1.5,
                          ),
                          boxShadow: widget.connected
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.45),
                                    blurRadius: 34,
                                    spreadRadius: 1,
                                    offset: const Offset(0, 12),
                                  ),
                                ]
                              : AppShadows.tile,
                        ),
                        child: Center(
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 160),
                            opacity: widget.busy ? 0.6 : 1,
                            child: Icon(
                              Icons.power_settings_new_rounded,
                              size: iconSize,
                              color: widget.connected
                                  ? (AppColors.isDark
                                      ? const Color(0xFF04130D)
                                      : Colors.white)
                                  : widget.enabled
                                      ? AppColors.ink
                                      : AppColors.inkMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.showLabel) ...[
          SizedBox(height: widget.compact ? 6 : 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              stateLabel,
              key: ValueKey(stateLabel),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: widget.enabled ? AppColors.ink : AppColors.inkSoft,
                fontSize: widget.compact ? 16 : 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SubscriptionPanel extends StatelessWidget {
  const _SubscriptionPanel({
    required this.product,
    required this.subscription,
    required this.hasAccess,
    required this.busy,
    required this.compact,
    required this.onRefresh,
    this.onReplaceConfig,
  });

  final VpnProduct product;
  final Subscription? subscription;
  final bool hasAccess;
  final bool busy;
  final bool compact;
  final VoidCallback onRefresh;
  final VoidCallback? onReplaceConfig;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final active = subscription?.isActive == true;
    final title = active
        ? subscription?.isTrial == true
            ? 'Пробный доступ'
            : 'Доступ активирован'
        : hasAccess
            ? 'Проверяем доступ'
            : 'Нет доступа';
    final expires =
        subscription?.isTrial == true && subscription?.expiresMs != null
            ? _formatTrialExpiry(subscription!.expiresMs!)
            : subscription?.expiresAt?.isNotEmpty == true
                ? subscription!.expiresAt!
                : active
                    ? 'активна'
                    : 'нет доступа';

    return _Panel(
      padding: EdgeInsets.all(compact ? 16 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (active) ...[
                _LiveDot(color: accent),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: compact ? 21 : 24,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: AppColors.ink,
                  ),
                ),
              ),
              IconButton(
                onPressed: busy ? null : onRefresh,
                icon: Icon(Icons.refresh_rounded),
                tooltip: 'Обновить',
              ),
            ],
          ),
          SizedBox(height: compact ? 7 : 10),
          Text(
            'Действует до',
            style: TextStyle(
              color: AppColors.inkSoft,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: compact ? 2 : 4),
          Text(
            expires,
            style: TextStyle(
              fontSize: compact ? 26 : 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: accent,
            ),
          ),
          if (hasAccess && onReplaceConfig != null) ...[
            SizedBox(height: compact ? 8 : 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : onReplaceConfig,
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('Обновить конфигурацию'),
              ),
            ),
            Text(
              'Если перестал подключаться — обновите конфигурацию: '
              'сервер обновился, нужен свежий конфиг.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: AppColors.inkSoft,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatTrialExpiry(int milliseconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

class _RoutePanel extends StatelessWidget {
  const _RoutePanel({
    required this.product,
    required this.value,
    required this.onChanged,
  });

  final VpnProduct product;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return _Panel(
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        activeTrackColor: accent,
        title: Text(
          'РФ-сервисы напрямую',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          'Ozon, Wildberries, Avito, Госуслуги, Сбер, Яндекс, VK',
          style: TextStyle(color: AppColors.inkSoft),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

// Kept for compatibility with older restored state; no longer rendered.
// ignore: unused_element
class _PendingPaymentPanel extends StatelessWidget {
  const _PendingPaymentPanel({
    required this.product,
    required this.busy,
    required this.hasPaymentUrl,
    required this.onOpenPayment,
    required this.onRefresh,
  });

  final VpnProduct product;
  final bool busy;
  final bool hasPaymentUrl;
  final VoidCallback onOpenPayment;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _LiveDot(color: AppColors.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${product.title}: запрос создан',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Можно закрыть страницу и вернуться позже. Приложение сохранит запрос и проверит статус автоматически.',
            style: TextStyle(
              color: AppColors.inkSoft,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy || !hasPaymentUrl ? null : onOpenPayment,
            icon: Icon(Icons.open_in_new_rounded),
            label: Text('Открыть страницу снова'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : onRefresh,
            icon: Icon(Icons.refresh_rounded),
            label: Text('Проверить статус'),
          ),
        ],
      ),
    );
  }
}

class _AccessGate extends StatelessWidget {
  const _AccessGate({
    required this.busy,
    required this.accountEmail,
    required this.trialUsed,
    required this.emailController,
    required this.passwordController,
    required this.onLogin,
    required this.onForgotPassword,
    required this.onTrial,
    required this.onOpenAccount,
    required this.onRefreshAccount,
    required this.onLogout,
    required this.onBack,
  });

  final bool busy;
  final String? accountEmail;
  final bool trialUsed;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final VoidCallback onLogin;
  final VoidCallback onForgotPassword;
  final VoidCallback onTrial;
  final VoidCallback onOpenAccount;
  final VoidCallback onRefreshAccount;
  final VoidCallback onLogout;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final signedIn = accountEmail != null;

    return _Panel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onBack != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : onBack,
                icon: Icon(Icons.arrow_back_rounded),
                label: Text('Вернуться'),
              ),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            signedIn ? 'Нет доступа' : 'Вход в аккаунт',
            style: TextStyle(
              fontSize: 23,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            signedIn
                ? 'Вы вошли как $accountEmail. Обновите данные или откройте личный кабинет.'
                : 'Войдите, чтобы приложение загрузило подписки и настроило подключение.',
            style: TextStyle(
              color: AppColors.inkSoft,
              height: 1.3,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          if (signedIn) ...[
            FilledButton.icon(
              onPressed: busy ? null : onRefreshAccount,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Обновить данные'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onOpenAccount,
              icon: Icon(Icons.open_in_new_rounded),
              label: Text('Открыть личный кабинет'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: busy ? null : onLogout,
              icon: Icon(Icons.logout_rounded),
              label: Text('Выйти из аккаунта'),
            ),
          ] else ...[
            TextField(
              controller: emailController,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'email@example.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              enabled: !busy,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => busy ? null : onLogin(),
              decoration: const InputDecoration(
                labelText: 'Пароль',
                hintText: 'Не менее 8 символов',
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : onForgotPassword,
                child: Text('Забыли пароль?'),
              ),
            ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: busy ? null : onLogin,
              icon: Icon(Icons.login_rounded),
              label: Text(busy ? 'Проверяем доступ...' : 'Войти'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onOpenAccount,
              icon: Icon(Icons.open_in_new_rounded),
              label: Text('Зарегистрироваться'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              // Always ask the server (never gate purely on local state) so a
              // backend trial reset takes effect without clearing app data.
              onPressed: busy ? null : onTrial,
              icon: Icon(Icons.timer_outlined),
              label: Text(
                trialUsed
                    ? 'Проверить пробный доступ'
                    : 'Пробный доступ на 24 часа',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({
    required this.product,
    required this.email,
    required this.busy,
    required this.onSync,
    required this.onLogin,
    required this.onOpenAccount,
    required this.onLogout,
  });

  final VpnProduct product;
  final String? email;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccount;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final signedIn = email != null;
    final accent = AppColors.accentFor(product);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                signedIn
                    ? Icons.verified_user_rounded
                    : Icons.person_outline_rounded,
                color: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Аккаунт',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      email ?? 'Пробный доступ без аккаунта',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.inkSoft,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (signedIn) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : onSync,
              icon: Icon(Icons.sync_rounded),
              label: Text('Обновить данные'),
            ),
            const SizedBox(height: 8),
          ] else ...[
            FilledButton.icon(
              onPressed: busy ? null : onLogin,
              icon: Icon(Icons.login_rounded),
              label: Text('Войти'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: busy ? null : onOpenAccount,
            icon: Icon(Icons.open_in_new_rounded),
            label: Text(
              signedIn ? 'Личный кабинет' : 'Создать аккаунт',
            ),
          ),
          if (signedIn) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: busy ? null : onLogout,
              child: Text('Выйти из аккаунта'),
            ),
          ],
        ],
      ),
    );
  }
}

class _AccountPurchasePanel extends StatelessWidget {
  const _AccountPurchasePanel({
    required this.product,
    required this.busy,
    required this.signedIn,
    required this.onOpenAccount,
    required this.onSyncAccount,
  });

  final VpnProduct product;
  final bool busy;
  final bool signedIn;
  final VoidCallback onOpenAccount;
  final VoidCallback onSyncAccount;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${product.title}: нет доступа',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            signedIn
                ? 'Откройте личный кабинет для управления подпиской, затем обновите данные.'
                : 'Создайте аккаунт на сайте. После входа приложение загрузит доступ автоматически.',
            style: TextStyle(
              color: AppColors.inkSoft,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy ? null : onOpenAccount,
            icon: Icon(Icons.open_in_new_rounded),
            label: Text('Открыть личный кабинет'),
          ),
          if (signedIn) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onSyncAccount,
              icon: Icon(Icons.sync_rounded),
              label: Text('Обновить данные'),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.selected,
    required this.activeProducts,
    required this.routeRussianDirect,
    required this.busy,
    required this.accountEmail,
    required this.darkTheme,
    required this.onDarkThemeChanged,
    required this.onRouteChanged,
    required this.autostart,
    required this.autoConnect,
    required this.killSwitch,
    required this.autoReconnect,
    required this.onAutostartChanged,
    required this.onAutoConnectChanged,
    required this.onKillSwitchChanged,
    required this.onAutoReconnectChanged,
    required this.onOpenLogs,
    required this.onSyncAccount,
    required this.onLogin,
    required this.onOpenAccount,
    required this.onLogout,
  });

  final VpnProduct selected;
  final Map<VpnProduct, bool> activeProducts;
  final bool routeRussianDirect;
  final bool busy;
  final String? accountEmail;
  final bool darkTheme;
  final ValueChanged<bool> onDarkThemeChanged;
  final ValueChanged<bool> onRouteChanged;
  final bool autostart;
  final bool autoConnect;
  final bool killSwitch;
  final bool autoReconnect;
  final ValueChanged<bool> onAutostartChanged;
  final ValueChanged<bool> onAutoConnectChanged;
  final ValueChanged<bool> onKillSwitchChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final VoidCallback onOpenLogs;
  final VoidCallback onSyncAccount;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccount;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final selectedActive = activeProducts[selected] == true;

    final accountPanel = _AccountPanel(
      product: selected,
      email: accountEmail,
      busy: busy,
      onSync: onSyncAccount,
      onLogin: onLogin,
      onOpenAccount: onOpenAccount,
      onLogout: onLogout,
    );
    final themePanel = _ThemePanel(
      product: selected,
      darkTheme: darkTheme,
      onChanged: onDarkThemeChanged,
    );
    final Widget routeOrPurchase = selectedActive
        ? _RoutePanel(
            product: selected,
            value: routeRussianDirect,
            onChanged: busy ? null : onRouteChanged,
          )
        : _AccountPurchasePanel(
            product: selected,
            busy: busy,
            signedIn: accountEmail != null,
            onOpenAccount: onOpenAccount,
            onSyncAccount: onSyncAccount,
          );
    final Widget? desktopOptions = Platform.isWindows
        ? _DesktopOptionsPanel(
            product: selected,
            autostart: autostart,
            autoConnect: autoConnect,
            killSwitch: killSwitch,
            autoReconnect: autoReconnect,
            busy: busy,
            onAutostartChanged: onAutostartChanged,
            onAutoConnectChanged: onAutoConnectChanged,
            onKillSwitchChanged: onKillSwitchChanged,
            onAutoReconnectChanged: onAutoReconnectChanged,
            onOpenLogs: onOpenLogs,
          )
        : null;

    final titleRow = Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.ink),
            tooltip: 'Назад',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          ),
          const SizedBox(width: 12),
          Text(
            'Настройки',
            style: TextStyle(
              fontSize: 26,
              height: 1,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );

    Widget scrollColumn(List<Widget> children) {
      return ScrollConfiguration(
        behavior: const _NoStretchScrollBehavior(),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          gradient: AppGradients.backgroundFor(selected),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Wide desktop window: two columns, no scrolling needed. Left =
              // account + appearance; right = routing + desktop options.
              if (constraints.maxWidth >= 820) {
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        titleRow,
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: scrollColumn([
                                    accountPanel,
                                    const SizedBox(height: 14),
                                    themePanel,
                                  ]),
                                ),
                                const SizedBox(width: 18),
                                Expanded(
                                  child: scrollColumn([
                                    routeOrPurchase,
                                    if (desktopOptions != null) ...[
                                      const SizedBox(height: 14),
                                      desktopOptions,
                                    ],
                                  ]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Narrow (mobile): single scrolling column.
              final width =
                  constraints.maxWidth < 620 ? constraints.maxWidth : 620.0;
              return Center(
                child: SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      titleRow,
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
                          child: scrollColumn([
                            accountPanel,
                            const SizedBox(height: 16),
                            routeOrPurchase,
                            const SizedBox(height: 16),
                            themePanel,
                            if (desktopOptions != null) ...[
                              const SizedBox(height: 16),
                              desktopOptions,
                            ],
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ThemePanel extends StatelessWidget {
  const _ThemePanel({
    required this.product,
    required this.darkTheme,
    required this.onChanged,
  });

  final VpnProduct product;
  final bool darkTheme;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.glassStrong,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Icon(
              darkTheme ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              color: darkTheme ? accent : AppColors.warn,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Оформление',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  darkTheme ? 'Тёмная тема' : 'Светлая тема',
                  style: TextStyle(
                    color: AppColors.inkSoft,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: darkTheme,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// Desktop-only options: autostart, auto-connect, kill-switch and a shortcut to
// the logs folder.
class _DesktopOptionsPanel extends StatelessWidget {
  const _DesktopOptionsPanel({
    required this.product,
    required this.autostart,
    required this.autoConnect,
    required this.killSwitch,
    required this.autoReconnect,
    required this.busy,
    required this.onAutostartChanged,
    required this.onAutoConnectChanged,
    required this.onKillSwitchChanged,
    required this.onAutoReconnectChanged,
    required this.onOpenLogs,
  });

  final VpnProduct product;
  final bool autostart;
  final bool autoConnect;
  final bool killSwitch;
  final bool autoReconnect;
  final bool busy;
  final ValueChanged<bool> onAutostartChanged;
  final ValueChanged<bool> onAutoConnectChanged;
  final ValueChanged<bool> onKillSwitchChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final VoidCallback onOpenLogs;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Column(
        children: [
          _DesktopOptionRow(
            icon: Icons.restart_alt_rounded,
            accent: accent,
            title: 'Автозапуск с Windows',
            subtitle: 'Запускать при входе в систему',
            trailing: Switch(value: autostart, onChanged: onAutostartChanged),
          ),
          const _OptionDivider(),
          _DesktopOptionRow(
            icon: Icons.flash_on_rounded,
            accent: accent,
            title: 'Автоподключение',
            subtitle: 'Подключаться сразу при запуске',
            trailing:
                Switch(value: autoConnect, onChanged: onAutoConnectChanged),
          ),
          const _OptionDivider(),
          _DesktopOptionRow(
            icon: Icons.autorenew_rounded,
            accent: accent,
            title: 'Авто-переподключение',
            subtitle: 'Восстанавливать туннель при обрыве',
            trailing:
                Switch(value: autoReconnect, onChanged: onAutoReconnectChanged),
          ),
          const _OptionDivider(),
          _DesktopOptionRow(
            icon: Icons.shield_moon_rounded,
            accent: accent,
            title: 'Kill-switch',
            subtitle: killSwitch
                ? 'Блокирует интернет вне VPN (локальная сеть тоже недоступна)'
                : 'Применится при следующем подключении',
            trailing: Switch(
              value: killSwitch,
              onChanged: busy ? null : onKillSwitchChanged,
            ),
          ),
          const _OptionDivider(),
          _DesktopOptionRow(
            icon: Icons.folder_open_rounded,
            accent: accent,
            title: 'Логи',
            subtitle: 'Открыть папку с логами',
            trailing:
                Icon(Icons.chevron_right_rounded, color: AppColors.inkMuted),
            onTap: onOpenLogs,
          ),
        ],
      ),
    );
  }
}

class _DesktopOptionRow extends StatelessWidget {
  const _DesktopOptionRow({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.glassStrong,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.glassBorder),
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppColors.inkSoft,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
    if (onTap == null) {
      return row;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }
}

class _OptionDivider extends StatelessWidget {
  const _OptionDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, color: AppColors.glassBorder);
  }
}

// Kept for compatibility with older restored state; no longer rendered.
// ignore: unused_element
class _RenewPanel extends StatelessWidget {
  const _RenewPanel({
    required this.product,
    required this.tariffKey,
    required this.busy,
    required this.hasPendingRenewal,
    required this.hasPendingRenewalUrl,
    required this.onTariffChanged,
    required this.onRenew,
    required this.onOpenRenewalPayment,
    required this.onRefreshRenewal,
  });

  final VpnProduct product;
  final String tariffKey;
  final bool busy;
  final bool hasPendingRenewal;
  final bool hasPendingRenewalUrl;
  final ValueChanged<String> onTariffChanged;
  final VoidCallback onRenew;
  final VoidCallback onOpenRenewalPayment;
  final VoidCallback onRefreshRenewal;

  @override
  Widget build(BuildContext context) {
    final plans = VpnCatalog.plansFor(product);
    final selectedPlan = VpnCatalog.findPlan(product, tariffKey) ?? plans.first;
    final price = VpnCatalog.totalPrice(product: product, plan: selectedPlan);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Продление',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Управление сроком доступно в личном кабинете без замены конфига.',
            style: TextStyle(
              color: AppColors.inkSoft,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 14),
          _PlanGrid(
            plans: plans,
            tariffKey: tariffKey,
            busy: busy,
            accent: AppColors.accentFor(product),
            onTariffChanged: onTariffChanged,
          ),
          if (hasPendingRenewal) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed:
                  busy || !hasPendingRenewalUrl ? null : onOpenRenewalPayment,
              icon: Icon(Icons.open_in_new_rounded),
              label: Text('Открыть страницу продления'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.blueDeep,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onRefreshRenewal,
              icon: Icon(Icons.refresh_rounded),
              label: Text('Проверить продление'),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy ? null : onRenew,
            icon: Icon(Icons.payment_rounded),
            label: Text(
              Platform.isIOS
                  ? 'Продлить на сайте: $price ₽'
                  : 'Продлить: $price ₽',
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanGrid extends StatelessWidget {
  const _PlanGrid({
    required this.plans,
    required this.tariffKey,
    required this.busy,
    required this.accent,
    required this.onTariffChanged,
  });

  final List<VpnPlan> plans;
  final String tariffKey;
  final bool busy;
  final Color accent;
  final ValueChanged<String> onTariffChanged;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];

    for (var index = 0; index < plans.length; index += 2) {
      final first = plans[index];
      final second = index + 1 < plans.length ? plans[index + 1] : null;

      rows.add(
        Row(
          children: [
            Expanded(child: _chipFor(first)),
            const SizedBox(width: 10),
            if (second != null)
              Expanded(child: _chipFor(second))
            else
              const Expanded(child: SizedBox.shrink()),
          ],
        ),
      );

      if (index + 2 < plans.length) {
        rows.add(const SizedBox(height: 10));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _chipFor(VpnPlan plan) {
    return SizedBox(
      height: 104,
      child: _PlanChip(
        plan: plan,
        selected: plan.key == tariffKey,
        accent: accent,
        onTap: busy ? null : () => onTariffChanged(plan.key),
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.plan,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final VpnPlan plan;
  final bool selected;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.chip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    accent.withValues(alpha: AppColors.isDark ? 0.15 : 0.07),
                    AppColors.glassStrong,
                  )
                : AppColors.glass,
            borderRadius: AppRadii.chip,
            border: Border.all(
              color: selected ? accent : AppColors.glassBorder,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (plan.badge != null) ...[
                    _MiniChip(label: plan.badge!, color: AppColors.warn),
                    const SizedBox(height: 5),
                  ],
                  Text(
                    plan.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '${plan.priceRub} ₽',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: selected ? accent : AppColors.greenDeep,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.product,
    required this.message,
  });

  final VpnProduct product;
  final String message;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    return _Panel(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Floating warning shown over the VPN-type selector (e.g. when the user tries
// to switch type while connected). Tap anywhere on it to dismiss; the parent
// also auto-dismisses it after a few seconds.
class _TypeToast extends StatelessWidget {
  const _TypeToast({
    required this.message,
    required this.product,
    required this.onDismiss,
  });

  final String message;
  final VpnProduct product;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final surface = Color.alphaBlend(
      AppColors.warn.withValues(alpha: AppColors.isDark ? 0.16 : 0.12),
      AppColors.backgroundAlt,
    );

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * -10),
            child: child,
          ),
        ),
        child: GestureDetector(
          onTap: onDismiss,
          behavior: HitTestBehavior.opaque,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: AppRadii.pill,
              border: Border.all(
                color: AppColors.warn.withValues(alpha: 0.55),
                width: 1.5,
              ),
              boxShadow: AppShadows.card,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded,
                    color: AppColors.warn, size: 18),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.product,
    required this.state,
  });

  final VpnProduct product;
  final VpnState state;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentFor(product);
    final (label, color) = switch (state) {
      VpnState.connected => ('ON', accent),
      VpnState.connecting => ('...', accent),
      VpnState.disconnecting => ('...', AppColors.warn),
      VpnState.unsupported => ('CORE', AppColors.warn),
      VpnState.error => ('ERR', AppColors.danger),
      VpnState.disconnected => ('OFF', AppColors.idle),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadii.pill,
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LiveDot(color: color, size: 7),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadii.pill,
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Small status dot with a soft halo.
class _LiveDot extends StatelessWidget {
  _LiveDot({required this.color, this.size = 9});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.5),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: AppDecorations.panel,
      child: child,
    );
  }
}
