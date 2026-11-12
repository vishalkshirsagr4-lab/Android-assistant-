import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/agent_controller.dart';

/// Renders Lucy's bundled Amica VRM character in a lightweight WebView.
/// The model and VRMA clips are local assets; Three.js/three-vrm are loaded
/// from a CDN, so the first avatar load requires an internet connection.
class LucyAvatar extends StatefulWidget {
  final AgentState state;

  const LucyAvatar({super.key, required this.state});

  @override
  State<LucyAvatar> createState() => _LucyAvatarState();
}

class _LucyAvatarState extends State<LucyAvatar> {
  late final WebViewController _webViewController;
  bool _pageReady = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    // The avatar is an Android WebView feature. Keep widget tests and other
    // unsupported platforms usable without a registered WebView plugin.
    if (!Platform.isAndroid) {
      _loadFailed = true;
      return;
    }
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF10121D))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageReady = true;
            _sendState();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _loadFailed = true);
            }
          },
        ),
      )
      ..loadFlutterAsset('assets/avatar_viewer/index.html');
  }

  @override
  void didUpdateWidget(covariant LucyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _sendState();
  }

  Future<void> _sendState() async {
    if (!_pageReady) return;
    try {
      await _webViewController.runJavaScript(
        "window.setAssistantState && window.setAssistantState('${widget.state.name}')",
      );
    } catch (_) {
      // The page may be reloading; onPageFinished sends the latest state.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the avatar prominent on phones without starving the conversation
    // area on compact screens and in smaller widget-test viewports.
    final avatarHeight =
        (MediaQuery.sizeOf(context).height * 0.28).clamp(140.0, 220.0);
    return SizedBox(
      height: avatarHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_loadFailed)
            const ColoredBox(
              color: Color(0xFF10121D),
              child: Center(
                child: Text(
                  '3D avatar is available on Android. Check your internet connection if it does not load.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            )
          else
            WebViewWidget(controller: _webViewController),
          Positioned(
            left: 14,
            bottom: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC171A2A),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _stateIcon(widget.state),
                      size: 14,
                      color: const Color(0xFF9D91FF),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _stateLabel(widget.state),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _stateIcon(AgentState state) {
    switch (state) {
      case AgentState.listening:
        return Icons.hearing;
      case AgentState.capturing:
        return Icons.visibility;
      case AgentState.analyzing:
        return Icons.psychology;
      case AgentState.speaking:
        return Icons.volume_up;
      case AgentState.executingAction:
        return Icons.touch_app;
      case AgentState.waitingConfirmation:
        return Icons.help_outline;
      case AgentState.idle:
        return Icons.nights_stay;
    }
  }

  String _stateLabel(AgentState state) {
    switch (state) {
      case AgentState.listening:
        return 'Listening';
      case AgentState.capturing:
        return 'Looking at screen';
      case AgentState.analyzing:
        return 'Thinking';
      case AgentState.speaking:
        return 'Speaking';
      case AgentState.executingAction:
        return 'Working';
      case AgentState.waitingConfirmation:
        return 'Waiting for confirmation';
      case AgentState.idle:
        return 'Ready';
    }
  }
}
