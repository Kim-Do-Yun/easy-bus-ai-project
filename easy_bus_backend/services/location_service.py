from math import asin, cos, isfinite, radians, sin, sqrt
from concurrent.futures import Future, TimeoutError as FutureTimeout
from copy import deepcopy
from hashlib import sha256
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
    # 실제 장소 데이터와 사용 가능한 검색 API가 확인되면 이 지점에 연동한다.
    if not config.NAVER_API_KEY_ID.strip() or not config.NAVER_API_KEY.strip():
        raise ServiceError("NAVER_CONFIG_MISSING", "네이버 서버 API 인증정보를 설정해 주세요.")
    if not query.strip():
        raise ServiceError("LOCATION_QUERY_EMPTY", "검색할 주소를 입력해 주세요.", 422)
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
                               "name": address, "address": address,
                               "latitude": latitude, "longitude": longitude})
        except (KeyError, TypeError, ValueError, AttributeError, ServiceError):
            raise ServiceError("NAVER_RESPONSE_INVALID", "주소 검색 좌표를 확인할 수 없습니다.", 502) from None
        if not places:
            raise ServiceError("LOCATION_NOT_FOUND", "주소 검색 결과가 없습니다. 상호명 대신 도로명 또는 지번 주소를 입력해 주세요.", 404)
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
                       config.NAVER_API_KEY_ID, config.NAVER_API_KEY):
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
