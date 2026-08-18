import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:talky_flutter/core/theme/locale_controller.dart';
import 'package:talky_flutter/l10n/app_localizations.dart';
import 'package:talky_flutter/widgets/profile/language_choice_list.dart';
import 'package:talky_flutter/widgets/profile/theme_preview_picker.dart';

/// Le sélecteur de langue a été refondu parce qu'il fallait, pour ajouter une
/// langue, penser à quatre endroits : deux écrans, la liste des préférences et
/// l'ARB. Ces tests verrouillent ce que la refonte achète — une langue ajoutée
/// à [kForcedLocalePreferences] apparaît partout ou fait échouer la suite.
void main() {
  Widget host(Widget child, {Locale locale = const Locale('fr')}) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('nativeLabelOf', () {
    test('couvre toute langue forcée', () {
      for (final preference in kForcedLocalePreferences) {
        expect(
          nativeLabelOf(preference),
          isNotNull,
          reason: 'Langue ajoutée sans nom natif : ${preference.name}. '
              'Ajouter le cas dans nativeLabelOf.',
        );
        expect(nativeLabelOf(preference), isNotEmpty);
      }
    });

    test('« Système » n\'a pas de nom natif : c\'est un mode', () {
      expect(nativeLabelOf(AppLocalePreference.system), isNull);
    });

    test('un nom natif ne se traduit pas', () {
      // La raison d'être de la fonction : quelqu'un qui a mis l'app en chinois
      // par erreur doit retrouver « English » écrit en anglais.
      expect(nativeLabelOf(AppLocalePreference.english), 'English');
      expect(nativeLabelOf(AppLocalePreference.chinese), '中文');
    });
  });

  group('LanguageChoiceList', () {
    testWidgets('propose « Système » plus toutes les langues forcées',
        (tester) async {
      await tester.pumpWidget(host(LanguageChoiceList(
        selected: AppLocalePreference.french,
        onChanged: (_) {},
      )));

      expect(
        find.byType(RadioListTile<AppLocalePreference>),
        findsNWidgets(kForcedLocalePreferences.length + 1),
      );
      for (final preference in kForcedLocalePreferences) {
        expect(find.text(nativeLabelOf(preference)!), findsOneWidget);
      }
    });

    testWidgets('les noms natifs survivent à un changement de langue d\'app',
        (tester) async {
      await tester.pumpWidget(host(
        LanguageChoiceList(
          selected: AppLocalePreference.chinese,
          onChanged: (_) {},
        ),
        locale: const Locale('zh'),
      ));

      // Interface en chinois, mais la liste reste lisible pour tout le monde.
      expect(find.text('Français'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('un tap remonte la préférence choisie', (tester) async {
      AppLocalePreference? chosen;
      await tester.pumpWidget(host(LanguageChoiceList(
        selected: AppLocalePreference.french,
        onChanged: (value) => chosen = value,
      )));

      await tester.tap(find.text('English'));
      expect(chosen, AppLocalePreference.english);
    });

    testWidgets('désactivée, elle ne remonte rien', (tester) async {
      AppLocalePreference? chosen;
      await tester.pumpWidget(host(LanguageChoiceList(
        enabled: false,
        selected: AppLocalePreference.french,
        onChanged: (value) => chosen = value,
      )));

      await tester.tap(find.text('English'), warnIfMissed: false);
      expect(chosen, isNull);
    });
  });

  group('ThemePreviewPicker', () {
    testWidgets('trois vignettes, la sélection remonte', (tester) async {
      ThemeMode? chosen;
      await tester.pumpWidget(host(ThemePreviewPicker(
        selected: ThemeMode.system,
        lightLabel: 'Clair',
        darkLabel: 'Sombre',
        systemLabel: 'Système',
        onChanged: (mode) => chosen = mode,
      )));

      expect(find.text('Clair'), findsOneWidget);
      expect(find.text('Sombre'), findsOneWidget);
      expect(find.text('Système'), findsOneWidget);

      await tester.tap(find.text('Sombre'));
      expect(chosen, ThemeMode.dark);
    });

    testWidgets('chaque vignette s\'annonce comme un choix exclusif',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(ThemePreviewPicker(
        selected: ThemeMode.light,
        lightLabel: 'Clair',
        darkLabel: 'Sombre',
        systemLabel: 'Système',
        onChanged: (_) {},
      )));

      // Sans ça, TalkBack lit trois boutons sans dire lequel est actif — et le
      // libellé ne doit sortir qu'une fois (pas « Clair Clair »).
      expect(
        tester.getSemantics(find.text('Clair')),
        matchesSemantics(
          label: 'Clair',
          hasSelectedState: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });
  });
}
