import 'package:flutter/material.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/why_screen.dart';

class _Section {
  final String title;
  final List<String> paragraphs;

  const _Section(this.title, this.paragraphs);
}

const List<_Section> _sections = [
  _Section('Your baseline', [
    'Each signal is compared with your own last 28 days, not with anyone '
        'else. When there are enough of them, weekdays are compared with '
        'weekdays and weekends with weekends.',
    'Until a few days exist for at least four signals, there is no score: '
        'the app is still learning your usual.',
  ]),
  _Section('Levels and drift', [
    'Each signal gets a level from 0 to 100. Level = 12 + 22 × how far '
        'today is from your usual, in the direction that counts. An ordinary '
        'day sits around 12.',
    'Drift is the average of the six levels.',
    'Stable is under 20, Early drift is under 45, Elevated drift is under '
        '70 and High drift is 70 and above.',
  ]),
  _Section('A worked example', [
    'Say you usually switch apps about 60 times a day, give or take 8. '
        'Today you switched 84 times, which is 3 steps of 8 above your usual. '
        'The level is 12 + 22 × 3 = 78.',
    'If the six levels are 78, 36, 34, 21, 12 and 12, their average is 32, '
        'which is Early drift.',
  ]),
  _Section('Context', [
    'If you mark a personal context such as Exams or Travelling, the number '
        'you see is lowered by 15 while it is active. The raw number is still '
        'shown next to it.',
  ]),
  _Section('What is shared', [
    'Only the daily summary: the drift, the six levels, a confidence and '
        'whether your baseline is ready. It is sent only at the sharing level '
        'you chose, and nothing at all when sharing is Nothing.',
    'App names, hours of use and raw motion data never leave this phone. '
        'Suggestions, experiments and check-ins stay on this phone too.',
  ]),
  _Section('What it is not', [
    'It is not a diagnosis and not a judgement of you. It only says how your '
        'own phone-use rhythm is shifting compared with your usual.',
  ]),
];

/// Plain-language explanation of the six signals, the baseline and the
/// drift. Static text only.
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  Widget _card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  Widget _paragraph(String t) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How this works')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card('What is measured', [
            _paragraph(
              'Each completed day, six signals from how you use your phone '
              'are compared with your own usual:',
            ),
            for (final k in signalKeys)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      signalNames[k]!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      signalSources[k]!,
                      style: const TextStyle(color: ShadowColors.textSecondary),
                    ),
                  ],
                ),
              ),
          ]),
          for (final s in _sections)
            _card(s.title, [for (final p in s.paragraphs) _paragraph(p)]),
        ],
      ),
    );
  }
}
