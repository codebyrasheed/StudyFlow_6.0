import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

// ───────────────────────── helpers ─────────────────────────
const kExam = Color(0xFFFF6B8A);
const kAssign = Color(0xFF5CB8FF);
const kHabit = Color(0xFF4ADE80);
const kAccent = Color(0xFF8B5CF6);

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();
Color typeColor(String t) => t == 'Exam' ? kExam : kAssign;
bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color onSurf(BuildContext c) => Theme.of(c).colorScheme.onSurface;

String rel(DateTime d) {
  final diff = dateOnly(d).difference(dateOnly(DateTime.now())).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 0) return 'in $diff days';
  return '${-diff} days ago';
}

int streak(Habit h) {
  var d = DateTime.now();
  if (!h.days.contains(dayKey(d))) d = d.subtract(const Duration(days: 1));
  var n = 0;
  while (h.days.contains(dayKey(d))) {
    n++;
    d = d.subtract(const Duration(days: 1));
  }
  return n;
}

// ───────────────────────── models ─────────────────────────
class Assignment {
  String id, title, subject, type;
  DateTime date;
  bool done;
  Assignment({
    required this.id,
    required this.title,
    required this.subject,
    required this.type,
    required this.date,
    this.done = false,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'type': type,
        'date': date.millisecondsSinceEpoch,
        'done': done,
      };
  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'],
        title: j['title'],
        subject: j['subject'] ?? '',
        type: j['type'] ?? 'Assignment',
        date: DateTime.fromMillisecondsSinceEpoch(j['date']),
        done: j['done'] ?? false,
      );
}

class Habit {
  String id, name, emoji;
  List<String> days;
  Habit({required this.id, required this.name, required this.emoji, List<String>? days})
      : days = days ?? [];
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'emoji': emoji, 'days': days};
  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'],
        name: j['name'],
        emoji: j['emoji'] ?? '✨',
        days: List<String>.from(j['days'] ?? []),
      );
}

// ───────────────────────── store ─────────────────────────
class Store extends ChangeNotifier {
  List<Assignment> assignments = [];
  List<Habit> habits = [];
  ThemeMode mode = ThemeMode.dark;
  Map<String, String> attendance = {};
  int thGreen = 85, thYellow = 75;
  List<Notif> inbox = [];
  List<Notif> plan = [];
  Map<String, bool> nOn = {'habit': true, 'assignment': true, 'exam': true, 'attendance': true};
  Map<String, int> nTime = {'habit': 1200, 'assignment': 540, 'exam': 480, 'attendance': 510};
  bool permAsked = false;
  SharedPreferences? _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    try {
      final a = _p!.getString('assignments');
      final h = _p!.getString('habits');
      if (a != null) {
        assignments = (jsonDecode(a) as List)
            .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      if (h != null) {
        habits = (jsonDecode(h) as List)
            .map((e) => Habit.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      mode = _p!.getString('mode') == 'light' ? ThemeMode.light : ThemeMode.dark;
      final att = _p!.getString('attendance');
      if (att != null) {
        attendance = Map<String, String>.from(jsonDecode(att) as Map);
      }
      thGreen = _p!.getInt('thGreen') ?? 85;
      thYellow = _p!.getInt('thYellow') ?? 75;
      final ib = _p!.getString('inbox');
      if (ib != null) {
        inbox = (jsonDecode(ib) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final pl = _p!.getString('plan');
      if (pl != null) {
        plan = (jsonDecode(pl) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final no = _p!.getString('nOn');
      if (no != null) nOn = {...nOn, ...Map<String, bool>.from(jsonDecode(no) as Map)};
      final nt = _p!.getString('nTime');
      if (nt != null) nTime = {...nTime, ...Map<String, int>.from(jsonDecode(nt) as Map)};
      permAsked = _p!.getBool('permAsked') ?? false;
    } catch (_) {}
  }

  void _save() {
    _p?.setString('assignments', jsonEncode(assignments.map((e) => e.toJson()).toList()));
    _p?.setString('habits', jsonEncode(habits.map((e) => e.toJson()).toList()));
    _p?.setString('mode', mode == ThemeMode.light ? 'light' : 'dark');
    _p?.setString('attendance', jsonEncode(attendance));
    _p?.setInt('thGreen', thGreen);
    _p?.setInt('thYellow', thYellow);
    _p?.setString('nOn', jsonEncode(nOn));
    _p?.setString('nTime', jsonEncode(nTime));
    notifyListeners();
    notifier.requestSync();
  }

  List<Assignment> get sorted =>
      [...assignments]..sort((a, b) => a.date.compareTo(b.date));

  List<Assignment> get upcoming {
    final t = dateOnly(DateTime.now());
    return sorted.where((a) => !a.done && !dateOnly(a.date).isBefore(t)).toList();
  }

  void setAttendance(DateTime d, String? status) {
    final k = dayKey(d);
    if (status == null) {
      attendance.remove(k);
    } else {
      attendance[k] = status;
    }
    _save();
  }

  void setThresholds(int green, int yellow) {
    thGreen = green;
    thYellow = yellow;
    _save();
  }

  int get unread => inbox.where((n) => !n.read).length;

  /// Persists the notification inbox and plan without triggering a re-sync.
  void saveNotifs() {
    _p?.setString('inbox', jsonEncode(inbox.map((e) => e.toJson()).toList()));
    _p?.setString('plan', jsonEncode(plan.map((e) => e.toJson()).toList()));
    _p?.setBool('permAsked', permAsked);
    notifyListeners();
  }

  void markRead(String key) {
    for (final n in inbox) {
      if (n.key == key) n.read = true;
    }
    saveNotifs();
  }

  void markAllRead() {
    for (final n in inbox) {
      n.read = true;
    }
    saveNotifs();
  }

  void deleteNotif(String key) {
    inbox.removeWhere((n) => n.key == key);
    saveNotifs();
  }

  void setNotifOn(String cat, bool v) {
    nOn[cat] = v;
    _save();
  }

  void setNotifTime(String cat, int minutes) {
    nTime[cat] = minutes;
    _save();
  }

  void toggleMode() {
    mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    _save();
  }

  void addAssignment(Assignment a) {
    assignments.add(a);
    _save();
  }

  void updateAssignment(Assignment a) => _save();

  void deleteAssignment(String id) {
    assignments.removeWhere((a) => a.id == id);
    _save();
  }

  void addHabit(Habit h) {
    habits.add(h);
    _save();
  }

  void deleteHabit(String id) {
    habits.removeWhere((h) => h.id == id);
    _save();
  }

  void toggleHabit(Habit h, DateTime day) {
    final k = dayKey(day);
    if (h.days.contains(k)) {
      h.days.remove(k);
    } else {
      h.days.add(k);
    }
    _save();
  }
}

final store = Store();

// ───────────────────────── app ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const StudyFlowApp());
  WidgetsBinding.instance.addObserver(_LifecycleSync());
  notifier.init();
}

class _LifecycleSync with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      notifier.refreshPermission().then((_) => notifier.requestSync());
    }
  }
}

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: ColorScheme.fromSeed(seedColor: kAccent, brightness: b),
      dialogBackgroundColor: b == Brightness.dark ? const Color(0xFF1B1636) : Colors.white,
    );

class StudyFlowApp extends StatelessWidget {
  const StudyFlowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => MaterialApp(
        navigatorKey: navKey,
        title: 'StudyFlow',
        debugShowCheckedModeBanner: false,
        themeMode: store.mode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

// ───────────────────────── glass widgets ─────────────────────────
class Glass extends StatefulWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final double? opacity;
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.onTap,
    this.opacity,
  });

  @override
  State<Glass> createState() => _GlassState();
}

class _GlassState extends State<Glass> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    final o = widget.opacity ?? (d ? 0.10 : 0.65);
    final r = BorderRadius.circular(widget.radius);
    final box = RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: widget.padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withOpacity(o), Colors.white.withOpacity(o * 0.45)],
              ),
              borderRadius: r,
              border: Border.all(color: Colors.white.withOpacity(d ? 0.16 : 0.85)),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
    if (widget.onTap == null) return box;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: box,
      ),
    );
  }
}

class Orb extends StatelessWidget {
  final Color color;
  final double size;
  const Orb(this.color, this.size, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withOpacity(0)]),
        ),
      );
}

class Background extends StatelessWidget {
  const Background({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    return Stack(fit: StackFit.expand, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: d
                ? const [Color(0xFF0A0A18), Color(0xFF15102E), Color(0xFF0B1426)]
                : const [Color(0xFFEDE9FE), Color(0xFFE0ECFF), Color(0xFFFCE7F3)],
          ),
        ),
      ),
      Positioned(top: -90, left: -80, child: Orb(kAccent.withOpacity(d ? 0.55 : 0.40), 320)),
      Positioned(top: 260, right: -140, child: Orb(const Color(0xFF22D3EE).withOpacity(d ? 0.35 : 0.30), 360)),
      Positioned(bottom: -120, left: -60, child: Orb(const Color(0xFFEC4899).withOpacity(d ? 0.35 : 0.28), 340)),
    ]);
  }
}

class GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  const GlassIconBtn(this.icon, this.onTap, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Glass(
        radius: 16,
        padding: const EdgeInsets.all(11),
        onTap: onTap,
        child: Icon(icon, size: 22, color: color ?? onSurf(context)),
      );
}

class PageHeader extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const PageHeader({super.key, required this.title, required this.subtitle, this.action});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        if (action != null) ...[action!, const SizedBox(width: 8)],
        const NotificationBell(),
        const SizedBox(width: 8),
        GlassIconBtn(
          isDark(context) ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          store.toggleMode,
        ),
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 20, 12),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: onSurf(context))),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

class EmptyCard extends StatelessWidget {
  final String emoji, text;
  const EmptyCard(this.emoji, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Glass(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: SizedBox(
            width: double.infinity,
            child: Column(children: [
              Text(emoji, style: const TextStyle(fontSize: 34)),
              const SizedBox(height: 8),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: onSurf(context).withOpacity(0.65))),
            ]),
          ),
        ),
      );
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );
}

Future<bool> confirmDelete(BuildContext c, String what) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (x) => AlertDialog(
      title: const Text('Delete?'),
      content: Text('Delete "$what"? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(x, true), child: const Text('Delete')),
      ],
    ),
  );
  return r ?? false;
}

InputDecoration deco(BuildContext c, String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: onSurf(c).withOpacity(0.07),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );

// ───────────────────────── shell ─────────────────────────
final navIndex = ValueNotifier<int>(0);

class Shell extends StatelessWidget {
  const Shell({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    const pages = [DashboardPage(), AssignmentsPage(), CalendarPage(), AttendancePage()];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Stack(children: [
        const Positioned.fill(child: Background()),
        Scaffold(
          extendBody: true,
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ValueListenableBuilder<int>(
              valueListenable: navIndex,
              builder: (c, idx, _) => AnimatedPage(index: idx, pages: pages),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ValueListenableBuilder<int>(
                valueListenable: navIndex,
                builder: (c, idx, _) =>
                    NavBar(idx: idx, onTap: (i) => navIndex.value = i),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class NavBar extends StatelessWidget {
  final int idx;
  final ValueChanged<int> onTap;
  const NavBar({super.key, required this.idx, required this.onTap});
  @override
  Widget build(BuildContext context) {
    const icons = [
      Icons.dashboard_rounded,
      Icons.assignment_rounded,
      Icons.calendar_month_rounded,
      Icons.how_to_reg_rounded,
    ];
    const labels = ['Dashboard', 'Assignments', 'Calendar', 'Attendance'];
    final on = onSurf(context);
    return Glass(
      radius: 28,
      padding: const EdgeInsets.all(6),
      opacity: isDark(context) ? 0.12 : 0.75,
      child: Row(
        children: List.generate(4, (i) {
          final sel = i == idx;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: sel ? kAccent.withOpacity(0.28) : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedScale(
                    scale: sel ? 1.15 : 1,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutBack,
                    child: Icon(icons[i], color: sel ? kAccent : on.withOpacity(0.55)),
                  ),
                  const SizedBox(height: 2),
                  Text(labels[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? kAccent : on.withOpacity(0.55),
                      )),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ───────────────────────── dashboard ─────────────────────────
class StatCard extends StatelessWidget {
  final String value, label;
  final Color color;
  const StatCard(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Glass(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        child: SizedBox(
          width: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ]),
        ),
      );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = DateTime.now();
        final k = dayKey(today);
        final done = store.habits.where((h) => h.days.contains(k)).length;
        final up = store.upcoming;
        final exams = up.where((a) => a.type == 'Exam').length;
        return RevealList(
          page: 'dash',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Dashboard',
              subtitle: DateFormat('EEEE, d MMMM').format(today),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: StatCard('$done/${store.habits.length}', 'Habits today', kHabit)),
                const SizedBox(width: 10),
                Expanded(child: StatCard('$exams', 'Upcoming exams', kExam)),
                const SizedBox(width: 10),
                Expanded(child: StatCard('${up.length - exams}', 'Assignments due', kAssign)),
              ]),
            ),
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: AttendanceSummary(),
            ),
            const SizedBox(height: 6),
            SectionTitle(
              'My Habits',
              trailing: GlassIconBtn(Icons.add_rounded, () => showHabitSheet(c)),
            ),
            if (store.habits.isEmpty)
              const EmptyCard('🌱', 'No habits yet.\nTap + to start tracking one.')
            else
              ...store.habits.map((h) => HabitTile(key: ValueKey('hab_${h.id}'), h: h)),
            const SectionTitle('Coming up'),
            if (up.isEmpty)
              const EmptyCard('🎉', 'Nothing due. Enjoy the free time!')
            else
              ...up.take(3).map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
          ],
        );
      },
    );
  }
}

class HabitTile extends StatelessWidget {
  final Habit h;
  const HabitTile({super.key, required this.h});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final today = DateTime.now();
    final done = h.days.contains(dayKey(today));
    final s = streak(h);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(
            width: 50,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kHabit.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(h.emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
              const SizedBox(height: 3),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...prev, if (cur != null) cur],
                ),
                child: Text(s > 0 ? '🔥 $s day streak' : 'Start your streak today',
                    key: ValueKey(s),
                    style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
              ),
              const SizedBox(height: 8),
              Row(
                children: List.generate(7, (i) {
                  final d = today.subtract(Duration(days: 6 - i));
                  final onDay = h.days.contains(dayKey(d));
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: onDay ? kHabit : on.withOpacity(0.15),
                    ),
                  );
                }),
              ),
            ]),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline_rounded, color: on.withOpacity(0.55)),
            onPressed: () async {
              if (await confirmDelete(context, h.name)) store.deleteHabit(h.id);
            },
          ),
          GestureDetector(
            onTap: () => store.toggleHabit(h, today),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? kHabit : Colors.transparent,
                border: Border.all(color: done ? kHabit : on.withOpacity(0.35), width: 2),
              ),
              child: AnimatedScale(
                scale: done ? 1 : 0.3,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: AnimatedOpacity(
                  opacity: done ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: const Icon(Icons.check_rounded, size: 22, color: Colors.white),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

Future<void> showHabitSheet(BuildContext context) {
  final name = TextEditingController();
  String emoji = '💧';
  const options = ['💧', '📚', '🏃', '🧘', '💪', '🥗', '😴', '✍️', '🎧', '🧹', '💻', '🙏'];
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('New habit',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: onSurf(ctx))),
            const SizedBox(height: 16),
            TextField(controller: name, decoration: deco(ctx, 'Habit name (e.g. Drink water)')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: options.map((e) {
                final sel = e == emoji;
                return GestureDetector(
                  onTap: () => set(() => emoji = e),
                  child: Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? kAccent.withOpacity(0.3) : onSurf(ctx).withOpacity(0.07),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: sel ? kAccent : Colors.transparent, width: 2),
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kAccent,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: () {
                  if (name.text.trim().isEmpty) return;
                  store.addHabit(Habit(id: newId(), name: name.text.trim(), emoji: emoji));
                  Navigator.pop(ctx);
                },
                child: const Text('Add habit', style: TextStyle(fontSize: 16)),
              ),
            ),
          ]),
        ),
      );
    }),
  );
}

// ───────────────────────── assignments ─────────────────────────
class AssignmentTile extends StatelessWidget {
  final Assignment a;
  const AssignmentTile({super.key, required this.a});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final c = typeColor(a.type);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        onTap: () => showAssignmentSheet(context, a: a),
        child: Row(children: [
          Container(
            width: 54,
            height: 58,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(DateFormat('d').format(a.date),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c)),
              Text(DateFormat('MMM').format(a.date).toUpperCase(),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: on.withOpacity(a.done ? 0.5 : 1),
                  decoration: a.done ? TextDecoration.lineThrough : null,
                ),
                child: Text(a.title),
              ),
              if (a.subject.isNotEmpty)
                Text(a.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(height: 6),
              Row(children: [
                Pill(a.type, c),
                const SizedBox(width: 8),
                Text(rel(a.date), style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
              ]),
            ]),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  a.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(a.done),
                  color: a.done ? kHabit : on.withOpacity(0.5),
                ),
              ),
              onPressed: () {
                a.done = !a.done;
                store.updateAssignment(a);
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline_rounded, color: on.withOpacity(0.55)),
              onPressed: () async {
                if (await confirmDelete(context, a.title)) store.deleteAssignment(a.id);
              },
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<void> showAssignmentSheet(BuildContext context, {Assignment? a, DateTime? date}) {
  final title = TextEditingController(text: a?.title ?? '');
  final subject = TextEditingController(text: a?.subject ?? '');
  String type = a?.type ?? 'Assignment';
  DateTime d = a?.date ?? date ?? DateTime.now();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a == null ? 'New entry' : 'Edit entry',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: onSurf(ctx))),
              const SizedBox(height: 16),
              TextField(controller: title, decoration: deco(ctx, 'Title (e.g. Maths Final)')),
              const SizedBox(height: 12),
              TextField(controller: subject, decoration: deco(ctx, 'Subject (optional)')),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Assignment', label: Text('Assignment'), icon: Icon(Icons.edit_note_rounded)),
                    ButtonSegment(value: 'Exam', label: Text('Exam'), icon: Icon(Icons.school_rounded)),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => set(() => type = s.first),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.event_rounded),
                  label: Text(DateFormat('EEE, d MMM yyyy').format(d)),
                  onPressed: () async {
                    final p = await showDatePicker(
                      context: ctx,
                      initialDate: d,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (p != null) set(() => d = p);
                  },
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: () {
                    if (title.text.trim().isEmpty) return;
                    if (a == null) {
                      store.addAssignment(Assignment(
                        id: newId(),
                        title: title.text.trim(),
                        subject: subject.text.trim(),
                        type: type,
                        date: d,
                      ));
                    } else {
                      a.title = title.text.trim();
                      a.subject = subject.text.trim();
                      a.type = type;
                      a.date = d;
                      store.updateAssignment(a);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(a == null ? 'Add' : 'Save changes', style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class AssignmentsPage extends StatefulWidget {
  const AssignmentsPage({super.key});
  @override
  State<AssignmentsPage> createState() => _AssignmentsPageState();
}

class _AssignmentsPageState extends State<AssignmentsPage> {
  String filter = 'All';
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = dateOnly(DateTime.now());
        final all = store.sorted.where((a) => filter == 'All' || a.type == filter).toList();
        final overdue = all.where((a) => !a.done && dateOnly(a.date).isBefore(today)).toList();
        final upcoming = all.where((a) => !a.done && !dateOnly(a.date).isBefore(today)).toList();
        final done = all.where((a) => a.done).toList();
        return RevealList(
          page: 'asg',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Assignments',
              subtitle: 'Exams & deadlines by date',
              action: GlassIconBtn(Icons.add_rounded, () => showAssignmentSheet(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Wrap(
                spacing: 8,
                children: ['All', 'Exam', 'Assignment'].map((f) {
                  return ChoiceChip(
                    label: Text(f == 'All' ? 'All' : '${f}s'),
                    selected: filter == f,
                    selectedColor: kAccent.withOpacity(0.35),
                    onSelected: (_) => setState(() => filter = f),
                  );
                }).toList(),
              ),
            ),
            if (all.isEmpty) const EmptyCard('📚', 'Nothing here yet.\nTap + to add an exam or assignment.'),
            if (overdue.isNotEmpty) ...[
              const SectionTitle('Overdue'),
              ...overdue.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
            if (upcoming.isNotEmpty) ...[
              const SectionTitle('Upcoming'),
              ...upcoming.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
            if (done.isNotEmpty) ...[
              const SectionTitle('Completed'),
              ...done.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ],
          ],
        );
      },
    );
  }
}

// ───────────────────────── calendar ─────────────────────────
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focused = DateTime.now();
  DateTime selected = DateTime.now();

  Widget legend(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12.5, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final dayAssign = store.sorted.where((a) => sameDay(a.date, selected)).toList();
        final dayHabits = store.habits.where((h) => h.days.contains(dayKey(selected))).toList();
        return RevealList(
          page: 'cal',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            const PageHeader(title: 'Calendar', subtitle: 'Exams, assignments & habits'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                child: TableCalendar<Object>(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2100, 12, 31),
                  focusedDay: focused,
                  rowHeight: 48,
                  pageAnimationDuration: const Duration(milliseconds: 300),
                  pageAnimationCurve: Curves.easeInOutCubic,
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  selectedDayPredicate: (d) => isSameDay(selected, d),
                  onDaySelected: (s, f) => setState(() {
                    selected = s;
                    focused = f;
                  }),
                  onPageChanged: (f) => focused = f,
                  eventLoader: (day) => <Object>[
                    ...store.assignments.where((a) => sameDay(a.date, day)),
                    ...store.habits.where((h) => h.days.contains(dayKey(day))),
                  ],
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(color: on, fontSize: 17, fontWeight: FontWeight.w700),
                    leftChevronIcon: Icon(Icons.chevron_left_rounded, color: on),
                    rightChevronIcon: Icon(Icons.chevron_right_rounded, color: on),
                  ),
                  daysOfWeekStyle: DaysOfWeekStyle(
                    weekdayStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                    weekendStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                  ),
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    defaultTextStyle: TextStyle(color: on),
                    weekendTextStyle: TextStyle(color: on.withOpacity(0.85)),
                    todayTextStyle: TextStyle(color: on, fontWeight: FontWeight.w700),
                    todayDecoration: BoxDecoration(
                      color: kAccent.withOpacity(0.35),
                      shape: BoxShape.circle,
                    ),
                    selectedTextStyle:
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    selectedDecoration:
                        const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                  ),
                  calendarBuilders: CalendarBuilders<Object>(
                    markerBuilder: (ctx, day, events) {
                      if (events.isEmpty) return null;
                      final exam = events.any((e) => e is Assignment && e.type == 'Exam');
                      final asg = events.any((e) => e is Assignment && e.type != 'Exam');
                      final hab = events.any((e) => e is Habit);
                      Widget dot(Color col) => Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(color: col, shape: BoxShape.circle),
                          );
                      return Positioned(
                        bottom: 4,
                        child: PopIn(child: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (exam) dot(kExam),
                          if (asg) dot(kAssign),
                          if (hab) dot(kHabit),
                        ])),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 20, 0),
              child: Wrap(spacing: 18, children: [
                legend('Exam', kExam),
                legend('Assignment', kAssign),
                legend('Habit done', kHabit),
              ]),
            ),
            const SizedBox(height: 6),
            SectionTitle(
              DateFormat('EEEE, d MMM').format(selected),
              trailing: GlassIconBtn(Icons.add_rounded, () => showAssignmentSheet(c, date: selected)),
            ),
            if (dayAssign.isEmpty && dayHabits.isEmpty)
              const EmptyCard('🗓️', 'Nothing scheduled for this day.'),
            ...dayAssign.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
            ...dayHabits.map((h) => Padding(
                  key: ValueKey('chab_${h.id}_${dayKey(selected)}'),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Text(h.emoji, style: const TextStyle(fontSize: 24)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(h.name,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                      ),
                      const Pill('Completed', kHabit),
                    ]),
                  ),
                )),
          ],
        );
      },
    );
  }
}


// ───────────────────────── attendance ─────────────────────────
const kPresent = Color(0xFF4ADE80);
const kSelfLeave = Color(0xFFFF6B8A);
const kHoliday = Color(0xFF9CA3AF);
const kWarn = Color(0xFFFACC15);
const kBad = Color(0xFFF87171);

bool isWeekend(DateTime d) => d.weekday >= 6;
DateTime prevDay(DateTime d) => DateTime(d.year, d.month, d.day - 1);
DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

Color attColor(String s) =>
    s == 'present' ? kPresent : (s == 'self' ? kSelfLeave : kHoliday);

String attLabel(String s) {
  if (s == 'present') return 'Present';
  if (s == 'self') return 'Self leave';
  if (s == 'public') return 'Public holiday';
  return 'College holiday';
}

IconData attIcon(String? s) {
  if (s == 'present') return Icons.check_circle_rounded;
  if (s == 'self') return Icons.person_off_rounded;
  if (s == null) return Icons.help_outline_rounded;
  return Icons.beach_access_rounded;
}

class AttStats {
  int present = 0, absent = 0, holidays = 0;
  int get working => present + absent;
  double? get pct => working == 0 ? null : present * 100 / working;
}

AttStats attStats({int? year, int? month}) {
  final st = AttStats();
  store.attendance.forEach((k, v) {
    final d = DateTime.parse(k);
    if (year != null && (d.year != year || d.month != month)) return;
    if (v == 'present') {
      st.present++;
    } else if (v == 'self') {
      st.absent++;
    } else {
      st.holidays++;
    }
  });
  return st;
}

Color pctColor(double? p) {
  if (p == null) return kHoliday;
  if (p >= store.thGreen) return kPresent;
  if (p >= store.thYellow) return kWarn;
  return kBad;
}

String pctLabel(double? p) {
  if (p == null) return 'No data yet';
  if (p >= store.thGreen) return 'On track';
  if (p >= store.thYellow) return 'Needs attention';
  return 'Low attendance';
}

/// Returns [current, longest] streak of attended days.
/// Weekends and holidays are skipped. Self leave and unrecorded weekdays break a streak.
List<int> attStreaks() {
  final a = store.attendance;
  if (a.isEmpty) return [0, 0];
  final today = dateOnly(DateTime.now());
  final first = a.keys.map(DateTime.parse).reduce((x, y) => x.isBefore(y) ? x : y);

  var cur = 0;
  var d = today;
  while (!d.isBefore(first)) {
    final v = a[dayKey(d)];
    if (v == 'present') {
      cur++;
    } else if (v == 'public' || v == 'college') {
    } else if (v == null && (isWeekend(d) || sameDay(d, today))) {
    } else {
      break;
    }
    d = prevDay(d);
  }

  var run = 0, best = 0;
  for (var x = first; !x.isAfter(today); x = nextDay(x)) {
    final v = a[dayKey(x)];
    if (v == 'present') {
      run++;
      if (run > best) best = run;
    } else if (v == 'public' || v == 'college') {
    } else if (v == null && (isWeekend(x) || sameDay(x, today))) {
    } else {
      run = 0;
    }
  }
  return [cur, best];
}

/// Present days divided by elapsed weekdays (holidays excluded). Unrecorded weekdays count against it.
double? attConsistency(int year, int month) {
  final today = dateOnly(DateTime.now());
  final dim = DateUtils.getDaysInMonth(year, month);
  var den = 0, att = 0;
  for (var i = 1; i <= dim; i++) {
    final d = DateTime(year, month, i);
    if (d.isAfter(today)) break;
    final v = store.attendance[dayKey(d)];
    if (sameDay(d, today) && v == null) continue;
    if (v == 'present') att++;
    if (!isWeekend(d) && v != 'public' && v != 'college') den++;
  }
  if (den == 0) return null;
  return (att * 100 / den).clamp(0, 100).toDouble();
}

Future<void> showAttendanceSheet(BuildContext context, DateTime day,
    {bool startAtReason = false}) {
  final isToday = sameDay(day, DateTime.now());
  var step = startAtReason ? 1 : 0;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);
      final cur = store.attendance[dayKey(day)];
      void save(String? v) {
        store.setAttendance(day, v);
        Navigator.pop(ctx);
      }

      Widget reason(IconData icon, String t, String sub, String code, Color col) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              radius: 18,
              padding: const EdgeInsets.all(14),
              onTap: () => save(code),
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: col.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: col),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                    Text(sub, style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  ]),
                ),
              ]),
            ),
          );

      final question = isToday
          ? 'Are you going to college today?'
          : 'Were you at college on ${DateFormat('EEE, d MMM').format(day)}?';

      final stepZero = Column(
        key: const ValueKey(0),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(question, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
          if (cur != null) ...[
            const SizedBox(height: 6),
            Text('Currently: ${attLabel(cur)}',
                style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
          ],
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kPresent,
                  foregroundColor: const Color(0xFF0B1F12),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: () => save('present'),
                child: const Text('Yes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                onPressed: () => set(() => step = 1),
                child: const Text('No', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          if (cur != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                onPressed: () => save(null),
                child: const Text('Clear record'),
              ),
            ),
        ],
      );

      final stepOne = Column(
        key: const ValueKey(1),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Why not?', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
          const SizedBox(height: 14),
          reason(Icons.flag_rounded, 'Public holiday', 'Excluded from working days', 'public', kHoliday),
          reason(Icons.school_rounded, 'College holiday', 'Excluded from working days', 'college', kHoliday),
          reason(Icons.person_off_rounded, 'Self leave', 'Counts as absent', 'self', kSelfLeave),
          TextButton(
            onPressed: () => set(() => step = 0),
            child: const Text('Back'),
          ),
        ],
      );

      return Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.of(ctx).viewInsets.bottom + 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: step == 0 ? stepZero : stepOne,
            ),
          ),
        ),
      );
    }),
  );
}

Future<void> showThresholdSheet(BuildContext context) {
  var g = store.thGreen;
  var y = store.thYellow;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance thresholds',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 4),
            Text('Choose where green and yellow start.',
                style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
            const SizedBox(height: 18),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kPresent),
              const SizedBox(width: 8),
              Expanded(child: Text('Green from $g%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: g.toDouble(),
              min: 51,
              max: 100,
              divisions: 49,
              label: '$g%',
              onChanged: (v) => set(() {
                g = v.round();
                if (y >= g) y = g - 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kWarn),
              const SizedBox(width: 8),
              Expanded(child: Text('Yellow from $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: y.toDouble(),
              min: 50,
              max: 99,
              divisions: 49,
              label: '$y%',
              onChanged: (v) => set(() {
                y = v.round();
                if (g <= y) g = y + 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kBad),
              const SizedBox(width: 8),
              Text('Red below $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on)),
            ]),
          ]),
        ),
      );
    }),
  );
}

class AttendanceSummary extends StatelessWidget {
  const AttendanceSummary({super.key});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final v = store.attendance[dayKey(DateTime.now())];
    final p = attStats().pct;
    final st = attStreaks();
    final col = v == null ? kAccent : attColor(v);
    return Glass(
      padding: const EdgeInsets.all(14),
      onTap: () => navIndex.value = 3,
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: col.withOpacity(0.2),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(attIcon(v), color: col),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance today',
                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
            Text(v == null ? 'Not marked yet' : attLabel(v),
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(p == null ? '–' : '${p.round()}%',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: pctColor(p))),
          Text('overall', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${st[0]}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kWarn)),
          Text('streak', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
      ]),
    );
  }
}

class MiniStat extends StatelessWidget {
  final String value, label;
  final Color color;
  const MiniStat(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: onSurf(context).withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ),
        ]),
      );
}

class Heatmap extends StatelessWidget {
  final DateTime month, selected;
  final ValueChanged<DateTime> onSelect;
  const Heatmap({super.key, required this.month, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final today = dateOnly(DateTime.now());
    final dim = DateUtils.getDaysInMonth(month.year, month.month);
    final offset = DateTime(month.year, month.month, 1).weekday - 1;
    final cols = ((offset + dim) / 7).ceil();
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return LayoutBuilder(builder: (c, box) {
      const gap = 6.0;
      const lw = 22.0;
      final cell = ((box.maxWidth - lw - cols * gap) / cols).clamp(20.0, 42.0).toDouble();
      return Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(
          children: List.generate(
            7,
            (r) => SizedBox(
              width: lw,
              height: cell + gap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(labels[r],
                    style: TextStyle(fontSize: 11, color: on.withOpacity(0.5))),
              ),
            ),
          ),
        ),
        ...List.generate(
          cols,
          (col) => Column(
            children: List.generate(7, (r) {
              final day = col * 7 + r - offset + 1;
              if (day < 1 || day > dim) {
                return SizedBox(width: cell + gap, height: cell + gap);
              }
              final date = DateTime(month.year, month.month, day);
              final v = store.attendance[dayKey(date)];
              final sel = sameDay(date, selected);
              final isToday = sameDay(date, today);
              final fill = sel
                  ? kAccent
                  : (v == null ? on.withOpacity(0.08) : attColor(v).withOpacity(0.9));
              final txt = sel
                  ? Colors.white
                  : (v == null ? on.withOpacity(0.55) : const Color(0xFF10101C));
              return SizedBox(
                width: cell + gap,
                height: cell + gap,
                child: Padding(
                  padding: const EdgeInsets.only(right: gap, bottom: gap),
                  child: GestureDetector(
                    onTap: () => onSelect(date),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      transformAlignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(sel ? 1.1 : 1.0, sel ? 1.1 : 1.0, 1.0),
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(cell * 0.28),
                        border: isToday && !sel
                            ? Border.all(color: on.withOpacity(0.7), width: 1.5)
                            : null,
                      ),
                      child: Stack(alignment: Alignment.center, children: [
                        Text('$day',
                            style: TextStyle(
                                fontSize: 11.5, fontWeight: FontWeight.w600, color: txt)),
                        if (sel && v != null)
                          Positioned(
                            bottom: 3,
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: attColor(v),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ]);
    });
  }
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime selected = dateOnly(DateTime.now());

  bool overall = false;

  void goMonth(int delta) {
    final m = DateTime(month.year, month.month + delta);
    final now = DateTime.now();
    setState(() {
      month = m;
      selected = (m.year == now.year && m.month == now.month) ? dateOnly(now) : m;
    });
  }

  Widget legendItem(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final today = dateOnly(DateTime.now());
        final todayV = store.attendance[dayKey(today)];
        final ms = attStats(year: month.year, month: month.month);
        final all = attStats();
        final shown = overall ? all : ms;
        final p = shown.pct;
        final pc = pctColor(p);
        final other = overall ? ms.pct : all.pct;
        final history = store.attendance.entries.where((e) {
          final d = DateTime.parse(e.key);
          return d.year == month.year && d.month == month.month;
        }).toList()
          ..sort((x, y) => y.key.compareTo(x.key));
        final st = attStreaks();
        final cons = attConsistency(month.year, month.month);
        final selV = store.attendance[dayKey(selected)];
        final future = selected.isAfter(today);

        return RevealList(
          page: 'att',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Attendance',
              subtitle: 'Track your college days',
              action: GlassIconBtn(Icons.tune_rounded, () => showThresholdSheet(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: todayV == null
                      ? Column(
                          key: const ValueKey('ask'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Are you going to college today?',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                            const SizedBox(height: 14),
                            Row(children: [
                              Expanded(
                                child: FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: kPresent,
                                    foregroundColor: const Color(0xFF0B1F12),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: () => store.setAttendance(today, 'present'),
                                  child: const Text('Yes',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: () =>
                                      showAttendanceSheet(c, today, startAtReason: true),
                                  child: const Text('No',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ]),
                          ],
                        )
                      : Row(key: const ValueKey('done'), children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: attColor(todayV).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(attIcon(todayV), color: attColor(todayV)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Today',
                                  style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                              Text(attLabel(todayV),
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: on)),
                            ]),
                          ),
                          TextButton(
                            onPressed: () => showAttendanceSheet(c, today),
                            child: const Text('Edit'),
                          ),
                        ]),
                ),
              ),
            ),
            SectionTitle(
              'Analytics',
              trailing: Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: Text(DateFormat('MMMM').format(month)),
                  selected: !overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = false),
                ),
                ChoiceChip(
                  label: const Text('Overall'),
                  selected: overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = true),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Column(children: [
                  Row(children: [
                    SizedBox(
                      width: 96,
                      height: 96,
                      child: Stack(alignment: Alignment.center, children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: (p ?? 0) / 100),
                          duration: const Duration(milliseconds: 800),
                          curve: Curves.easeOutCubic,
                          builder: (ctx, v, _) => SizedBox(
                            width: 96,
                            height: 96,
                            child: CircularProgressIndicator(
                              value: v,
                              strokeWidth: 9,
                              strokeCap: StrokeCap.round,
                              backgroundColor: on.withOpacity(0.1),
                              valueColor: AlwaysStoppedAnimation<Color>(pc),
                            ),
                          ),
                        ),
                        Text(p == null ? '–' : '${p.round()}%',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                      ]),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(overall ? 'All time' : DateFormat('MMMM yyyy').format(month),
                            style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                        const SizedBox(height: 4),
                        Pill(pctLabel(p), pc),
                        const SizedBox(height: 8),
                        Text(
                          other == null
                              ? (overall ? 'This month: no data' : 'Overall: no data')
                              : (overall
                                  ? 'This month: ${other.round()}%'
                                  : 'Overall: ${other.round()}%'),
                          style: TextStyle(fontSize: 13, color: on.withOpacity(0.7)),
                        ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.working}', 'Working days', kAssign)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.present}', 'Present', kPresent)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.absent}', 'Absent', kSelfLeave)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.holidays}', 'Holidays', kHoliday)),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    'Present days divided by working days. Holidays and unrecorded days are left out.',
                    style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.55)),
                  ),
                ]),
              ),
            ),
            SectionTitle('Attendance Calendar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Column(children: [
                  Row(children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left_rounded, color: on),
                      onPressed: () => goMonth(-1),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          DateFormat('MMMM yyyy').format(month),
                          key: ValueKey(month),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: on),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.chevron_right_rounded, color: on),
                      onPressed: () => goMonth(1),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: KeyedSubtree(
                      key: ValueKey(month),
                      child: Heatmap(
                        month: month,
                        selected: selected,
                        onSelect: (d) => setState(() => selected = d),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 14, runSpacing: 6, children: [
                    legendItem('Present', kPresent),
                    legendItem('Self leave', kSelfLeave),
                    legendItem('Holiday', kHoliday),
                    legendItem('Unrecorded', on.withOpacity(0.15)),
                    legendItem('Selected', kAccent),
                  ]),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: (selV == null ? kAccent : attColor(selV)).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(attIcon(selV), color: selV == null ? kAccent : attColor(selV)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(DateFormat('EEEE, d MMM').format(selected),
                          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                      Text(
                        future
                            ? 'Upcoming date'
                            : (selV == null
                                ? (isWeekend(selected) ? 'Weekend, not recorded' : 'Not recorded')
                                : attLabel(selV)),
                        style: TextStyle(fontSize: 13, color: on.withOpacity(0.6)),
                      ),
                    ]),
                  ),
                  if (!future)
                    FilledButton.tonal(
                      onPressed: () => showAttendanceSheet(c, selected),
                      child: Text(selV == null ? 'Mark' : 'Edit'),
                    ),
                ]),
              ),
            ),
            SectionTitle('Streaks & Consistency'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Row(children: [
                  Expanded(child: _streakCell(Icons.local_fire_department_rounded, '${st[0]}', 'Current', kWarn)),
                  Expanded(child: _streakCell(Icons.emoji_events_rounded, '${st[1]}', 'Longest', kAccent)),
                  Expanded(
                    child: _streakCell(Icons.insights_rounded,
                        cons == null ? '–' : '${cons.round()}%', 'Consistency', kPresent),
                  ),
                ]),
              ),
            ),
            SectionTitle(
              'History',
              trailing: Text(DateFormat('MMMM').format(month),
                  style: TextStyle(fontSize: 13, color: on.withOpacity(0.55))),
            ),
            if (history.isEmpty)
              const EmptyCard('🗓️', 'No attendance recorded this month.')
            else
              ...history.map((e) => AttendanceHistoryTile(
                    key: ValueKey('hist_${e.key}'),
                    dateKey: e.key,
                    status: e.value,
                  )),
          ],
        );
      },
    );
  }

  Widget _streakCell(IconData icon, String value, String label, Color color) {
    final on = onSurf(context);
    return Column(children: [
      Icon(icon, color: color, size: 26),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
      Text(label, style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
    ]);
  }
}


// ───────────────────────── smart notifications ─────────────────────────
const kNotifCats = ['habit', 'assignment', 'exam', 'attendance'];

final navKey = GlobalKey<NavigatorState>();
final notifier = Notifier();

String catLabel(String c) {
  if (c == 'habit') return 'Habits';
  if (c == 'assignment') return 'Assignments';
  if (c == 'exam') return 'Exams';
  return 'Attendance';
}

IconData catIcon(String c) {
  if (c == 'habit') return Icons.task_alt_rounded;
  if (c == 'assignment') return Icons.assignment_rounded;
  if (c == 'exam') return Icons.school_rounded;
  return Icons.how_to_reg_rounded;
}

Color catColor(String c) {
  if (c == 'habit') return kHabit;
  if (c == 'assignment') return kAssign;
  if (c == 'exam') return kExam;
  return kAccent;
}

int tabFor(String cat) => cat == 'habit' ? 0 : (cat == 'attendance' ? 3 : 1);

String notifTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  final time = DateFormat('h:mm a').format(t);
  if (sameDay(t, now)) return 'Today, $time';
  if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'Yesterday, $time';
  return '${DateFormat('d MMM').format(t)}, $time';
}

class Notif {
  String key, cat, title, body;
  int at;
  bool read;
  Notif({
    required this.key,
    required this.cat,
    required this.title,
    required this.body,
    required this.at,
    this.read = false,
  });
  Map<String, dynamic> toJson() =>
      {'key': key, 'cat': cat, 'title': title, 'body': body, 'at': at, 'read': read};
  factory Notif.fromJson(Map<String, dynamic> j) => Notif(
        key: j['key'],
        cat: j['cat'],
        title: j['title'],
        body: j['body'],
        at: j['at'],
        read: j['read'] ?? false,
      );
}

class Notifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);
  bool ready = false;
  bool _syncing = false, _again = false;
  Timer? _debounce, _tick;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => _open(r.payload),
      );
      final a = _android;
      for (final c in kNotifCats) {
        await a?.createNotificationChannel(AndroidNotificationChannel(
          'studyflow_$c',
          '${catLabel(c)} reminders',
          description: 'Reminders for ${catLabel(c).toLowerCase()}',
          importance: Importance.high,
        ));
      }
      ready = true;
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d != null && d.didNotificationLaunchApp) _open(d.notificationResponse?.payload);
    } catch (_) {
      return;
    }
    try {
      if (!store.permAsked) {
        await requestPermission();
        store.permAsked = true;
        store.saveNotifs();
      } else {
        await refreshPermission();
      }
    } catch (_) {}
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => deliverDue());
    await sync();
  }

  void _open(String? payload) {
    if (payload == null) return;
    navKey.currentState?.popUntil((r) => r.isFirst);
    navIndex.value = tabFor(payload);
  }

  Future<bool> requestPermission() async {
    var ok = true;
    try {
      ok = await _android?.requestNotificationsPermission() ?? true;
    } catch (_) {}
    allowed.value = ok;
    if (ok) requestSync();
    return ok;
  }

  Future<void> refreshPermission() async {
    try {
      allowed.value = await _android?.areNotificationsEnabled() ?? true;
    } catch (_) {}
  }

  void requestSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), sync);
  }

  int _id(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  NotificationDetails _details(String cat, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          'studyflow_$cat',
          '${catLabel(cat)} reminders',
          channelDescription: 'Reminders for ${catLabel(cat).toLowerCase()}',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  Future<void> sendTest() async {
    const body = 'Reminders are working. You will get them at the times you chose.';
    try {
      await _plugin.show(7, 'StudyFlow notifications are on', body, _details('habit', body));
    } catch (_) {}
  }

  /// Moves notifications whose time has passed from the plan into the inbox.
  void deliverDue() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    final keep = <Notif>[];
    for (final p in store.plan) {
      if (p.at <= now) {
        if (!store.inbox.any((n) => n.key == p.key)) {
          store.inbox.add(Notif(key: p.key, cat: p.cat, title: p.title, body: p.body, at: p.at));
        }
        changed = true;
      } else {
        keep.add(p);
      }
    }
    if (changed) {
      store.plan = keep;
      _prune();
      store.saveNotifs();
    }
  }

  /// Removes inbox items that are old or no longer relevant to the current data.
  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    store.inbox.removeWhere((n) {
      if (n.at < cutoff) return true;
      final p = n.key.split(':');
      if (p.length < 2) return false;
      if (p[0] == 'asg' || p[0] == 'exam') {
        final a = store.assignments.where((x) => x.id == p[1]);
        return a.isEmpty || a.first.done;
      }
      if (p[0] == 'att') return store.attendance.containsKey(p[1]);
      return false;
    });
    store.inbox.sort((a, b) => b.at.compareTo(a.at));
    if (store.inbox.length > 150) store.inbox = store.inbox.sublist(0, 150);
  }

  List<Notif> _build(DateTime now) {
    final out = <Notif>[];
    final today = dateOnly(now);
    DateTime at(DateTime d, int m) => DateTime(d.year, d.month, d.day, m ~/ 60, m % 60);
    void add(String key, String cat, String title, String body, DateTime when) {
      if (!when.isAfter(now)) return;
      out.add(Notif(key: key, cat: cat, title: title, body: body, at: when.millisecondsSinceEpoch));
    }

    final on = store.nOn;
    final tm = store.nTime;

    if (on['habit'] == true && store.habits.isNotEmpty) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        String body;
        if (i == 0) {
          final left = store.habits.where((h) => !h.days.contains(dayKey(day))).toList();
          if (left.isEmpty) continue;
          body = left.length == 1
              ? 'Still to do today: ${left.first.name}'
              : '${left.length} habits left today: ${left.take(3).map((h) => h.name).join(", ")}${left.length > 3 ? "..." : ""}';
        } else {
          final n = store.habits.length;
          body = 'Check in on your $n habit${n == 1 ? "" : "s"} today';
        }
        add('habit:${dayKey(day)}', 'habit', 'Habit check-in', body, at(day, tm['habit']!));
      }
    }

    if (on['attendance'] == true) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        if (isWeekend(day) || store.attendance.containsKey(dayKey(day))) continue;
        add('att:${dayKey(day)}', 'attendance', 'Are you going to college today?',
            'Tap to mark your attendance.', at(day, tm['attendance']!));
      }
    }

    final horizon = DateTime(today.year, today.month, today.day + 30);
    for (final a in store.assignments) {
      if (a.done) continue;
      final d = dateOnly(a.date);
      if (d.isBefore(today)) continue;
      final isExam = a.type == 'Exam';
      final cat = isExam ? 'exam' : 'assignment';
      if (on[cat] != true) continue;
      final offsets = isExam ? [3, 1, 0] : [1, 0];
      for (final o in offsets) {
        final day = DateTime(d.year, d.month, d.day - o);
        if (day.isAfter(horizon)) continue;
        String title;
        if (isExam) {
          title = o == 0 ? 'Exam today' : (o == 1 ? 'Exam tomorrow' : 'Exam in $o days');
        } else {
          title = o == 0 ? 'Assignment due today' : 'Assignment due tomorrow';
        }
        final sub = a.subject.isEmpty ? '' : ' · ${a.subject}';
        add('${isExam ? "exam" : "asg"}:${a.id}:$o', cat, title,
            '${a.title}$sub · ${DateFormat("EEE, d MMM").format(a.date)}', at(day, tm[cat]!));
      }
    }
    return out;
  }

  Future<void> sync() async {
    if (!ready) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      deliverDue();
      _prune();
      final now = DateTime.now();
      final desired = <String, Notif>{for (final n in _build(now)) n.key: n};
      final old = <String, Notif>{for (final p in store.plan) p.key: p};

      var exact = false;
      try {
        exact = await _android?.canScheduleExactNotifications() ?? false;
      } catch (_) {}

      var pendingIds = <int>{};
      try {
        final pending = await _plugin.pendingNotificationRequests();
        final desiredIds = desired.keys.map(_id).toSet();
        for (final p in pending) {
          if (!desiredIds.contains(p.id)) await _plugin.cancel(p.id);
        }
        pendingIds = pending.map((p) => p.id).toSet();
      } catch (_) {}

      if (allowed.value) {
        for (final n in desired.values) {
          final o = old[n.key];
          final same = o != null && o.at == n.at && o.title == n.title && o.body == n.body;
          if (same && pendingIds.contains(_id(n.key))) continue;
          try {
            final u = DateTime.fromMillisecondsSinceEpoch(n.at).toUtc();
            await _plugin.zonedSchedule(
              _id(n.key),
              n.title,
              n.body,
              tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second),
              _details(n.cat, n.body),
              androidScheduleMode: exact
                  ? AndroidScheduleMode.exactAllowWhileIdle
                  : AndroidScheduleMode.inexactAllowWhileIdle,
              payload: n.cat,
            );
          } catch (_) {}
        }
      }

      store.plan = desired.values.toList()..sort((a, b) => a.at.compareTo(b.at));
      store.saveNotifs();
    } finally {
      _syncing = false;
      if (_again) {
        _again = false;
        requestSync();
      }
    }
  }
}

// ───────────────────────── notification UI ─────────────────────────
Future<void> openScreen(BuildContext context, Widget page) {
  return Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 350),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  ));
}

Widget screenFrame(BuildContext c, Widget body) {
  final d = isDark(c);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(statusBarColor: Colors.transparent),
    child: Stack(children: [
      const Positioned.fill(child: Background()),
      Scaffold(backgroundColor: Colors.transparent, body: SafeArea(child: body)),
    ]),
  );
}

class SubHeader extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  const SubHeader({super.key, required this.title, required this.subtitle, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(context).pop()),
        const SizedBox(width: 14),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: on)),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        for (final a in actions) ...[const SizedBox(width: 10), a],
      ]),
    );
  }
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final n = store.unread;
        return Stack(clipBehavior: Clip.none, children: [
          GlassIconBtn(
            n > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
            () => openScreen(c, const NotificationCenterPage()),
          ),
          Positioned(
            top: -5,
            right: -5,
            child: AnimatedScale(
              scale: n > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Container(
                constraints: const BoxConstraints(minWidth: 19),
                height: 19,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kExam,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark(c) ? const Color(0xFF15102E) : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: Text(n > 9 ? '9+' : '$n',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});
  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  String filter = 'all';

  String _group(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (sameDay(t, now)) return 'TODAY';
    if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'YESTERDAY';
    return DateFormat('d MMMM yyyy').format(t).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          final items = store.inbox.where((n) => filter == 'all' || n.cat == filter).toList()
            ..sort((a, b) => b.at.compareTo(a.at));
          final unread = store.unread;
          final children = <Widget>[];
          String? last;
          for (var i = 0; i < items.length; i++) {
            final g = _group(items[i].at);
            if (g != last) {
              children.add(Padding(
                key: ValueKey('g_$g'),
                padding: const EdgeInsets.fromLTRB(24, 6, 20, 10),
                child: Text(g,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: on.withOpacity(0.5))),
              ));
              last = g;
            }
            children.add(NotifTile(key: ValueKey('n_${items[i].key}'), n: items[i], index: i));
          }
          return Column(children: [
            SubHeader(
              title: 'Notifications',
              subtitle: unread == 0 ? 'All caught up' : '$unread unread',
              actions: [
                GlassIconBtn(Icons.tune_rounded, () => openScreen(c, const NotificationSettingsPage())),
              ],
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: ['all', ...kNotifCats].map((f) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f == 'all' ? 'All' : catLabel(f)),
                      selected: filter == f,
                      selectedColor: kAccent.withOpacity(0.35),
                      onSelected: (_) => setState(() => filter = f),
                    ),
                  );
                }).toList(),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: unread > 0
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: store.markAllRead,
                          icon: const Icon(Icons.done_all_rounded, size: 18),
                          label: const Text('Mark all as read'),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 8),
            ),
            Expanded(
              child: items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.only(top: 20),
                      children: const [
                        EmptyCard('🔔', 'Nothing here yet.\nYour reminders will show up as they arrive.'),
                      ],
                    )
                  : RevealList(
                      page: 'nc',
                      padding: const EdgeInsets.only(bottom: 30),
                      children: children,
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class NotifTile extends StatelessWidget {
  final Notif n;
  final int index;
  const NotifTile({super.key, required this.n, required this.index});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final col = catColor(n.cat);
    final unread = !n.read;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: child),
      ),
      child: Dismissible(
        key: ValueKey(n.key),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => store.deleteNotif(n.key),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 26),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          decoration: BoxDecoration(
            color: kBad.withOpacity(0.22),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: kBad),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Glass(
            padding: const EdgeInsets.all(14),
            onTap: () {
              store.markRead(n.key);
              Navigator.of(context).pop();
              navIndex.value = tabFor(n.cat);
            },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: col.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(catIcon(n.cat), color: col),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n.title,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                          color: on.withOpacity(unread ? 1 : 0.8))),
                  const SizedBox(height: 2),
                  Text(n.body, style: TextStyle(fontSize: 13, color: on.withOpacity(0.65))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Pill(catLabel(n.cat), col),
                    const SizedBox(width: 8),
                    Text(notifTime(n.at),
                        style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: unread ? 10 : 0,
                  height: unread ? 10 : 0,
                  decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatelessWidget {
  const NotificationSettingsPage({super.key});

  static const Map<String, String> desc = {
    'habit': 'A daily nudge, skipped once all your habits are done',
    'assignment': 'The day before and on the due date',
    'exam': '3 days before, the day before and on exam day',
    'attendance': 'Weekday prompt, skipped once you have marked it',
  };

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          return RevealList(
            page: 'ns',
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              const SubHeader(title: 'Reminder settings', subtitle: 'Choose what and when'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: ValueListenableBuilder<bool>(
                  valueListenable: notifier.allowed,
                  builder: (ctx, ok, _) => Glass(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: (ok ? kPresent : kBad).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          ok ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
                          color: ok ? kPresent : kBad,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ok ? 'Notifications are on' : 'Notifications are blocked',
                              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                          Text(
                            ok
                                ? 'Reminders arrive even when the app is closed'
                                : "Allow them in your phone's Settings > Apps > StudyFlow",
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6)),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () async {
                          if (ok) {
                            await notifier.sendTest();
                          } else {
                            await notifier.requestPermission();
                          }
                        },
                        child: Text(ok ? 'Test' : 'Allow'),
                      ),
                    ]),
                  ),
                ),
              ),
              ...kNotifCats.map((cat) {
                final enabled = store.nOn[cat] == true;
                final mins = store.nTime[cat]!;
                final col = catColor(cat);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: col.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(catIcon(cat), color: col),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(catLabel(cat),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                            Text(desc[cat]!,
                                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                          ]),
                        ),
                        Switch(
                          value: enabled,
                          activeTrackColor: kAccent,
                          onChanged: (v) => store.setNotifOn(cat, v),
                        ),
                      ]),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: enabled
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () async {
                                    final t = await showTimePicker(
                                      context: c,
                                      initialTime: TimeOfDay(hour: mins ~/ 60, minute: mins % 60),
                                    );
                                    if (t != null) store.setNotifTime(cat, t.hour * 60 + t.minute);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: on.withOpacity(0.07),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Row(children: [
                                      Icon(Icons.schedule_rounded, size: 20, color: col),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text('Remind me at',
                                            style: TextStyle(color: on.withOpacity(0.7))),
                                      ),
                                      Text(
                                        TimeOfDay(hour: mins ~/ 60, minute: mins % 60).format(c),
                                        style: TextStyle(fontWeight: FontWeight.w800, color: on),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(Icons.edit_rounded, size: 16, color: on.withOpacity(0.5)),
                                    ]),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ]),
                  ),
                );
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 4, 26, 0),
                child: Text(
                  'Reminders stay in sync with your habits, assignments, exams and attendance. Completed or deleted items never send reminders.',
                  style: TextStyle(fontSize: 12, color: on.withOpacity(0.5)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


// ───────────────────────── motion system ─────────────────────────
const kRevealDuration = Duration(milliseconds: 400);
const int kStaggerMs = 70;
const double kRevealShift = 18;

class _RevealData extends InheritedWidget {
  final Set<String> seen;
  const _RevealData({required this.seen, required super.child});
  static Set<String>? of(BuildContext c) =>
      c.getInheritedWidgetOfExactType<_RevealData>()?.seen;
  @override
  bool updateShouldNotify(_RevealData old) => false;
}

/// Remembers which items were already revealed while a screen is open,
/// so scrolling back never replays an animation. A new screen visit starts fresh.
class RevealScope extends StatefulWidget {
  final Widget child;
  const RevealScope({super.key, required this.child});
  @override
  State<RevealScope> createState() => _RevealScopeState();
}

class _RevealScopeState extends State<RevealScope> {
  final Set<String> _seen = {};
  @override
  Widget build(BuildContext context) => _RevealData(seen: _seen, child: widget.child);
}

/// Fade + upward slide. Staggered when the item is on screen as the page opens,
/// and triggered individually when it scrolls into view.
class Reveal extends StatefulWidget {
  final String id;
  final int index;
  final Widget child;
  Reveal({required this.id, this.index = 0, required this.child}) : super(key: ValueKey('rv_$id'));
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  bool _shown = false;
  bool _first = true;
  Timer? _timer;
  ScrollPosition? _pos;
  Set<String>? _seen;

  @override
  void initState() {
    super.initState();
    _seen = _RevealData.of(context);
    if (_seen?.contains(widget.id) ?? false) {
      _shown = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attach();
    });
  }

  void _attach() {
    if (_shown) return;
    _pos = Scrollable.maybeOf(context)?.position;
    _pos?.addListener(_check);
    _check();
  }

  void _check() {
    if (_shown || !mounted) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    final top = ro.localToGlobal(Offset.zero).dy;
    final h = MediaQuery.sizeOf(context).height;
    if (top < h - 100) {
      _pos?.removeListener(_check);
      _seen?.add(widget.id);
      final delay = _first ? (widget.index < 8 ? widget.index : 8) * kStaggerMs : 0;
      if (delay == 0) {
        setState(() => _shown = true);
      } else {
        _timer = Timer(Duration(milliseconds: delay), () {
          if (mounted) setState(() => _shown = true);
        });
      }
    }
    _first = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pos?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown ? 1.0 : 0.0),
      duration: kRevealDuration,
      curve: Curves.easeOutCubic,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * kRevealShift), child: child),
      ),
      child: widget.child,
    );
  }
}

String _revealId(Widget w, Map<String, int> counts) {
  final k = w.key;
  if (k is ValueKey) return 'k:${k.value}';
  if (w is SectionTitle) return 'st:${w.text}';
  if (w is EmptyCard) return 'ec:${w.text}';
  final t = w.runtimeType.toString();
  final n = counts[t] ?? 0;
  counts[t] = n + 1;
  return '$t#$n';
}

/// Drop-in replacement for ListView(children: ...) that adds entrance and scroll reveals.
class RevealList extends StatelessWidget {
  final String page;
  final EdgeInsetsGeometry? padding;
  final List<Widget> children;
  const RevealList({super.key, required this.page, this.padding, required this.children});

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    return RevealScope(
      child: ListView(
        padding: padding,
        children: [
          for (var i = 0; i < children.length; i++)
            Reveal(id: '$page/${_revealId(children[i], counts)}', index: i, child: children[i]),
        ],
      ),
    );
  }
}

/// Small scale + fade pop used for calendar event markers.
class PopIn extends StatelessWidget {
  final Widget child;
  const PopIn({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (c, v, ch) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.6 + 0.4 * v, child: ch),
      ),
      child: child,
    );
  }
}

/// Tab transition: incoming screen slides in from the direction of travel,
/// the outgoing screen fades out the other way.
class AnimatedPage extends StatefulWidget {
  final int index;
  final List<Widget> pages;
  const AnimatedPage({super.key, required this.index, required this.pages});
  @override
  State<AnimatedPage> createState() => _AnimatedPageState();
}

class _AnimatedPageState extends State<AnimatedPage> {
  int _dir = 1;

  @override
  void didUpdateWidget(AnimatedPage old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _dir = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final incoming = child.key == ValueKey<int>(widget.index);
        final dx = 0.05 * _dir;
        final slide = SlideTransition(
          position: Tween<Offset>(begin: Offset(incoming ? dx : -dx, 0), end: Offset.zero)
              .animate(anim),
          child: child,
        );
        return incoming ? slide : FadeTransition(opacity: anim, child: slide);
      },
      child: KeyedSubtree(key: ValueKey<int>(widget.index), child: widget.pages[widget.index]),
    );
  }
}


class AttendanceHistoryTile extends StatelessWidget {
  final String dateKey, status;
  const AttendanceHistoryTile({super.key, required this.dateKey, required this.status});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final d = DateTime.parse(dateKey);
    final col = attColor(status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Glass(
        padding: const EdgeInsets.all(12),
        onTap: () => showAttendanceSheet(context, d),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: col.withOpacity(0.2),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(attIcon(status), size: 20, color: col),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(DateFormat('EEEE, d MMM').format(d),
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: on)),
          ),
          Pill(attLabel(status), col),
        ]),
      ),
    );
  }
}
