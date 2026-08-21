import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/ssh/ssh_service.dart';

class TerminalSpecialKeys extends ConsumerStatefulWidget {
  const TerminalSpecialKeys({
    super.key,
    required this.order,
    required this.customKeys,
    required this.onSend,
    required this.inputController,
    required this.onAi,
    required this.onPortForward,
    required this.onSystemManagement,
    required this.pictureInPicture,
    required this.onPictureInPicture,
    required this.fullscreen,
    required this.onFullscreen,
    required this.split,
    required this.onSplit,
  });

  final List<String> order;
  final List<TerminalCustomKey> customKeys;
  final void Function(String, {bool enter}) onSend;
  final TerminalInputController inputController;
  final VoidCallback onAi;
  final VoidCallback? onPortForward;
  final VoidCallback? onSystemManagement;
  final bool pictureInPicture;
  final VoidCallback? onPictureInPicture;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final bool split;
  final VoidCallback? onSplit;

  @override
  ConsumerState<TerminalSpecialKeys> createState() =>
      _TerminalSpecialKeysState();
}

class _TerminalSpecialKeysState extends ConsumerState<TerminalSpecialKeys> {
  @override
  Widget build(BuildContext context) {
    final definitions = <String, _QuickKey>{
      ..._quickKeys,
      for (final key in widget.customKeys)
        key.id: _QuickKey(key.label, key.value),
    };
    final normalized = [
      ...widget.order.where(definitions.containsKey),
      ...defaultTerminalQuickKeys.where(
        (value) => !widget.order.contains(value),
      ),
    ];
    return AnimatedBuilder(
      animation: widget.inputController,
      builder: (context, _) => Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _quickKeyGrid(normalized, definitions),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  IconButton(
                    key: const ValueKey('terminal-action-ai'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('Catty Agent'),
                    onPressed: widget.onAi,
                    icon: Icon(
                      Icons.auto_awesome,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-port-forward'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('端口转发'),
                    onPressed: widget.onPortForward,
                    icon: const Icon(Icons.swap_horiz),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-system-management'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('系统管理'),
                    onPressed: widget.onSystemManagement,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-picture-in-picture'),
                    visualDensity: VisualDensity.compact,
                    tooltip: widget.pictureInPicture ? '退出画中画' : '画中画',
                    isSelected: widget.pictureInPicture,
                    onPressed: widget.onPictureInPicture,
                    icon: Icon(
                      widget.pictureInPicture
                          ? Icons.picture_in_picture_alt
                          : Icons.picture_in_picture,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-fullscreen'),
                    visualDensity: VisualDensity.compact,
                    tooltip: widget.fullscreen ? '退出全屏' : '全屏',
                    isSelected: widget.fullscreen,
                    onPressed: widget.onFullscreen,
                    icon: Icon(
                      widget.fullscreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-split'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('分屏'),
                    isSelected: widget.split,
                    onPressed: widget.onSplit,
                    icon: const Icon(Icons.vertical_split_outlined),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-edit'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('编辑快捷键'),
                    onPressed: () => _customize(context, normalized),
                    icon: const Icon(Icons.tune, size: 20),
                  ),
                  IconButton(
                    key: const ValueKey('terminal-action-hide-keyboard'),
                    visualDensity: VisualDensity.compact,
                    tooltip: localized('收起键盘'),
                    onPressed: () =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    icon: const Icon(Icons.keyboard_hide_outlined),
                  ),
                ]
                    .map((button) => Expanded(child: button))
                    .toList(growable: false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickKeyGrid(
    List<String> order,
    Map<String, _QuickKey> definitions,
  ) {
    const columnCount = 6;
    const rowHeight = 38.0;
    final rowCount = (order.length / columnCount).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < rowCount; row++) ...[
          if (row > 0) const SizedBox(height: 4),
          SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                for (var column = 0; column < columnCount; column++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: row * columnCount + column < order.length
                          ? _keyButton(
                              definitions[order[row * columnCount + column]]!,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _keyButton(_QuickKey key) {
    final selected = key.type == _QuickKeyType.modifier &&
        widget.inputController.modifiers.contains(key.modifierId);
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: () => _press(key),
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor:
              selected ? Theme.of(context).colorScheme.primaryContainer : null,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
          ),
        ),
        child: key.icon == null
            ? FittedBox(
                fit: BoxFit.scaleDown,
                child: LText(
                  key.label,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                ),
              )
            : Tooltip(
                message: key.label,
                child: Icon(key.icon, size: 20),
              ),
      ),
    );
  }

  Future<void> _press(_QuickKey key) async {
    if (key.type == _QuickKeyType.modifier) {
      final next = {...widget.inputController.modifiers};
      if (!next.add(key.modifierId!)) next.remove(key.modifierId);
      widget.inputController.setModifiers(next);
      return;
    }
    if (key.type == _QuickKeyType.paste) {
      widget.inputController.clearModifiers();
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text?.isNotEmpty == true) widget.onSend(text!);
      return;
    }
    final value = decodeTerminalKeyEscapes(key.value ?? '');
    if (value.isNotEmpty) widget.onSend(value);
  }

  Future<void> _customize(
    BuildContext context,
    List<String> current,
  ) async {
    final working = [...current];
    final custom = [...widget.customKeys];
    final result = await showModalBottomSheet<_QuickKeySettingsResult>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          String labelFor(String id) {
            final builtIn = _quickKeys[id];
            if (builtIn != null) return builtIn.label;
            for (final key in custom) {
              if (key.id == id) return key.label;
            }
            return id;
          }

          return SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: Column(
              children: [
                ListTile(
                  title: const LText('快捷键设置'),
                  subtitle: const LText('拖动排序；按键会根据屏幕宽度自动换行'),
                  trailing: TextButton(
                    onPressed: () => setModalState(() {
                      working
                        ..clear()
                        ..addAll(defaultTerminalQuickKeys);
                      custom.clear();
                    }),
                    child: const LText('恢复默认'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final key = await _editCustomKey(context);
                        if (key == null) return;
                        setModalState(() {
                          custom.add(key);
                          working.add(key.id);
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: const LText('添加自定义快捷键'),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: working.length,
                    onReorderItem: (oldIndex, newIndex) => setModalState(() {
                      final value = working.removeAt(oldIndex);
                      working.insert(newIndex, value);
                    }),
                    itemBuilder: (context, index) {
                      final id = working[index];
                      final customIndex =
                          custom.indexWhere((key) => key.id == id);
                      return ListTile(
                        key: ValueKey(id),
                        leading: const Icon(Icons.drag_handle),
                        title: LText(labelFor(id)),
                        subtitle: customIndex < 0
                            ? const LText('内置按键')
                            : LText('发送：${custom[customIndex].value}'),
                        trailing: customIndex < 0
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: localized('编辑'),
                                    onPressed: () async {
                                      final key = await _editCustomKey(
                                        context,
                                        initial: custom[customIndex],
                                      );
                                      if (key == null) return;
                                      setModalState(() {
                                        custom[customIndex] = key;
                                      });
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: localized('删除'),
                                    onPressed: () => setModalState(() {
                                      custom.removeAt(customIndex);
                                      working.remove(id);
                                    }),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        _QuickKeySettingsResult(working, custom),
                      ),
                      child: const LText('保存快捷键'),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result == null) return;
    final settings = ref.read(settingsControllerProvider);
    await ref.read(settingsControllerProvider.notifier).update(
          settings.copyWith(
            terminalQuickKeys: result.order,
            terminalCustomKeys: result.customKeys,
          ),
        );
  }

  Future<TerminalCustomKey?> _editCustomKey(
    BuildContext context, {
    TerminalCustomKey? initial,
  }) async {
    final label = TextEditingController(text: initial?.label);
    final value = TextEditingController(text: initial?.value);
    return showDialog<TerminalCustomKey>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(initial == null ? '添加自定义快捷键' : '编辑自定义快捷键'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              autofocus: true,
              decoration: LInputDecoration(
                labelText: '显示名称',
                hintText: '例如：清屏',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: value,
              decoration: LInputDecoration(
                labelText: '发送内容',
                hintText: r'例如：clear\n 或 \x03',
                helperText: r'支持 \n、\t、\e 和 \xNN 转义',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () {
              final keyLabel = label.text.trim();
              final keyValue = value.text;
              if (keyLabel.isEmpty || keyValue.isEmpty) return;
              Navigator.pop(
                context,
                TerminalCustomKey(
                  id: initial?.id ??
                      'custom-${DateTime.now().microsecondsSinceEpoch}',
                  label: keyLabel,
                  value: keyValue,
                ),
              );
            },
            child: const LText('确定'),
          ),
        ],
      ),
    );
  }
}

class _QuickKeySettingsResult {
  const _QuickKeySettingsResult(this.order, this.customKeys);

  final List<String> order;
  final List<TerminalCustomKey> customKeys;
}

enum _QuickKeyType { text, modifier, paste }

class _QuickKey {
  const _QuickKey(
    this.label,
    this.value, {
    this.type = _QuickKeyType.text,
    this.modifierId,
    this.icon,
  });

  final String label;
  final String? value;
  final _QuickKeyType type;
  final String? modifierId;
  final IconData? icon;
}

const _quickKeys = <String, _QuickKey>{
  'escape': _QuickKey('Esc', '\x1b'),
  'alt': _QuickKey(
    'Alt',
    null,
    type: _QuickKeyType.modifier,
    modifierId: 'alt',
  ),
  'ctrl': _QuickKey(
    'Ctrl',
    null,
    type: _QuickKeyType.modifier,
    modifierId: 'ctrl',
  ),
  'shift': _QuickKey(
    'Shift',
    null,
    type: _QuickKeyType.modifier,
    modifierId: 'shift',
  ),
  'tab': _QuickKey('Tab', '\t'),
  'arrowUp': _QuickKey('↑', '\x1b[A'),
  'arrowDown': _QuickKey('↓', '\x1b[B'),
  'arrowLeft': _QuickKey('←', '\x1b[D'),
  'arrowRight': _QuickKey('→', '\x1b[C'),
  'home': _QuickKey('Home', '\x1b[H'),
  'end': _QuickKey('End', '\x1b[F'),
  'paste': _QuickKey(
    '粘贴',
    null,
    type: _QuickKeyType.paste,
    icon: Icons.content_paste_outlined,
  ),
  'ctrlC': _QuickKey('Ctrl+C', '\x03'),
  'ctrlD': _QuickKey('Ctrl+D', '\x04'),
  'ctrlZ': _QuickKey('Ctrl+Z', '\x1a'),
  'pipe': _QuickKey('|', '|'),
  'slash': _QuickKey('/', '/'),
  'tilde': _QuickKey('~', '~'),
};

String decodeTerminalKeyEscapes(String input) {
  var value = input
      .replaceAll(r'\e', '\x1b')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t');
  value = value.replaceAllMapped(
    RegExp(r'\\x([0-9a-fA-F]{2})'),
    (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
  );
  return value.replaceAll(r'\\', '\\');
}
