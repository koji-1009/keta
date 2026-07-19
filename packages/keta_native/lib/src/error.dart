import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'ffi/libcrypto.dart';

/// Pops the least-recent error off the current thread's BoringSSL error queue,
/// formats it as a human-readable string, then clears the whole queue so no
/// residual error state leaks into the next call on this thread.
///
/// Returns a placeholder when the queue was empty (some failures set no error).
String consumeBoringSslError() {
  final code = ERR_get_error();
  // Drain anything else the failing call may have stacked, unconditionally.
  ERR_clear_error();
  if (code == 0) {
    return 'no BoringSSL error on the queue';
  }
  const bufLen = 256;
  final buf = malloc<Uint8>(bufLen);
  try {
    ERR_error_string_n(code, buf, bufLen);
    return buf.cast<Utf8>().toDartString();
  } finally {
    malloc.free(buf);
  }
}
