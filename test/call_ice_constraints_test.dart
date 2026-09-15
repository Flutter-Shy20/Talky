// Les contraintes d'une offre de redémarrage ICE.
//
// flutter_webrtc passe la map au natif, qui ne lit que `mandatory` et
// `optional`. Une map plate produit des contraintes vides : l'offre part avec
// le même ufrag, le pair y répond, et rien ne redémarre. C'est silencieux — et
// c'est ce qui faisait mourir toutes les reconnexions.
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/services/call/call_ice_constraints.dart';

void main() {
  test('le format hérité est respecté', () {
    // Sans ces deux clés, le parseur natif rend des contraintes vides.
    expect(iceRestartOfferConstraints.containsKey('mandatory'), isTrue);
    expect(iceRestartOfferConstraints.containsKey('optional'), isTrue);
    expect(iceRestartOfferConstraints['mandatory'], isA<Map>());
    expect(iceRestartOfferConstraints['optional'], isA<List>());
  });

  test('la clé porte bien sa majuscule', () {
    final m = iceRestartOfferConstraints['mandatory'] as Map;
    expect(m['IceRestart'], isTrue, reason: 'le natif lit « IceRestart »');
    expect(
      m.containsKey('iceRestart'), isFalse,
      reason: 'la minuscule est ignorée en silence — c\'était le défaut',
    );
  });

  test('les directions de l\'offre initiale sont conservées', () {
    // L'offre d'origine part sans argument, donc avec le défaut du plugin.
    // Les omettre ferait partir la reprise avec d\'autres directions.
    final m = iceRestartOfferConstraints['mandatory'] as Map;
    expect(m['OfferToReceiveAudio'], isTrue);
    expect(m['OfferToReceiveVideo'], isTrue);
  });

  test('aucune clé au premier niveau hors mandatory/optional', () {
    // Une clé égarée à la racine serait ignorée sans un mot.
    expect(iceRestartOfferConstraints.keys.toSet(), {'mandatory', 'optional'});
  });
}
