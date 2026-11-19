// lib/screens/booking_screen.dart

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_theme.dart';
import '../models/app_session.dart';
import '../services/ml_api_service.dart';
import '../widgets/symptom_picker_field.dart';

class BookingScreen extends StatefulWidget {
  final dynamic preselectedDoctor;

  const BookingScreen({super.key, this.preselectedDoctor});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends State<BookingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _symptomController = TextEditingController();

  List<dynamic> _doctors = [];
  dynamic _selectedDoctor;

  DateTime? _selectedDate;
  bool _loadingDoctors = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Block doctors if they navigate here directly
    if (AppSession.instance.role == AccountRole.doctor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Doctors cannot request appointments.')),
        );
      });
      return;
    }
    _fetchDoctors();
  }

  @override
  void dispose() {
    _symptomController.dispose();
    super.dispose();
  }

  Future<void> _fetchDoctors() async {
    try {
      final response = await Supabase.instance.client
          .from('doctors')
          .select()
          .eq('verification_status', 'Approved')
          .eq('is_active', true);

      final List<dynamic> list = response as List<dynamic>;

      setState(() {
        _doctors = list;
        _loadingDoctors = false;
        if (widget.preselectedDoctor != null) {
          final found = _doctors.where(
            (d) => d['id'] == widget.preselectedDoctor['id'],
          );
          if (found.isNotEmpty) {
            _selectedDoctor = found.first;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingDoctors = false);
      _showSnackBar('Failed to load doctors list.');
    }
  }

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
    if (_selectedDoctor == null) return [];
    final days = _selectedDoctor['available_days'];
    if (days is List) {
      return days.map((e) => _normalizeDay(e.toString())).toList();
    }
    return [];
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

  Future<void> _pickDate() async {
    if (_selectedDoctor == null) {
      _showSnackBar('Please select a doctor first.');
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
      _showSnackBar('This doctor has no visiting days available.');
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 60)),
      selectableDayPredicate: (date) => _isDayAvailable(date),
    );

    if (picked != null && mounted) {
      final dateStr =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      try {
        final settings = await Supabase.instance.client
            .from('doctor_daily_settings')
            .select('is_locked, daily_limit')
            .eq('doctor_id', _selectedDoctor['id'])
            .eq('date', dateStr)
            .maybeSingle();

        if (settings?['is_locked'] == true) {
          if (mounted) {
            _showSnackBar(
                'This day has been reserved for rescheduled appointments. No new patient bookings can be accepted.');
          }
          return;
        }
      } catch (_) {}

      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _openDoctorSearchModal() async {
    final selected = await showModalBottomSheet<dynamic>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _DoctorSearchModal(doctors: _doctors);
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedDoctor = selected;
        _selectedDate = null;
      });
    }
  }

  Future<void> _submitAppointment() async {
    if (AppSession.instance.role == AccountRole.doctor) {
      _showSnackBar('Doctors cannot request appointments.');
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    if (_selectedDoctor == null) {
      _showSnackBar('Please select a doctor.');
      return;
    }

    if (_selectedDate == null) {
      _showSnackBar('Please choose a date for your appointment.');
      return;
    }

    if (_symptomController.text.trim().isEmpty) {
      _showSnackBar('Please select your initial symptoms.');
      return;
    }

    final session = AppSession.instance;

    setState(() => _submitting = true);
    try {
      final patientResp = await Supabase.instance.client
          .from('patients')
          .select('id')
          .eq('user_id', session.userId)
          .single();

      final patientId = patientResp['id'];
      final doctorId = _selectedDoctor['id'];

      final dateStr =
          '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}';

      // Check daily limit constraint and locked status
      final settingsResp = await Supabase.instance.client
          .from('doctor_daily_settings')
          .select('daily_limit, is_locked')
          .eq('doctor_id', doctorId)
          .eq('date', dateStr)
          .maybeSingle();

      if (settingsResp?['is_locked'] == true) {
        if (!mounted) return;
        _showSnackBar(
            'This date is reserved for transferred appointments. New bookings are closed.');
        setState(() => _submitting = false);
        return;
      }

      final dailyLimit = (settingsResp?['daily_limit'] as int?) ?? 50;

      {
        final countResp = await Supabase.instance.client
            .from('appointments')
            .select('id')
            .eq('doctor_id', doctorId)
            .eq('preferred_date', dateStr)
            .neq('status', 'Cancelled')
            .neq('status', 'Rejected');

        final currentCount = (countResp as List).length;

        if (currentCount >= dailyLimit) {
          if (!mounted) return;
          _showSnackBar(
              'Appointment limit ($dailyLimit) reached for this date. Please select another date.');
          setState(() => _submitting = false);
          return;
        }
      }

      final arrivalDateTime = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
      );

      final symptomText = _symptomController.text.trim();
      // Live model on Render (falls back to the offline model if unreachable).
      final predictedMins = await MLApiService.predictMinutes(
        symptomText: symptomText,
        patientAge: MLApiService.ageFromDob(session.profile?['date_of_birth']),
      );

      await Supabase.instance.client.from('appointments').insert({
        'doctor_id': doctorId,
        'patient_id': patientId,
        'initial_symptom': symptomText,
        'predicted_duration_minutes': predictedMins,
        'preferred_date': dateStr,
        'arrival_time': arrivalDateTime.toIso8601String(),
        'status': 'Scheduled',
      });

      if (!mounted) return;
      _showSnackBar('Appointment requested successfully!');
      Navigator.pop(context);
    } on PostgrestException catch (e) {
      if (mounted) _showSnackBar('Booking failed: ${e.message}');
    } catch (e) {
      if (mounted) _showSnackBar('Error creating appointment. Try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSnackBar(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Book Appointment')),
      body: _loadingDoctors
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Request Appointment',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.dark,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Select a doctor and specify your symptoms.',
                      style: TextStyle(color: AppTheme.green),
                    ),
                    const SizedBox(height: 20),

                    // Doctor Selector Button
                    InkWell(
                      onTap: _openDoctorSearchModal,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 16),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.person_search_outlined,
                                color: AppTheme.green),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _selectedDoctor == null
                                    ? 'Search & Select Doctor *'
                                    : 'Dr. ${_selectedDoctor['full_name']} (${_selectedDoctor['specialization']})',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: _selectedDoctor == null
                                      ? Colors.grey.shade700
                                      : AppTheme.dark,
                                  fontWeight: _selectedDoctor == null
                                      ? FontWeight.normal
                                      : FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    if (_selectedDoctor != null) ...[
                      Card(
                        color: AppTheme.pale,
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Hospital: ${_selectedDoctor['hospital_clinic_name'] ?? 'N/A'}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                  'Fee: BDT ${_selectedDoctor['consultation_fee'] ?? '0.00'}'),
                              Text(
                                  'Available Days: ${_getAvailableDays().join(", ")}'),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Date Selection Tile
                    ListTile(
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      leading: const Icon(Icons.calendar_today_outlined,
                          color: AppTheme.green),
                      title: Text(
                        _selectedDate == null
                            ? 'Select Appointment Date *'
                            : 'Date: ${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')} (${_getDayName(_selectedDate!.weekday)})',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _pickDate,
                    ),
                    const SizedBox(height: 16),

                    // Initial Symptoms Field with ML trained options and search
                    SymptomPickerField(
                      controller: _symptomController,
                    ),
                    const SizedBox(height: 24),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.green,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        onPressed: _submitting ? null : _submitAppointment,
                        child: Text(
                          _submitting ? 'Submitting...' : 'Request Appointment',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _DoctorSearchModal extends StatefulWidget {
  final List<dynamic> doctors;

  const _DoctorSearchModal({required this.doctors});

  @override
  State<_DoctorSearchModal> createState() => _DoctorSearchModalState();
}

class _DoctorSearchModalState extends State<_DoctorSearchModal> {
  final _searchController = TextEditingController();
  List<dynamic> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.doctors;
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = widget.doctors;
      } else {
        _filtered = widget.doctors.where((doc) {
          final name = (doc['full_name'] ?? '').toString().toLowerCase();
          final spec = (doc['specialization'] ?? '').toString().toLowerCase();
          final clinic =
              (doc['hospital_clinic_name'] ?? '').toString().toLowerCase();
          return name.contains(q) || spec.contains(q) || clinic.contains(q);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          TextField(
            controller: _searchController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search by doctor, specialty, or clinic...',
              prefixIcon: const Icon(Icons.search, color: AppTheme.green),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _filtered.isEmpty
                ? const Center(
                    child: Text('No doctors match your search query.'),
                  )
                : ListView.builder(
                    itemCount: _filtered.length,
                    itemBuilder: (ctx, index) {
                      final doc = _filtered[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppTheme.pale,
                          child:
                              const Icon(Icons.person, color: AppTheme.green),
                        ),
                        title: Text('Dr. ${doc['full_name']}'),
                        subtitle: Text(
                            '${doc['specialization']} • ${doc['hospital_clinic_name'] ?? ''}'),
                        onTap: () => Navigator.pop(context, doc),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
