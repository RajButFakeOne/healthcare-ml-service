/// Connection settings for the hosted duration-prediction model (Render).
class MLConfig {
  /// Set after deploying, or override at build time:
  ///   flutter run --dart-define=ML_API_URL=https://healthcare-ml.onrender.com
  static const baseUrl = String.fromEnvironment(
    'ML_API_URL',
    defaultValue: 'https://YOUR-SERVICE.onrender.com',
  );

  /// If the service doesn't answer in time we silently use the offline model.
  static const timeout = Duration(seconds: 6);
}
