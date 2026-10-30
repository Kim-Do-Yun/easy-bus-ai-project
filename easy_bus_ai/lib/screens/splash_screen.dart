import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';

import 'home_screen.dart';

// 지도 인증 실패는 홈 화면에서도 안내할 수 있도록 공유한다.
final mapAuthError = ValueNotifier<String?>(null);

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _error;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      const clientId = String.fromEnvironment('NAVER_MAP_CLIENT_ID');
      if (clientId.isEmpty)
        throw Exception('네이버 지도 Client ID를 설정한 뒤 앱을 다시 실행해 주세요.');
      // 최초 실행에서만 SDK를 준비하고 검색 중에는 이 화면으로 돌아오지 않는다.
      await FlutterNaverMap()
          .init(
            clientId: clientId,
            onAuthFailed: (error) {
              mapAuthError.value =
                  '지도 인증에 실패했습니다. Client ID와 앱 등록 정보를 확인해 주세요.';
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '지도 초기화 실패: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '말로 타는 AI 쉬운 버스',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            if (_error != null) ...[
              const SizedBox(height: 24),
              Text(_error!, textAlign: TextAlign.center),
              const Text('설정을 확인한 뒤 앱을 다시 실행해 주세요.'),
            ],
          ],
        ),
      ),
    ),
  );
}
