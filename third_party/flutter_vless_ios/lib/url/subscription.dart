import 'dart:convert';

import 'package:flutter_vless/url/url.dart';
import 'package:yaml/yaml.dart';

typedef FlutterVlessUrlParser = FlutterVlessURL Function(String url);

class VlessSubscriptionParser {
  VlessSubscriptionParser._();

  static List<FlutterVlessURL> parseMany({
    required String input,
    required FlutterVlessUrlParser parseUrl,
    required FlutterVlessURL Function(String json) parseJson,
  }) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('subscription is empty');
    }

    final jsonResult = _parseJson(trimmed, parseUrl, parseJson);
    if (jsonResult.isNotEmpty) {
      return jsonResult;
    }

    final directLinks = _parseShareLines(trimmed, parseUrl);
    if (directLinks.isNotEmpty) {
      return directLinks;
    }

    final decoded = _decodeBase64Subscription(trimmed);
    if (decoded != null && decoded.trim() != trimmed) {
      final decodedJson = _parseJson(decoded.trim(), parseUrl, parseJson);
      if (decodedJson.isNotEmpty) {
        return decodedJson;
      }

      final decodedLinks = _parseShareLines(decoded, parseUrl);
      if (decodedLinks.isNotEmpty) {
        return decodedLinks;
      }

      final decodedYaml = _parseClashYaml(decoded, parseUrl);
      if (decodedYaml.isNotEmpty) {
        return decodedYaml;
      }
    }

    final clashYaml = _parseClashYaml(trimmed, parseUrl);
    if (clashYaml.isNotEmpty) {
      return clashYaml;
    }

    throw ArgumentError('subscription is invalid or unsupported');
  }

  static List<FlutterVlessURL> _parseJson(
    String input,
    FlutterVlessUrlParser parseUrl,
    FlutterVlessURL Function(String json) parseJson,
  ) {
    final decoded = _tryJsonDecode(input);
    if (decoded == null) {
      return [];
    }

    if (decoded is Map<String, dynamic>) {
      if (_isXrayConfig(decoded)) {
        return [parseJson(jsonEncode(decoded))];
      }
      if (_isSingBoxConfig(decoded)) {
        return _parseSingBoxJson(decoded, parseUrl);
      }
      return [];
    }

    if (decoded is List<dynamic>) {
      final configs = <FlutterVlessURL>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          if (_isXrayConfig(item)) {
            configs.add(parseJson(jsonEncode(item)));
          } else if (_isSingBoxOutbound(item)) {
            final url = _linkFromSingBoxOutbound(item);
            if (url != null) {
              configs.add(parseUrl(url));
            }
          }
        }
      }
      return configs;
    }

    return [];
  }

  static dynamic _tryJsonDecode(String input) {
    try {
      return jsonDecode(input);
    } catch (_) {
      return null;
    }
  }

  static bool _isXrayConfig(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    return outbounds is List<dynamic> &&
        outbounds.any((outbound) =>
            outbound is Map<String, dynamic> && outbound['protocol'] is String);
  }

  static bool _isSingBoxConfig(Map<String, dynamic> config) {
    final outbounds = config['outbounds'];
    return outbounds is List<dynamic> && outbounds.any(_isSingBoxOutbound);
  }

  static bool _isSingBoxOutbound(Object? value) {
    return value is Map<String, dynamic> && value['type'] is String;
  }

  static List<FlutterVlessURL> _parseSingBoxJson(
    Map<String, dynamic> config,
    FlutterVlessUrlParser parseUrl,
  ) {
    final outbounds = config['outbounds'];
    if (outbounds is! List<dynamic>) {
      return [];
    }

    final parsed = <FlutterVlessURL>[];
    for (final outbound in outbounds) {
      if (outbound is! Map<String, dynamic>) {
        continue;
      }
      final link = _linkFromSingBoxOutbound(outbound);
      if (link != null) {
        parsed.add(parseUrl(link));
      }
    }
    return parsed;
  }

  static List<FlutterVlessURL> _parseShareLines(
    String input,
    FlutterVlessUrlParser parseUrl,
  ) {
    final parsed = <FlutterVlessURL>[];
    for (final rawLine in input.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      if (!_hasSupportedScheme(line)) {
        continue;
      }
      parsed.add(parseUrl(line));
    }
    return parsed;
  }

  static bool _hasSupportedScheme(String value) {
    final scheme = value.split('://').first.toLowerCase();
    return const {'vmess', 'vless', 'trojan', 'ss', 'socks'}.contains(scheme);
  }

  static String? _decodeBase64Subscription(String input) {
    var normalized = input.replaceAll(RegExp(r'\s+'), '');
    normalized = normalized.replaceAll('-', '+').replaceAll('_', '/');
    if (normalized.length % 4 > 0) {
      normalized += '=' * (4 - normalized.length % 4);
    }
    try {
      return utf8.decode(base64Decode(normalized));
    } catch (_) {
      return null;
    }
  }

  static List<FlutterVlessURL> _parseClashYaml(
    String input,
    FlutterVlessUrlParser parseUrl,
  ) {
    final root = _tryLoadYaml(input);
    if (root is! Map<String, dynamic>) {
      return [];
    }

    final proxies = root['proxies'];
    if (proxies is! List<dynamic>) {
      return [];
    }

    final parsed = <FlutterVlessURL>[];
    for (final proxy in proxies) {
      if (proxy is! Map<String, dynamic>) {
        continue;
      }
      final link = _linkFromClashProxy(proxy);
      if (link != null) {
        parsed.add(parseUrl(link));
      }
    }
    return parsed;
  }

  static dynamic _tryLoadYaml(String input) {
    try {
      return _normalizeYaml(loadYaml(input));
    } catch (_) {
      return null;
    }
  }

  static dynamic _normalizeYaml(dynamic value) {
    if (value is YamlMap) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _normalizeYaml(entry.value)
      };
    }
    if (value is YamlList) {
      return value.map(_normalizeYaml).toList();
    }
    return value;
  }

  static String? _linkFromClashProxy(Map<String, dynamic> proxy) {
    final type = _string(proxy, 'type')?.toLowerCase();
    switch (type) {
      case 'vless':
        return _vlessFromClash(proxy);
      case 'vmess':
        return _vmessFromClash(proxy);
      case 'trojan':
        return _trojanFromClash(proxy);
      case 'ss':
      case 'shadowsocks':
        return _shadowsocksFromMap(proxy);
      case 'socks':
      case 'socks5':
        return _socksFromMap(proxy);
      default:
        return null;
    }
  }

  static String? _linkFromSingBoxOutbound(Map<String, dynamic> outbound) {
    final type = _string(outbound, 'type')?.toLowerCase();
    switch (type) {
      case 'vless':
        return _vlessFromSingBox(outbound);
      case 'vmess':
        return _vmessFromSingBox(outbound);
      case 'trojan':
        return _trojanFromSingBox(outbound);
      case 'shadowsocks':
        return _shadowsocksFromMap(outbound);
      case 'socks':
        return _socksFromMap(outbound);
      default:
        return null;
    }
  }

  static String? _vlessFromClash(Map<String, dynamic> proxy) {
    final server = _string(proxy, 'server');
    final port = _int(proxy, 'port');
    final uuid = _string(proxy, 'uuid');
    if (server == null || port == null || uuid == null) {
      return null;
    }

    final network = _string(proxy, 'network') ?? 'tcp';
    final reality = _map(proxy, 'reality-opts') ?? _map(proxy, 'reality_opts');
    final query = <String, String>{
      'type': network,
      'security': reality != null
          ? 'reality'
          : _bool(proxy, 'tls') == true
              ? 'tls'
              : _string(proxy, 'security') ?? 'none',
    };
    _addIfPresent(query, 'flow', _string(proxy, 'flow'));
    _addIfPresent(query, 'encryption', _string(proxy, 'encryption'));
    _addIfPresent(
        query, 'sni', _string(proxy, 'servername') ?? _string(proxy, 'sni'));
    _addIfPresent(query, 'fp', _string(proxy, 'client-fingerprint'));
    if (reality != null) {
      _addIfPresent(query, 'pbk',
          _string(reality, 'public-key') ?? _string(reality, 'public_key'));
      _addIfPresent(query, 'sid',
          _string(reality, 'short-id') ?? _string(reality, 'short_id'));
      _addIfPresent(query, 'spx',
          _string(reality, 'spider-x') ?? _string(reality, 'spider_x'));
    }
    _addTransportOptions(query, network, proxy);

    return _uriWithUserInfo(
      scheme: 'vless',
      userInfo: uuid,
      host: server,
      port: port,
      query: query,
      fragment: _string(proxy, 'name') ?? server,
    );
  }

  static String? _vlessFromSingBox(Map<String, dynamic> outbound) {
    final server = _string(outbound, 'server');
    final port = _int(outbound, 'server_port');
    final uuid = _string(outbound, 'uuid');
    if (server == null || port == null || uuid == null) {
      return null;
    }

    final transport = _map(outbound, 'transport');
    final tls = _map(outbound, 'tls');
    final reality = _map(tls, 'reality');
    final network = _singBoxTransportType(transport);
    final query = <String, String>{
      'type': network,
      'security': _bool(reality, 'enabled') == true
          ? 'reality'
          : _bool(tls, 'enabled') == true
              ? 'tls'
              : 'none',
    };
    _addIfPresent(query, 'flow', _string(outbound, 'flow'));
    _addIfPresent(query, 'encryption', _string(outbound, 'encryption'));
    _addIfPresent(query, 'sni', _string(tls, 'server_name'));
    _addIfPresent(query, 'alpn', _stringOrList(tls?['alpn']));
    _addIfPresent(query, 'fp', _string(_map(tls, 'utls'), 'fingerprint'));
    if (reality != null) {
      _addIfPresent(query, 'pbk', _string(reality, 'public_key'));
      _addIfPresent(query, 'sid', _string(reality, 'short_id'));
    }
    _addSingBoxTransportOptions(query, network, transport);

    return _uriWithUserInfo(
      scheme: 'vless',
      userInfo: uuid,
      host: server,
      port: port,
      query: query,
      fragment: _string(outbound, 'tag') ?? server,
    );
  }

  static String? _vmessFromClash(Map<String, dynamic> proxy) {
    final server = _string(proxy, 'server');
    final port = _int(proxy, 'port');
    final uuid = _string(proxy, 'uuid');
    if (server == null || port == null || uuid == null) {
      return null;
    }

    final network = _string(proxy, 'network') ?? 'tcp';
    final config = <String, dynamic>{
      'v': '2',
      'ps': _string(proxy, 'name') ?? server,
      'add': server,
      'port': port.toString(),
      'id': uuid,
      'aid':
          (_int(proxy, 'alterId') ?? _int(proxy, 'alter-id') ?? 0).toString(),
      'scy': _string(proxy, 'cipher') ?? 'auto',
      'net': network,
      'type': _string(proxy, 'headerType') ?? 'none',
      'host': _transportHost(network, proxy) ?? '',
      'path': _transportPath(network, proxy) ?? '',
      'tls': _bool(proxy, 'tls') == true ? 'tls' : '',
      'sni': _string(proxy, 'servername') ?? _string(proxy, 'sni') ?? '',
      'fp': _string(proxy, 'client-fingerprint') ?? '',
      'alpn': _stringOrList(proxy['alpn']) ?? '',
    };
    return 'vmess://${base64Encode(utf8.encode(jsonEncode(config)))}';
  }

  static String? _vmessFromSingBox(Map<String, dynamic> outbound) {
    final server = _string(outbound, 'server');
    final port = _int(outbound, 'server_port');
    final uuid = _string(outbound, 'uuid');
    if (server == null || port == null || uuid == null) {
      return null;
    }

    final transport = _map(outbound, 'transport');
    final tls = _map(outbound, 'tls');
    final network = _singBoxTransportType(transport);
    final config = <String, dynamic>{
      'v': '2',
      'ps': _string(outbound, 'tag') ?? server,
      'add': server,
      'port': port.toString(),
      'id': uuid,
      'aid': (_int(outbound, 'alter_id') ?? 0).toString(),
      'scy': _string(outbound, 'security') ?? 'auto',
      'net': network,
      'type': 'none',
      'host': _singBoxTransportHost(transport) ?? '',
      'path': _singBoxTransportPath(transport) ?? '',
      'tls': _bool(tls, 'enabled') == true ? 'tls' : '',
      'sni': _string(tls, 'server_name') ?? '',
      'fp': _string(_map(tls, 'utls'), 'fingerprint') ?? '',
      'alpn': _stringOrList(tls?['alpn']) ?? '',
    };
    return 'vmess://${base64Encode(utf8.encode(jsonEncode(config)))}';
  }

  static String? _trojanFromClash(Map<String, dynamic> proxy) {
    return _trojanFromFields(
      server: _string(proxy, 'server'),
      port: _int(proxy, 'port'),
      password: _string(proxy, 'password'),
      remark: _string(proxy, 'name'),
      network: _string(proxy, 'network') ?? 'tcp',
      security: _bool(proxy, 'tls') == false ? 'none' : 'tls',
      sni: _string(proxy, 'sni') ?? _string(proxy, 'servername'),
      alpn: _stringOrList(proxy['alpn']),
      host: _transportHost(_string(proxy, 'network') ?? 'tcp', proxy),
      path: _transportPath(_string(proxy, 'network') ?? 'tcp', proxy),
      serviceName: _grpcServiceName(proxy),
    );
  }

  static String? _trojanFromSingBox(Map<String, dynamic> outbound) {
    final transport = _map(outbound, 'transport');
    final tls = _map(outbound, 'tls');
    final network = _singBoxTransportType(transport);
    return _trojanFromFields(
      server: _string(outbound, 'server'),
      port: _int(outbound, 'server_port'),
      password: _string(outbound, 'password'),
      remark: _string(outbound, 'tag'),
      network: network,
      security: _bool(tls, 'enabled') == true ? 'tls' : 'none',
      sni: _string(tls, 'server_name'),
      alpn: _stringOrList(tls?['alpn']),
      host: _singBoxTransportHost(transport),
      path: _singBoxTransportPath(transport),
      serviceName: _string(transport, 'service_name'),
    );
  }

  static String? _trojanFromFields({
    required String? server,
    required int? port,
    required String? password,
    required String? remark,
    required String network,
    required String security,
    required String? sni,
    required String? alpn,
    required String? host,
    required String? path,
    required String? serviceName,
  }) {
    if (server == null || port == null || password == null) {
      return null;
    }

    final query = <String, String>{
      'type': network,
      'security': security,
    };
    _addIfPresent(query, 'sni', sni);
    _addIfPresent(query, 'alpn', alpn);
    _addIfPresent(query, 'host', host);
    _addIfPresent(query, 'path', path);
    _addIfPresent(query, 'serviceName', serviceName);
    return _uriWithUserInfo(
      scheme: 'trojan',
      userInfo: password,
      host: server,
      port: port,
      query: query,
      fragment: remark ?? server,
    );
  }

  static String? _shadowsocksFromMap(Map<String, dynamic> source) {
    final server = _string(source, 'server');
    final port = _int(source, 'server_port') ?? _int(source, 'port');
    final method = _string(source, 'method') ?? _string(source, 'cipher');
    final password = _string(source, 'password');
    if (server == null || port == null || method == null || password == null) {
      return null;
    }
    final userInfo = base64Encode(utf8.encode('$method:$password'));
    return _uriWithUserInfo(
      scheme: 'ss',
      userInfo: userInfo,
      host: server,
      port: port,
      query: const {},
      fragment: _string(source, 'tag') ?? _string(source, 'name') ?? server,
    );
  }

  static String? _socksFromMap(Map<String, dynamic> source) {
    final server = _string(source, 'server');
    final port = _int(source, 'server_port') ?? _int(source, 'port');
    if (server == null || port == null) {
      return null;
    }

    final username = _string(source, 'username');
    final password = _string(source, 'password');
    final userInfo = username == null
        ? ''
        : base64Encode(utf8.encode('$username:${password ?? ''}'));
    return _uriWithUserInfo(
      scheme: 'socks',
      userInfo: userInfo,
      host: server,
      port: port,
      query: const {},
      fragment: _string(source, 'tag') ?? _string(source, 'name') ?? server,
    );
  }

  static void _addTransportOptions(
    Map<String, String> query,
    String network,
    Map<String, dynamic> proxy,
  ) {
    _addIfPresent(query, 'host', _transportHost(network, proxy));
    _addIfPresent(query, 'path', _transportPath(network, proxy));
    _addIfPresent(query, 'serviceName', _grpcServiceName(proxy));
    _addIfPresent(query, 'mode', _string(_map(proxy, 'xhttp-opts'), 'mode'));
  }

  static void _addSingBoxTransportOptions(
    Map<String, String> query,
    String network,
    Map<String, dynamic>? transport,
  ) {
    _addIfPresent(query, 'host', _singBoxTransportHost(transport));
    _addIfPresent(query, 'path', _singBoxTransportPath(transport));
    _addIfPresent(query, 'serviceName', _string(transport, 'service_name'));
    if (network == 'xhttp') {
      _addIfPresent(query, 'mode', _string(transport, 'mode'));
    }
  }

  static String? _transportHost(String network, Map<String, dynamic> proxy) {
    if (network == 'ws') {
      final headers = _map(_map(proxy, 'ws-opts'), 'headers');
      return _string(headers, 'Host') ?? _string(headers, 'host');
    }
    if (network == 'xhttp') {
      return _string(_map(proxy, 'xhttp-opts'), 'host') ??
          _string(_map(proxy, 'xhttp_opts'), 'host');
    }
    if (network == 'grpc') {
      return _string(proxy, 'servername') ?? _string(proxy, 'sni');
    }
    return _string(proxy, 'host');
  }

  static String? _transportPath(String network, Map<String, dynamic> proxy) {
    if (network == 'ws') {
      return _string(_map(proxy, 'ws-opts'), 'path');
    }
    if (network == 'xhttp') {
      return _string(_map(proxy, 'xhttp-opts'), 'path') ??
          _string(_map(proxy, 'xhttp_opts'), 'path');
    }
    if (network == 'h2' || network == 'http') {
      return _string(_map(proxy, 'h2-opts'), 'path') ??
          _string(_map(proxy, 'http-opts'), 'path');
    }
    return _string(proxy, 'path');
  }

  static String? _grpcServiceName(Map<String, dynamic> proxy) {
    return _string(_map(proxy, 'grpc-opts'), 'grpc-service-name') ??
        _string(_map(proxy, 'grpc-opts'), 'serviceName') ??
        _string(_map(proxy, 'grpc_opts'), 'service_name');
  }

  static String _singBoxTransportType(Map<String, dynamic>? transport) {
    final type = _string(transport, 'type')?.toLowerCase();
    switch (type) {
      case 'websocket':
        return 'ws';
      case 'http':
        return 'h2';
      case 'grpc':
      case 'quic':
      case 'xhttp':
        return type!;
      default:
        return 'tcp';
    }
  }

  static String? _singBoxTransportHost(Map<String, dynamic>? transport) {
    final headers = _map(transport, 'headers');
    return _string(headers, 'Host') ??
        _string(headers, 'host') ??
        _string(transport, 'host');
  }

  static String? _singBoxTransportPath(Map<String, dynamic>? transport) {
    final path = transport?['path'];
    if (path is List<dynamic>) {
      return path.isEmpty ? null : path.first.toString();
    }
    return _string(transport, 'path');
  }

  static String _uriWithUserInfo({
    required String scheme,
    required String userInfo,
    required String host,
    required int port,
    required Map<String, String> query,
    required String fragment,
  }) {
    final encodedUserInfo =
        userInfo.isEmpty ? '' : '${Uri.encodeComponent(userInfo)}@';
    final queryString = query.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    final encodedFragment = Uri.encodeComponent(fragment);
    return '$scheme://$encodedUserInfo$host:$port'
        '${queryString.isEmpty ? '' : '?$queryString'}'
        '#$encodedFragment';
  }

  static Map<String, dynamic>? _map(Map<String, dynamic>? source, String key) {
    final value = source?[key];
    return value is Map<String, dynamic> ? value : null;
  }

  static String? _string(Map<String, dynamic>? source, String key) {
    final value = source?[key];
    if (value == null) {
      return null;
    }
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static String? _stringOrList(Object? value) {
    if (value is List<dynamic>) {
      return value.map((item) => item.toString()).join(',');
    }
    if (value == null) {
      return null;
    }
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static int? _int(Map<String, dynamic> source, String key) {
    final value = source[key];
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static bool? _bool(Map<String, dynamic>? source, String key) {
    final value = source?[key];
    if (value is bool) {
      return value;
    }
    if (value is String) {
      return value.toLowerCase() == 'true';
    }
    return null;
  }

  static void _addIfPresent(
    Map<String, String> query,
    String key,
    String? value,
  ) {
    if (value != null && value.isNotEmpty) {
      query[key] = value;
    }
  }
}
