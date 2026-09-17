// BROKA v3.0 - Result type for repository returns
// Inspired by Rust/Kotlin Result — avoids throwing exceptions across layers.

sealed class Result<T> {
  const Result();
}

final class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);
}

final class Failure<T> extends Result<T> {
  final String message;
  final int? statusCode;
  const Failure(this.message, {this.statusCode});
}

extension ResultExtension<T> on Result<T> {
  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T get data => (this as Success<T>).data;
  String get errorMessage => (this as Failure<T>).message;
  int? get errorCode => (this as Failure<T>).statusCode;

  R fold<R>({
    required R Function(T data) onSuccess,
    required R Function(String message, int? code) onFailure,
  }) {
    return switch (this) {
      Success<T> s => onSuccess(s.data),
      Failure<T> f => onFailure(f.message, f.statusCode),
    };
  }
}
