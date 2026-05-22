package com.magoremote.mago_remote

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path

/**
 * Manages continuous touch gestures via [AccessibilityService.dispatchGesture].
 *
 * Each pointer id is tracked independently. A pointer's lifetime maps to a
 * chain of [GestureDescription.StrokeDescription]s linked through
 * `continueStroke()` so that what looks to the OS like a real held finger —
 * unlocking long-press, drag, fling and (when multiple pointers overlap in
 * time) pinch behaviours.
 *
 * Per-pointer continuations are dispatched in their own
 * [GestureDescription], one stroke at a time. The OS interleaves concurrent
 * continuations from different pointer ids correctly because `continueStroke()`
 * was specifically designed to bypass the dispatch synchronization that
 * prevents two independent gestures from running at once.
 *
 * Requires Android API 26 (Oreo). The accessibility service declaration
 * already gates this so we don't need to runtime-check.
 */
class GestureSession(
    private val service: AccessibilityService,
    private val metrics: () -> Pair<Int, Int>,
) {
    private data class PointerState(
        var stroke: GestureDescription.StrokeDescription,
        var endX: Float,
        var endY: Float,
    )

    /** Active pointers keyed by controller-supplied pointerId. */
    private val pointers = mutableMapOf<Int, PointerState>()

    /** Synthetic stroke used as the head of every continuation chain. */
    private fun initialStroke(x: Float, y: Float): GestureDescription.StrokeDescription {
        // GestureDescription validates that paths have non-zero length.
        // A 1-pixel sliver is invisible to the user but satisfies the
        // contract; subsequent moves will real-world the pointer.
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x + 1f, y)
        }
        return GestureDescription.StrokeDescription(
            path,
            /* startTime = */ 0L,
            /* duration = */ 1L,
            /* willContinue = */ true,
        )
    }

    /** Open a new pointer at the given normalized coordinates. */
    fun begin(id: Int, nx: Double, ny: Double): Boolean {
        val (w, h) = metrics()
        val x = (nx.coerceIn(0.0, 1.0) * w).toFloat()
        val y = (ny.coerceIn(0.0, 1.0) * h).toFloat()
        // If a stale pointer with this id still exists, close it first so
        // the OS doesn't end up with a "ghost" finger.
        pointers.remove(id)?.let { stale ->
            try {
                val tail = stale.stroke.continueStroke(
                    Path().apply {
                        moveTo(stale.endX, stale.endY)
                        lineTo(stale.endX + 1f, stale.endY)
                    },
                    0L, 1L, false,
                )
                service.dispatchGesture(
                    GestureDescription.Builder().addStroke(tail).build(),
                    null, null,
                )
            } catch (_: Throwable) {}
        }
        val initial = initialStroke(x, y)
        // The endpoint of initialStroke is x+1, y (see initialStroke()).
        pointers[id] = PointerState(initial, x + 1f, y)
        return service.dispatchGesture(
            GestureDescription.Builder().addStroke(initial).build(),
            null, null,
        )
    }

    /**
     * Continue an existing pointer to the new normalized coordinates. If
     * no pointer with [id] exists (lost begin event), [begin] is called
     * implicitly so the gesture isn't silently dropped.
     */
    fun move(id: Int, nx: Double, ny: Double): Boolean {
        val state = pointers[id] ?: return begin(id, nx, ny)
        val (w, h) = metrics()
        val x = (nx.coerceIn(0.0, 1.0) * w).toFloat()
        val y = (ny.coerceIn(0.0, 1.0) * h).toFloat()
        // continueStroke() requires the new path to start at the previous
        // path's exact endpoint, otherwise it throws.
        if (x == state.endX && y == state.endY) {
            // Zero-length move would be rejected; nothing to dispatch.
            return true
        }
        val path = Path().apply {
            moveTo(state.endX, state.endY)
            lineTo(x, y)
        }
        return try {
            val cont = state.stroke.continueStroke(path, 0L, 16L, true)
            state.stroke = cont
            state.endX = x
            state.endY = y
            service.dispatchGesture(
                GestureDescription.Builder().addStroke(cont).build(),
                null, null,
            )
        } catch (t: Throwable) {
            // If continuation fails (e.g. previous stroke already settled
            // because dispatch was rejected), restart the pointer so the
            // user's finger doesn't get stuck.
            pointers.remove(id)
            begin(id, nx, ny)
            move(id, nx, ny)
        }
    }

    /**
     * Close a pointer. When [cancel] is false, the final segment moves
     * the touch to the supplied normalized coordinates first; when true,
     * it just lifts at the previous endpoint (used on PointerCancel /
     * shutdown).
     */
    fun end(id: Int, nx: Double, ny: Double, cancel: Boolean): Boolean {
        val state = pointers.remove(id) ?: return false
        val (w, h) = metrics()
        val finalX = if (cancel) state.endX else (nx.coerceIn(0.0, 1.0) * w).toFloat()
        val finalY = if (cancel) state.endY else (ny.coerceIn(0.0, 1.0) * h).toFloat()
        // Path needs non-zero length; if the lift coords match the
        // previous endpoint, nudge by 1px so the validator accepts it.
        val (toX, toY) = if (finalX == state.endX && finalY == state.endY) {
            (state.endX + 1f) to state.endY
        } else {
            finalX to finalY
        }
        val path = Path().apply {
            moveTo(state.endX, state.endY)
            lineTo(toX, toY)
        }
        return try {
            val tail = state.stroke.continueStroke(path, 0L, 16L, false)
            service.dispatchGesture(
                GestureDescription.Builder().addStroke(tail).build(),
                null, null,
            )
        } catch (_: Throwable) {
            false
        }
    }

    /** Best-effort cancel of every open pointer. */
    fun cancelAll() {
        for (id in pointers.keys.toList()) {
            end(id, 0.0, 0.0, cancel = true)
        }
        pointers.clear()
    }
}
