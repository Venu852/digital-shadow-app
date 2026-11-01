import 'package:flutter/material.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/ui/theme.dart';

/// "Demo data: simulated. ..." while demo mode is on, otherwise nothing.
class DemoBanner extends StatelessWidget {
  /// True above the app bar, where the banner sits under the status bar.
  final bool safeTop;

  const DemoBanner({super.key, this.safeTop = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DemoMode.enabled,
      builder: (context, on, _) => !on
          ? const SizedBox.shrink()
          : Material(
              color: ShadowColors.selected,
              child: SafeArea(
                top: safeTop,
                bottom: false,
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: minTouchTarget),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: ShadowColors.selectedBorder),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.science_outlined, color: ShadowColors.primary),
                      SizedBox(width: 12),
                      Expanded(child: Text(DemoMode.banner)),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
