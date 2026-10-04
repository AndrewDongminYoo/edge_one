/// In-memory UTC daily accounting in application-defined integer microcredits.
///
/// Share one instance between every backend that draws from the same allowance.
/// Charging is synchronous within one Dart isolate. This is neither persistent
/// billing nor a cross-isolate limit. Dispatched attempts are never refunded.
final class RemoteBudget {
  RemoteBudget({required this.dailyLimitMicrocredits, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _checkCost(dailyLimitMicrocredits);
  }

  final int dailyLimitMicrocredits;
  final DateTime Function() _now;
  DateTime? _day;
  int _spent = 0;

  int get spentMicrocredits {
    _rollDay();
    return _spent;
  }

  /// Atomically charges [microcredits] if the daily allowance permits it.
  ///
  /// Throws [ArgumentError] for negative or non-JSON-safe integer amounts.
  /// A later UTC date starts a fresh allowance; clock rollback never does.
  /// [beforeCharge] runs after the clock callback and before charging. If it
  /// throws, no amount is charged. No callback runs after it.
  bool tryCharge(int microcredits, {void Function()? beforeCharge}) {
    _checkCost(microcredits);
    _rollDay();
    beforeCharge?.call();
    if (microcredits > dailyLimitMicrocredits - _spent) return false;
    _spent += microcredits;
    return true;
  }

  void _rollDay() {
    final now = _now().toUtc();
    final day = DateTime.utc(now.year, now.month, now.day);
    if (_day == null || day.isAfter(_day!)) {
      _day = day;
      _spent = 0;
    }
  }
}

void _checkCost(int value) {
  if (value < 0 || value > 9007199254740991) {
    throw ArgumentError.value(value, 'microcredits', 'must be in [0, 2^53-1]');
  }
}
