package com.localmind.localmind

import io.flutter.embedding.android.FlutterActivity

/**
 * Main activity for LocalMind.
 *
 * Extends the v2 embedding FlutterActivity. The v1 embedding was removed from
 * Flutter, so importing `io.flutter.app.FlutterActivity` (v1) fails the build
 * with "use of deleted Android v1 embedding".
 */
class MainActivity : FlutterActivity()
