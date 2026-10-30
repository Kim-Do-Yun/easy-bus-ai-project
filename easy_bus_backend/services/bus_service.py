from core import config
from services.location_service import ServiceError, validate_coordinate


def require_data(path, label: str) -> None:
    # 원본 자료의 컬럼과 노선 순서를 확인하기 전에는 추정 형식으로 읽지 않는다.
    if not path.is_file():
        raise ServiceError("BUS_DATA_UNAVAILABLE", f"{label} 데이터가 아직 준비되지 않았습니다.")
    raise ServiceError("BUS_DATA_ADAPTER_REQUIRED", f"{label} 원본 형식을 확인한 뒤 데이터 연결이 필요합니다.")


def nearby_stops(latitude: float, longitude: float, radius_m: float) -> list[dict]:
    validate_coordinate(latitude, longitude)
    require_data(config.STOPS_PATH, "강릉시 정류장")


def stop_routes(stop_id: str) -> list[dict]:
    require_data(config.ROUTES_PATH, "강릉시 노선")


def find_routes(origin: dict, destination: dict) -> list[dict]:
    validate_coordinate(**origin)
    validate_coordinate(**destination)
    require_data(config.ROUTES_PATH, "강릉시 노선 및 정류장 순서")
