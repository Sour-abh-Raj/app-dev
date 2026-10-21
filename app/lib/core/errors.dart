/// Error taxonomy shared by the outbox, the API client and the UI (O2:
/// transient vs permanent is explicit; permanent failures are surfaced).
sealed class AppError implements Exception {
  const AppError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Worth retrying later: offline, timeouts, 5xx, 409 in-progress, rate limits.
class TransientError extends AppError {
  const TransientError(super.message, {this.retryAfter});
  final Duration? retryAfter;
}

/// Retrying will not help: validation errors, forbidden, not found.
class PermanentError extends AppError {
  const PermanentError(super.message, {this.code});
  final String? code;
}

/// A free/Pro allowance is used up. Never blocking: the UI shows an inline
/// upsell card and keeps manual paths open.
class CapReachedError extends AppError {
  const CapReachedError(
    this.cap, {
    required this.retryAfter,
    required this.paywall,
  }) : super('cap_reached:$cap');
  final String cap;
  final Duration retryAfter;
  final String paywall;
}

class OfflineError extends TransientError {
  const OfflineError() : super('needs connection');
}
