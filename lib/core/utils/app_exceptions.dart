import '../theme/locale_controller.dart';

class AppException implements Exception {
  final String message;
  final String? code;
  final int? statusCode;

  AppException(this.message, {this.code, this.statusCode});

  @override
  String toString() => 'AppException: $message';
}

class AuthException extends AppException {
  AuthException(super.message, {super.code, super.statusCode});
}

class NetworkException extends AppException {
  NetworkException(super.message) : super(code: 'NETWORK_ERROR');
}

class TokenExpiredException extends AuthException {
  /// `resolveL10n()` et non `LocaleController.instance` : le contrôleur est
  /// fourni par un provider paresseux, donc absent tant que le premier `build`
  /// n'a pas eu lieu. Construire cette exception avant — au démarrage, ou dans
  /// l'isolate FCM d'arrière-plan — levait un `StateError` qui masquait
  /// l'expiration de session qu'on cherchait justement à signaler.
  TokenExpiredException()
      : super(resolveL10n().sessionExpired,
            code: 'TOKEN_EXPIRED', statusCode: 401);
}
