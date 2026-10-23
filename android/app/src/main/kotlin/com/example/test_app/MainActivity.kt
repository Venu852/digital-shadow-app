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
                        "queryHourly" -> {
                            val start = call.argument<Number>("startMs")?.toLong()
                            val end = call.argument<Number>("endMs")?.toLong()
                            if (start == null || end == null) {
                                result.error("ARGS", "startMs and endMs required", null)
                            } else {
                                result.success(queryHourly(start, end))
                            }
                        }
                        "queryBehaviorHourly" -> {
                            val start = call.argument<Number>("startMs")?.toLong()
                            val end = call.argument<Number>("endMs")?.toLong()
                            if (start == null || end == null) {
                                result.error("ARGS", "startMs and endMs required", null)
                            } else {
                                result.success(queryBehaviorHourly(start, end))
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

    private var homePackagesCache: Set<String>? = null

    @Suppress("DEPRECATION")
    private fun homePackages(): Set<String> {
        homePackagesCache?.let { return it }
        val out = HashSet<String>()
        try {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            for (ri in packageManager.queryIntentActivities(home, 0)) {
                ri.activityInfo?.packageName?.let { out.add(it) }
            }
            packageManager.resolveActivity(home, 0)?.activityInfo?.packageName
                ?.let { out.add(it) }
        } catch (e: Exception) {
            // Fall back to the name check below.
        }
        homePackagesCache = out
        return out
    }

    private fun isHomeApp(pkg: String): Boolean =
        homePackages().contains(pkg) || pkg.contains("launcher", ignoreCase = true)

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
        val lastBg = HashMap<String, Long>()

        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val pkg = e.packageName ?: continue
            val ts = e.timeStamp
            when (e.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                    val d = depth[pkg] ?: 0
                    if (d == 0) {
                        openAt[pkg] = ts
                        // Moving between screens of the same app leaves the
                        // foreground for a moment, so only count a new session
                        // if the app was away for more than 2 seconds.
                        val bg = lastBg[pkg]
                        if (bg == null || ts - bg > 2000L) {
                            sessions[pkg] = (sessions[pkg] ?: 0) + 1
                        }
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
                            lastBg[pkg] = ts
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
            if (ms <= 0L || isHomeApp(pkg)) continue
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

    private fun addInterval(arr: LongArray, startMs: Long, st: Long, en: Long) {
        var a = maxOf(st, startMs)
        while (a < en) {
            val idx = ((a - startMs) / 3_600_000L).toInt()
            if (idx < 0 || idx > 23) break
            val bucketEnd = startMs + (idx + 1) * 3_600_000L
            val seg = minOf(en, bucketEnd) - a
            if (seg <= 0L) break
            arr[idx] += seg
            a += seg
        }
    }

    @Suppress("DEPRECATION")
    private fun queryHourly(startMs: Long, endMs: Long): List<Map<String, Any>> {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(startMs, endMs)
        val e = UsageEvents.Event()

        val depth = HashMap<String, Int>()
        val openAt = HashMap<String, Long>()
        val seen = HashSet<String>()
        val hours = HashMap<String, LongArray>()

        fun arr(pkg: String): LongArray = hours.getOrPut(pkg) { LongArray(24) }

        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val pkg = e.packageName ?: continue
            val ts = e.timeStamp
            when (e.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                    val d = depth[pkg] ?: 0
                    if (d == 0) openAt[pkg] = ts
                    depth[pkg] = d + 1
                    seen.add(pkg)
                }
                UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                    val d = depth[pkg] ?: 0
                    if (d <= 0) {
                        if (!seen.contains(pkg)) addInterval(arr(pkg), startMs, startMs, ts)
                    } else {
                        depth[pkg] = d - 1
                        if (d - 1 == 0) {
                            val st = openAt.remove(pkg)
                            if (st != null) addInterval(arr(pkg), startMs, st, ts)
                        }
                    }
                    seen.add(pkg)
                }
            }
        }

        val end = minOf(endMs, System.currentTimeMillis())
        for ((pkg, st) in openAt) addInterval(arr(pkg), startMs, st, end)

        val pm = packageManager
        val out = ArrayList<Map<String, Any>>()
        for ((pkg, hourArr) in hours) {
            if (hourArr.sum() <= 0L) continue
            if (pkg == packageName || isHomeApp(pkg)) continue
            var label = ""
            var category = -1
            try {
                val ai = pm.getApplicationInfo(pkg, 0)
                label = pm.getApplicationLabel(ai).toString()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) category = ai.category
            } catch (ex: Exception) {
                continue // not a visible app: same rule as the summary tab
            }
            out.add(
                mapOf(
                    "package" to pkg,
                    "label" to label,
                    "category" to category,
                    "hours" to hourArr.toList()
                )
            )
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun queryBehaviorHourly(startMs: Long, endMs: Long): Map<String, Any> {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(startMs, endMs)
        val e = UsageEvents.Event()
        val pm = packageManager

        val visible = HashMap<String, Boolean>()
        fun isApp(pkg: String): Boolean = visible.getOrPut(pkg) {
            if (pkg == packageName || isHomeApp(pkg)) {
                false
            } else {
                try {
                    pm.getApplicationInfo(pkg, 0)
                    true
                } catch (ex: Exception) {
                    false
                }
            }
        }

        val opens = IntArray(24)
        val switches = IntArray(24)
        val wakeups = IntArray(24)
        val unlocks = IntArray(24)
        val typeCounts = HashMap<String, Int>()
        val depth = HashMap<String, Int>()
        val lastBg = HashMap<String, Long>()
        var lastPkg: String? = null

        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            val type = e.eventType
            val key = type.toString()
            typeCounts[key] = (typeCounts[key] ?: 0) + 1
            val idx = ((e.timeStamp - startMs) / 3_600_000L).toInt()
            if (idx < 0 || idx > 23) continue
            when (type) {
                1 -> { // activity resumed / moved to foreground
                    val pkg = e.packageName
                    if (pkg != null && isApp(pkg)) {
                        val d = depth[pkg] ?: 0
                        if (d == 0) {
                            // Moving between screens of the same app leaves the
                            // foreground for a moment. Only count a new open if
                            // the app was away for more than 2 seconds.
                            val bg = lastBg[pkg]
                            val isNewOpen = bg == null || e.timeStamp - bg > 2000L
                            if (isNewOpen) {
                                opens[idx]++
                                val prev = lastPkg
                                if (prev != null && prev != pkg) switches[idx]++
                            }
                            lastPkg = pkg
                        }
                        depth[pkg] = d + 1
                    }
                }
                2 -> { // activity paused / moved to background
                    val pkg = e.packageName
                    if (pkg != null && isApp(pkg)) {
                        val d = depth[pkg] ?: 0
                        if (d > 0) {
                            depth[pkg] = d - 1
                            if (d - 1 == 0) lastBg[pkg] = e.timeStamp
                        }
                    }
                }
                15 -> wakeups[idx]++ // screen turned on (interactive)
                18 -> unlocks[idx]++ // keyguard dismissed
            }
        }

        return mapOf(
            "opens" to opens.toList(),
            "switches" to switches.toList(),
            "wakeups" to wakeups.toList(),
            "unlocks" to unlocks.toList(),
            "typeCounts" to typeCounts
        )
    }
}