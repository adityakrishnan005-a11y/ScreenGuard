import 'package:flutter/material.dart';

import 'package:screenguard/theme/app_theme.dart';

/// Coarse window-size classes, mirroring Material 3's compact / medium /
/// expanded guidance. They are intentionally based on width so the same code
/// works for desktop windows, Android phones and TV screens.
enum AppWindowClass { compact, medium, expanded }

/// Resolved layout information for the current window.
///
/// [isDirectional] becomes true when the platform reports D-pad navigation
/// (Android TV / leanback). Widgets can use it to enlarge targets and avoid
/// hover-only affordances.
@immutable
class AppLayout {
  const AppLayout({
    required this.windowClass,
    required this.isDirectional,
    required this.size,
  });

  final AppWindowClass windowClass;
  final bool isDirectional;
  final Size size;

  bool get isCompact => windowClass == AppWindowClass.compact;
  bool get isMedium => windowClass == AppWindowClass.medium;
  bool get isExpanded => windowClass == AppWindowClass.expanded;
  bool get isTv => isDirectional;

  /// Whether a side navigation rail fits better than a bottom bar.
  bool get useRail => !isCompact;

  double get contentMaxWidth => switch (windowClass) {
        AppWindowClass.compact => double.infinity,
        AppWindowClass.medium => 980,
        AppWindowClass.expanded => 1240,
      };

  EdgeInsets get pagePadding => switch (windowClass) {
        AppWindowClass.compact => const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        AppWindowClass.medium => const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.xxl),
        AppWindowClass.expanded => const EdgeInsets.fromLTRB(
            AppSpacing.xxl, AppSpacing.xl, AppSpacing.xxl, AppSpacing.xxxl),
      };

  static AppLayout of(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final windowClass = width >= 1100
        ? AppWindowClass.expanded
        : width >= 700
            ? AppWindowClass.medium
            : AppWindowClass.compact;
    return AppLayout(
      windowClass: windowClass,
      isDirectional: media.navigationMode == NavigationMode.directional,
      size: media.size,
    );
  }
}

/// Centers page content at a readable max width and applies the shared
/// responsive padding. Use inside a scrollable child.
class AppContent extends StatelessWidget {
  const AppContent({
    super.key,
    required this.child,
    this.padding,
    this.maxWidth,
  });

  final Widget child;
  final EdgeInsets? padding;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    final width = maxWidth ?? layout.contentMaxWidth;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width.isFinite ? width : double.infinity,
        ),
        child: Padding(
          padding: padding ?? layout.pagePadding,
          child: child,
        ),
      ),
    );
  }
}

/// A vertically scrolling page with the app's shared max width and padding.
/// Optionally wraps the list in a [RefreshIndicator].
class AppScrollView extends StatelessWidget {
  const AppScrollView({
    super.key,
    required this.children,
    this.onRefresh,
    this.padding,
    this.controller,
    this.physics,
  });

  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final EdgeInsets? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final layout = AppLayout.of(context);
    Widget list = ListView(
      controller: controller,
      physics: physics ?? const AlwaysScrollableScrollPhysics(),
      padding: padding ?? layout.pagePadding,
      children: children,
    );
    if (onRefresh != null) {
      list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    }
    final width = layout.contentMaxWidth;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width.isFinite ? width : double.infinity,
        ),
        child: list,
      ),
    );
  }
}

/// Lets descendants switch the shell's selected tab (for example the
/// dashboard's settings shortcut).
class MainShellScope extends InheritedWidget {
  const MainShellScope({
    super.key,
    required this.goToTab,
    required super.child,
  });

  final ValueChanged<int> goToTab;

  static MainShellScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MainShellScope>();
  }

  static MainShellScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'MainShellScope.of() called outside MainShell');
    return scope!;
  }

  @override
  bool updateShouldNotify(MainShellScope oldWidget) => false;
}
