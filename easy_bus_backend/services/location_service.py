from math import asin, cos, isfinite, radians, sin, sqrt


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
    raise ServiceError("LOCATION_DATA_UNAVAILABLE", "장소 검색 데이터가 아직 연결되지 않았습니다.")
