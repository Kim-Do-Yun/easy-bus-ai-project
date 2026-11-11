import 'package:flutter/material.dart';

import '../models/bus_models.dart';
import '../services/device_service.dart';
import 'home_screen.dart' show EasyColors;

// 우측 버스 카드에서 여는 상세 화면이며 선택한 경로의 버스 구간을 실제 응답 순서대로 보여 준다.
class BusDetailScreen extends StatelessWidget {
  final BusRoute route;
  final DeviceService device;
  final Color accent;
  const BusDetailScreen({
    super.key,
    required this.route,
    required this.device,
    required this.accent,
  });

  // 경유 정류장 목록이 없으면 승하차 정류장만 사용하고 중간 정류장을 만들지 않는다.
  static List<Place> _stopsOf(RouteSegment segment) =>
      segment.stops.length >= 2 ? segment.stops : [segment.start, segment.end];

  String _arrivalText(BusArrival arrival) => arrival.available
      ? '약 ${arrival.minutes}분 후'
      : '도착정보 없음';

  // 음성안내 문장은 실제 도착정보와 정류장 정보로만 만든다.
  String _voiceGuide() {
    final buses = route.busSegments;
    final first = buses.first;
    final number = first.bus?.number ?? '';
    final arrival = first.arrival;
    final parts = <String>[
      arrival.available
          ? '$number번 버스는 현재 ${arrival.remainingStops != null ? '${arrival.remainingStops}정류장 전이며, ' : ''}약 ${arrival.minutes}분 뒤 ${first.start.name} 정류장에 도착합니다.'
          : '$number번 버스의 실시간 도착정보가 없습니다.',
      first.stops.length >= 2
          ? '${first.start.name}에서 타고 ${first.stops.length - 1}정류장 이동한 뒤 ${first.end.name}에서 내리세요.'
          : '${first.start.name}에서 타고 ${first.end.name}에서 내리세요.',
      for (final next in buses.skip(1))
        '${next.start.name}에서 ${next.bus?.number ?? ''}번 버스로 갈아타 ${next.end.name}에서 내리세요.',
    ];
    return parts.join(' ');
  }

  Future<void> _speak(BuildContext context) async {
    try {
      await device.speak(_voiceGuide());
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('음성 안내를 재생하지 못했습니다.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final buses = route.busSegments;
    final first = buses.first;
    return Scaffold(
      backgroundColor: EasyColors.surface,
      body: Column(
        children: [
          Material(
            color: EasyColors.white,
            elevation: 1,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Material(
                      color: EasyColors.surfaceContainer,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        // 뒤로 가면 결과 화면이 그대로 남아 있어 선택한 최적 경로가 유지된다.
                        onTap: () => Navigator.of(context).pop(),
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(
                            Icons.arrow_back,
                            size: 28,
                            color: EasyColors.onSurface,
                            semanticLabel: '이전 화면으로 이동',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                first.bus?.number ?? '',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  color: EasyColors.primary,
                                ),
                              ),
                              // 운행 상태 정보는 없으므로 실시간 도착정보가 있을 때만 운행중으로 표시한다.
                              if (first.arrival.available)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: EasyColors.secondaryContainer,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Text(
                                    '운행중',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: EasyColors.onSecondaryFixed,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          Text(
                            buses.length > 1
                                ? '${first.end.name} 방면 · 환승 ${buses.length - 1}회'
                                : '${first.end.name} 방면',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: EasyColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Material(
                      color: EasyColors.surfaceContainerHigh,
                      shape: const StadiumBorder(),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: () => _speak(context),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.volume_up,
                                size: 20,
                                color: EasyColors.primary,
                              ),
                              SizedBox(width: 6),
                              Text(
                                '음성안내',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: EasyColors.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                for (var i = 0; i < buses.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  _segmentCard(buses[i], i, buses.length),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _segmentCard(RouteSegment segment, int index, int count) {
    final stops = _stopsOf(segment);
    final hasList = segment.stops.length >= 2;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: EasyColors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: EasyColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.route, size: 24, color: EasyColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  count > 1
                      ? '${segment.bus?.number ?? ''}번 정류장 운행 구간'
                      : '정류장 운행 구간',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: EasyColors.onSurface,
                  ),
                ),
              ),
              if (hasList)
                Text(
                  '총 ${stops.length}개 정류장',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: EasyColors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          for (var k = 0; k < stops.length; k++)
            _stopRow(segment, stops, k, index),
          if (!hasList)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '경유 정류장 정보가 제공되지 않았습니다.',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: EasyColors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stopRow(
    RouteSegment segment,
    List<Place> stops,
    int k,
    int segmentIndex,
  ) {
    final stop = stops[k];
    final boarding = k == 0, alighting = k == stops.length - 1;
    final hasList = segment.stops.length >= 2;
    // 승차는 파란 버스 아이콘, 하차는 빨간 핀, 중간 정류장은 회색 원으로 구분한다.
    final Widget node = boarding
        ? _node(EasyColors.primary, const Icon(Icons.directions_bus, size: 20, color: EasyColors.white))
        : alighting
        ? _node(EasyColors.tertiary, const Icon(Icons.place, size: 20, color: EasyColors.white))
        : _node(
            EasyColors.surfaceContainerHighest,
            Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: EasyColors.outline,
                shape: BoxShape.circle,
              ),
            ),
          );
    final String? right = boarding
        ? (segmentIndex == 0 ? _arrivalText(segment.arrival) : null)
        : !hasList
        ? null
        : k == 1 && !alighting
        ? '다음'
        : '$k정류장 후';
    final details = [
      if (stop.arsId != null) '정류장 번호 ${stop.arsId}',
      if (alighting && segment.durationMinutes != null)
        '약 ${segment.durationMinutes!.round()}분 소요',
    ];
    const line = EasyColors.surfaceContainerHighest;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 40,
            child: Column(
              children: [
                Container(
                  width: 4,
                  height: 14,
                  color: boarding ? Colors.transparent : line,
                ),
                node,
                Expanded(
                  child: Container(
                    width: 4,
                    color: alighting ? Colors.transparent : line,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              stop.name,
                              style: TextStyle(
                                fontSize: boarding || alighting ? 22 : 20,
                                fontWeight: FontWeight.w600,
                                color: boarding
                                    ? EasyColors.primary
                                    : EasyColors.onSurface,
                              ),
                            ),
                            if (boarding)
                              _badge(
                                '승차',
                                EasyColors.primaryFixed,
                                EasyColors.onPrimaryFixed,
                              ),
                            if (alighting)
                              _badge(
                                '하차',
                                EasyColors.tertiaryContainer,
                                EasyColors.onTertiaryContainer,
                              ),
                          ],
                        ),
                      ),
                      if (right != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 4),
                          child: Text(
                            right,
                            style: TextStyle(
                              fontSize: boarding || alighting ? 16 : 14,
                              fontWeight: FontWeight.w700,
                              color: boarding
                                  ? accent
                                  : alighting
                                  ? EasyColors.tertiary
                                  : EasyColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (details.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        details.join(' · '),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: EasyColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _node(Color color, Widget child) => Container(
    width: 40,
    height: 40,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: child,
  );

  Widget _badge(String text, Color background, Color foreground) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: foreground,
      ),
    ),
  );
}
