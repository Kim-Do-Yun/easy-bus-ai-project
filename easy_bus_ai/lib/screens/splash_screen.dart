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
    backgroundColor: const Color(0xFFFAF8FF),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 디자인 1의 버스 로봇 로고를 벡터 그리기로 옮겨 별도 이미지 패키지 없이 표시한다.
            const SizedBox(
              width: 160,
              height: 130,
              child: CustomPaint(painter: _LogoPainter()),
            ),
            const SizedBox(height: 24),
            const Text(
              '말로 타는',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
                height: 1.25,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 6),
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'AI ',
                    style: TextStyle(color: Color(0xFF2563EB)),
                  ),
                  TextSpan(text: '쉬운 버스'),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
                height: 1.25,
                letterSpacing: -0.6,
              ),
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

// 디자인 1 SVG(150x130 좌표계)의 도형 순서와 색상을 그대로 따른다.
class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.height / 130);
    Paint stroke(int color, double width, [double opacity = 1]) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = Color(color).withValues(alpha: opacity);
    Paint fill(int color, [double opacity = 1]) =>
        Paint()..color = Color(color).withValues(alpha: opacity);
    Path curve(List<double> p) {
      final path = Path()..moveTo(p[0], p[1]);
      for (var i = 2; i + 5 < p.length; i += 6) {
        path.cubicTo(p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5]);
      }
      return path;
    }

    void box(double x, double y, double w, double h, double r, Paint paint) =>
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
          paint,
        );

    canvas.drawPath(curve([40, 50, 40, 22, 110, 22, 110, 50]), stroke(0xFF1E40AF, 6));
    canvas.drawPath(
      curve([126, 34, 132, 39, 135, 46, 135, 54, 135, 62, 132, 69, 126, 74]),
      stroke(0xFF2563EB, 4),
    );
    canvas.drawPath(
      curve([134, 26, 143, 33, 147, 43, 147, 54, 147, 65, 143, 75, 134, 82]),
      stroke(0xFF2563EB, 4, 0.6),
    );
    canvas.drawPath(
      curve([142, 18, 153, 28, 158, 40, 158, 54, 158, 68, 153, 80, 142, 90]),
      stroke(0xFF2563EB, 3.5, 0.35),
    );
    box(44, 94, 14, 16, 5, fill(0xFF1E293B));
    box(92, 94, 14, 16, 5, fill(0xFF1E293B));
    box(40, 38, 70, 62, 22, fill(0xFF2563EB));
    box(46, 44, 58, 32, 14, fill(0xFFFFFFFF));
    canvas.drawPath(curve([57, 56, 57, 53, 63, 53, 63, 56]), stroke(0xFF1E293B, 3.5));
    canvas.drawPath(curve([87, 56, 87, 53, 93, 53, 93, 56]), stroke(0xFF1E293B, 3.5));
    canvas.drawPath(curve([70, 65, 72, 68, 78, 68, 80, 65]), stroke(0xFF1E293B, 3));
    canvas.drawCircle(const Offset(55, 61), 3.5, fill(0xFFFCA5A5, 0.7));
    canvas.drawCircle(const Offset(95, 61), 3.5, fill(0xFFFCA5A5, 0.7));
    for (final x in [52.0, 98.0]) {
      canvas.drawCircle(Offset(x, 86), 5.5, fill(0xFFFCD34D));
      canvas.drawCircle(Offset(x, 86), 3, fill(0xFFFFFFFF));
    }
    box(65, 84, 20, 5, 2.5, fill(0xFF1D4ED8));
    box(29, 48, 13, 24, 6, fill(0xFF1E3A8A));
    box(31, 50, 9, 20, 4.5, fill(0xFF3B82F6));
    box(108, 48, 13, 24, 6, fill(0xFF1E3A8A));
    box(110, 50, 9, 20, 4.5, fill(0xFF3B82F6));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
