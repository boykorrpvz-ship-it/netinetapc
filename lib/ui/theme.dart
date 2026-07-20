import 'package:flutter/material.dart';

import '../models/vpn_product.dart';

class AppColors {
  AppColors._();

  static bool _dark = true;

  static void useDarkTheme(bool value) {
    _dark = value;
  }

  static bool get isDark => _dark;

  // Palette matches the netineta.com redesign: bg #070B0D/#0B1113, ink
  // #EEF2F3, accent green #16B980 (on-accent #071011), AWG orange #F7860B.
  static Color get background =>
      _dark ? const Color(0xFF070B0D) : const Color(0xFFEEF3F6);
  static Color get backgroundAlt =>
      _dark ? const Color(0xFF0B1113) : Colors.white;
  static Color get ink =>
      _dark ? const Color(0xFFEEF2F3) : const Color(0xFF0A1C20);
  static Color get inkSoft =>
      _dark ? const Color(0xFFC2CDD1) : const Color(0xFF45585E);
  static Color get inkMuted =>
      _dark ? const Color(0xFF7C898E) : const Color(0xFF6C7E84);

  static Color get green =>
      _dark ? const Color(0xFF16B980) : const Color(0xFF07835C);
  static Color get greenDeep =>
      _dark ? const Color(0xFF7FF0C6) : const Color(0xFF0A6F4F);
  static Color get orange =>
      _dark ? const Color(0xFFF7860B) : const Color(0xFFC2620A);
  static Color get orangeDeep =>
      _dark ? const Color(0xFFE06C00) : const Color(0xFFA8530A);
  static Color get blue =>
      _dark ? const Color(0xFF61A0FF) : const Color(0xFF3B82F6);
  static Color get blueDeep =>
      _dark ? const Color(0xFF397EEB) : const Color(0xFF2563EB);

  static Color get danger =>
      _dark ? const Color(0xFFFF6B6B) : const Color(0xFFD23A3A);
  static Color get warn =>
      _dark ? const Color(0xFFF5B942) : const Color(0xFF9A6A00);
  static Color get idle =>
      _dark ? const Color(0xFF7C8A8F) : const Color(0xFF8497A0);

  static Color get glass =>
      _dark ? const Color(0x0FFFFFFF) : const Color(0xF7FFFFFF);
  static Color get glassStrong =>
      _dark ? const Color(0x17FFFFFF) : Colors.white;
  static Color get glassBorder =>
      _dark ? const Color(0x1AFFFFFF) : const Color(0x1F0B2A33);
  static Color get glassBorderStrong =>
      _dark ? const Color(0x2EFFFFFF) : const Color(0x330B2A33);

  static Color accentFor(VpnProduct product) =>
      product == VpnProduct.vless ? green : orange;

  static Color accentDeepFor(VpnProduct product) =>
      product == VpnProduct.vless ? const Color(0xFF0FA577) : orangeDeep;
}

/// Typography accents from the site design: Space Grotesk for latin display
/// text (wordmark, VLESS/AWG), JetBrains Mono for labels/statuses/configs.
/// Both fall back to Manrope for glyphs they lack.
class AppFonts {
  AppFonts._();

  static const display = 'SpaceGrotesk';
  static const mono = 'JetBrainsMono';

  /// Site-style mono eyebrow label: uppercase, letterspaced, muted.
  static TextStyle monoLabel({Color? color, double size = 11}) => TextStyle(
        fontFamily: mono,
        fontFamilyFallback: const ['Manrope'],
        fontSize: size,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w500,
        color: color ?? AppColors.inkMuted,
      );
}

class AppGradients {
  AppGradients._();

  static LinearGradient backgroundFor(VpnProduct product) {
    final accent = AppColors.accentFor(product);
    final tinted = Color.alphaBlend(
      accent.withValues(alpha: AppColors.isDark ? 0.13 : 0.08),
      AppColors.backgroundAlt,
    );

    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        AppColors.background,
        tinted,
        AppColors.backgroundAlt,
      ],
      stops: const [0, 0.55, 1],
    );
  }

  static LinearGradient get background => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          AppColors.background,
          AppColors.backgroundAlt,
        ],
      );
}

class AppRadii {
  AppRadii._();

  // Site design: cards 22, tiles 16 (netineta.com glass panels)
  static const card = BorderRadius.all(Radius.circular(22));
  static const tile = BorderRadius.all(Radius.circular(16));
  static const chip = BorderRadius.all(Radius.circular(14));
  static const pill = BorderRadius.all(Radius.circular(100));
}

class AppShadows {
  AppShadows._();

  static List<BoxShadow> get card => [
        BoxShadow(
          color: AppColors.isDark
              ? const Color(0x99000000)
              : const Color(0x263A525A),
          blurRadius: 32,
          spreadRadius: -16,
          offset: const Offset(0, 20),
        ),
      ];

  static List<BoxShadow> get tile => [
        BoxShadow(
          color: AppColors.isDark
              ? const Color(0x73000000)
              : const Color(0x1F3A525A),
          blurRadius: 22,
          spreadRadius: -13,
          offset: const Offset(0, 14),
        ),
      ];
}

class AppDecorations {
  AppDecorations._();

  static BoxDecoration get panel => BoxDecoration(
        color: AppColors.glass,
        borderRadius: AppRadii.card,
        border: Border.all(color: AppColors.glassBorder),
        boxShadow: AppShadows.card,
      );
}
