package com.example.test_app

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "digital_shadow/usage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "hasUsageAccess" -> result.success(hasUsageAccess())
                        "openUsageAccessSettings" -> {
                            val i = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(true)
                        }
                        "queryUsage" -> {
                            val start = call.argument<Number>("startMs")?.toLong()
                            val end = call.argument<Number>("endMs")?.toLong()
                            if (start == null || end == null) {
                                result.error("ARGS", "startMs and endMs required", null)
                            } else {
                                result.success(queryUsage(start, end))
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("USAGE_ERROR", e.message, null)
                }
            }
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    @Suppress("DEPRECATION")
    private fun queryUsage(startMs: Long, endMs: Long): List<Map<String, Any>> {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(startMs, endMs)
        val e = UsageEvents.Event()

        val depth = HashMap<String, Int>()
        val openAt = HashMap<String, Long>()
        val seen = HashSet<String>()
        val total = HashMap<String, Long>()
        val sessions = HashMap<String, Int>()
        val lastUsed = HashMap<String, Long>()

        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val pkg = e.packageName ?: continue
            val ts = e.timeStamp
            when (e.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                    val d = depth[pkg] ?: 0
                    if (d == 0) {
                        openAt[pkg] = ts
                        sessions[pkg] = (sessions[pkg] ?: 0) + 1
                    }
                    depth[pkg] = d + 1
                    seen.add(pkg)
                    lastUsed[pkg] = ts
                }
                UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                    val d = depth[pkg] ?: 0
                    if (d <= 0) {
                        // App was already in the foreground when the range began.
                        if (!seen.contains(pkg)) {
                            total[pkg] = (total[pkg] ?: 0L) + (ts - startMs).coerceAtLeast(0L)
                        }
                    } else {
                        depth[pkg] = d - 1
                        if (d - 1 == 0) {
                            val st = openAt.remove(pkg)
                            if (st != null) total[pkg] = (total[pkg] ?: 0L) + (ts - st)
                        }
                    }
                    seen.add(pkg)
                    lastUsed[pkg] = ts
                }
            }
        }

        // Apps still in the foreground at the end of the range.
        val end = minOf(endMs, System.currentTimeMillis())
        for ((pkg, st) in openAt) {
            total[pkg] = (total[pkg] ?: 0L) + (end - st).coerceAtLeast(0L)
            lastUsed[pkg] = end
        }

        val pm = packageManager
        val out = ArrayList<Map<String, Any>>()
        for ((pkg, ms) in total) {
            if (ms <= 0L) continue
            var label = pkg
            var category = -1
            try {
                val ai = pm.getApplicationInfo(pkg, 0)
                label = pm.getApplicationLabel(ai).toString()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) category = ai.category
            } catch (ex: Exception) {
                // Not visible or uninstalled: keep the package name as the label.
            }
            out.add(
                mapOf(
                    "package" to pkg,
                    "label" to label,
                    "totalMs" to ms,
                    "sessions" to (sessions[pkg] ?: 0),
                    "lastUsedMs" to (lastUsed[pkg] ?: 0L),
                    "category" to category
                )
            )
        }
        return out
    }
}