import 'package:flutter/foundation.dart';

/// Connects the terminal toolbar's keyboard button to the visible pane.
///
/// The soft keyboard is only opened from this button. Tapping the terminal is
/// reserved for scrolling and selecting text, so a stray tap can no longer pop
/// the keyboard and jump the scrollback to the bottom.
class TerminalKeyboardToggle extends ChangeNotifier {
  VoidCallback? _open;
  VoidCallback? _close;
  var _isOpen = false;

  /// Whether the soft keyboard is currently requested.
  bool get isOpen => _isOpen;

  /// Whether a pane is mounted and able to take keyboard requests.
  bool get isAttached => _open != null && _close != null;

  /// Called by the pane with the callbacks that drive its focus node.
  void attach({required VoidCallback onOpen, required VoidCallback onClose}) {
    _open = onOpen;
    _close = onClose;
  }

  /// Called by the pane when it goes away. Does not notify: the pane is being
  /// disposed, and the toolbar for this session is gone as well.
  void detach() {
    _open = null;
    _close = null;
    _isOpen = false;
  }

  /// Opens or closes the soft keyboard. No-op until a pane is attached.
  void toggle() {
    if (!isAttached) return;
    _isOpen = !_isOpen;
    notifyListeners();
    if (_isOpen) {
      _open!();
    } else {
      _close!();
    }
  }

  /// Called by the pane when the platform dismissed the keyboard on its own,
  /// for example with the Android back gesture.
  void markClosed() {
    if (!_isOpen) return;
    _isOpen = false;
    notifyListeners();
  }
}
