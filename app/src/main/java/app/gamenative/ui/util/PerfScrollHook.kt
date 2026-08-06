package app.gamenative.ui.util

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import timber.log.Timber

/**
 * BENCHMARK ONLY — must not reach a release build; the receiver below is **exported**.
 *
 * Returns the library grid to item 0 without a downward pointer gesture:
 *
 *   adb shell am broadcast -a app.gamenative.PERF_FLAGS --ez scrollToStart true
 *
 * A fling harness needs this. Resetting the grid with a pointer gesture instead activates
 * PullToRefreshBox at item 0, which rebuilds the paged library and invalidates the run — and a
 * reset that costs measured frames pollutes the very histogram being measured.
 *
 * Used by docs/perf_fling_bench.sh. Add A/B knobs for a specific experiment as extra flags on this
 * object, in the branch doing the experiment; keep this file to the scroll reset.
 */
object PerfScrollHook {
    const val ACTION = "app.gamenative.PERF_FLAGS"

    var scrollToStartRequest by mutableIntStateOf(0)
        private set

    /**
     * Experiment arm: grid cards draw as a flat colour first and compose their real content only
     * after a short per-card delay. See GridViewCard.
     *
     *   adb shell am broadcast -a app.gamenative.PERF_FLAGS --ez lateAppear true
     */
    var lateAppear by mutableStateOf(false)
        private set

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getBooleanExtra("scrollToStart", false)) {
                scrollToStartRequest++
                Timber.tag("PerfScrollHook").i("scrollToStart #$scrollToStartRequest")
            }
            if (intent.hasExtra("lateAppear")) {
                lateAppear = intent.getBooleanExtra("lateAppear", false)
                Timber.tag("PerfScrollHook").i("lateAppear=$lateAppear")
            }
        }
    }

    fun register(context: Context) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, IntentFilter(ACTION), Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, IntentFilter(ACTION))
        }
        Timber.tag("PerfScrollHook").i("listening on $ACTION")
    }
}
