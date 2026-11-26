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
  // 음성 안내용 도착정보 문장이며 TAGO가 실제로 제공한 값만 사용하고 없는 값은 만들지 않는다.
  // 서버는 음수·형식 오류 값을 미제공으로 처리하므로 0분·0정류장은 곧 도착하는 실제 값으로 본다.
  String voiceText(String number, String stopName) {
    final bus = number.trim().isEmpty ? '버스' : '${number.trim()}번 버스';
    final valid = status == 'available';
    final m = valid && minutes != null && minutes! >= 0 ? minutes : null;
    final r = valid && remainingStops != null && remainingStops! >= 0
        ? remainingStops
        : null;
    final stop = stopName.trim().isEmpty ? '' : '${stopLabel(stopName)}에 ';
    final time = m == null
        ? null
        : m == 0
        ? '곧 $stop도착할 예정입니다.'
        : '약 $m분 후 $stop도착할 예정입니다.';
    if (r != null && r > 0 && time != null) return '$bus는 현재 $r정류장 전이며, $time';
    if (time != null) return '$bus는 $time';
    if (r != null) {
      return r > 0 ? '$bus는 현재 $r정류장 전에 있습니다.' : '$bus는 곧 도착할 예정입니다.';
    }
    return '$bus의 실시간 도착정보를 확인할 수 없습니다.';
  }

  // 정류장 이름 뒤에 '정류장'을 붙이되 이미 정류장·정류소로 끝나면 그대로 사용한다.
  static String stopLabel(String name) {
    final text = name.trim();
    return text.endsWith('정류장') || text.endsWith('정류소') ? text : '$text 정류장';
  }
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

  // 음성 안내용 도보 거리·시간이며 단위를 읽기 쉬운 말로 쓴다.
  // 값이 없으면 빈 문자열, 거리와 시간이 모두 0이면 걸을 필요가 없는 구간으로 보고 null을 반환한다.
  String? get walkSpeech {
    if (type != 'WALK') return null;
    final d = distanceM, m = durationMinutes;
    if ((d != null || m != null) && (d ?? 0) <= 0 && (m ?? 0) <= 0) return null;
    final meters = d ?? 0;
    final hasDistance = meters > 0;
    final parts = [
      if (hasDistance)
        meters >= 1000
            ? '약 ${(meters / 1000).toStringAsFixed(1)}킬로미터'
            : '약 ${meters.round()}미터',
      // 거리 문구가 앞에 있으면 시간 문구의 '약'을 반복하지 않는다.
      if (m != null && m > 0) hasDistance ? '${m.round()}분' : '약 ${m.round()}분',
    ];
    return parts.join(', ');
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
  // 경로 결과 화면의 음성 안내 문장이며 경로 검색 응답에 담긴 이 경로의 값만으로 만든다.
  // 총 소요시간·환승 → 승차 정류장까지 도보 → 첫 버스 실시간 도착정보 → 승차·이동 정류장 수·하차 → 환승 → 목적지까지 도보 순서이다.
  // 실시간 도착정보는 첫 승차 버스만 안내하며, 환승 버스의 현재 조회값은 환승 시점 도착시간으로 오해할 수 있어 읽지 않는다.
  String get guidance {
    final parts = <String>[];
    final total = durationMinutes != null && durationMinutes! > 0
        ? '약 ${durationMinutes!.round()}분'
        : null;
    final transfer = transferCount > 0
        ? '${const ['한', '두', '세', '네'].elementAtOrNull(transferCount - 1) ?? '$transferCount'} 번 환승해야 합니다'
        : null;
    if (total != null) {
      parts.add(
        transfer == null ? '목적지까지 $total이 걸립니다.' : '목적지까지 $total이 걸리며, $transfer.',
      );
    } else if (transfer != null) {
      parts.add('목적지까지 $transfer.');
    }
    var busIndex = 0;
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      if (s.type == 'BUS') {
        final number = s.bus?.number.trim() ?? '';
        final bus = number.isEmpty ? '버스' : '$number번 버스';
        // 이동 정류장 수는 승하차 정류장이 양 끝과 일치하는 경유 정류장 목록이 있을 때만 안내한다.
        final ride = s.stops.length >= 2
            ? '${s.stops.length - 1}개 정류장을 이동한 후'
            : '이동한 후';
        final end = BusArrival.stopLabel(s.end.name);
        if (busIndex == 0) {
          parts.add(s.arrival.voiceText(number, s.start.name));
          parts.add('$bus에 탑승하여 $ride $end에서 내리세요.');
        } else {
          parts.add(
            '${BusArrival.stopLabel(s.start.name)}에서 $bus로 갈아타고 $ride $end에서 내리세요.',
          );
        }
        busIndex++;
        continue;
      }
      final walk = s.walkSpeech;
      if (walk == null) continue;
      final amount = walk.isEmpty ? '' : '$walk ';
      if (i == segments.length - 1) {
        parts.add('하차 후 $amount걸어가시면 목적지에 도착합니다.');
      } else {
        parts.add(
          '${busIndex == 0 ? '' : '환승할 '}${BusArrival.stopLabel(s.end.name)}까지 $amount걸어가세요.',
        );
      }
    }
    return parts.join(' ');
  }
  List<RouteSegment> get busSegments =>
      segments.where((s) => s.type == 'BUS').toList();
  // 총 도보시간은 모든 도보 구간의 ODsay 소요시간이 있을 때만 합산하고, 하나라도 없으면 표시하지 않는다.
  double? get totalWalkMinutes {
    final walks = segments.where((s) => s.type == 'WALK').toList();
    if (walks.any((s) => s.durationMinutes == null)) return null;
    return walks.fold<double>(0, (sum, s) => sum + s.durationMinutes!);
  }
}
