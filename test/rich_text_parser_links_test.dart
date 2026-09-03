import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/utils/alanya_phone_formatter.dart';
import 'package:talky_flutter/core/utils/rich_text_parser.dart';

/// Ce que les quatre tamis de `parseRichSpans` retiennent, et surtout ce
/// qu'ils laissent passer : décorer en lien une arobase ordinaire ou tailler
/// un numéro dans un nombre plus long se voit dans toutes les discussions.
void main() {
  const base = TextStyle(fontSize: 16);

  /// Le texte des spans rendus tappables — ceux qui portent un recognizer.
  List<String> tappables(List<InlineSpan> spans) => [
        for (final s in spans)
          if (s is TextSpan && s.recognizer != null) s.text ?? '',
      ];

  /// Le texte reconstitué : aucun tamis ne doit perdre un caractère.
  String recolle(List<InlineSpan> spans) => [
        for (final s in spans)
          if (s is TextSpan) s.text ?? '',
      ].join();

  List<InlineSpan> parse(String texte, {bool numeros = true}) => parseRichSpans(
        texte,
        base,
        onAlanyaNumber: numeros ? (_) {} : null,
      );

  group('adresses e-mail', () {
    test('une adresse au fil du texte devient tappable', () {
      const texte = 'écris à jean@exemple.com stp';
      final spans = parse(texte);
      expect(tappables(spans), ['jean@exemple.com']);
      expect(recolle(spans), texte);
    });

    test('le point final de la phrase reste hors de l\'adresse', () {
      const texte = 'mon mail : a.b+c@exemple.co.uk.';
      final spans = parse(texte);
      expect(tappables(spans), ['a.b+c@exemple.co.uk']);
      expect(recolle(spans), texte);
    });

    test('une arobase ordinaire n\'est pas décorée', () {
      final spans = parse('rendez-vous @ midi');
      expect(tappables(spans), isEmpty);
    });

    test('un domaine sans point n\'est pas une adresse', () {
      final spans = parse('salut jean@maison');
      expect(tappables(spans), isEmpty);
    });
  });

  group('numéros Alanya', () {
    test('les longueurs valides sont retenues', () {
      // Le jeu suit AlanyaPhoneFormatter : la détection ne doit pas dériver
      // de la source de vérité de l'app.
      for (final n in AlanyaPhoneFormatter.validLengths) {
        final numero = '1' * n;
        expect(tappables(parse('appelle le $numero')), [numero],
            reason: '$n chiffres');
      }
    });

    test('les autres longueurs ne le sont pas', () {
      for (final n in [1, 2, 5, 6, 7, 9, 12]) {
        expect(tappables(parse('code ${'1' * n}')), isEmpty,
            reason: '$n chiffres');
      }
    });

    test('un numéro de huit chiffres n\'est pas coupé en deux', () {
      expect(tappables(parse('12345678')), ['12345678']);
    });

    test('sans destination, les numéros restent du texte ordinaire', () {
      final spans = parse('appelle le 12345678', numeros: false);
      expect(tappables(spans), isEmpty);
      expect(recolle(spans), 'appelle le 12345678');
    });

    test('le numéro tapé est transmis tel quel', () {
      String? recu;
      final spans = parseRichSpans('mon numéro est 4242',
          base, onAlanyaNumber: (n) => recu = n);
      final span = spans.whereType<TextSpan>()
          .firstWhere((s) => s.recognizer != null);
      (span.recognizer! as TapGestureRecognizer).onTap!();
      expect(recu, '4242');
    });
  });

  group('priorité des tamis', () {
    test('les chiffres d\'une URL ne deviennent pas un numéro', () {
      const texte = 'https://exemple.com/12345678';
      final spans = parse(texte);
      expect(tappables(spans), [texte]);
    });

    test('une adresse à l\'intérieur d\'une URL n\'est pas re-découpée', () {
      const texte = 'https://exemple.com/?m=jean@exemple.com';
      final spans = parse(texte);
      expect(tappables(spans), [texte]);
    });

    test('une URL, une adresse et un numéro cohabitent', () {
      const texte = 'vois https://a.co, écris à b@c.fr ou appelle 12345678';
      final spans = parse(texte);
      expect(tappables(spans),
          ['https://a.co', 'b@c.fr', '12345678']);
      expect(recolle(spans), texte);
    });
  });
}
