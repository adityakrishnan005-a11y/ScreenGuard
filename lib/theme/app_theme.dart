import 'package:flutter/material.dart';

/// Shared spacing scale. Using a single scale keeps every screen aligned and
/// makes it easy to tune density for phones, desktops and TVs later.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii used across cards, dialogs and controls.
abstract final class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

/// App-specific colours that Material's [ColorScheme] does not model:
/// chart hues, the idle/away slice, goal states and focus/break accents.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.chartColors,
    required this.chartBar,
    required this.idle,
    required this.success,
    required this.warning,
    required this.danger,
    required this.breakTime,
  });

  final List<Color> chartColors;

  /// Primary colour for the daily bar chart. Kept separate from the teal
  /// accent so bars stay vivid and easy to read at a glance.
  final Color chartBar;
  final Color idle;
  final Color success;
  final Color warning;
  final Color danger;
  final Color breakTime;

  static const AppPalette _fallback = AppPalette(
    chartColors: [
      Color(0xFF00B4D8),
      Color(0xFF7209B7),
      Color(0xFF38B000),
      Color(0xFFFFA200),
      Color(0xFFF72585),
      Color(0xFF4CC9F0),
      Color(0xFF78909C),
    ],
    chartBar: Color(0xFF2979FF),
    idle: Color(0xFF78909C),
    success: Color(0xFF2E7D32),
    warning: Color(0xFFEF6C00),
    danger: Color(0xFFC62828),
    breakTime: Color(0xFF1E88E5),
  );

  static const AppPalette light = _fallback;

  static const AppPalette dark = AppPalette(
    chartColors: [
      Color(0xFF22D3EE),
      Color(0xFFA78BFA),
      Color(0xFF4ADE80),
      Color(0xFFFBBF24),
      Color(0xFFFB7185),
      Color(0xFF60A5FA),
      Color(0xFF94A3B8),
    ],
    chartBar: Color(0xFF5B9DFF),
    idle: Color(0xFF90A4AE),
    success: Color(0xFF81C784),
    warning: Color(0xFFFFB74D),
    danger: Color(0xFFEF5350),
    breakTime: Color(0xFF64B5F6),
  );

  /// Convenient accessor that never throws, even when a widget is rendered
  /// outside the app's [MaterialApp] (for example in a widget test).
  static AppPalette of(BuildContext context) {
    return Theme.of(context).extension<AppPalette>() ?? _fallback;
  }

  /// Colour for the Nth chart slice / app row.
  Color colorAt(int index) => chartColors[index % chartColors.length];

  @override
  AppPalette copyWith({
    List<Color>? chartColors,
    Color? chartBar,
    Color? idle,
    Color? success,
    Color? warning,
    Color? danger,
    Color? breakTime,
  }) {
    return AppPalette(
      chartColors: chartColors ?? this.chartColors,
      chartBar: chartBar ?? this.chartBar,
      idle: idle ?? this.idle,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      breakTime: breakTime ?? this.breakTime,
    );
  }

  @override
  AppPalette lerp(covariant ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    final length = chartColors.length;
    return AppPalette(
      chartColors: [
        for (var i = 0; i < length; i++)
          Color.lerp(chartColors[i], other.chartColors[i % other.chartColors.length], t) ??
              chartColors[i],
      ],
      idle: Color.lerp(idle, other.idle, t) ?? idle,
      chartBar: Color.lerp(chartBar, other.chartBar, t) ?? chartBar,
      success: Color.lerp(success, other.success, t) ?? success,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      danger: Color.lerp(danger, other.danger, t) ?? danger,
      breakTime: Color.lerp(breakTime, other.breakTime, t) ?? breakTime,
    );
  }
}

/// Central Material 3 theme. Keeping this in one place means the whole app
/// (and any future Android phone/TV target) shares the same visual language.
abstract final class AppTheme {
  static const Color seed = Color(0xFF009688);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme);

    final cardColor = isDark ? scheme.surfaceContainerLow : Colors.white;
    final scaffoldColor = isDark ? scheme.surface : const Color(0xFFF4F6F6);

    return base.copyWith(
      scaffoldBackgroundColor: scaffoldColor,
      canvasColor: scaffoldColor,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: base.textTheme.copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      extensions: [palette],
      cardTheme: CardThemeData(
        elevation: 0,
        color: cardColor,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.55),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        iconColor: scheme.onSurfaceVariant,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: isDark ? scheme.surfaceContainer : cardColor,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return base.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? scheme.surfaceContainer : cardColor,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer, size: 24),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 24),
        selectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: base.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.5 : 0.55),
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        labelStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        secondaryLabelStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          textStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
          textStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.35 : 0.45),
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        hintStyle: base.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: base.textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}
