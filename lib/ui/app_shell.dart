import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/order_access.dart';
import '../models/subscription.dart';
import '../models/vless_profile.dart';
import '../services/ironvpn_api.dart';
import '../services/profile_store.dart';
import '../services/vpn_controller.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _store = ProfileStore();
  final _api = const IronVpnApi();
  final _vpn = VpnController();
  final _appLinks = AppLinks();
  final _emailController = TextEditingController();
  final _deviceController = TextEditingController(text: 'iPhone');

  StreamSubscription<Uri>? _linkSub;
  OrderAccess? _access;
  Subscription? _subscription;
  VlessProfile? _profile;
  VpnState _state = VpnState.disconnected;
  bool _routeRussianDirect = true;
  bool _busy = true;
  String _tariffKey = 't_3m';
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deviceController.text = Platform.isAndroid ? 'Android' : 'iPhone';
    _load();
    _listenLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    _emailController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncVpnState();
      _refreshSubscription(silent: true);
    }
  }

  Future<void> _load() async {
    final access = await _store.loadOrderAccess();
    final profile = await _store.loadProfile();
    final routeRussianDirect = await _store.loadRouteRussianServicesDirect();
    final state = await _vpn.status();

    if (!mounted) {
      return;
    }

    setState(() {
      _access = access;
      _profile = profile;
      _routeRussianDirect = routeRussianDirect;
      _state = state;
      _busy = false;
    });

    await _refreshSubscription(silent: true);
  }

  Future<void> _listenLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        await _handleIncomingLink(initial);
      }

      _linkSub = _appLinks.uriLinkStream.listen(_handleIncomingLink);
    } catch (_) {
      // Deep links are optional. The app also works from stored order access.
    }
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    final access = OrderAccess.fromUri(uri);
    if (access == null) {
      return;
    }

    await _store.saveOrderAccess(access);
    setState(() {
      _access = access;
      _message = 'Покупка привязана. Проверяю оплату.';
    });
    await _refreshSubscription();
  }

  Future<void> _startPayment() async {
    final email = _emailController.text.trim();
    final deviceName = _deviceController.text.trim();

    if (!email.contains('@') || deviceName.isEmpty) {
      _showMessage('Укажите email и название устройства.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final payment = await _api.createPayment(
        tariffKey: _tariffKey,
        deviceName: deviceName,
        contact: email,
      );
      await _store.saveOrderAccess(payment.access);

      setState(() {
        _access = payment.access;
        _message = 'После оплаты вернитесь в приложение. Оно само получит конфиг.';
      });

      await launchUrl(payment.confirmationUrl, mode: LaunchMode.externalApplication);
    } on IronVpnApiException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('Не удалось открыть оплату.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _refreshSubscription({bool silent = false}) async {
    final access = _access ?? await _store.loadOrderAccess();
    if (access == null) {
      return;
    }

    if (!silent) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }

    try {
      final subscription = await _api.fetchSubscription(access);
      VlessProfile? profile = _profile;

      if (subscription.isFulfilled && subscription.vpnLink != null) {
        profile = VlessProfile.parse(subscription.vpnLink!);
        await _store.saveProfile(profile);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _access = access;
        _subscription = subscription;
        _profile = profile;
        if (!silent) {
          _message = subscription.isFulfilled
              ? 'Подписка активна. Конфиг настроен.'
              : 'Оплата пока не подтверждена.';
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

  Future<void> _connect() async {
    final profile = _profile;
    final subscription = _subscription;
    if (profile == null || subscription == null || !subscription.isFulfilled) {
      _showMessage('Сначала оплатите подписку.');
      return;
    }

    setState(() {
      _busy = true;
      _state = VpnState.connecting;
      _message = null;
    });

    final prepared = await _vpn.prepare();
    if (!prepared) {
      setState(() {
        _busy = false;
        _state = VpnState.disconnected;
        _message = 'Разрешите VPN-подключение в системном окне.';
      });
      return;
    }

    final nextState = await _vpn.start(
      profile: profile,
      routeRussianServicesDirect: _routeRussianDirect,
    );

    setState(() {
      _busy = false;
      _state = nextState;
      if (nextState == VpnState.unsupported) {
        _message = 'VPN-движок ещё не подключён в приложении.';
      } else if (nextState == VpnState.error) {
        _message = 'Ошибка запуска VPN.';
      } else if (nextState == VpnState.disconnected) {
        _message = 'VPN не успел запуститься. Попробуйте ещё раз.';
      }
    });
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _state = VpnState.disconnecting;
      _message = null;
    });

    final nextState = await _vpn.stop();

    setState(() {
      _busy = false;
      _state = nextState;
    });
  }

  Future<void> _syncVpnState() async {
    final state = await _vpn.status();
    if (!mounted) {
      return;
    }

    setState(() => _state = state);
  }

  Future<void> _toggleRussianDirect(bool value) async {
    await _store.saveRouteRussianServicesDirect(value);
    setState(() => _routeRussianDirect = value);
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _busy = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = _state == VpnState.connected;
    final active = _subscription?.isFulfilled == true && _profile != null;
    final canBuy = !active &&
        (_access == null ||
            _subscription?.status == 'canceled' ||
            _subscription?.status == 'payment_error');

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFEAF7F4),
              Color(0xFFFFFFFF),
              Color(0xFFD9ECFF),
            ],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
            children: [
              _Header(state: _state),
              const SizedBox(height: 22),
              _RoundConnectButton(
                busy: _busy,
                enabled: active,
                connected: connected,
                onConnect: _connect,
                onDisconnect: _disconnect,
              ),
              const SizedBox(height: 18),
              _SubscriptionPanel(
                subscription: _subscription,
                hasAccess: _access != null,
                busy: _busy,
                onRefresh: () => _refreshSubscription(),
              ),
              const SizedBox(height: 16),
              _RoutePanel(
                value: _routeRussianDirect,
                onChanged: _toggleRussianDirect,
              ),
              if (canBuy) ...[
                const SizedBox(height: 16),
                _PaymentPanel(
                  emailController: _emailController,
                  deviceController: _deviceController,
                  tariffKey: _tariffKey,
                  busy: _busy,
                  onTariffChanged: (value) => setState(() => _tariffKey = value),
                  onPay: _startPayment,
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 16),
                _MessagePanel(message: _message!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final VpnState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFF007B5F),
            borderRadius: BorderRadius.circular(15),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26007B5F),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'IV',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'IronVPN',
                style: TextStyle(
                  fontSize: 24,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF061418),
                ),
              ),
              SizedBox(height: 5),
              Text(
                'Защищённый трафик',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF007B5F),
                ),
              ),
            ],
          ),
        ),
        _StatusChip(state: state),
      ],
    );
  }
}

class _SubscriptionPanel extends StatelessWidget {
  const _SubscriptionPanel({
    required this.subscription,
    required this.hasAccess,
    required this.busy,
    required this.onRefresh,
  });

  final Subscription? subscription;
  final bool hasAccess;
  final bool busy;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final active = subscription?.isFulfilled == true;
    final title = active ? 'Подписка активна' : hasAccess ? 'Ожидаем оплату' : 'Подписка не найдена';
    final expires = subscription?.expiresAt?.isNotEmpty == true
        ? subscription!.expiresAt!
        : active
            ? 'активна'
            : 'после оплаты';

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 24,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF061418),
                  ),
                ),
              ),
              IconButton(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                tooltip: 'Обновить',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Действует до',
            style: TextStyle(
              color: Colors.blueGrey.shade600,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            expires,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: Color(0xFF007B5F),
            ),
          ),
          if (subscription != null) ...[
            const SizedBox(height: 14),
            _InfoLine(label: 'Тариф', value: subscription!.tariffName),
            _InfoLine(label: 'Устройство', value: subscription!.deviceName),
          ],
        ],
      ),
    );
  }
}

class _RoundConnectButton extends StatelessWidget {
  const _RoundConnectButton({
    required this.busy,
    required this.enabled,
    required this.connected,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool busy;
  final bool enabled;
  final bool connected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final canTap = !busy && enabled;
    final label = connected ? 'Отключить VPN' : 'Включить VPN';
    final stateLabel = connected
        ? 'VPN включён'
        : enabled
            ? 'Нажмите для подключения'
            : 'Активируйте подписку';

    return Column(
      children: [
        Semantics(
          button: true,
          enabled: canTap,
          label: label,
          child: GestureDetector(
            onTap: canTap ? (connected ? onDisconnect : onConnect) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 184,
              height: 184,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? null : const Color(0xFFB7C5C8),
                gradient: enabled
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: connected
                            ? const [
                                Color(0xFF101D22),
                                Color(0xFF31424A),
                              ]
                            : const [
                                Color(0xFF00A77D),
                                Color(0xFF227DAE),
                              ],
                      )
                    : null,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.72),
                  width: 8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (connected
                            ? const Color(0xFF101D22)
                            : const Color(0xFF008E6E))
                        .withValues(alpha: enabled ? 0.32 : 0.12),
                    blurRadius: 34,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.power_settings_new,
                    size: 64,
                    color: Colors.white.withValues(alpha: enabled ? 1 : 0.72),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    connected ? 'ON' : 'START',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: enabled ? 1 : 0.72),
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          stateLabel,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled ? const Color(0xFF061418) : const Color(0xFF6C7B80),
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

// ignore: unused_element
class _ConnectPanel extends StatelessWidget {
  const _ConnectPanel({
    required this.busy,
    required this.enabled,
    required this.connected,
    required this.onConnect,
    required this.onDisconnect,
  });

  final bool busy;
  final bool enabled;
  final bool connected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy || !enabled ? null : (connected ? onDisconnect : onConnect),
            icon: Icon(connected ? Icons.power_settings_new : Icons.shield),
            label: Text(connected ? 'Отключить VPN' : 'Включить VPN'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(64),
              backgroundColor: connected
                  ? const Color(0xFF0F1E24)
                  : const Color(0xFF008E6E),
              textStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoutePanel extends StatelessWidget {
  const _RoutePanel({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'РФ-сервисы напрямую',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: const Text('Ozon, WB, Госуслуги, банки, Steam, FACEIT'),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _PaymentPanel extends StatelessWidget {
  const _PaymentPanel({
    required this.emailController,
    required this.deviceController,
    required this.tariffKey,
    required this.busy,
    required this.onTariffChanged,
    required this.onPay,
  });

  final TextEditingController emailController;
  final TextEditingController deviceController;
  final String tariffKey;
  final bool busy;
  final ValueChanged<String> onTariffChanged;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Купить подписку',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: Color(0xFF061418),
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 't_1m', label: Text('1 мес')),
              ButtonSegment(value: 't_3m', label: Text('3 мес')),
              ButtonSegment(value: 't_1y', label: Text('1 год')),
            ],
            selected: {tariffKey},
            onSelectionChanged: busy ? null : (values) => onTariffChanged(values.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: deviceController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Устройство',
              hintText: 'Например, iPhone',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'email@example.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: busy ? null : onPay,
            icon: const Icon(Icons.payment),
            label: Text(Platform.isIOS ? 'Оплатить на сайте' : 'Оплатить'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              backgroundColor: const Color(0xFF008E6E),
              textStyle: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        children: [
          SizedBox(
            width: 94,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF66777D),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Color(0xFF007B5F)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF16343A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final VpnState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      VpnState.connected => ('ON', const Color(0xFF008E6E)),
      VpnState.connecting => ('...', const Color(0xFF287DA8)),
      VpnState.disconnecting => ('...', const Color(0xFF9C6A00)),
      VpnState.unsupported => ('CORE', const Color(0xFF9C6A00)),
      VpnState.error => ('ERR', const Color(0xFFC43C3C)),
      VpnState.disconnected => ('OFF', const Color(0xFF819096)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.86)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A355B65),
            blurRadius: 30,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: child,
    );
  }
}
