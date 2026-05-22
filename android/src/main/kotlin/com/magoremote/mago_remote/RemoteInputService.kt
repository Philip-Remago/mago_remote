package com.magoremote.mago_remote

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Bridges Flutter input events into Android via the AccessibilityService API.
 *
 * Limitations (OS-imposed for non-system apps):
 *   - Cannot inject arbitrary key codes.
 *   - Cannot interact with screens marked FLAG_SECURE.
 *   - The user must enable this service manually.
 */
class RemoteInputService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: RemoteInputService? = null
            private set

        /** Most recent "is editable input focused?" value, broadcast on change. */
        @Volatile
        var editableFocused: Boolean = false
            private set

        private val focusListeners = mutableListOf<(Boolean) -> Unit>()

        @Synchronized
        fun addFocusListener(l: (Boolean) -> Unit) {
            focusListeners.add(l)
            // Replay current state so subscribers don't have to wait for
            // the next focus change.
            l(editableFocused)
        }

        @Synchronized
        fun removeFocusListener(l: (Boolean) -> Unit) {
            focusListeners.remove(l)
        }

        @Synchronized
        private fun notifyFocus(value: Boolean) {
            if (editableFocused == value) return
            editableFocused = value
            for (l in focusListeners.toList()) {
                try { l(value) } catch (_: Throwable) {}
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        gestureSession = GestureSession(this) { realMetrics() }
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        gestureSession?.cancelAll()
        gestureSession = null
        instance = null
        notifyFocus(false)
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // Find current input focus across all windows; fall back to
                // event.source when no input-focused node exists.
                val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                val isEditable = (focused?.isEditable == true) ||
                    (event.source?.isEditable == true)
                notifyFocus(isEditable)
            }
        }
    }

    override fun onInterrupt() { /* unused */ }

    /**
     * Multi-pointer gesture engine. Lazily created when the service binds
     * so that GestureSession can call dispatchGesture without nullable-
     * service guarding everywhere.
     */
    var gestureSession: GestureSession? = null
        private set

    fun tapNormalized(nx: Double, ny: Double): Boolean {
        val (w, h) = realMetrics()
        val x = (nx.coerceIn(0.0, 1.0) * w).toFloat()
        val y = (ny.coerceIn(0.0, 1.0) * h).toFloat()
        val path = Path().apply { moveTo(x, y) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, 60L))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    fun setFocusedText(text: String): Boolean {
        // ACTION_SET_TEXT replaces the *entire* node value, so we must
        // splice the new chars at the current cursor (or append if no
        // selection info is available). Otherwise typing "a", then "b"
        // wipes "a" and leaves just "b" in the field.
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        // node.text returns the placeholder (hint) when the field is
        // empty on API 26+, which would otherwise get spliced into the
        // real value ("Search" + "a" -> "Searcha"). Treat hint as empty.
        val isShowingHint =
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                node.isShowingHintText
        val existing = if (isShowingHint) "" else (node.text?.toString() ?: "")
        val rawSelStart = node.textSelectionStart
        val rawSelEnd = node.textSelectionEnd
        // Selection indices are stale (still pointing into the hint)
        // when the hint is being shown; force append-from-empty.
        val selStart = if (isShowingHint) 0 else rawSelStart
        val selEnd = if (isShowingHint) 0 else rawSelEnd

        val (newText, newCursor) = if (selStart in 0..existing.length &&
            selEnd in 0..existing.length && selStart <= selEnd
        ) {
            val before = existing.substring(0, selStart)
            val after = existing.substring(selEnd)
            (before + text + after) to (selStart + text.length)
        } else {
            // No usable selection info — append at end.
            (existing + text) to (existing.length + text.length)
        }

        val setArgs = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                newText,
            )
        }
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setArgs)) {
            return false
        }
        // Best-effort: place the cursor where it would have moved on a
        // real keypress. Some IMEs reject this when the text hasn't been
        // committed yet, so we ignore the result.
        val selArgs = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursor)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
        return true
    }

    /**
     * Delete [count] characters before the cursor on the focused editable
     * node. AccessibilityService cannot inject KeyEvents (system-level
     * privilege), so we synthesize a backspace by re-splicing the node
     * text directly. Returns false if no editable node is focused or the
     * splice fails.
     */
    fun deleteBackward(count: Int): Boolean {
        if (count <= 0) return true
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        val isShowingHint =
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
                node.isShowingHintText
        if (isShowingHint) return true // nothing to delete from a hint
        val existing = node.text?.toString() ?: return false
        val selStart = node.textSelectionStart
        val selEnd = node.textSelectionEnd

        val (newText, newCursor) = if (selStart in 0..existing.length &&
            selEnd in 0..existing.length && selStart <= selEnd
        ) {
            if (selStart != selEnd) {
                // Selection exists -> delete the selection (1 backspace
                // press collapses it; extra count is ignored to match
                // platform behaviour).
                val before = existing.substring(0, selStart)
                val after = existing.substring(selEnd)
                (before + after) to selStart
            } else {
                val deleteN = count.coerceAtMost(selStart)
                val before = existing.substring(0, selStart - deleteN)
                val after = existing.substring(selEnd)
                (before + after) to (selStart - deleteN)
            }
        } else {
            // No selection info — delete from the end.
            val deleteN = count.coerceAtMost(existing.length)
            existing.substring(0, existing.length - deleteN) to
                (existing.length - deleteN)
        }

        val setArgs = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                newText,
            )
        }
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setArgs)) {
            return false
        }
        val selArgs = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursor)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
        return true
    }

    fun globalAction(action: Int): Boolean = performGlobalAction(action)

    /**
     * Activate the focused editor's IME action (Search / Done / Send /
     * Go / Next). Falls back to splicing a literal newline for true
     * multi-line fields where the IME action is unset.
     *
     * Without this, pressing Enter on a remote search bar would insert
     * a stray '\n' into the query string instead of submitting it.
     */
    fun performImeAction(): Boolean {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        // ACTION_IME_ENTER was added in API 30. Try it first; if the
        // node refuses (returns false), splice a newline as a fallback
        // so multi-line editors still get a line break.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            val accepted = node.performAction(
                AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id,
            )
            if (accepted) return true
        }
        return setFocusedText("\n")
    }

    private fun realMetrics(): Pair<Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val m = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(m)
        return m.widthPixels to m.heightPixels
    }
}
