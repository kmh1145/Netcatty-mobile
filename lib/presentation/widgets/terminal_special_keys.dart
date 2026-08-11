import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';

class TerminalSpecialKeys extends ConsumerStatefulWidget {
  const TerminalSpecialKeys({
    super.key,
    required this.order,
    required this.customKeys,
    required this.onSend,
    required this.onAi,
    required this.onPortForward,
    required this.split,
    required this.onSplit,
  });

  final List<String> order;
  final List<TerminalCustomKey> customKeys;
  final void Function(String, {bool enter}) onSend;
  final VoidCallback onAi;
  final VoidCallback? onPortForward;
  final bool split;
  final VoidCallback? onSplit;

  @override
  ConsumerState<TerminalSpecialKeys> createState() =>
      _TerminalSpecialKeysState();
}

class _TerminalSpecialKeysState extends ConsumerState<TerminalSpecialKeys> {
  final modifiers = <String>{};

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
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final id in normalized) _keyButton(definitions[id]!),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Catty Agent',
                  onPressed: widget.onAi,
                  icon: Icon(
                    Icons.auto_awesome,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                IconButton(
                  tooltip: '端口转发',
                  onPressed: widget.onPortForward,
                  icon: const Icon(Icons.swap_horiz),
                ),
                IconButton(
                  tooltip: '分屏',
                  isSelected: widget.split,
                  onPressed: widget.onSplit,
                  icon: const Icon(Icons.vertical_split_outlined),
                ),
                IconButton(
                  tooltip: '收起键盘',
                  onPressed: () =>
                      FocusManager.instance.primaryFocus?.unfocus(),
                  icon: const Icon(Icons.keyboard_hide_outlined),
                ),
                IconButton(
                  tooltip: '编辑快捷键',
                  onPressed: () => _customize(context, normalized),
                  icon: const Icon(Icons.tune, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyButton(_QuickKey key) {
    final selected = key.type == _QuickKeyType.modifier &&
        modifiers.contains(key.modifierId);
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: () => _press(key),
        style: TextButton.styleFrom(
          minimumSize: const Size(46, 38),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor:
              selected ? Theme.of(context).colorScheme.primaryContainer : null,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
          ),
        ),
        child: Text(key.label),
      ),
    );
  }

  Future<void> _press(_QuickKey key) async {
    if (key.type == _QuickKeyType.modifier) {
      setState(() {
        if (!modifiers.add(key.modifierId!)) {
          modifiers.remove(key.modifierId);
        }
      });
      return;
    }
    if (key.type == _QuickKeyType.paste) {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text?.isNotEmpty == true) widget.onSend(text!);
      return;
    }
    final value = _applyModifiers(decodeTerminalKeyEscapes(key.value ?? ''));
    if (value.isNotEmpty) widget.onSend(value);
    if (modifiers.isNotEmpty) setState(modifiers.clear);
  }

  String _applyModifiers(String value) {
    if (modifiers.isEmpty) return value;
    final shift = modifiers.contains('shift');
    final alt = modifiers.contains('alt');
    final ctrl = modifiers.contains('ctrl');
    final parameter = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    if (value.length == 3 &&
        value.startsWith('\x1b[') &&
        'ABCDHF'.contains(value[2])) {
      return '\x1b[1;$parameter${value[2]}';
    }
    var result = value;
    if (shift && result.length == 1) result = result.toUpperCase();
    if (ctrl && result.length == 1) {
      final code = result.toUpperCase().codeUnitAt(0);
      if (code >= 64 && code <= 95) {
        result = String.fromCharCode(code & 0x1f);
      }
    }
    if (alt) result = '\x1b$result';
    return result;
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
                  title: const Text('快捷键设置'),
                  subtitle: const Text('拖动排序；按键会根据屏幕宽度自动换行'),
                  trailing: TextButton(
                    onPressed: () => setModalState(() {
                      working
                        ..clear()
                        ..addAll(defaultTerminalQuickKeys);
                      custom.clear();
                    }),
                    child: const Text('恢复默认'),
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
                      label: const Text('添加自定义快捷键'),
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
                        title: Text(labelFor(id)),
                        subtitle: customIndex < 0
                            ? const Text('内置按键')
                            : Text('发送：${custom[customIndex].value}'),
                        trailing: customIndex < 0
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '编辑',
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
                                    tooltip: '删除',
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
                      child: const Text('保存快捷键'),
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
        title: Text(initial == null ? '添加自定义快捷键' : '编辑自定义快捷键'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '显示名称',
                hintText: '例如：清屏',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: value,
              decoration: const InputDecoration(
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
            child: const Text('取消'),
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
            child: const Text('确定'),
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
  });

  final String label;
  final String? value;
  final _QuickKeyType type;
  final String? modifierId;
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
  'paste': _QuickKey('粘贴', null, type: _QuickKeyType.paste),
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
