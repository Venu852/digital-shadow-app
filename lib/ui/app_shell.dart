import 'package:flutter/material.dart';
import 'package:test_app/ui/privacy_tab.dart';
import 'package:test_app/ui/results_screen.dart';
import 'package:test_app/ui/today_screen.dart';
import 'package:test_app/ui/usage_summary_screen.dart';
import 'package:test_app/ui/why_screen.dart';

class ShellDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const ShellDestination(this.label, this.icon, this.selectedIcon);
}

const List<ShellDestination> shellDestinations = [
  ShellDestination('Today', Icons.today_outlined, Icons.today),
  ShellDestination('Trends', Icons.show_chart_outlined, Icons.show_chart),
  ShellDestination('Why', Icons.help_outline, Icons.help),
  ShellDestination('Usage', Icons.apps_outlined, Icons.apps),
  ShellDestination('Privacy', Icons.shield_outlined, Icons.shield),
];

/// The five bottom tabs. A tab is built the first time it is shown and then
/// kept, so the Usage tab only syncs once it is opened.
class AppShell extends StatefulWidget {
  /// Builds the page for a tab; tests pass placeholders.
  final Widget Function(int index, ValueNotifier<int> tab)? pageFor;

  const AppShell({super.key, this.pageFor});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final ValueNotifier<int> _tab = ValueNotifier<int>(0);
  final Map<int, Widget> _built = {};

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Widget _page(int i) {
    final custom = widget.pageFor;
    if (custom != null) return custom(i, _tab);
    switch (i) {
      case 0:
        return TodayScreen(tab: _tab, index: 0);
      case 1:
        return const ResultsScreen();
      case 2:
        return WhyScreen(tab: _tab, index: 2);
      case 3:
        return const UsageSummaryScreen();
      default:
        return PrivacyTab(tab: _tab, index: 4);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _tab.value;
    _built.putIfAbsent(current, () => _page(current));
    return Scaffold(
      body: IndexedStack(
        index: current,
        children: [
          for (var i = 0; i < shellDestinations.length; i++)
            _built[i] ?? const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: current,
        onDestinationSelected: (i) => setState(() => _tab.value = i),
        destinations: [
          for (final d in shellDestinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
