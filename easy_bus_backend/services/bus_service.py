from datetime import datetime, timezone, timedelta
from hashlib import sha256
from math import ceil, isfinite
from time import monotonic
from threading import Lock
from urllib.parse import unquote

from easy_bus_backend.core import config
from easy_bus_backend.services.location_service import (ServiceError, validate_coordinate, distance_m,
                                       cached, request_json, tago_error)


_TAGO = "https://apis.data.go.kr/1613000/"
_STOPS = "BusSttnInfoInqireService"
_ROUTES = "BusRouteInfoInqireService"
_ARRIVALS = "ArvlInfoInqireService"
# ODsay 공식 도시코드이며 TAGO 도시코드와 서로 바꾸어 사용하지 않는다.
_ODSAY_WONJU = "10010"
_odsay_usage_lock = Lock()
_odsay_usage = {"date": None, "searchPubTransPathT": 0, "loadLane": 0}


def _invalid(provider="TAGO"):
    return ServiceError(f"{provider}_RESPONSE_INVALID", f"{provider} 응답 구조 또는 좌표를 확인할 수 없습니다.", 502)


def _text(value):
    if value is None or isinstance(value, (dict, list, bool)) or not str(value).strip():
        raise ValueError()
    return str(value).strip()


def _number(value):
    if isinstance(value, bool):
        raise ValueError()
    result = float(value)
    if not isfinite(result) or result < 0:
        raise ValueError()
    return result


def _region():
    if config.SERVICE_REGION.strip().lower() != "wonju":
        raise ServiceError("REGION_UNSUPPORTED", "현재는 원주시 버스 정보만 지원합니다.", 422)


def _tago_body(service, operation, params, deadline):
    if not config.TAGO_SERVICE_KEY.strip():
        raise ServiceError("TAGO_CONFIG_MISSING", "TAGO 서비스 키를 설정해 주세요.")
    result = request_json("TAGO", f"{_TAGO}{service}/{operation}",
                          {**params, "serviceKey": unquote(config.TAGO_SERVICE_KEY.strip()), "_type": "json"}, deadline)
    try:
        response = result["response"]
        tago_error(response["header"]["resultCode"])
        body = response["body"]
        if not isinstance(body, dict):
            raise ValueError()
        return body
    except (KeyError, TypeError, ValueError):
        raise _invalid() from None


def _items(body):
    items = body.get("items")
    if items in (None, ""):
        return []
    if not isinstance(items, dict):
        raise _invalid()
    rows = items.get("item", [])
    if rows in (None, ""):
        return []
    if isinstance(rows, dict):
        rows = [rows]
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise _invalid()
    return rows


def _tago_list(service, operation, params, deadline):
    rows = []
    total = None
    # 일부 페이지만 받은 목록을 전체 데이터처럼 사용하지 않는다.
    for page in range(1, 201):
        body = _tago_body(service, operation, {**params, "pageNo": page, "numOfRows": 1000}, deadline)
        try:
            count = int(body["totalCount"])
            if count < 0 or (total is not None and total != count):
                raise ValueError()
            total = count
        except (KeyError, TypeError, ValueError):
            raise _invalid() from None
        current = _items(body)
        rows.extend(current)
        if len(rows) == total:
            return rows
        if not current or len(rows) > total:
            raise _invalid()
    raise ServiceError("TAGO_PAGE_LIMIT", "정류장 목록이 조회 한도를 초과했습니다.", 502)


def _city(deadline):
    _region()
    city = config.TAGO_CITY_CODE.strip()
    if not city:
        raise ServiceError("TAGO_CITY_MISSING", "공식 도시코드 목록에서 원주시 TAGO 도시코드를 확인해 설정해 주세요.")

    def load():
        body = _tago_body(_STOPS, "getCtyCodeList", {}, deadline)
        if "items" not in body:
            raise _invalid()
        rows = _items(body)
        if not any(str(row.get("citycode")) == city and row.get("cityname") in ("원주", "원주시") for row in rows):
            raise ServiceError("TAGO_CITY_MISMATCH", "설정한 TAGO 도시코드가 서비스 가능한 원주시 코드인지 확인해 주세요.")
        return city

    return cached(("city", city), config.TAGO_CACHE_SECONDS, load, deadline)


def _all_stops(city, deadline):
    def load():
        rows = _tago_list(_STOPS, "getSttnNoList", {"cityCode": city}, deadline)
        stops = {}
        try:
            for row in rows:
                latitude, longitude = float(row["gpslati"]), float(row["gpslong"])
                validate_coordinate(latitude, longitude)
                stop = {"id": _text(row["nodeid"]), "name": _text(row["nodenm"]),
                        "latitude": latitude, "longitude": longitude}
                if stop["id"] in stops and stops[stop["id"]] != stop:
                    raise ValueError()
                stops[stop["id"]] = stop
        except (KeyError, TypeError, ValueError, ServiceError):
            raise _invalid() from None
        return list(stops.values())

    return cached(("stops", city), config.TAGO_CACHE_SECONDS, load, deadline)


def require_data(path, label: str) -> None:
    # 원본 자료의 컬럼과 노선 순서를 확인하기 전에는 추정 형식으로 읽지 않는다.
    if not path.is_file():
        raise ServiceError("BUS_DATA_UNAVAILABLE", f"{label} 데이터가 아직 준비되지 않았습니다.")
    raise ServiceError("BUS_DATA_ADAPTER_REQUIRED", f"{label} 원본 형식을 확인한 뒤 데이터 연결이 필요합니다.")


def nearby_stops(latitude: float, longitude: float, radius_m: float) -> list[dict]:
    validate_coordinate(latitude, longitude)
    if not isfinite(radius_m) or not 0 < radius_m <= 5000:
        raise ServiceError("RADIUS_INVALID", "정류장 검색 반경을 확인해 주세요.", 422)
    deadline = monotonic() + config.TRANSIT_REQUEST_SECONDS
    city = _city(deadline)
    result = []
    # 공식 근접 조회는 500m 고정이므로 도시 목록 캐시에서 요청 반경을 계산한다.
    for stop in _all_stops(city, deadline):
        distance = distance_m(latitude, longitude, stop["latitude"], stop["longitude"])
        if distance <= radius_m:
            result.append({**stop, "distance_m": round(distance, 1)})
    return sorted(result, key=lambda stop: (stop["distance_m"], stop["id"]))


def stop_routes(stop_id: str) -> list[dict]:
    deadline = monotonic() + config.TRANSIT_REQUEST_SECONDS
    city = _city(deadline)
    if not any(stop["id"] == stop_id for stop in _all_stops(city, deadline)):
        raise ServiceError("STOP_NOT_FOUND", "원주시 정류장 정보를 찾을 수 없습니다.", 404)
    return _stop_routes(city, stop_id, deadline)


def _stop_routes(city, stop_id, deadline):
    def load():
        rows = _tago_list(_STOPS, "getSttnThrghRouteList", {"cityCode": city, "nodeid": stop_id}, deadline)
        try:
            return list({str(row["routeid"]): {"id": _text(row["routeid"]), "number": _text(row["routeno"])}
                         for row in rows}.values())
        except (KeyError, TypeError, ValueError):
            raise _invalid() from None
    return cached(("stop_routes", city, stop_id), config.TAGO_CACHE_SECONDS, load, deadline)


def _route_stops(city, route_id, deadline):
    def load():
        rows = _tago_list(_ROUTES, "getRouteAcctoThrghSttnList", {"cityCode": city, "routeId": route_id}, deadline)
        try:
            for row in rows:
                if row.get("routeid") not in (None, "", route_id):
                    raise ValueError()
                row["nodeid"] = _text(row["nodeid"])
                row["nodeord"] = int(row["nodeord"])
                if row["nodeord"] < 0 or str(row.get("updowncd", "")) not in ("", "None", "0", "1"):
                    raise ValueError()
            if len({row["nodeord"] for row in rows}) != len(rows):
                raise ValueError()
            return sorted(rows, key=lambda row: row["nodeord"])
        except (KeyError, TypeError, ValueError):
            raise _invalid() from None
    return cached(("route_stops", city, route_id), config.TAGO_CACHE_SECONDS, load, deadline)


def _odsay(operation, params, deadline):
    if not config.ODSAY_API_KEY.strip():
        raise ServiceError("ODSAY_CONFIG_MISSING", "ODsay API 키를 설정해 주세요.")

    def load():
        # 프로세스 내 호출 시도를 API별로 집계한다. 재시작 및 다른 서버의 사용량은 포함하지 않는다.
        today = datetime.now(timezone(timedelta(hours=9))).date()
        with _odsay_usage_lock:
            if _odsay_usage["date"] != today:
                _odsay_usage.update(date=today, searchPubTransPathT=0, loadLane=0)
            if _odsay_usage["searchPubTransPathT"] + _odsay_usage["loadLane"] >= config.ODSAY_DAILY_CALL_LIMIT:
                raise ServiceError("ODSAY_QUOTA_EXCEEDED", "설정된 ODsay 일일 호출 예산을 초과했습니다.", 429)
            if monotonic() >= deadline:
                raise ServiceError("TRANSIT_TIMEOUT", "교통정보 조회 제한 시간을 초과했습니다.", 504)
            _odsay_usage[operation] += 1
        payload = request_json("ODSAY", f"https://api.odsay.com/v1/api/{operation}",
                               {**params, "apiKey": unquote(config.ODSAY_API_KEY.strip()), "output": "json"}, deadline)
        if "error" in payload:
            errors = payload["error"]
            error = errors[0] if isinstance(errors, list) and errors else errors
            if not isinstance(error, dict):
                raise _invalid("ODSAY")
            code = str(error.get("code", ""))
            if code in ("3", "4", "5", "-98", "-99"):
                raise ServiceError("ROUTE_NOT_FOUND", "이용 가능한 대중교통 경로가 없습니다.", 404)
            if code == "6":
                raise ServiceError("REGION_UNSUPPORTED", "ODsay가 지원하지 않는 지역입니다.", 422)
            # 알려지지 않은 공급자 오류 원문은 사용자나 로그에 전달하지 않는다.
            raise ServiceError("ODSAY_API_ERROR", "ODsay 요청에 실패했습니다. 인증 권한과 호출 한도를 확인해 주세요.", 502)
        result = payload.get("result")
        if not isinstance(result, dict):
            raise _invalid("ODSAY")
        return result

    # 경로 검색과 형상 조회를 별도 키로 캐시하여 각각의 반복 호출을 줄인다.
    return cached(("odsay", operation, tuple(sorted(params.items()))), config.ODSAY_CACHE_SECONDS, load, deadline)


def _odsay_place(part, prefix):
    latitude, longitude = float(part[prefix + "Y"]), float(part[prefix + "X"])
    try:
        validate_coordinate(latitude, longitude)
    except ServiceError:
        raise ValueError() from None
    return {"id": _text(part[prefix + "ID"]), "name": _text(part[prefix + "Name"]),
            "latitude": latitude, "longitude": longitude,
            "local_station_id": str(part.get(prefix + "LocalStationID") or "") or None,
            "ars_id": _ars_id(part.get(prefix + "ArsID"))}


def _ars_id(value):
    # 정류장 번호가 없거나 공란 기호이면 임의 번호를 만들지 않고 비워 둔다.
    text = "" if value is None or isinstance(value, (dict, list, bool)) else str(value).strip()
    return None if text in ("", "-", "0") else text


def _optional_number(value):
    # 선택 수치는 형식이 맞지 않으면 추정하지 않고 미제공으로 처리한다.
    try:
        return None if value in (None, "") else _number(value)
    except (TypeError, ValueError):
        return None


def _pass_stops(part, start, end):
    # 노선 순서의 경유 정류장은 승하차 정류장과 양 끝이 일치할 때만 사용한다.
    try:
        stations = part["passStopList"]["stations"]
        if not isinstance(stations, list) or len(stations) < 2:
            return []
        stops = []
        for station in stations:
            latitude, longitude = float(station["y"]), float(station["x"])
            validate_coordinate(latitude, longitude)
            stops.append({"id": _text(station["stationID"]), "name": _text(station["stationName"]),
                          "latitude": latitude, "longitude": longitude,
                          "local_station_id": str(station.get("localStationID") or "") or None,
                          "ars_id": _ars_id(station.get("arsID"))})
        if stops[0]["id"] != start["id"] or stops[-1]["id"] != end["id"]:
            return []
        return stops
    except (KeyError, TypeError, ValueError, ServiceError):
        return []


def _convert_path(path, origin, destination):
    parts = path["subPath"]
    if not isinstance(parts, list) or not parts:
        raise ValueError()
    if any(part["trafficType"] not in (2, 3) for part in parts):
        raise ServiceError("ROUTE_MODE_UNSUPPORTED", "원주시 시내버스 경로만 지원합니다.", 422)
    bus_parts = [part for part in parts if part["trafficType"] == 2]
    if not bus_parts:
        raise ValueError()
    # 승하차 도시코드는 ODsay 체계로 확인하며 GPS 좌표를 다른 지역으로 대체하지 않는다.
    if any(str(part[key]) != _ODSAY_WONJU for part in bus_parts
           for key in ("startStationCityCode", "endStationCityCode")):
        raise ServiceError("REGION_UNSUPPORTED", "원주시 안에서 승하차하는 버스 경로만 지원합니다.", 422)
    segments = []
    for index, part in enumerate(parts):
        segment = {"type": "BUS" if part["trafficType"] == 2 else "WALK",
                   "geometry_status": "unavailable", "coordinates": [],
                   "arrival": {"status": "unavailable", "minutes": None, "reason": "NOT_REQUESTED"},
                   "duration_minutes": _number(part["sectionTime"]),
                   "distance_m": _optional_number(part.get("distance")), "stops": []}
        if part["trafficType"] == 2:
            lane = part["lane"][0]
            segment.update(start=_odsay_place(part, "start"), end=_odsay_place(part, "end"),
                           bus={"id": _text(lane["busID"]), "number": _text(lane["busNo"]),
                                "local_route_id": str(lane.get("busLocalBlID") or "") or None})
            segment["stops"] = _pass_stops(part, segment["start"], segment["end"])
        else:
            previous = next((p for p in reversed(parts[:index]) if p["trafficType"] == 2), None)
            following = next((p for p in parts[index + 1:] if p["trafficType"] == 2), None)
            segment["start"] = _odsay_place(previous, "end") if previous else {"id": "origin", "name": "출발지", **origin}
            segment["end"] = _odsay_place(following, "start") if following else {"id": "destination", "name": "목적지", **destination}
        segments.append(segment)
    signature = repr((origin, destination, path["info"]["mapObj"]))
    return {"id": "odsay:" + sha256(signature.encode()).hexdigest()[:20], "segments": segments,
            "transfer_count": max(0, len(bus_parts) - 1),
            "duration_minutes": _number(path["info"]["totalTime"]),
            "total_walk_m": _optional_number(path["info"].get("totalWalk")),
            "recommendation": None}


def _walk_metrics(route):
    # 총 도보거리는 ODsay 합계를 우선하고, 없으면 모든 도보 구간 거리가 있을 때만 합산한다.
    segments = route["segments"]
    walks = [segment.get("distance_m") for segment in segments if segment["type"] == "WALK"]
    total = route.get("total_walk_m")
    if total is None and all(walk is not None for walk in walks):
        total = float(sum(walks))
    if total is None:
        return None

    def edge(segment):
        # 버스 구간으로 시작하거나 끝나면 해당 쪽 도보거리는 0으로 본다.
        return 0.0 if segment["type"] == "BUS" else segment.get("distance_m")
    access, egress = edge(segments[0]), edge(segments[-1])
    edges = None if access is None or egress is None else access + egress
    return {"total": total, "edges": edges}


def _bus_signature(route):
    return tuple((segment["bus"]["number"], segment["start"]["id"], segment["end"]["id"])
                 for segment in route["segments"] if segment["type"] == "BUS")


def _similar(first, second):
    # 같은 승하차·노선 조합이거나 같은 버스 순서에 도보·시간 차이가 작으면 중복으로 본다.
    if _bus_signature(first) == _bus_signature(second):
        return True
    if [s[0] for s in _bus_signature(first)] != [s[0] for s in _bus_signature(second)]:
        return False
    first_walk, second_walk = _walk_metrics(first), _walk_metrics(second)
    if first_walk is None or second_walk is None:
        return False
    return (abs(first_walk["total"] - second_walk["total"]) < config.ROUTE_SIMILAR_WALK_M
            and abs(first["duration_minutes"] - second["duration_minutes"]) < config.ROUTE_SIMILAR_MINUTES)


def _recommend(routes):
    # 후보 순서와 무관하게 최적 1·최적 2를 고르고 선택된 후보의 위치만 반환한다.
    fastest = min(route["duration_minutes"] for route in routes)
    fewest = min(route["transfer_count"] for route in routes)
    known = [(index, route, _walk_metrics(route)) for index, route in enumerate(routes)]
    known = [item for item in known if item[2] is not None]
    acceptable = [item for item in known
                  if item[1]["duration_minutes"] <= fastest * config.ROUTE_BEST1_MAX_TIME_RATIO
                  and item[1]["duration_minutes"] - fastest <= config.ROUTE_BEST1_MAX_EXTRA_MINUTES
                  and item[1]["transfer_count"] - fewest <= config.ROUTE_BEST1_MAX_EXTRA_TRANSFERS]
    if not acceptable:
        # 도보거리를 확인할 수 있는 후보가 없으면 최적 2 성격의 가장 빠른 경로만 추천한다.
        index = min(range(len(routes)), key=lambda i: (routes[i]["duration_minutes"], routes[i]["transfer_count"], i))
        routes[index]["recommendation"] = "BEST_TIME"
        return [index]
    best_index, best, best_walk = min(acceptable, key=lambda item: (
        item[2]["total"] + item[1]["transfer_count"] * config.ROUTE_TRANSFER_WALK_PENALTY_M,
        item[2]["edges"] if item[2]["edges"] is not None else float("inf"),
        item[1]["duration_minutes"], item[0]))
    best["recommendation"] = "BEST_WALK"
    alternatives = []
    for index, route, walk in known:
        if index == best_index or _similar(best, route):
            continue
        if walk["total"] - best_walk["total"] > config.ROUTE_BEST2_MAX_EXTRA_WALK_M:
            continue
        faster = best["duration_minutes"] - route["duration_minutes"] >= config.ROUTE_BEST2_MIN_TIME_GAIN_MINUTES
        fewer_transfers = (route["transfer_count"] < best["transfer_count"]
                           and route["duration_minutes"] - best["duration_minutes"]
                           <= config.ROUTE_BEST2_TRANSFER_TIME_TOLERANCE_MINUTES)
        # 시간·환승 어느 쪽에도 실질적 이점이 없으면 최적 2로 추천하지 않는다.
        if faster or fewer_transfers:
            alternatives.append((route["duration_minutes"], route["transfer_count"], walk["total"], index))
    if not alternatives:
        return [best_index]
    second_index = min(alternatives)[3]
    routes[second_index]["recommendation"] = "BEST_TIME"
    return [best_index, second_index]


def _geometry(route, map_object, deadline):
    buses = [segment for segment in route["segments"] if segment["type"] == "BUS"]
    try:
        # 기준점을 0:0으로 지정해 실제 경위도만 받으며 정류장 직선은 생성하지 않는다.
        pieces = map_object.split("@")
        if ":" in pieces[0] and len(pieces[0].split(":")) == 2:
            pieces = pieces[1:]
        if len(pieces) != len(buses):
            return
        for piece, bus in zip(pieces, buses):
            fields = piece.split(":")
            if len(fields) != 4 or fields[0] != bus["bus"]["id"] or fields[1] != "1":
                return
            # 전체 노선 형상을 승하차 구간 형상으로 표시하지 않는다.
            if min(int(fields[2]), int(fields[3])) < 0:
                return
        result = _odsay("loadLane", {"mapObject": "0:0@" + "@".join(pieces)}, deadline)
        lanes = result["lane"]
        if not isinstance(lanes, list) or len(lanes) != len(buses):
            raise ValueError()
        for lane, segment in zip(lanes, buses):
            sections = lane["section"]
            # 여러 분리 형상을 한 선으로 이어 그리는 것은 기존 단일 폴리라인 계약에서 제외한다.
            if lane["class"] != 1 or len(sections) != 1:
                continue
            coordinates = []
            for point in sections[0]["graphPos"]:
                latitude, longitude = float(point["y"]), float(point["x"])
                validate_coordinate(latitude, longitude)
                coordinates.append({"latitude": latitude, "longitude": longitude})
            if len(coordinates) >= 2:
                segment["coordinates"] = coordinates
                segment["geometry_status"] = "available"
    except ServiceError as exc:
        for segment in buses:
            segment["geometry_reason"] = exc.code
    except (KeyError, TypeError, ValueError, IndexError, AttributeError):
        for segment in buses:
            segment["geometry_reason"] = "ODSAY_RESPONSE_INVALID"


def _matches(place, stops):
    name = "".join(place["name"].split())
    candidates = [stop for stop in stops if "".join(stop["name"].split()) == name
                  and distance_m(place["latitude"], place["longitude"], stop["latitude"], stop["longitude"])
                  <= config.STOP_MATCH_RADIUS_M]
    # 공통 ID라는 보장이 없으므로 접두어 제거나 숫자 일부 일치로 ID를 만들지 않는다.
    exact = [stop for stop in candidates if stop["id"] == place.get("local_station_id")]
    return exact or candidates


def _arrival(segment, city, stops, deadline):
    starts, ends = _matches(segment["start"], stops), _matches(segment["end"], stops)
    if not starts or not ends:
        return {"status": "unavailable", "reason": "STOP_MATCH_NOT_FOUND"}
    if len(starts) > 4 or len(ends) > 4:
        return {"status": "unavailable", "reason": "STOP_MATCH_AMBIGUOUS"}
    matches = []
    for start in starts:
        routes = [route for route in _stop_routes(city, start["id"], deadline)
                  if route["number"] == segment["bus"]["number"]]
        exact = [route for route in routes if route["id"] == segment["bus"].get("local_route_id")]
        routes = exact or routes
        if len(routes) > 6:
            return {"status": "unavailable", "reason": "ROUTE_MATCH_AMBIGUOUS"}
        for route in routes:
            sequence = _route_stops(city, route["id"], deadline)
            start_indices = [i for i, stop in enumerate(sequence) if stop["nodeid"] == start["id"]]
            if len(start_indices) != 1:
                continue
            first = start_indices[0]
            for end in ends:
                end_indices = [i for i, stop in enumerate(sequence) if stop["nodeid"] == end["id"]]
                if len(end_indices) != 1 or first >= end_indices[0]:
                    continue
                last = end_indices[0]
                directions = {str(stop["updowncd"]) for stop in sequence[first:last + 1]
                              if stop.get("updowncd") not in (None, "")}
                if len(directions) > 1:
                    continue
                matches.append((start, end, route, sequence[first], sequence[last]))
    if len(matches) != 1:
        return {"status": "unavailable", "reason": "ROUTE_MATCH_AMBIGUOUS" if matches else "ROUTE_MATCH_NOT_FOUND"}
    start, end, route, first, last = matches[0]
    segment["start"]["tago_id"], segment["end"]["tago_id"] = start["id"], end["id"]
    direction = first.get("updowncd")
    segment["bus"].update(tago_id=route["id"], direction=None if direction in (None, "") else str(direction),
                          boarding_order=first["nodeord"], alighting_order=last["nodeord"])

    def load():
        return {"rows": _tago_list(_ARRIVALS, "getSttnAcctoArvlPrearngeInfoList",
                                   {"cityCode": city, "nodeId": start["id"]}, deadline),
                "observed_at": datetime.now(timezone.utc).isoformat()}
    payload = cached(("arrivals", city, start["id"]), config.TAGO_ARRIVAL_CACHE_SECONDS, load, deadline)
    choices = []
    malformed = False
    for row in payload["rows"]:
        if str(row.get("routeid")) != route["id"] or str(row.get("nodeid")) != start["id"]:
            continue
        try:
            seconds = int(_number(row["arrtime"]))
            remaining = int(_number(row["arrprevstationcnt"]))
            choices.append((seconds, remaining))
        except (KeyError, TypeError, ValueError):
            malformed = True
    if not choices:
        return {"status": "unavailable", "reason": "TAGO_RESPONSE_INVALID" if malformed else "ARRIVAL_NOT_AVAILABLE"}
    seconds, remaining = min(choices)
    return {"status": "available", "minutes": ceil(seconds / 60), "seconds": seconds,
            "remaining_stops": remaining, "observed_at": payload["observed_at"], "reason": None}


def find_routes(origin: dict, destination: dict) -> list[dict]:
    validate_coordinate(**origin)
    validate_coordinate(**destination)
    _region()
    deadline = monotonic() + config.TRANSIT_REQUEST_SECONDS
    result = _odsay("searchPubTransPathT", {"SX": origin["longitude"], "SY": origin["latitude"],
                                          "EX": destination["longitude"], "EY": destination["latitude"],
                                          "SearchType": 0, "SearchPathType": 2, "OPT": 0}, deadline)
    routes, paths = [], []
    unsupported = False
    try:
        if result["searchType"] != 0:
            raise ServiceError("REGION_UNSUPPORTED", "원주시 도시 내 버스 경로만 지원합니다.", 422)
        raw_paths = result["path"]
        if not isinstance(raw_paths, list):
            raise ValueError()
        for path in raw_paths:
            try:
                routes.append(_convert_path(path, origin, destination))
                paths.append(path)
            except ServiceError as exc:
                if exc.code not in ("REGION_UNSUPPORTED", "ROUTE_MODE_UNSUPPORTED"):
                    raise
                unsupported = True
        if not routes:
            if unsupported:
                raise ServiceError("REGION_UNSUPPORTED", "검색된 경로는 원주시 시내버스 지원 범위를 벗어납니다.", 422)
            raise ServiceError("ROUTE_NOT_FOUND", "원주시에서 이용 가능한 버스 경로가 없습니다.", 404)
    except (KeyError, TypeError, ValueError, IndexError):
        raise _invalid("ODSAY") from None
    # 최적 1·최적 2를 앞쪽에 두어 기존처럼 첫 후보를 쓰는 앱도 최적 1을 받도록 한다.
    selected = _recommend(routes)
    order = selected + [index for index in range(len(routes)) if index not in selected]
    routes, paths = [routes[index] for index in order], [paths[index] for index in order]
    detailed = routes[:len(selected)]
    # 앱이 표시하는 추천 후보에만 상세 호출을 수행하고 나머지 후보는 기본 경로를 보존한다.
    for route, path in zip(detailed, paths):
        _geometry(route, path["info"]["mapObj"], deadline)
    try:
        city = _city(deadline)
        stops = _all_stops(city, deadline)
        for route in detailed:
            for segment in route["segments"]:
                if segment["type"] == "BUS":
                    try:
                        segment["arrival"] = _arrival(segment, city, stops, deadline)
                    except ServiceError as exc:
                        segment["arrival"] = {"status": "unavailable", "reason": exc.code}
    except ServiceError as exc:
        for route in detailed:
            for segment in route["segments"]:
                if segment["type"] == "BUS":
                    segment["arrival"] = {"status": "unavailable", "reason": exc.code}
    return routes
