package com.magoremote.mago_remote

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter plugin entry point for mago_remote.
 *
 * Registers two platform channels:
 *  - `remote_desk/android_input`  (MethodChannel) — input injection & service control.
 *  - `remote_desk/android_focus`  (EventChannel)  — editable-focus state broadcast.
 *
 * Intentionally does NOT implement ActivityAware: all operations that
 * previously relied on an Activity context have been ported to use the
 * application context (or are no-ops on the plugin side).
 */
class MagoRemotePlugin : FlutterPlugin {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        // ---- Focus event stream ----
        eventChannel = EventChannel(
            binding.binaryMessenger,
            "remote_desk/android_focus",
        )
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            private var listener: ((Boolean) -> Unit)? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l: (Boolean) -> Unit = { value -> events.success(value) }
                listener = l
                RemoteInputService.addFocusListener(l)
            }

            override fun onCancel(arguments: Any?) {
                listener?.let { RemoteInputService.removeFocusListener(it) }
                listener = null
            }
        })

        // ---- Method channel ----
        methodChannel = MethodChannel(
            binding.binaryMessenger,
            "remote_desk/android_input",
        )
        methodChannel.setMethodCallHandler { call, result ->
            val ctx = context
            if (ctx == null) {
                result.error("DETACHED", "Plugin is detached from engine.", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {

                    "isAccessibilityEnabled" -> {
                        result.success(isAccessibilityServiceEnabled(ctx))
                    }

                    "openAccessibilitySettings" -> {
                        val i = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ctx.startActivity(i)
                        result.success(null)
                    }

                    "screenInfo" -> {
                        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                        val m = DisplayMetrics()
                        @Suppress("DEPRECATION")
                        wm.defaultDisplay.getRealMetrics(m)
                        result.success(
                            mapOf(
                                "w" to m.widthPixels,
                                "h" to m.heightPixels,
                                "s" to m.density.toDouble(),
                            )
                        )
                    }

                    "tap" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.error(
                                "NO_SERVICE",
                                "RemoteInputService not connected; enable it in Accessibility settings.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val x = call.argument<Double>("x") ?: 0.0
                        val y = call.argument<Double>("y") ?: 0.0
                        result.success(svc.tapNormalized(x, y))
                    }

                    "setText" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val s = call.argument<String>("s") ?: ""
                        result.success(svc.setFocusedText(s))
                    }

                    "deleteBackward" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val n = call.argument<Int>("n") ?: 1
                        result.success(svc.deleteBackward(n))
                    }

                    "imeAction" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(svc.performImeAction())
                    }

                    "globalAction" -> {
                        val svc = RemoteInputService.instance
                        if (svc == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val a = call.argument<Int>("a") ?: -1
                        result.success(svc.globalAction(a))
                    }

                    "gestureBegin" -> {
                        val gs = RemoteInputService.instance?.gestureSession
                        if (gs == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val id = call.argument<Int>("id") ?: 0
                        val x = call.argument<Double>("x") ?: 0.0
                        val y = call.argument<Double>("y") ?: 0.0
                        result.success(gs.begin(id, x, y))
                    }

                    "gestureMove" -> {
                        val gs = RemoteInputService.instance?.gestureSession
                        if (gs == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val id = call.argument<Int>("id") ?: 0
                        val x = call.argument<Double>("x") ?: 0.0
                        val y = call.argument<Double>("y") ?: 0.0
                        result.success(gs.move(id, x, y))
                    }

                    "gestureEnd" -> {
                        val gs = RemoteInputService.instance?.gestureSession
                        if (gs == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val id = call.argument<Int>("id") ?: 0
                        val x = call.argument<Double>("x") ?: 0.0
                        val y = call.argument<Double>("y") ?: 0.0
                        val cancel = call.argument<Boolean>("c") ?: false
                        result.success(gs.end(id, x, y, cancel))
                    }

                    "startScreenCaptureService" -> {
                        val i = Intent(ctx, ScreenCaptureService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            ctx.startForegroundService(i)
                        } else {
                            ctx.startService(i)
                        }
                        // Don't resolve the Flutter result until the service has
                        // actually entered the foreground state. This closes the
                        // race where MediaProjectionManager.getMediaProjection()
                        // runs before the FGS is alive and produces black frames
                        // on Android 14+.
                        val resolved = java.util.concurrent.atomic.AtomicBoolean(false)
                        ScreenCaptureService.awaitStarted {
                            if (resolved.compareAndSet(false, true)) {
                                result.success(null)
                            }
                        }
                        // Safety timeout so we never hang forever.
                        android.os.Handler(android.os.Looper.getMainLooper())
                            .postDelayed({
                                if (resolved.compareAndSet(false, true)) {
                                    result.error(
                                        "FGS_TIMEOUT",
                                        "ScreenCaptureService did not start in time.",
                                        null,
                                    )
                                }
                            }, 5_000)
                    }

                    "stopScreenCaptureService" -> {
                        ctx.stopService(Intent(ctx, ScreenCaptureService::class.java))
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("EXCEPTION", t.message, null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        context = null
    }

    // ---- Helpers ----

    private fun isAccessibilityServiceEnabled(ctx: Context): Boolean {
        // The most reliable check: scan the colon-separated list stored in
        // Settings.Secure. AccessibilityManager-based checks can miss services
        // that the user enabled but the system hasn't bound yet.
        val expected = "${ctx.packageName}/${RemoteInputService::class.java.name}"
        val flat = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return flat.split(':').any { it.equals(expected, ignoreCase = true) }
    }
}
