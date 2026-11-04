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
    debugPrint('[EASY_BUS_INIT] SplashScreen initState 진입');
    _initialize();
  }

  Future<void> _initialize() async {
    final elapsed = Stopwatch()..start();
    var stage = 'Client ID 설정 확인';
    var stageStartedMs = 0;
    debugPrint('[EASY_BUS_INIT] _initialize 시작 (누적=${elapsed.elapsedMilliseconds}ms)');
    try {
      // config/app.json을 --dart-define-from-file로 전달한 앱용 지도 설정을 읽는다.
      const clientId = String.fromEnvironment('NAVER_MAP_CLIENT_ID');
      if (clientId.isEmpty)
        throw Exception('네이버 지도 Client ID를 설정한 뒤 앱을 다시 실행해 주세요.');
      // 최초 실행에서만 SDK를 준비하고 검색 중에는 이 화면으로 돌아오지 않는다.
      stage = '네이버 지도 SDK 초기화';
      stageStartedMs = elapsed.elapsedMilliseconds;
      final sdkStartedMs = stageStartedMs;
      debugPrint('[EASY_BUS_INIT] $stage 호출 직전 (누적=${elapsed.elapsedMilliseconds}ms)');
      await FlutterNaverMap()
          .init(
            clientId: clientId,
            onAuthFailed: (error) {
              // 인증정보가 포함될 수 있는 오류 원문 대신 유형과 시간만 기록한다.
              debugPrint('[EASY_BUS_INIT] 지도 인증 콜백 오류 유형=${error.runtimeType} '
                  '(SDK 호출 후=${elapsed.elapsedMilliseconds - sdkStartedMs}ms)');
              mapAuthError.value =
                  '지도 인증에 실패했습니다. Client ID와 앱 등록 정보를 확인해 주세요.';
            },
          )
          .timeout(const Duration(seconds: 20));
      debugPrint('[EASY_BUS_INIT] $stage 반환 직후 '
          '(단계=${elapsed.elapsedMilliseconds - stageStartedMs}ms, 누적=${elapsed.elapsedMilliseconds}ms)');
      if (!mounted) return;
      stage = 'HomeScreen 전환';
      stageStartedMs = elapsed.elapsedMilliseconds;
      debugPrint('[EASY_BUS_INIT] HomeScreen 전환 직전 (누적=${elapsed.elapsedMilliseconds}ms)');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
      );
    } catch (error) {
      // 예외 메시지와 스택은 출력하지 않고 실패한 단계만 구분한다.
      debugPrint('[EASY_BUS_INIT] $stage 예외 유형=${error.runtimeType} '
          '(단계=${elapsed.elapsedMilliseconds - stageStartedMs}ms, 누적=${elapsed.elapsedMilliseconds}ms)');
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
