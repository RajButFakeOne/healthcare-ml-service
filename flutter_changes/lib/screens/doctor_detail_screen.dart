// lib/screens/doctor_detail_screen.dart

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_theme.dart';
import '../models/doctor_listing.dart';
import '../models/app_session.dart';
import '../services/ml_api_service.dart';
import '../widgets/symptom_picker_field.dart';
import '../widgets/ui.dart';

class DoctorDetailScreen extends StatefulWidget {
  final DoctorListing doctor;
  const DoctorDetailScreen({super.key, required this.doctor});

  @override
  State<DoctorDetailScreen> createState() => _DoctorDetailScreenState();
}

class _DoctorDetailScreenState extends State<DoctorDetailScreen> {
  bool _isSubmitting = false;
  bool _hasRequested = false; // Tracks if an appointment request has been sent

  String _normalizeDay(String raw) {
    final clean = raw.trim().toLowerCase();
    if (clean.startsWith('sat')) return 'Saturday';
    if (clean.startsWith('sun')) return 'Sunday';
    if (clean.startsWith('mon')) return 'Monday';
    if (clean.startsWith('tue')) return 'Tuesday';
    if (clean.startsWith('wed')) return 'Wednesday';
    if (clean.startsWith('thu')) return 'Thursday';
    if (clean.startsWith('fri')) return 'Friday';
    return raw;
  }

  List<String> _getAvailableDays() {
    return widget.doctor.days.map((e) => _normalizeDay(e)).toList();
  }

  String _getDayName(int weekday) {
    switch (weekday) {
      case DateTime.saturday:
        return 'Saturday';
      case DateTime.sunday:
        return 'Sunday';
      case DateTime.monday:
        return 'Monday';
      case DateTime.tuesday:
        return 'Tuesday';
      case DateTime.wednesday:
        return 'Wednesday';
      case DateTime.thursday:
        return 'Thursday';
      case DateTime.friday:
        return 'Friday';
      default:
        return '';
    }
  }

  bool _isDayAvailable(DateTime date) {
    final available = _getAvailableDays();
    final dayName = _getDayName(date.weekday);
    return available.contains(dayName);
  }

  static const _countedStatuses =
      'status.eq.Scheduled,status.eq.Confirmed,status.eq.In_Progress,status.eq.Completed';

  /// Returns the daily limit if the doctor is already full on [dateStr],
  /// -1 if the date is locked for rescheduled appointments,
  /// or null when there is still room (or no limit is set).
  Future<int?> _fullLimitFor(String dateStr) async {
    final supabase = Supabase.instance.client;
    final settings = await supabase
        .from('doctor_daily_settings')
        .select('daily_limit, is_locked')
        .eq('doctor_id', widget.doctor.id)
        .eq('date', dateStr)
        .maybeSingle();

    if (settings?['is_locked'] == true) {
      return -1; // -1 represents locked date
    }

    final limit = (settings?['daily_limit'] as int?) ?? 50;
    if (limit <= 0) return null;

    final rows = await supabase
        .from('appointments')
        .select('id')
        .eq('doctor_id', widget.doctor.id)
        .eq('preferred_date', dateStr)
        .or(_countedStatuses);
    return (rows as List).length >= limit ? limit : null;
  }

  Future<void> _showFullDialog(BuildContext ctx, int? limit, String dateStr) {
    final isLocked = limit == -1;
    return showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.event_busy, color: Colors.red, size: 40),
        title: Text(isLocked ? 'Date is Locked' : 'Doctor is fully booked'),
        content: Text(
          isLocked
              ? 'This date ($dateStr) has been reserved by the doctor for rescheduled appointments. No new patient bookings can be accepted for this date.\n\nPlease choose another date.'
              : (limit == null
                      ? 'This doctor has reached the daily patient limit for '
                      : 'This doctor has reached the daily limit of $limit patients for ') +
                  '$dateStr, so new requests cannot be sent for this date.\n\n'
                  'Please choose another date.',
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.green),
            onPressed: () => Navigator.pop(c),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showBookingDialog(BuildContext context) async {
    // Prevent doctors from opening or executing the booking flow
    if (AppSession.instance.role == AccountRole.doctor) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Doctors cannot request appointments.')),
      );
      return;
    }

    final symptomController = TextEditingController();
    DateTime? selectedDate;
    int? fullLimit; // set when the chosen date is already full
    final supabase = Supabase.instance.client;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Request Appointment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Provide your symptom or reason for visit. The doctor will review and confirm your request.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 14),

                // 1. Initial Symptom (Required by Database Schema)
                SymptomPickerField(controller: symptomController),
                const SizedBox(height: 14),

                // 2. Preferred Date Selection (Restricted to Doctor's Visiting Days)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 18),
                    label: Text(
                      selectedDate == null
                          ? 'Select Preferred Date *'
                          : '${selectedDate!.year}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')} (${_getDayName(selectedDate!.weekday)})',
                    ),
                    onPressed: () async {
                      final availableDays = _getAvailableDays();
                      if (availableDays.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'This doctor has no visiting days available.')),
                        );
                        return;
                      }

                      final now = DateTime.now();
                      DateTime initial = now;
                      bool foundValidInitial = false;
                      for (int i = 0; i < 60; i++) {
                        final testDate = now.add(Duration(days: i));
                        if (_isDayAvailable(testDate)) {
                          initial = testDate;
                          foundValidInitial = true;
                          break;
                        }
                      }

                      if (!foundValidInitial) {
                        initial = now;
                      }

                      final pickedDate = await showDatePicker(
                        context: context,
                        initialDate: initial,
                        firstDate: now,
                        lastDate: now.add(const Duration(days: 90)),
                        selectableDayPredicate: (date) => _isDayAvailable(date),
                      );
                      if (pickedDate != null) {
                        setDialogState(() {
                          selectedDate = pickedDate;
                          fullLimit = null;
                        });
                        final dStr = pickedDate.toIso8601String().split('T')[0];
                        try {
                          final full = await _fullLimitFor(dStr);
                          setDialogState(() => fullLimit = full);
                          if (full != null && context.mounted) {
                            await _showFullDialog(context, full, dStr);
                          }
                        } catch (_) {}
                      }
                    },
                  ),
                ),
                if (fullLimit != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Fully booked: the daily limit of $fullLimit patients is reached for this date. Please choose another date.',
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.green),
              onPressed: () async {
                if (AppSession.instance.role == AccountRole.doctor) {
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Doctors cannot request appointments.')),
                  );
                  return;
                }

                final symptom = symptomController.text.trim();
                if (symptom.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Please enter your initial symptom')),
                  );
                  return;
                }

                if (selectedDate == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Please select a preferred date')),
                  );
                  return;
                }

                final submitDate =
                    selectedDate!.toIso8601String().split('T')[0];
                try {
                  final full = await _fullLimitFor(submitDate);
                  if (full != null) {
                    setDialogState(() => fullLimit = full);
                    if (context.mounted) {
                      await _showFullDialog(context, full, submitDate);
                    }
                    return; // keep the request dialog open to pick another date
                  }
                } catch (_) {}

                Navigator.pop(dialogContext);
                setState(() => _isSubmitting = true);

                try {
                  final user = supabase.auth.currentUser;
                  if (user == null) {
                    throw Exception('User not logged in');
                  }

                  // Fetch patient record linked to current logged-in user
                  final patientResponse = await supabase
                      .from('patients')
                      .select('id')
                      .eq('user_id', user.id)
                      .single();

                  final patientId = patientResponse['id'];

                  // Live model on Render (falls back to the offline model if unreachable).
                  final predictedMins = await MLApiService.predictMinutes(
                    symptomText: symptom,
                    patientAge: MLApiService.ageFromDob(
                        AppSession.instance.profile?['date_of_birth']),
                  );

                  // Payload dictionary with Pending status
                  final Map<String, dynamic> appointmentData = {
                    'doctor_id': widget.doctor.id,
                    'patient_id': patientId,
                    'initial_symptom': symptom,
                    'predicted_duration_minutes': predictedMins,
                    'status': 'Pending', // Awaiting doctor verification
                    'preferred_date':
                        selectedDate!.toIso8601String().split('T')[0],
                    'arrival_time': selectedDate!.toIso8601String(),
                  };

                  // Insert new appointment request
                  await supabase.from('appointments').insert(appointmentData);

                  setState(() {
                    _hasRequested = true;
                  });

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Appointment request sent! Pending doctor review.'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    final msg = e.toString().toLowerCase();
                    final looksFull = msg.contains('limit') ||
                        msg.contains('full') ||
                        msg.contains('row-level security') ||
                        msg.contains('violates');
                    if (looksFull) {
                      await _showFullDialog(this.context, null, submitDate);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to book appointment: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  }
                } finally {
                  if (mounted) {
                    setState(() => _isSubmitting = false);
                  }
                }
              },
              child: const Text('Submit Request',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.doctor;
    final isDoctor = AppSession.instance.role == AccountRole.doctor;

    return Scaffold(
      appBar: AppBar(title: const Text('Doctor Profile')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Row(
            children: [
              const CircleAvatar(
                radius: 38,
                backgroundColor: AppTheme.pale,
                child: Icon(Icons.medical_services_outlined,
                    size: 36, color: AppTheme.green),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name,
                        style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.dark)),
                    const SizedBox(height: 4),
                    Text(d.specialization,
                        style: const TextStyle(
                            color: AppTheme.green, fontSize: 16)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _line(Icons.school_outlined, 'Qualifications', d.qualifications),
          _line(Icons.work_outline, 'Experience', '${d.experience} years'),
          _line(Icons.payments_outlined, 'Visit fee', d.feeText),
          if (d.bio.isNotEmpty)
            _line(Icons.description_outlined, 'About', d.bio),
          const SizedBox(height: 14),
          const Text('Visiting hours',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.dark)),
          const SizedBox(height: 8),
          if (d.days.isEmpty) const Text('No visiting hours listed.'),
          for (final day in d.days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                      width: 110,
                      child: Text(day,
                          style: const TextStyle(color: AppTheme.green))),
                  Expanded(
                      child: Text(d.hoursFor(day),
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
          const SizedBox(height: 18),
          const Text('Location',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.dark)),
          const SizedBox(height: 8),
          _line(Icons.local_hospital_outlined, 'Hospital / Clinic', d.hospital),
          _line(Icons.location_on_outlined, 'Address', d.address),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => openMap(context, d.mapQuery),
            icon: const Icon(Icons.map_outlined),
            label: const Text('View Map'),
          ),
          const SizedBox(height: 30),
        ],
      ),
      // Hide the bottom request bar completely if the user is a doctor
      bottomNavigationBar: isDoctor
          ? null
          : Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _hasRequested ? Colors.orange : AppTheme.green,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: (_isSubmitting || _hasRequested)
                    ? null
                    : () => _showBookingDialog(context),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        _hasRequested
                            ? 'Request Pending (Awaiting Verification)'
                            : 'Request Appointment',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
              ),
            ),
    );
  }

  Widget _line(IconData icon, String title, String value) =>
      value.trim().isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: AppTheme.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: AppTheme.green, fontSize: 12)),
                        const SizedBox(height: 2),
                        Text(value,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppTheme.dark)),
                      ],
                    ),
                  ),
                ],
              ),
            );
}
