import 'dart:convert';

import 'package:flclashx/common/xray.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _vless(String tag, String address, {String? sni}) => {
      'tag': tag,
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': address,
            'port': 443,
            'users': [
              {'id': 'uuid-$address', 'flow': 'xtls-rprx-vision', 'encryption': 'none'}
            ],
          }
        ],
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'reality',
        'realitySettings': {
          'serverName': sni ?? 'www.example.com',
          'publicKey': 'PBK',
          'fingerprint': 'firefox',
        },
      },
    };

void main() {
  final subscription = json.encode([
    {
      'remarks': '🇵🇱 Польша',
      'outbounds': [
        _vless('proxy', 'pl1.example.ru'),
        _vless('proxy-2', 'pl2.example.ru'),
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'balancers': [
          {'tag': 'Balancer', 'selector': ['proxy']}
        ],
        'rules': [
          {'inboundTag': ['dns'], 'outboundTag': 'direct'},
          {'domain': ['max.ru', 'domain:vk.com', 'full:mc.yandex.ru'], 'outboundTag': 'block'},
          {'ip': ['1.1.1.1'], 'balancerTag': 'Balancer'},
        ],
      },
    },
    {
      'remarks': 'Staged',
      'outbounds': [
        _vless('stage-2', 'b.example.ru'),
        _vless('stage-1', 'a.example.ru'),
        // Same endpoint as Польша #1: must be deduplicated.
        _vless('stage-1-2', 'pl1.example.ru'),
      ],
      'routing': {
        'balancers': [
          {'tag': 'Balancer-s1', 'selector': ['stage-1'], 'fallbackTag': 'fb'},
          {'tag': 'Balancer-s2', 'selector': ['stage-2']},
        ],
      },
    },
  ]);

  test('detects Xray JSON and leaves Clash YAML alone', () {
    expect(XrayConverter.isXrayJson(subscription), isTrue);
    expect(XrayConverter.isXrayJson('proxies:\n  - name: a'), isFalse);
    expect(XrayConverter.isXrayJson('{"proxies": []}'), isFalse);
  });

  test('turns every Happ config into a group with all of its nodes', () {
    final cfg = json.decode(XrayConverter.convert(subscription));
    final groups = {for (final g in cfg['proxy-groups']) g['name']: g};

    expect(groups['🇵🇱 Польша']['type'], 'url-test');
    expect(groups['🇵🇱 Польша']['proxies'], ['🇵🇱 Польша #1', '🇵🇱 Польша #2']);
    // Staged balancers keep their order and reuse the shared node.
    expect(groups['Staged']['type'], 'fallback');
    expect(groups['Staged']['proxies'], ['Staged #1', '🇵🇱 Польша #1', 'Staged #3']);
    expect(cfg['proxies'], hasLength(4));
    expect(groups['🛡️ VPN']['proxies'], ['🇵🇱 Польша', 'Staged']);
  });

  test('maps VLESS Reality outbounds', () {
    final cfg = json.decode(XrayConverter.convert(subscription));
    final node = cfg['proxies'].first;
    expect(node['server'], 'pl1.example.ru');
    expect(node['flow'], 'xtls-rprx-vision');
    expect(node['servername'], 'www.example.com');
    expect(node['client-fingerprint'], 'firefox');
    expect(node['reality-opts'], {'public-key': 'PBK', 'short-id': ''});
  });

  test('keeps provider rules before the service template', () {
    final rules = (json.decode(XrayConverter.convert(subscription))['rules']
            as List)
        .cast<String>();
    expect(rules, containsAllInOrder([
      'DOMAIN-KEYWORD,max.ru,REJECT',
      'DOMAIN-SUFFIX,vk.com,REJECT',
      'DOMAIN,mc.yandex.ru,REJECT',
      'IP-CIDR,1.1.1.1/32,PROXY,no-resolve',
      'RULE-SET,youtube,📺 Youtube',
    ]));
    expect(rules.last, 'MATCH,PROXY');
    expect(rules.where((r) => r.contains('inbound')), isEmpty);
  });
}
