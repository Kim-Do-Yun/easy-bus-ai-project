# 말로 타는 AI 쉬운 버스 구현 내역

## 기존 상태

기존 백엔드는 `main.py`의 `/api/health`만 제공했고, Flutter는 기본 카운터 예제였다. 지도 SDK/키, 녹음, GPS, TTS, HTTP 통신 및 버스·장소 원본 데이터는 없었다. 기존 Python `.venv`와 Flutter SDK(`C:/src/flutter`)는 그대로 사용한다.

## ① 생성한 파일

- `easy_bus_backend/api/routes.py`: 요청 검증, API와 Flutter 공통 응답 계약, 음성 임시 파일 관리. `api/__init__.py`는 패키지 구분용이다.
- `easy_bus_backend/core/config.py`, `core/__init__.py`: 환경변수 및 백엔드 기준 경로 관리.
- `easy_bus_backend/services/ai_service.py`: Whisper CPU/int8 지연 로딩, 한국어 STT, Ollama Qwen3 문장 해석과 결과 검증.
- `easy_bus_backend/services/location_service.py`: 좌표 검증, 구면 거리 계산, 장소 검색 미지원 응답 및 공통 서비스 오류.
- `easy_bus_backend/services/bus_service.py`, `services/__init__.py`: 정류장·노선·경로 연결 지점과 데이터 미확보 오류 처리.
- `easy_bus_backend/requirements.txt`, `.env`, `.env.example`, `.gitignore`: 의존성·설정·모델 및 비밀 설정 제외. `.env`는 Git에 포함하지 않는다.
- `easy_bus_backend/data/raw/.gitkeep`, `data/processed/.gitkeep`, `models/whisper/.gitkeep`: 실제 자료와 모델을 위한 빈 디렉터리 유지.
- `easy_bus_ai/lib/models/bus_models.dart`: 해석·장소·정류장·노선·경로·도착정보 모델.
- `easy_bus_ai/lib/services/api_service.dart`: HTTP/업로드/오류/시간 제한.
- `easy_bus_ai/lib/services/device_service.dart`: 권한, GPS, WAV 녹음, 녹음 정리, 한국어 TTS.
- `easy_bus_ai/lib/screens/splash_screen.dart`: 최초 SDK 초기화 및 초기화 실패 안내.
- `easy_bus_ai/lib/screens/home_screen.dart`: 단일 지도와 상태별 입력·경로·녹음 UI.
- `IMPLEMENTATION.md`: 설치 방법, 실제 지원 범위 및 후속 연동 사항. 요청한 완료 보고와 실행 지침을 남기기 위해 추가했다.

## ② 수정한 파일

- 백엔드 `main.py`: 기존 health 응답을 그대로 유지하고 라우터·서비스 오류 처리 등록.
- Flutter `lib/main.dart`: 앱 이름과 첫 화면 연결. 기존 카운터 클래스와 주석은 삭제하지 않았다.
- `pubspec.yaml`: 지도, 녹음, HTTP, 위치, TTS, 임시 폴더 패키지를 추가했다. 기존 의존성은 보존했다.
- Android `app/src/main/AndroidManifest.xml`: 인터넷·녹음·위치 권한과 TTS 조회 추가.
- Android `app/src/debug/AndroidManifest.xml`: 로컬 개발 서버 HTTP 허용. 릴리스에서는 HTTPS 서버를 사용해야 한다.
- Android `app/build.gradle.kts`: 지도/녹음 플러그인에 필요한 최소 SDK 23 보장.
- iOS `Runner/Info.plist`: 마이크·위치 사용 설명 추가. iOS 기기 실행과 네이티브 의존성 설치는 수행하지 않았다.

## ③ 구현한 기능

- `/api/health` 기존 응답 유지. `/docs` 유지.
- `/api/interpret`: 한국어 요청 → 출발지/목적지/현재 위치/추가 확인 여부. Ollama 미실행·모델 누락·시간 초과·잘못된 JSON 오류 처리.
- `/api/speech`: PCM WAV 확장자 및 실제 WAV 헤더·길이·용량 검증, Whisper 한국어 인식, 요청 종료 시 임시 파일 정리. 동시 추론은 429로 제한한다.
- `/api/locations/search`, `/api/bus/stops`, `/api/bus/stops/{stop_id}/routes`, `/api/bus/routes`: 요청 계약과 명확한 503 미지원 응답.
- Flutter: 같은 지도 위 상단 입력, 후보 선택, 고정 마이크, 녹음 종료·자동 제한, 음성 인식 후 문장 해석, GPS, TTS, 반복 안내.
- 경로 응답이 연결되면 도보/버스 구간·환승·승하차·도착정보 상태를 표시한다. 상세 좌표가 제공된 구간만 선을 그린다.
- 요청 시작 시 기존 경로 보존, 성공 시 교체, 지연 로딩 오버레이, 중복 요청 방지, 요청 번호를 이용한 취소 결과 무효화, 시스템 및 화면 뒤로 가기.
- 취소는 서버 추론을 강제 종료하지 않고 결과를 무효화한다. 이미 실행 중인 Whisper 작업은 완료될 수 있다.

## ④ 미구현 및 현재 제한

**현재 실제 버스 경로 검색은 성공할 수 없다.** 정류장·노선·장소 데이터 및 검색 API가 없기 때문이다. 데이터 로더, 정류장 조회, 직접 노선/환승 탐색, 도보 및 버스 형상 계산, 실시간 도착정보는 구현 완료로 간주하지 않는다.

원본 형식이 확인되지 않아 임의 JSON/CSV 스키마를 가정한 로더를 만들지 않았다. 파일을 설정 경로에 놓는 것만으로 동작하지 않으며, 원본 컬럼과 정류장 방문 순서/방향을 확인한 뒤 `bus_service.py`와 `location_service.py`에 연결해야 한다. 파일이 없으면 `BUS_DATA_UNAVAILABLE`, 파일만 존재하면 `BUS_DATA_ADAPTER_REQUIRED`를 반환한다.

장소 검색은 `LOCATION_DATA_UNAVAILABLE`를 반환한다. 향후 이름이 같은 후보가 여러 개면 후보 목록을 반환해야 하며 앱이 사용자 선택을 받는다. 정류장 좌표 간 거리 계산은 직선 거리이고 실제 도보 경로가 아니다.

지도 키가 없으면 최초 화면에서 설정 오류를 표시한다. 실제 지도 인증, 모델 실행, Android/iOS 빌드 및 기기 동작은 확인하지 않았다. 기존 Flutter 기본 카운터 테스트는 그대로 남아 있으며 새 시작 화면에 맞게 변경하거나 실행하지 않았다.

## ⑤ 기존 기능 보존

`/api/health` 경로와 응답, FastAPI 문서, 기존 가상환경, Flutter 플랫폼 구조, 기존 테스트 및 카운터 예제 클래스를 보존했다. 기존 지도 설정이나 AI 기능은 존재하지 않아 신규 연결했으며 임의 키·정류장·버스번호·도착시간은 추가하지 않았다.

## ⑥ 추가 준비

1. 아래 명령으로 기존 가상환경과 Flutter 프로젝트에 의존성을 설치한다. 이번 작업에서는 설치·빌드·테스트를 실행하지 않았다. `pubspec.lock`은 `flutter pub get` 실행 시 갱신된다.
2. Ollama를 설치·실행한 뒤 `ollama pull qwen3:1.7b`를 실행한다. 모델은 Ollama 자체 저장소에서 관리한다.
3. Whisper Small의 CTranslate2 모델을 아래 명령으로 다운로드한다. 서버는 요청 시 자동 다운로드하지 않는다.
4. 네이버 클라우드 Maps에서 Android 패키지 `com.easybus.easy_bus_ai`를 등록하고 실제 Client ID를 전달한다. iOS 사용 시 실제 Bundle ID도 등록한다.
5. 강릉시 실제 정류장·노선 순서·방향 데이터 및 장소 검색 데이터/API를 확보해야 한다. 상세 도보·버스 경로 형상과 실시간 도착정보는 별도 연동이 필요하다.

## ⑦ 실행 방법 (PowerShell)

프로젝트 루트에서 백엔드 실행:

```powershell
cd easy_bus_backend
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -c "from faster_whisper.utils import download_model; download_model('small', output_dir='models/whisper/small')"
ollama pull qwen3:1.7b
.\.venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

Ollama가 백그라운드에서 실행되지 않는 환경이면 별도 터미널에서 `ollama serve`를 실행한다. 서버 설정은 `.env`에서 변경하며 운영체제 환경변수가 우선한다.

별도 터미널의 프로젝트 루트에서 Android 에뮬레이터 실행:

```powershell
cd easy_bus_ai
C:\src\flutter\bin\flutter.bat pub get
C:\src\flutter\bin\flutter.bat run --dart-define=NAVER_MAP_CLIENT_ID=발급받은_Client_ID --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

실제 Android 휴대전화는 같은 네트워크의 PC IPv4 주소로 `API_BASE_URL`을 바꾸고 Windows 방화벽에서 개발 서버 포트를 허용한다. iOS와 릴리스 앱은 HTTPS 백엔드 주소를 사용한다.

테스트 파일을 생성하거나 테스트를 실행하지 않았다. Dart 코드 포맷만 수행했으며 실제 실행 검증 완료를 의미하지 않는다.

참고한 공식 구현 문서: [flutter_naver_map](https://pub.dev/packages/flutter_naver_map), [record](https://pub.dev/packages/record), [geolocator](https://pub.dev/packages/geolocator), [faster-whisper](https://github.com/SYSTRAN/faster-whisper), [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md).
