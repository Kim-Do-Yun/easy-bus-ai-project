from math import asin, cos, isfinite, radians, sin, sqrt
from concurrent.futures import Future, TimeoutError as FutureTimeout
from copy import deepcopy
from hashlib import sha256
from html import unescape
import re
from threading import Lock
from time import monotonic
from xml.etree import ElementTree
import logging
from urllib.parse import quote, quote_plus, unquote

import httpx

from easy_bus_backend.core import config


class ServiceError(Exception):
    def __init__(self, code: str, message: str, status: int = 503):
        self.code, self.message, self.status = code, message, status
        super().__init__(message)


def validate_coordinate(latitude: float, longitude: float) -> None:
    # NaN 및 무한대도 유효한 GPS 좌표로 받아들이지 않는다.
    if not (isfinite(latitude) and isfinite(longitude)
            and -90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise ServiceError("INVALID_COORDINATE", "위도와 경도를 확인해 주세요.", 422)


def distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    validate_coordinate(lat1, lon1)
    validate_coordinate(lat2, lon2)
    a = sin(radians(lat2 - lat1) / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2) ** 2
    return 6371000 * 2 * asin(sqrt(min(1, max(0, a))))


def search_locations(query: str) -> list[dict]:
    # 장소명은 네이버 지역 검색, 주소는 네이버 Geocoding, 정류장은 TAGO 원주시 목록으로 찾아 실제 좌표 후보만 반환한다.
    if not query.strip():
        raise ServiceError("LOCATION_QUERY_EMPTY", "검색할 장소나 주소를 입력해 주세요.", 422)
    query = query.strip()
    # 순환 참조를 피하기 위해 정류장 목록 조회는 호출 시점에 가져온다.
    from easy_bus_backend.services import bus_service
    results, errors = [], []
    # 한 공급자의 실패가 다른 공급자의 검색 결과를 가리지 않도록 각각 조회한다.
    for loader in (_local_search, _geocode, bus_service.search_stop_places):
        try:
            results.extend(loader(query))
        except ServiceError as exc:
            errors.append(exc)
    places = _merge_places(results)
    if places:
        return places
    # 결과가 하나도 없을 때만 장소명 검색 오류를 우선하여 인증·지연 오류를 그대로 안내한다.
    failures = [error for error in errors if error.code != "LOCATION_NOT_FOUND"]
    if failures:
        raise failures[0]
    raise ServiceError("LOCATION_NOT_FOUND",
                       "검색 결과가 없습니다. 원주시의 장소명, 도로명·지번 주소 또는 버스 정류장 이름으로 다시 입력해 주세요.", 404)


def _merge_places(places: list[dict]) -> list[dict]:
    # 이름 또는 주소가 같고 100m 이내인 후보는 같은 장소로 보고 먼저 찾은 결과(장소명 > 주소 > 정류장)를 남긴다.
    merged = []
    for place in places:
        name = "".join(place["name"].split())
        address = place.get("address")
        if any(kept["id"] == place["id"]
               or (("".join(kept["name"].split()) == name or (address and kept.get("address") == address))
                   and distance_m(kept["latitude"], kept["longitude"], place["latitude"], place["longitude"]) <= 100)
               for kept in merged):
            continue
        merged.append(place)
    # 원주시 주소 또는 원주시 정류장 후보를 앞에 두고, 같은 순위 안에서는 공급자 순서를 유지한다.
    return sorted(merged, key=lambda p: not (p.get("kind") == "STOP" or "원주" in (p.get("address") or "")))


def _local_search(query: str) -> list[dict]:
    # NAVER API HUB 지역 검색 API는 서버에서만 호출하여 Client Secret이 앱에 포함되지 않게 한다.
    if not config.NAVER_SEARCH_CLIENT_ID.strip() or not config.NAVER_SEARCH_CLIENT_SECRET.strip():
        raise ServiceError("NAVER_SEARCH_CONFIG_MISSING", "네이버 장소 검색 API 인증정보를 설정해 주세요.")
    deadline = monotonic() + config.TRANSIT_REQUEST_SECONDS
    # 원주가 빠진 검색어는 원주를 붙인 검색도 함께 수행해 원주시 장소를 우선 확보한다.
    queries = [query] if "원주" in query else ["원주 " + query, query]
    places = []
    for text in queries:
        places.extend(cached(("local", text), 300, lambda text=text: _local_items(text, deadline), deadline))
    return places


def _local_items(text: str, deadline: float) -> list[dict]:
    try:
        # API HUB 개발 가이드의 지역 검색 경로와 NCP API Gateway 공통 인증 헤더를 사용한다.
        result = request_json("NAVER_SEARCH", "https://naverapihub.apigw.ntruss.com/search/v1/local",
                              {"query": text, "display": 5, "start": 1, "sort": "random", "format": "json"},
                              deadline,
                              headers={"X-NCP-APIGW-API-KEY-ID": config.NAVER_SEARCH_CLIENT_ID.strip(),
                                       "X-NCP-APIGW-API-KEY": config.NAVER_SEARCH_CLIENT_SECRET.strip()})
    except ServiceError as exc:
        # 공급자 코드명 대신 사용자가 이해할 수 있는 안내로 바꾸고 오류 코드는 유지한다.
        if exc.code == "NAVER_SEARCH_AUTH_FAILED":
            # 401은 인증 실패, 403은 애플리케이션에 지역 검색 API가 선택되지 않은 경우 등 호출 불허이다.
            raise ServiceError(exc.code, "네이버 장소 검색 인증에 실패했습니다. API HUB의 Client ID·Secret과 지역 검색 API 선택 여부를 확인해 주세요.", exc.status) from None
        if exc.code == "NAVER_SEARCH_HTTP_ERROR":
            raise ServiceError(exc.code, "네이버 장소 검색 요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.", exc.status) from None
        if exc.code == "NAVER_SEARCH_QUOTA_EXCEEDED":
            raise ServiceError(exc.code, "네이버 장소 검색 호출 한도를 초과했습니다. 잠시 후 다시 시도해 주세요.", 429) from None
        if exc.code == "NAVER_SEARCH_TIMEOUT":
            raise ServiceError(exc.code, "장소 검색 응답이 지연되고 있습니다. 잠시 후 다시 시도해 주세요.", 504) from None
        raise
    items = result.get("items")
    if not isinstance(items, list):
        raise ServiceError("NAVER_SEARCH_RESPONSE_INVALID", "장소 검색 응답 형식을 확인할 수 없습니다.", 502)
    places = []
    for item in items:
        try:
            # 제목의 강조 태그와 HTML 문자를 제거한 장소명만 사용한다.
            name = unescape(re.sub(r"<[^>]+>", "", str(item["title"]))).strip()
            address = str(item.get("roadAddress") or item.get("address") or "").strip() or None
            # 지역 검색 좌표는 WGS84 기준이며 mapx가 경도, mapy가 위도이다.
            longitude, latitude = _local_coordinate(item["mapx"], item["mapy"])
            validate_coordinate(latitude, longitude)
        except (KeyError, TypeError, ValueError, ServiceError):
            continue
        if not name:
            continue
        places.append({"id": "naver_local:" + sha256(f"{name}|{address}".encode()).hexdigest()[:20],
                       "name": name, "address": address, "kind": "PLACE",
                       "latitude": latitude, "longitude": longitude})
    return places


def _local_coordinate(mapx, mapy) -> tuple[float, float]:
    # 문서 예시가 자리표시자뿐이라 경위도 그대로인지 10^7을 곱한 정수인지 확정하지 않고,
    # 두 표기 중 국내 범위에 드는 값만 사용하며 둘 다 아니면 선택 후보에서 제외한다.
    x, y = float(mapx), float(mapy)
    for scale in (1, 1e7):
        longitude, latitude = x / scale, y / scale
        if 124 <= longitude <= 132 and 33 <= latitude <= 39:
            return longitude, latitude
    raise ValueError()


def _geocode(query: str) -> list[dict]:
    # 네이버 Maps Geocoding은 주소 검색 전용이며 상호명 검색은 별도 인증의 지역 검색 API가 필요하다.
    if not config.NAVER_API_KEY_ID.strip() or not config.NAVER_API_KEY.strip():
        raise ServiceError("NAVER_CONFIG_MISSING", "네이버 서버 API 인증정보를 설정해 주세요.")
    deadline = monotonic() + config.TRANSIT_REQUEST_SECONDS

    def load():
        # Maps Geocoding은 주소 검색이며 별도 인증의 지역 검색 API로 바꾸지 않는다.
        result = request_json("NAVER", "https://maps.apigw.ntruss.com/map-geocode/v2/geocode",
                              {"query": query.strip(), "count": 100}, deadline,
                              headers={"x-ncp-apigw-api-key-id": config.NAVER_API_KEY_ID,
                                       "x-ncp-apigw-api-key": config.NAVER_API_KEY})
        if result.get("status") != "OK" or not isinstance(result.get("addresses"), list):
            raise ServiceError("NAVER_RESPONSE_INVALID", "주소 검색 응답 형식을 확인할 수 없습니다.", 502)
        places = []
        try:
            for item in result["addresses"]:
                address = item.get("roadAddress") or item["jibunAddress"]
                if not isinstance(address, str) or not address.strip():
                    raise ValueError()
                latitude, longitude = float(item["y"]), float(item["x"])
                validate_coordinate(latitude, longitude)
                places.append({"id": "naver:" + sha256(address.encode()).hexdigest()[:20],
                               "name": address, "address": address, "kind": "ADDRESS",
                               "latitude": latitude, "longitude": longitude})
        except (KeyError, TypeError, ValueError, AttributeError, ServiceError):
            raise ServiceError("NAVER_RESPONSE_INVALID", "주소 검색 좌표를 확인할 수 없습니다.", 502) from None
        if not places:
            raise ServiceError("LOCATION_NOT_FOUND", "주소 검색 결과가 없습니다.", 404)
        return sorted(places, key=lambda p: "원주시" not in p["address"])

    return cached(("geocode", query.strip()), 300, load, deadline)


# 동일 요청은 한 번만 조회하고, 성공 응답만 제한된 메모리에 보관한다.
_cache = {}
_pending = {}
_cache_lock = Lock()


def cached(key, ttl, loader, deadline):
    with _cache_lock:
        now = monotonic()
        for old in [k for k, (until, _) in _cache.items() if until <= now]:
            del _cache[old]
        if key in _cache:
            return deepcopy(_cache[key][1])
        future = _pending.get(key)
        owner = future is None
        if owner:
            future = _pending[key] = Future()
    if not owner:
        try:
            return deepcopy(future.result(timeout=max(0.01, deadline - monotonic())))
        except FutureTimeout:
            raise ServiceError("TRANSIT_TIMEOUT", "교통정보 조회가 지연되고 있습니다.", 504) from None
    try:
        value = loader()
        with _cache_lock:
            if len(_cache) >= 256:
                _cache.pop(next(iter(_cache)))
            _cache[key] = (monotonic() + ttl, deepcopy(value))
        future.set_result(value)
        return deepcopy(value)
    except Exception as exc:
        future.set_exception(exc)
        raise
    finally:
        with _cache_lock:
            _pending.pop(key, None)


class _CredentialFilter(logging.Filter):
    # HTTP 라이브러리 로그를 켜더라도 쿼리와 헤더의 인증값은 남기지 않는다.
    def filter(self, record):
        message = record.getMessage()
        for secret in (config.ODSAY_API_KEY, config.TAGO_SERVICE_KEY,
                       config.NAVER_API_KEY_ID, config.NAVER_API_KEY,
                       config.NAVER_SEARCH_CLIENT_ID, config.NAVER_SEARCH_CLIENT_SECRET):
            if secret:
                decoded = unquote(secret.strip())
                values = {secret, secret.strip(), decoded, quote(decoded, safe=""), quote_plus(decoded),
                          quote(secret, safe=""), quote_plus(secret)}
                for value in sorted(values - {""}, key=len, reverse=True):
                    message = message.replace(value, "[인증정보 숨김]")
        record.msg, record.args = message, ()
        return True


for _logger in ("httpx", "httpcore.connection", "httpcore.http11", "httpcore.http2",
                "httpcore.proxy", "httpcore.socks"):
    logging.getLogger(_logger).addFilter(_CredentialFilter())


def request_json(provider, url, params, deadline, headers=None):
    remaining = deadline - monotonic()
    if remaining <= 0:
        raise ServiceError("TRANSIT_TIMEOUT", "교통정보 조회 제한 시간을 초과했습니다.", 504)
    try:
        # 기존 동기 라우터는 FastAPI 작업 스레드에서 실행되며 HTTP 자원은 매번 닫는다.
        with httpx.Client(timeout=min(config.TRANSIT_HTTP_TIMEOUT, remaining)) as client:
            response = client.get(url, params=params, headers=headers)
        if response.status_code in (401, 403):
            raise ServiceError(f"{provider}_AUTH_FAILED", f"{provider} API 인증 또는 이용 권한을 확인해 주세요.")
        if response.status_code == 429:
            raise ServiceError(f"{provider}_QUOTA_EXCEEDED", f"{provider} API 호출 한도를 초과했습니다.", 429)
        response.raise_for_status()
        try:
            result = response.json()
        except ValueError:
            # TAGO 게이트웨이는 JSON 요청에도 인증 오류를 XML로 반환할 수 있다.
            if provider == "TAGO":
                try:
                    code = ElementTree.fromstring(response.content).findtext(".//returnReasonCode")
                except ElementTree.ParseError:
                    code = None
                if code:
                    tago_error(code)
            raise ServiceError(f"{provider}_RESPONSE_INVALID", f"{provider} 응답 형식을 확인할 수 없습니다.", 502) from None
        if not isinstance(result, dict):
            raise ServiceError(f"{provider}_RESPONSE_INVALID", f"{provider} 응답 형식을 확인할 수 없습니다.", 502)
        return result
    except httpx.TimeoutException:
        raise ServiceError(f"{provider}_TIMEOUT", f"{provider} 응답이 지연되고 있습니다.", 504) from None
    except httpx.RequestError:
        raise ServiceError(f"{provider}_NETWORK_ERROR", f"{provider} 서버에 연결할 수 없습니다.", 503) from None
    except httpx.HTTPStatusError:
        raise ServiceError(f"{provider}_HTTP_ERROR", f"{provider} 서버가 요청을 처리하지 못했습니다.", 502) from None


def tago_error(code):
    code = str(code).zfill(2)
    if code in ("00", "0"):
        return
    if code in ("20", "21", "29", "30", "31", "32"):
        raise ServiceError("TAGO_AUTH_FAILED", "TAGO 인증키와 서비스 활용신청 상태를 확인해 주세요.")
    if code in ("22", "23"):
        raise ServiceError("TAGO_QUOTA_EXCEEDED", "TAGO 호출 한도를 초과했습니다.", 429)
    if code == "05":
        raise ServiceError("TAGO_TIMEOUT", "TAGO 응답이 지연되고 있습니다.", 504)
    raise ServiceError("TAGO_API_ERROR", "TAGO에서 정류장 또는 버스 정보를 조회하지 못했습니다.", 502)
