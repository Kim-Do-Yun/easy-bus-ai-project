class Place {
  final String id, name;
  final double latitude, longitude;
  const Place(this.id, this.name, this.latitude, this.longitude);
  factory Place.fromJson(Map<String, dynamic> j) => Place(
    j['id'] as String,
    j['name'] as String,
    (j['latitude'] as num).toDouble(),
    (j['longitude'] as num).toDouble(),
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
  BusArrival.fromJson(Map<String, dynamic> j)
    : status = j['status'],
      minutes = j['minutes'];
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
  RouteSegment.fromJson(Map<String, dynamic> j)
    : type = j['type'],
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
  BusRoute.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      transferCount = j['transfer_count'],
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
}
