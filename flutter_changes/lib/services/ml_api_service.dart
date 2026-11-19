import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/ml_config.dart';
import 'ml_duration_predictor.dart';

/// Real-time predictions from the hosted model, which keeps learning from every
/// completed appointment. Falls back to the bundled offline model if the
/// service is unreachable, so booking never fails because of ML.
class MLApiService {
  static final _headers = {'Content-Type': 'application/json'};

  static Future<double> predictMinutes({
    required String symptomText,
    int queueSerial = 1,
    int? patientAge,
  }) async {
    if (symptomText.trim().isEmpty) return 15.0;
    try {
      final res = await http
          .post(
            Uri.parse('${MLConfig.baseUrl}/predict'),
            headers: _headers,
            body: jsonEncode({
              'symptom': symptomText,
              'queue_serial': queueSerial,
              if (patientAge != null) 'age': patientAge,
            }),
          )
          .timeout(MLConfig.timeout);
      if (res.statusCode == 200) {
        final minutes = (jsonDecode(res.body)['minutes'] as num?)?.toDouble();
        if (minutes != null) return minutes;
      }
    } catch (_) {
      // network error / timeout / cold start: fall through to offline model
    }
    return MLDurationPredictor.predictMinutes(
      symptomText: symptomText,
      queueSerial: queueSerial,
      patientAge: patientAge,
    );
  }

  /// Fire-and-forget ping so a sleeping Render instance is awake by the time
  /// the user reaches the booking screen.
  static void warmUp() {
    http
        .get(Uri.parse('${MLConfig.baseUrl}/health'))
        .timeout(const Duration(seconds: 60))
        .catchError((_) => http.Response('', 599));
  }

  /// Age in whole years from a `date_of_birth` value ('YYYY-MM-DD'), or null.
  static int? ageFromDob(dynamic dob) {
    final d = DateTime.tryParse((dob ?? '').toString());
    if (d == null) return null;
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) age--;
    return (age >= 0 && age <= 120) ? age : null;
  }
}
