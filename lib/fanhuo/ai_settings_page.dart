/// AI 设置页（Dart/Flutter）。
///
/// 结构：
///   1. 厂商选择（按国内 / 海外分组）
///   2. Base URL（可改，预填厂商默认）
///   3. 模型（下拉，来自 data/ai-providers.json；也可手填）
///   4. API Key（密码框，不回显；只写本机存储）
///   5. 「测试连接」按钮 → 走 [Proofreader.ping]
///   6. 纠错开关：整章纠错后写缓存 / 打开章节时自动纠错（默认关）
library;

import 'package:flutter/material.dart';

import 'ai_proofread.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({
    super.key,
    required this.providers,
    required this.initial,
    required this.onSave,
    required this.onTest,
    this.autoProofread = false,
    this.onAutoProofreadChanged,
    this.apiKey = '',
    this.onApiKeyChanged,
  });

  final List<AiProvider> providers;
  final AiConfig initial;
  final void Function(AiProvider provider, AiConfig config) onSave;
  final Future<String> Function(AiProvider provider, AiConfig config) onTest;
  final bool autoProofread;
  final ValueChanged<bool>? onAutoProofreadChanged;

  /// 初始 key。由上层从本机安全存储读出来传进来。
  final String apiKey;
  final ValueChanged<String>? onApiKeyChanged;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late AiProvider _provider;
  late TextEditingController _baseUrl;
  late TextEditingController _model;
  late TextEditingController _apiKey;
  late double _temperature;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.providers.firstWhere(
      (p) => p.id == widget.initial.providerId,
      orElse: () => widget.providers.first,
    );
    _baseUrl = TextEditingController(
      text: widget.initial.baseUrl.isEmpty ? _provider.baseUrl : widget.initial.baseUrl,
    );
    _model = TextEditingController(
      text: widget.initial.model.isEmpty ? _provider.defaultModel : widget.initial.model,
    );
    _apiKey = TextEditingController(text: widget.apiKey);
    _temperature = widget.initial.temperature;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  AiConfig get _config => AiConfig(
        providerId: _provider.id,
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        apiKey: _apiKey.text.trim(),
        temperature: _temperature,
      );

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final reply = await widget.onTest(_provider, _config);
      setState(() {
        _messageIsError = false;
        _message = '连接成功，模型回了：「$reply」';
      });
    } catch (error) {
      setState(() {
        _messageIsError = true;
        _message = '$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    widget.onApiKeyChanged?.call(_apiKey.text.trim());
    widget.onSave(_provider, _config);
    setState(() {
      _messageIsError = false;
      _message = '已保存到本机，不会上传、不会进备份';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cn = widget.providers.where((p) => p.cn).toList();
    final intl = widget.providers.where((p) => !p.cn).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('AI 纠错设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('厂商', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _provider.id,
            isExpanded: true,
            items: [
              for (final group in [('国内', cn), ('海外', intl)])
                if (group.$2.isNotEmpty) ...[
                  for (final p in group.$2)
                    DropdownMenuItem(value: p.id, child: Text('${p.label}（${group.$1}）')),
                ],
            ],
            onChanged: (id) {
              if (id == null) return;
              final next = widget.providers.firstWhere((p) => p.id == id);
              setState(() {
                _provider = next;
                if (_baseUrl.text.trim().isEmpty || next.baseUrl.isNotEmpty) {
                  _baseUrl.text = next.baseUrl;
                }
                _model.text = next.defaultModel;
              });
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrl,
            decoration: InputDecoration(
              labelText: 'Base URL',
              helperText: _provider.baseUrl.isEmpty ? '自定义服务要填完整的 /v1 地址' : '留空则用默认：${_provider.baseUrl}',
            ),
          ),
          const SizedBox(height: 12),
          if (_provider.models.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _provider.models.contains(_model.text) ? _model.text : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '常用模型'),
              items: [
                for (final m in _provider.models)
                  DropdownMenuItem(value: m, child: Text(m)),
              ],
              onChanged: (m) {
                if (m != null) setState(() => _model.text = m);
              },
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: '模型名（可手填）'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: _provider.keyHint,
            ),
            onChanged: (v) => widget.onApiKeyChanged?.call(v.trim()),
          ),
          const SizedBox(height: 12),
          Text('温度 ${_temperature.toStringAsFixed(2)}（纠错建议 0.0～0.2）',
              style: theme.textTheme.bodySmall),
          Slider(
            value: _temperature,
            min: 0,
            max: 1,
            divisions: 20,
            label: _temperature.toStringAsFixed(2),
            onChanged: (v) => setState(() => _temperature = v),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('打开章节时自动纠错'),
            subtitle: const Text('默认关。开了以后每章首次打开都会调一次模型（花钱）'),
            value: widget.autoProofread,
            onChanged: widget.onAutoProofreadChanged,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _test,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageIsError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _message!,
                style: TextStyle(
                  color: _messageIsError
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSurface,
                  fontSize: 13,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'key 只存这台手机的本地存储，不上传、不写日志、不进备份。'
            '换机器要重填。担心的话，去厂商控制台建一个只给本机用的子 key，随时可删。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
