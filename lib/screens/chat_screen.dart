import 'dart:async';
import 'package:flutter/material.dart';
import '../services/agent_controller.dart';

/// Independent text-only Lucy session. It owns its controller and transcript;
/// it never starts speech recognition or text-to-speech.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final AgentController _controller;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _controller = AgentController();
    _controller.addListener(_onChanged);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize(voiceEnabled: false);
      await _controller.startChatMode();
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _controller.isChatApprovalPending) return;
    _messageController.clear();
    await _controller.sendChatMessage(text);
  }

  @override
  void dispose() {
    unawaited(_controller.closeChatMode());
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final busy = _controller.state == AgentState.analyzing ||
        _controller.state == AgentState.executingAction ||
        _controller.state == AgentState.waitingConfirmation;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.chat_bubble_outline),
            SizedBox(width: 10),
            Text('Lucy Chat'),
          ],
        ),
        actions: [
          if (_controller.state == AgentState.analyzing ||
              _controller.state == AgentState.executingAction)
            IconButton(
              tooltip: 'Cancel current task',
              onPressed: () => _controller.cancelChatTask(),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          IconButton(
            tooltip: 'Clear chat history',
            onPressed: _controller.conversation.isEmpty
                ? null
                : _controller.clearConversation,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  color: colors.surfaceContainerHighest.withOpacity(0.45),
                  child: const Row(
                    children: [
                      Icon(Icons.shield_outlined, size: 16),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Text-only session · Microphone and spoken replies are off',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _controller.conversation.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.forum_outlined, size: 54, color: colors.primary),
                                const SizedBox(height: 14),
                                const Text('What can I help you with?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                Text('Ask questions, plan tasks, or ask Lucy to work with supported phone apps.', textAlign: TextAlign.center, style: TextStyle(color: colors.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 20),
                          itemCount: _controller.conversation.length,
                          itemBuilder: (context, index) {
                            final item = _controller.conversation[index];
                            final user = item.isUser;
                            return Align(
                              alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .86),
                                margin: const EdgeInsets.symmetric(vertical: 5),
                                padding: const EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  color: user ? colors.primaryContainer : colors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: SelectableText(item.text, style: TextStyle(color: user ? colors.onPrimaryContainer : colors.onSurface, height: 1.35)),
                              ),
                            );
                          },
                        ),
                ),
                if (_controller.isChatApprovalPending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _controller.respondToChatApproval(false),
                            icon: const Icon(Icons.close),
                            label: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _controller.respondToChatApproval(true),
                            icon: const Icon(Icons.check),
                            label: const Text('Approve'),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (busy && !_controller.isChatApprovalPending)
                  const LinearProgressIndicator(minHeight: 2),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            enabled: !busy,
                            decoration: InputDecoration(
                              hintText: 'Message Lucy…',
                              filled: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Send message',
                          onPressed: busy ? null : _send,
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
