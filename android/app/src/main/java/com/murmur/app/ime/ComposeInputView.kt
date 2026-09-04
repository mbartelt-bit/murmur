package com.murmur.app.ime

import android.annotation.SuppressLint
import android.content.Context
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.AbstractComposeView
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner

/**
 * A Compose view that can live inside an `InputMethodService`.
 *
 * Compose refuses to run without a `LifecycleOwner`, a `ViewModelStoreOwner` and a
 * `SavedStateRegistryOwner` on the view tree. An activity installs all three for free; an
 * input method has no activity, so the service implements the three owners itself and
 * [installOwners] puts them on the tree — on this view *and* on the input window's decor view,
 * because Compose's window recomposer looks for the lifecycle from the decor view, not from us.
 * Miss the decor view and the keyboard dies with
 * "ViewTreeLifecycleOwner not found from DecorView" the first time it is shown.
 */
// Never inflated from XML — the service constructs it in onCreateInputView — so the
// (Context, AttributeSet) constructor lint asks for would only be dead code.
@SuppressLint("ViewConstructor")
class ComposeInputView(
    context: Context,
    private val content: @Composable () -> Unit,
) : AbstractComposeView(context) {

    @Composable
    override fun Content() = content()
}

/** Puts [owner] (a service that is all three owners) on [this] view's tree. */
fun <T> View.installOwners(owner: T) where T : LifecycleOwner, T : ViewModelStoreOwner, T : SavedStateRegistryOwner {
    setViewTreeLifecycleOwner(owner)
    setViewTreeViewModelStoreOwner(owner)
    setViewTreeSavedStateRegistryOwner(owner)
}
