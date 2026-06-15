import 'dart:convert';

class VlessProfile {
  const VlessProfile({
    required this.name,
    required this.uuid,
    required this.host,
    required this.port,
    required this.type,
    required this.security,
    required this.publicKey,
    required this.fingerprint,
    required this.sni,
    required this.shortId,
    required this.spiderX,
    required this.flow,
    required this.transportPath,
    required this.hostHeader,
    required this.alpn,
    required this.rawLink,
  });

  final String name;
  final String uuid;
  final String host;
  final int port;
  final String type;
  final String security;
  final String publicKey;
  final String fingerprint;
  final String sni;
  final String shortId;
  final String spiderX;
  final String flow;
  final String transportPath;
  final String hostHeader;
  final String alpn;
  final String rawLink;

  static VlessProfile parse(String value) {
    final raw = value.trim();
    if (raw.isEmpty) {
      throw const FormatException('Вставьте VLESS-ссылку.');
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.toLowerCase() != 'vless') {
      throw const FormatException('Поддерживаются только ссылки vless://');
    }

    final uuid = Uri.decodeComponent(uri.userInfo).trim();
    if (!_uuidRegex.hasMatch(uuid)) {
      throw const FormatException('В ссылке нет корректного UUID клиента.');
    }

    if (uri.host.isEmpty) {
      throw const FormatException('В ссылке не указан сервер.');
    }

    final params = uri.queryParameters;
    final type = params['type'] ?? 'tcp';
    final security = params['security'] ?? '';
    final publicKey = params['pbk'] ?? '';
    final shortId = params['sid'] ?? '';
    final hostHeader = params['host'] ?? '';
    final path = params['path'] ?? '/';

    if (security == 'reality' && (publicKey.isEmpty || shortId.isEmpty)) {
      throw const FormatException('Нужна VLESS Reality ссылка с pbk и sid.');
    }

    if (security != 'reality' && security != 'tls') {
      throw const FormatException('Поддерживаются VLESS Reality и VLESS TLS.');
    }

    if (type != 'tcp' && type != 'ws') {
      throw const FormatException('Поддерживаются VLESS TCP и WebSocket.');
    }

    return VlessProfile(
      name:
          Uri.decodeComponent(uri.fragment.isEmpty ? 'netineta' : uri.fragment),
      uuid: uuid,
      host: uri.host,
      port: uri.hasPort ? uri.port : 443,
      type: type,
      security: security,
      publicKey: publicKey,
      fingerprint: params['fp'] ?? 'chrome',
      sni: params['sni'] ?? (hostHeader.isEmpty ? uri.host : hostHeader),
      shortId: shortId,
      spiderX: params['spx'] ?? '/',
      flow: params['flow'] ?? (type == 'tcp' ? 'xtls-rprx-vision' : ''),
      transportPath: path.startsWith('/') ? path : '/$path',
      hostHeader: hostHeader,
      alpn: params['alpn'] ?? '',
      rawLink: raw,
    );
  }

  factory VlessProfile.fromJson(Map<String, dynamic> json) {
    return VlessProfile(
      name: json['name'] as String,
      uuid: json['uuid'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      type: json['type'] as String,
      security: json['security'] as String,
      publicKey: json['publicKey'] as String,
      fingerprint: json['fingerprint'] as String,
      sni: json['sni'] as String,
      shortId: json['shortId'] as String,
      spiderX: json['spiderX'] as String,
      flow: json['flow'] as String,
      transportPath: json['transportPath'] as String? ?? '/',
      hostHeader: json['hostHeader'] as String? ?? '',
      alpn: json['alpn'] as String? ??
          _alpnFromRawLink(json['rawLink'] as String? ?? ''),
      rawLink: json['rawLink'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'uuid': uuid,
      'host': host,
      'port': port,
      'type': type,
      'security': security,
      'publicKey': publicKey,
      'fingerprint': fingerprint,
      'sni': sni,
      'shortId': shortId,
      'spiderX': spiderX,
      'flow': flow,
      'transportPath': transportPath,
      'hostHeader': hostHeader,
      'alpn': alpn,
      'rawLink': rawLink,
    };
  }

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toSingBoxConfig({
    bool routeRussianServicesDirect = true,
  }) {
    final routeRules = <Map<String, dynamic>>[
      {
        'protocol': 'dns',
        'action': 'hijack-dns',
      },
      if (routeRussianServicesDirect)
        {
          'domain_suffix': _directDomainSuffixes,
          'outbound': 'direct',
        },
      {
        'protocol': ['bittorrent'],
        'outbound': 'block',
      },
    ];

    final outbound = <String, dynamic>{
      'type': 'vless',
      'tag': 'proxy',
      'server': _connectHost(host),
      'server_port': port,
      'uuid': uuid,
      'packet_encoding': 'xudp',
      'tls': _tlsConfig(),
    };

    if (flow.isNotEmpty && type == 'tcp') {
      outbound['flow'] = flow;
    }

    if (type == 'ws') {
      outbound['transport'] = {
        'type': 'ws',
        'path': transportPath,
        if (hostHeader.isNotEmpty)
          'headers': {
            'Host': hostHeader,
          },
      };
    }

    return {
      'log': {
        'level': 'warn',
        'timestamp': true,
      },
      'dns': {
        'servers': [
          {
            'tag': 'cloudflare',
            'address': 'https://1.1.1.1/dns-query',
            'detour': 'proxy',
          },
          {
            'tag': 'local',
            'address': 'local',
            'detour': 'direct',
          },
        ],
        'rules': [
          if (routeRussianServicesDirect)
            {
              'domain_suffix': _directDomainSuffixes,
              'server': 'local',
            },
        ],
        'final': 'cloudflare',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'ironvpn0',
          'address': ['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
          'sniff': true,
        },
      ],
      'outbounds': [
        outbound,
        {
          'type': 'direct',
          'tag': 'direct',
        },
        {
          'type': 'block',
          'tag': 'block',
        },
      ],
      'route': {
        'rules': routeRules,
        'final': 'proxy',
        'auto_detect_interface': true,
      },
    };
  }

  String toSingBoxConfigJson({bool routeRussianServicesDirect = true}) {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(
      toSingBoxConfig(routeRussianServicesDirect: routeRussianServicesDirect),
    );
  }

  Map<String, dynamic> _tlsConfig() {
    return {
      'enabled': true,
      'server_name': sni,
      'utls': {
        'enabled': true,
        'fingerprint': fingerprint,
      },
      if (alpn.isNotEmpty)
        'alpn': alpn
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(),
      if (security == 'reality')
        'reality': {
          'enabled': true,
          'public_key': publicKey,
          'short_id': shortId,
        },
    };
  }

  static final _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static String _alpnFromRawLink(String rawLink) {
    final uri = Uri.tryParse(rawLink);
    if (uri == null) {
      return '';
    }
    return uri.queryParameters['alpn'] ?? '';
  }

  static String _connectHost(String host) {
    final match = _sslipIpv4Regex.firstMatch(host);
    if (match == null) {
      return host;
    }

    return '${match.group(1)}.${match.group(2)}.${match.group(3)}.${match.group(4)}';
  }

  static final _sslipIpv4Regex = RegExp(
    r'^(\d{1,3})-(\d{1,3})-(\d{1,3})-(\d{1,3})\.sslip\.io$',
  );

  static const _directDomainSuffixes = [
    'ozon.ru',
    'wildberries.ru',
    'avito.ru',
    'gosuslugi.ru',
    'yandex.ru',
    'ya.ru',
    'vk.com',
    'ok.ru',
    'mail.ru',
    'sberbank.ru',
    'tbank.ru',
    'tinkoff.ru',
    'alfabank.ru',
    'vtb.ru',
    'faceit.com',
    'steamcommunity.com',
    'steampowered.com',
    'steamstatic.com',
  ];
}
