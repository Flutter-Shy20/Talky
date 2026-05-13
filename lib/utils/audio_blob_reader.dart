// Sélectionne automatiquement l'implémentation selon la plateforme :
// - web  → dart:html pour lire les blob URLs renvoyées par record
// - stub → mobile/desktop n'en ont pas besoin (ils lisent un fichier)
export 'audio_blob_reader_stub.dart'
    if (dart.library.html) 'audio_blob_reader_web.dart';