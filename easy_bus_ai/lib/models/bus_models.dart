class Place {
  final String id, name;
  final double latitude, longitude;
  // 정류장 번호는 서버가 실제 값을 제공한 경우에만 채운다.
  final String? arsId;
  const Place(this.id, this.name, this.latitude, this.longitude, {this.arsId});
  factory Place.fromJson(Map<String, dynamic> j) => Place(
    j['id'] as String,
    j['name'] as String,
    (j['latitude'] as num).toDouble(),
    (j['longitude'] as num).toDouble(),
    arsId: j['ars_id'] as String?,
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
  BusArrival.fromJson(Map<String, dynamic> j)
    : status = j['status'],
      minutes = j['minutes'],
      remainingStops = j['remaining_stops'];
  bool get available => status == 'available' && minutes != null;
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
            : '${s.start.name}에서 ${s.end.name}까지 도보 구간입니다.',
      )
      .join(' ');
  List<RouteSegment> get busSegments =>
      segments.where((s) => s.type == 'BUS').toList();
}
