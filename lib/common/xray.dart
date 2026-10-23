import 'dart:convert';

/// Converts Happ-style subscriptions (a JSON list of full Xray configs, as served
/// by Remnawave panels to the Happ client) into a mihomo config.
///
/// Every Xray config becomes one hidden mihomo group with all of its proxy
/// outbounds, so the core picks a live node the way Xray's balancer does. The
/// provider's Xray routing rules are kept, followed by per-service tunnels
/// (YouTube / Discord / Games) on public roscomvpn rule-sets.
class XrayConverter {
  const XrayConverter._();

  /// User-Agent for panels that serve the subscription to Happ only.
  static const happUserAgent = 'Happ/6.1.0';

  static const _testUrl = 'https://www.gstatic.com/generate_204';
  static const _proxyProtocols = {'vless', 'vmess', 'trojan', 'shadowsocks'};
  static const _vpn = '🛡️ VPN';
  static const _youtube = '📺 Youtube';
  static const _discord = '💬 Discord';
  static const _games = '🎮 Игры';

  static const _gs =
      'https://raw.githubusercontent.com/hydraponique/roscomvpn-geosite/release/mihomo/';
  static const _gi =
      'https://raw.githubusercontent.com/hydraponique/roscomvpn-geoip/release/mihomo/';
  static const _cc =
      'https://raw.githubusercontent.com/roscomvpn/custom-category/release/mihomo/';

  /// name -> (behavior, format, url)
  static final Map<String, (String, String, String)> _ruleSets = {
    for (final e in const {
      'private-domains': 'private',
      'category-ru': 'category-ru',
      'category-ads': 'category-ads',
      'win-spy': 'win-spy',
      'torrent-domains': 'torrent',
      'twitch-ads': 'twitch-ads',
      'youtube': 'youtube',
      'telegram': 'telegram',
      'github': 'github',
      'twitch': 'twitch',
      'microsoft': 'microsoft',
      'apple': 'apple',
      'google-play': 'google-play',
      'pinterest': 'pinterest',
      'epicgames': 'epicgames',
      'origin': 'origin',
      'riot': 'riot',
      'escapefromtarkov': 'escapefromtarkov',
      'steam': 'steam',
      'faceit': 'faceit',
    }.entries)
      e.key: ('domain', 'mrs', '$_gs${e.value}.mrs'),
    'private-ips': ('ipcidr', 'mrs', '${_gi}private.mrs'),
    'direct-ips': ('ipcidr', 'mrs', '${_gi}direct.mrs'),
    'torrent-clients': (
      'classical',
      'yaml',
      'https://raw.githubusercontent.com/legiz-ru/mihomo-rule-sets/main/other/torrent-clients.yaml'
    ),
    'games': ('classical', 'yaml', '${_cc}games.yaml'),
    'ru-apps': ('classical', 'yaml', '${_cc}ru-apps.yaml'),
  };

  static const _rulesHead = [
    'RULE-SET,private-ips,DIRECT,no-resolve',
    'IP-CIDR,::/0,REJECT-DROP,no-resolve',
    // No QUIC: browsers fall back to TCP, which tunnels reliably.
    'AND,((NETWORK,UDP),(DST-PORT,443/853)),REJECT-DROP',
  ];

  static final _rulesTail = [
    'RULE-SET,private-domains,DIRECT',
    'RULE-SET,category-ads,REJECT-DROP',
    'RULE-SET,win-spy,REJECT-DROP',
    'RULE-SET,torrent-domains,DIRECT',
    'RULE-SET,twitch-ads,PROXY',
    'RULE-SET,youtube,$_youtube',
    for (final d in const [
      'discord.com',
      'discord.gg',
      'discordapp.com',
      'discordapp.net',
      'discord.media',
      'discordcdn.com',
    ])
      'DOMAIN-SUFFIX,$d,$_discord',
    'PROCESS-NAME-REGEX,(?i)discord,$_discord',
    'PROCESS-NAME-REGEX,(?i)vesktop,$_discord',
    'RULE-SET,telegram,PROXY',
    'RULE-SET,github,PROXY',
    for (final n in const [
      'epicgames',
      'origin',
      'riot',
      'escapefromtarkov',
      'steam',
      'faceit',
    ])
      'RULE-SET,$n,$_games',
    for (final n in const [
      'twitch',
      'microsoft',
      'apple',
      'google-play',
      'pinterest',
      'category-ru',
      'torrent-clients',
    ])
      'RULE-SET,$n,DIRECT',
    'RULE-SET,games,$_games',
    'RULE-SET,ru-apps,DIRECT',
    'RULE-SET,direct-ips,DIRECT,no-resolve',
    'DOMAIN,lknpd.nalog.ru,DIRECT',
    'MATCH,PROXY',
  ];

  /// Node domains of these panels are .ru hosts; FlClashX's default
  /// proxy-server-nameserver (doh.pub) fails to resolve them from Russia, which
  /// left only IP-addressed nodes working. Mirror Happ's DNS instead.
  /// Yandex DNS gets both of its addresses: when 77.88.8.8 alone was
  /// unreachable from a home network, every .ru site stopped resolving.
  static const _yandexDns = ['77.88.8.8', '77.88.8.1'];
  static const _dns = {
    'enable': true,
    'listen': '0.0.0.0:1053',
    'ipv6': false,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'default-nameserver': [..._yandexDns, '1.1.1.1'],
    'proxy-server-nameserver': [..._yandexDns, 'https://1.1.1.1/dns-query'],
    'nameserver': ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
    'nameserver-policy': {
      '+.ru,+.su,+.xn--p1ai': _yandexDns,
    },
  };

  /// True when [text] is an Xray JSON subscription rather than a Clash config.
  static bool isXrayJson(String text) {
    final trimmed = text.trimLeft();
    if (!trimmed.startsWith('[') && !trimmed.startsWith('{')) return false;
    try {
      final data = json.decode(trimmed);
      final configs = data is List ? data : [data];
      return configs.isNotEmpty &&
          configs.every((c) => c is Map && c['outbounds'] is List);
    } on FormatException {
      return false;
    }
  }

  /// Converts an Xray JSON subscription to a mihomo config (JSON is valid YAML).
  static String convert(String text) {
    final data = json.decode(text);
    final configs = [
      for (final c in (data is List ? data : [data])) c as Map<String, dynamic>
    ];

    final proxies = <Map<String, dynamic>>[];
    final groups = <Map<String, dynamic>>[];
    final nameByKey = <String, String>{};

    for (final cfg in configs) {
      final groupName = (cfg['remarks'] as String?)?.trim().isNotEmpty == true
          ? cfg['remarks'] as String
          : 'group ${groups.length + 1}';
      final (outbounds, type) = _groupNodes(cfg);
      final members = <String>[];
      for (final (i, o) in outbounds.indexed) {
        final proxy = _convertOutbound('$groupName #${i + 1}', o);
        if (proxy == null) continue;
        // Identical endpoints repeat across Happ groups: keep one node each.
        final key = json.encode({...proxy}..remove('name'));
        final name = nameByKey.putIfAbsent(key, () {
          proxies.add(proxy);
          return proxy['name'] as String;
        });
        if (!members.contains(name)) members.add(name);
      }
      if (members.isEmpty) continue;
      groups.add({
        'name': groupName,
        'type': type,
        'proxies': members,
        'url': _testUrl,
        'interval': 180,
        'lazy': true,
        'hidden': true,
        if (type == 'url-test') 'tolerance': 50,
      });
    }

    final happRules = [
      for (final r in _routingRules(configs.firstOrNull)) ..._convertRule(r)
    ];
    final rules = {..._rulesHead, ...happRules, ..._rulesTail}.toList();

    final countries = [for (final g in groups) g['name'] as String];
    Map<String, dynamic> select(String name, List<String> first) =>
        {'name': name, 'type': 'select', 'proxies': [...first, ...countries]};

    return json.encode({
      'dns': _dns,
      'proxies': proxies,
      'proxy-groups': [
        select(_vpn, []),
        select(_youtube, [_vpn, 'DIRECT']),
        select(_discord, [_vpn, 'DIRECT']),
        select(_games, ['DIRECT', _vpn]),
        ...groups,
        {
          'name': 'PROXY',
          'type': 'select',
          'proxies': [_vpn],
          'hidden': true,
        },
      ],
      'rule-providers': {
        for (final MapEntry(key: name, value: (behavior, format, url))
            in _ruleSets.entries)
          name: {
            'type': 'http',
            'behavior': behavior,
            'format': format,
            'url': url,
            'path': './ruleset/$name.$format',
            'interval': 86400,
            'proxy': 'PROXY',
          },
      },
      'rules': rules,
    });
  }

  /// Proxy outbounds of one config in balancer order, plus the group type:
  /// staged configs (several balancers chained by fallbackTag) become
  /// `fallback`, a single balancer becomes `url-test`.
  static (List<Map<String, dynamic>>, String) _groupNodes(
      Map<String, dynamic> cfg) {
    final outs = [
      for (final o in (cfg['outbounds'] as List? ?? const []))
        if (o is Map<String, dynamic> && _proxyProtocols.contains(o['protocol']))
          o
    ];
    final routing = cfg['routing'];
    final balancers = routing is Map ? (routing['balancers'] as List? ?? []) : [];
    if (balancers.isEmpty) return (outs, 'url-test');
    final ordered = <Map<String, dynamic>>[];
    for (final b in balancers) {
      final selectors = [...(b['selector'] as List? ?? const [])];
      for (final o in outs) {
        final tag = o['tag'] as String? ?? '';
        if (selectors.any((s) => tag.startsWith(s as String)) &&
            !ordered.contains(o)) {
          ordered.add(o);
        }
      }
    }
    return (
      ordered.isEmpty ? outs : ordered,
      balancers.length > 1 ? 'fallback' : 'url-test'
    );
  }

  static List<Map<String, dynamic>> _routingRules(Map<String, dynamic>? cfg) {
    final routing = cfg?['routing'];
    if (routing is! Map) return const [];
    return [
      for (final r in (routing['rules'] as List? ?? const []))
        if (r is Map<String, dynamic>) r
    ];
  }

  static Map<String, dynamic>? _convertOutbound(
      String name, Map<String, dynamic> o) {
    final settings = o['settings'] as Map<String, dynamic>? ?? const {};
    final Map<String, dynamic> proxy;
    switch (o['protocol']) {
      case 'vless' || 'vmess':
        final server = (settings['vnext'] as List?)?.firstOrNull as Map?;
        final user = (server?['users'] as List?)?.firstOrNull as Map?;
        if (server == null || user == null) return null;
        proxy = {
          'name': name,
          'type': o['protocol'],
          'server': server['address'],
          'port': server['port'],
          'uuid': user['id'],
          'udp': true,
        };
        if (o['protocol'] == 'vless') {
          final flow = user['flow'] as String?;
          if (flow != null && flow.isNotEmpty) proxy['flow'] = flow;
        } else {
          proxy['alterId'] = user['alterId'] ?? 0;
          proxy['cipher'] = user['security'] ?? 'auto';
        }
      case 'trojan':
        final server = (settings['servers'] as List?)?.firstOrNull as Map?;
        if (server == null) return null;
        proxy = {
          'name': name,
          'type': 'trojan',
          'server': server['address'],
          'port': server['port'],
          'password': server['password'],
          'udp': true,
        };
      case 'shadowsocks':
        final server = (settings['servers'] as List?)?.firstOrNull as Map?;
        if (server == null) return null;
        return {
          'name': name,
          'type': 'ss',
          'server': server['address'],
          'port': server['port'],
          'cipher': server['method'],
          'password': server['password'],
          'udp': true,
        };
      default:
        return null;
    }
    _applyStream(proxy, o['streamSettings'] as Map<String, dynamic>? ?? const {});
    return proxy;
  }

  static void _applyStream(Map<String, dynamic> p, Map<String, dynamic> ss) {
    var network = ss['network'] as String? ?? 'tcp';
    if (network == 'raw') network = 'tcp';
    p['network'] = network;
    switch (network) {
      case 'ws':
        final ws = ss['wsSettings'] as Map? ?? const {};
        final host = ws['host'] ?? (ws['headers'] as Map?)?['Host'];
        p['ws-opts'] = {
          'path': ws['path'] ?? '/',
          if (host != null) 'headers': {'Host': host},
        };
      case 'grpc':
        p['grpc-opts'] = {
          'grpc-service-name': (ss['grpcSettings'] as Map?)?['serviceName'] ?? '',
        };
      case 'httpupgrade':
        final hu = ss['httpupgradeSettings'] as Map? ?? const {};
        p['network'] = 'ws';
        p['ws-opts'] = {
          'path': hu['path'] ?? '/',
          'v2ray-http-upgrade': true,
          if (hu['host'] != null) 'headers': {'Host': hu['host']},
        };
      case 'xhttp':
        final xh = ss['xhttpSettings'] as Map? ?? const {};
        p['xhttp-opts'] = {
          for (final k in const ['path', 'host', 'mode'])
            if (xh[k] != null) k: xh[k],
        };
    }

    final security = ss['security'] as String? ?? 'none';
    if (security != 'tls' && security != 'reality') return;
    final s = (security == 'tls' ? ss['tlsSettings'] : ss['realitySettings'])
            as Map? ??
        const {};
    p['tls'] = true;
    if (s['serverName'] != null) {
      p[p['type'] == 'trojan' ? 'sni' : 'servername'] = s['serverName'];
    }
    if (s['fingerprint'] != null) p['client-fingerprint'] = s['fingerprint'];
    if (s['alpn'] != null) p['alpn'] = s['alpn'];
    if (s['allowInsecure'] == true) p['skip-cert-verify'] = true;
    if (security == 'reality') {
      p['reality-opts'] = {
        'public-key': s['publicKey'] ?? '',
        'short-id': s['shortId'] ?? '',
      };
    }
  }

  static const _targets = {'direct': 'DIRECT', 'block': 'REJECT'};

  static List<String> _convertRule(Map<String, dynamic> r) {
    // DNS/inbound plumbing and protocol sniffing have no mihomo equivalent here.
    if (r.containsKey('inboundTag') ||
        r.containsKey('port') ||
        r.containsKey('protocol')) {
      return const [];
    }
    final target =
        _targets[r['outboundTag'] ?? r['balancerTag'] ?? ''] ?? 'PROXY';
    return [
      for (final d in (r['domain'] as List? ?? const []).cast<String>())
        if (_domainRule(d) case final rule?) '$rule,$target',
      for (final ip in (r['ip'] as List? ?? const []).cast<String>())
        if (ip.startsWith('geoip:'))
          'GEOIP,${ip.substring(6).toUpperCase()},$target,no-resolve'
        else if (ip.contains(':'))
          'IP-CIDR6,${ip.contains('/') ? ip : '$ip/128'},$target,no-resolve'
        else
          'IP-CIDR,${ip.contains('/') ? ip : '$ip/32'},$target,no-resolve',
    ];
  }

  /// Xray domain matchers: `domain:` suffix, `full:` exact, `keyword:`,
  /// `regexp:`, `geosite:`, and a bare string meaning substring.
  static String? _domainRule(String d) {
    final i = d.indexOf(':');
    final (kind, value) = i < 0 ? ('', d) : (d.substring(0, i), d.substring(i + 1));
    return switch (kind) {
      'domain' => 'DOMAIN-SUFFIX,$value',
      'full' => 'DOMAIN,$value',
      'keyword' || '' => 'DOMAIN-KEYWORD,$value',
      'regexp' => 'DOMAIN-REGEX,$value',
      'geosite' => 'GEOSITE,$value',
      _ => null,
    };
  }
}
