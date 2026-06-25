enum VpnProduct {
  vless('vless'),
  amneziaWg('amneziawg');

  const VpnProduct(this.apiValue);

  final String apiValue;

  String get title {
    return switch (this) {
      VpnProduct.vless => 'Обычный VPN',
      VpnProduct.amneziaWg => 'AmneziaWG',
    };
  }

  String get shortTitle {
    return switch (this) {
      VpnProduct.vless => 'VLESS',
      VpnProduct.amneziaWg => 'AWG',
    };
  }

  String get description {
    return switch (this) {
      VpnProduct.vless =>
        'Стабильный вариант для повседневного использования. Работает как текущие ссылки.',
      VpnProduct.amneziaWg =>
        'Отдельный протокол на базе AmneziaWG 2.0. Хорош для сетей, где обычное подключение работает нестабильно.',
    };
  }

  static VpnProduct fromApi(Object? value) {
    final raw = (value ?? '').toString().trim().toLowerCase();
    return switch (raw) {
      'awg' || 'amnezia' || 'amnezia_wg' || 'amneziawg' => VpnProduct.amneziaWg,
      _ => VpnProduct.vless,
    };
  }
}

class VpnPlan {
  const VpnPlan({
    required this.key,
    required this.title,
    required this.priceRub,
    required this.days,
    this.badge,
  });

  final String key;
  final String title;
  final int priceRub;
  final int days;
  final String? badge;
}

class VpnCatalog {
  const VpnCatalog._();

  static const vlessPlans = [
    VpnPlan(key: 't_1m', title: '1 месяц', priceRub: 150, days: 30),
    VpnPlan(key: 't_3m', title: '3 месяца', priceRub: 300, days: 90),
    VpnPlan(key: 't_6m', title: '6 месяцев', priceRub: 600, days: 180),
    VpnPlan(key: 't_1y', title: '1 год', priceRub: 1000, days: 365),
  ];

  static const amneziaWgPlans = [
    VpnPlan(key: 'awg_1m', title: '1 месяц', priceRub: 250, days: 30),
    VpnPlan(
      key: 'awg_3m',
      title: '3 месяца',
      priceRub: 600,
      days: 90,
    ),
    VpnPlan(key: 'awg_6m', title: '6 месяцев', priceRub: 1000, days: 180),
    VpnPlan(key: 'awg_1y', title: '1 год', priceRub: 1500, days: 365),
  ];

  static List<VpnPlan> plansFor(VpnProduct product) {
    return switch (product) {
      VpnProduct.vless => vlessPlans,
      VpnProduct.amneziaWg => amneziaWgPlans,
    };
  }

  static VpnPlan defaultPlanFor(VpnProduct product) {
    return switch (product) {
      VpnProduct.vless => vlessPlans[0],
      VpnProduct.amneziaWg => amneziaWgPlans[0],
    };
  }

  static VpnPlan? findPlan(VpnProduct product, String key) {
    for (final plan in plansFor(product)) {
      if (plan.key == key) {
        return plan;
      }
    }
    return null;
  }

  static int totalPrice({
    required VpnProduct product,
    required VpnPlan plan,
  }) {
    return plan.priceRub;
  }
}
