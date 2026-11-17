class Place {
  final String id, name;
  final double latitude, longitude;
  // 정류장 번호는 서버가 실제 값을 제공한 경우에만 채운다.
  final String? arsId;
  // 장소 검색 후보의 주소와 TAGO 정류장 ID는 서버가 제공한 경우에만 채운다.
  // 장소 구분은 PLACE(장소명), ADDRESS(주소), STOP(정류장) 중 서버가 준 값만 사용한다.
  final String? address, tagoId, kind;
  const Place(
    this.id,
    this.name,
    this.latitude,
    this.longitude, {
    this.arsId,
    this.address,
    this.tagoId,
    this.kind,
  });
  factory Place.fromJson(Map<String, dynamic> j) => Place(
    j['id'] as String,
    j['name'] as String,
    (j['latitude'] as num).toDouble(),
    (j['longitude'] as num).toDouble(),
    arsId: j['ars_id'] as String?,
    address: j['address'] as String?,
    tagoId: j['tago_id'] as String?,
    kind: j['kind'] as String?,
  );
  Map<String, double> get coordinate => {
    'latitude': latitude,
    'longitude': longitude,
  };
}

class BusStop extends Place {
  final double? distanceM;
  BusStop(
    super.id,
    super.name,
    super.latitude,
    super.longitude,
    this.distanceM,
  );
  factory BusStop.fromJson(Map<String, dynamic> j) => BusStop(
    j['id'],
    j['name'],
    (j['latitude'] as num).toDouble(),
    (j['longitude'] as num).toDouble(),
    (j['distance_m'] as num?)?.toDouble(),
  );
}

class Interpretation {
  final String intent;
  final String? origin, destination, clarificationMessage;
  final bool useCurrentLocation, needsClarification;
  Interpretation.fromJson(Map<String, dynamic> j)
    : intent = j['intent'],
      origin = j['origin'],
      destination = j['destination'],
      useCurrentLocation = j['use_current_location'],
      needsClarification = j['needs_clarification'],
      clarificationMessage = j['clarification_message'];
}

class BusLine {
  final String id, number;
  BusLine.fromJson(Map<String, dynamic> j) : id = j['id'], number = j['number'];
}

class BusArrival {
  final String status;
  final int? minutes;
  // 남은 정류장 수는 TAGO가 제공한 경우에만 표시한다.
  final int? remainingStops;
  // 미제공 사유 코드이며 매칭 실패와 도착 예정 버스 없음을 구분하는 데만 사용한다.
  final String? reason;
  // 다음 도착 차량은 TAGO 응답에 두 번째 차량이 있을 때만 채운다.
  final int? nextMinutes, nextRemainingStops;
  BusArrival.fromJson(Map<String, dynamic> j)
    : status = j['status'],
      minutes = j['minutes'],
      remainingStops = j['remaining_stops'],
      reason = j['reason'] as String?,
      nextMinutes = j['next_minutes'] as int?,
      nextRemainingStops = j['next_remaining_stops'] as int?;
  bool get available => status == 'available' && minutes != null;
  // 도착정보가 없을 때 사용자에게 보여 줄 사유이며 임의의 도착시간은 만들지 않는다.
  String? get unavailableReason {
    if (available) return null;
    final code = reason ?? '';
    if (code == 'ARRIVAL_NOT_AVAILABLE')
      return '현재 이 정류장에 도착 예정인 버스가 없습니다.';
    if (code.startsWith('STOP_MATCH'))
      return '실시간 정보의 정류장을 확인하지 못했습니다.';
    if (code.startsWith('ROUTE_MATCH'))
      return '실시간 정보의 버스 노선을 확인하지 못했습니다.';
    if (code.endsWith('_TIMEOUT'))
      return '실시간 정보 응답이 지연되어 표시하지 못했습니다.';
    if (code.endsWith('_AUTH_FAILED') ||
        code.endsWith('_QUOTA_EXCEEDED') ||
        code.endsWith('_CONFIG_MISSING') ||
        code.startsWith('TAGO_'))
      return '실시간 버스 정보 서비스 인증 또는 연결에 문제가 있습니다.';
    return '이 경로는 실시간 도착정보를 제공하지 않습니다.';
  }
  String get label => status == 'available' && minutes != null
      ? '도착 예정 $minutes분'
      : '실시간 도착정보 미제공';
}

class RouteSegment {
  final String type, geometryStatus;
  final Place start, end;
  final BusLine? bus;
  final BusArrival arrival;
  final List<Place> coordinates;
  // 구간 거리·시간과 경유 정류장은 이전 서버 응답에 없으면 미제공으로 둔다.
  final double? distanceM, durationMinutes;
  final List<Place> stops;
  RouteSegment.fromJson(Map<String, dynamic> j)
    : type = j['type'],
      distanceM = (j['distance_m'] as num?)?.toDouble(),
      durationMinutes = (j['duration_minutes'] as num?)?.toDouble(),
      stops = ((j['stops'] as List?) ?? const [])
          .map((p) => Place.fromJson(p))
          .toList(),
      geometryStatus = j['geometry_status'],
      start = Place.fromJson(j['start']),
      end = Place.fromJson(j['end']),
      bus = j['bus'] == null ? null : BusLine.fromJson(j['bus']),
      arrival = BusArrival.fromJson(j['arrival']),
      coordinates = (j['coordinates'] as List)
          .map(
            (p) => Place(
              '',
              '',
              (p['latitude'] as num).toDouble(),
              (p['longitude'] as num).toDouble(),
            ),
          )
          .toList();
  // 도보 경로선은 제공되지 않으므로 서버가 준 도보 거리와 시간만 문장으로 안내한다.
  String? get walkText {
    if (type != 'WALK') return null;
    final parts = [
      if (distanceM != null && distanceM! > 0)
        distanceM! >= 1000
            ? '약 ${(distanceM! / 1000).toStringAsFixed(1)}km'
            : '약 ${distanceM!.round()}m',
      if (durationMinutes != null && durationMinutes! > 0)
        '약 ${durationMinutes!.round()}분',
    ];
    return parts.isEmpty ? null : '도보 ${parts.join(', ')}';
  }
}

class BusRoute {
  final String id;
  final int transferCount;
  final List<RouteSegment> segments;
  // 총 소요시간·총 도보거리·최적 경로 구분(BEST_WALK, BEST_TIME)은 서버 값만 사용한다.
  final double? durationMinutes, totalWalkM;
  final String? recommendation;
  BusRoute.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      transferCount = j['transfer_count'],
      durationMinutes = (j['duration_minutes'] as num?)?.toDouble(),
      totalWalkM = (j['total_walk_m'] as num?)?.toDouble(),
      recommendation = j['recommendation'] as String?,
      segments = (j['segments'] as List)
          .map((s) => RouteSegment.fromJson(s))
          .toList();
  String get guidance => segments
      .map(
        (s) => s.type == 'BUS'
            ? '${s.start.name}에서 ${s.bus?.number ?? ""}번 버스를 타고 ${s.end.name}에서 내리세요.'
            : '${s.start.name}에서 ${s.end.name}까지 도보 구간입니다.${s.walkText == null ? '' : ' ${s.walkText}.'}',
      )
      .join(' ');
  List<RouteSegment> get busSegments =>
      segments.where((s) => s.type == 'BUS').toList();
  // 총 도보시간은 모든 도보 구간의 ODsay 소요시간이 있을 때만 합산하고, 하나라도 없으면 표시하지 않는다.
  double? get totalWalkMinutes {
    final walks = segments.where((s) => s.type == 'WALK').toList();
    if (walks.any((s) => s.durationMinutes == null)) return null;
    return walks.fold<double>(0, (sum, s) => sum + s.durationMinutes!);
  }
}
