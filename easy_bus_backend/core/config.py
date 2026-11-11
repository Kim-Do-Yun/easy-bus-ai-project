import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parents[1]
load_dotenv(BASE_DIR / ".env", override=False)


def data_path(name: str, default: str) -> Path:
    # 상대 경로는 서버 실행 위치와 관계없이 백엔드 폴더를 기준으로 해석한다.
    path = Path(os.getenv(name, default))
    return path if path.is_absolute() else BASE_DIR / path


OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen3:1.7b")
AI_TIMEOUT = float(os.getenv("AI_TIMEOUT", "120"))
WHISPER_PATH = data_path("WHISPER_PATH", "models/whisper/small")
WHISPER_DEVICE = os.getenv("WHISPER_DEVICE", "cpu")
WHISPER_COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
STOPS_PATH = data_path("STOPS_PATH", "data/processed/stops.json")
ROUTES_PATH = data_path("ROUTES_PATH", "data/processed/routes.json")
MAX_AUDIO_BYTES = int(os.getenv("MAX_AUDIO_BYTES", "10485760"))
MAX_AUDIO_SECONDS = int(os.getenv("MAX_AUDIO_SECONDS", "60"))

# 서버 API 인증정보는 앱용 지도 Client ID와 분리하고, 미설정 상태도 허용한다.
NAVER_API_KEY_ID = os.getenv("NAVER_API_KEY_ID", "")
NAVER_API_KEY = os.getenv("NAVER_API_KEY", "")
ODSAY_API_KEY = os.getenv("ODSAY_API_KEY", "")
TAGO_SERVICE_KEY = os.getenv("TAGO_SERVICE_KEY", "")
# 도시코드는 실제 원주시 코드를 확인한 뒤 입력하며 임의로 추정하지 않는다.
TAGO_CITY_CODE = os.getenv("TAGO_CITY_CODE", "")
SERVICE_REGION = os.getenv("SERVICE_REGION", "wonju")

# 외부 조회와 메모리 캐시의 한도는 실제 인증정보와 별도로 조정한다.
TRANSIT_HTTP_TIMEOUT = float(os.getenv("TRANSIT_HTTP_TIMEOUT", "10"))
TRANSIT_REQUEST_SECONDS = float(os.getenv("TRANSIT_REQUEST_SECONDS", "100"))
TAGO_CACHE_SECONDS = float(os.getenv("TAGO_CACHE_SECONDS", "3600"))
TAGO_ARRIVAL_CACHE_SECONDS = float(os.getenv("TAGO_ARRIVAL_CACHE_SECONDS", "15"))
ODSAY_CACHE_SECONDS = float(os.getenv("ODSAY_CACHE_SECONDS", "300"))
# 요청서의 호출 예산을 기본값으로 사용하며 실제 계정 한도와는 별도로 관리한다.
ODSAY_DAILY_CALL_LIMIT = int(os.getenv("ODSAY_DAILY_CALL_LIMIT", "30"))
STOP_MATCH_RADIUS_M = float(os.getenv("STOP_MATCH_RADIUS_M", "60"))

# 최적 1(도보 최소)·최적 2(시간·환승 이점) 선정 기준이며 실제 데이터에 맞춰 환경변수로 조정한다.
# 최적 1은 가장 빠른 후보 대비 이 비율과 추가 시간을 모두 넘지 않는 경로 중에서 고른다.
ROUTE_BEST1_MAX_TIME_RATIO = float(os.getenv("ROUTE_BEST1_MAX_TIME_RATIO", "1.5"))
ROUTE_BEST1_MAX_EXTRA_MINUTES = float(os.getenv("ROUTE_BEST1_MAX_EXTRA_MINUTES", "20"))
# 최적 1은 최소 환승 후보보다 이 횟수를 넘게 더 환승하는 경로를 고르지 않는다.
ROUTE_BEST1_MAX_EXTRA_TRANSFERS = int(os.getenv("ROUTE_BEST1_MAX_EXTRA_TRANSFERS", "1"))
# 환승 1회를 도보 몇 m에 해당하는 부담으로 볼지 정한다.
ROUTE_TRANSFER_WALK_PENALTY_M = float(os.getenv("ROUTE_TRANSFER_WALK_PENALTY_M", "300"))
# 최적 2는 최적 1보다 이 시간 이상 빠르거나, 환승이 적으면서 허용 시간 안에 도착해야 한다.
ROUTE_BEST2_MIN_TIME_GAIN_MINUTES = float(os.getenv("ROUTE_BEST2_MIN_TIME_GAIN_MINUTES", "3"))
ROUTE_BEST2_TRANSFER_TIME_TOLERANCE_MINUTES = float(os.getenv("ROUTE_BEST2_TRANSFER_TIME_TOLERANCE_MINUTES", "5"))
# 최적 2라도 최적 1보다 이 거리를 넘게 더 걷는 경로는 추천하지 않는다.
ROUTE_BEST2_MAX_EXTRA_WALK_M = float(os.getenv("ROUTE_BEST2_MAX_EXTRA_WALK_M", "700"))
# 같은 버스 순서이면서 도보·시간 차이가 이 값 미만이면 사실상 같은 경로로 본다.
ROUTE_SIMILAR_WALK_M = float(os.getenv("ROUTE_SIMILAR_WALK_M", "100"))
ROUTE_SIMILAR_MINUTES = float(os.getenv("ROUTE_SIMILAR_MINUTES", "2"))
