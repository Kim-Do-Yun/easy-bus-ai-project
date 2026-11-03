# easy_bus_ai

고령자를 위함 음성 기반 AI버스 안내 애플리케이션

## API 환경설정

앱 설정은 `config/app.json`에서 관리한다. 새로 내려받은 프로젝트에서는
`config/app.example.json`을 `config/app.json`으로 복사한 뒤
`NAVER_MAP_CLIENT_ID`에 앱용 네이버 지도 Client ID를 입력한다.
`API_BASE_URL`의 기본값은 Android 에뮬레이터용 `http://10.0.2.2:8000`이며,
실제 기기에서는 기기에서 접근 가능한 서버 주소로 변경한다.
`SERVICE_REGION=wonju`는 향후 연동용 설정이며 기존 지역 문구나 검색 동작을 바꾸지 않는다.

Flutter 프로젝트 폴더(`easy_bus_ai`)에서 다음 명령으로 실행한다.

```powershell
flutter run --dart-define-from-file=config/app.json
```

설정 변경 후에는 실행을 종료하고 위 명령으로 다시 실행한다.
Android Studio의 기존 `main.dart` 실행 구성에도 같은 옵션을 추가했다.
`.idea`는 Git에서 제외되므로 다른 개발 환경에서는 Flutter 실행 구성의
Additional run args에 `--dart-define-from-file=config/app.json`을 직접 추가한다.
프로젝트는 `easy_bus_ai` 폴더를 기준으로 연다.

서버 비밀키는 `../easy_bus_backend/.env`에만 입력한다.
파일이 없다면 같은 폴더의 `.env.example`을 복사한다. 기존 `.env`는 덮어쓰지 않는다.
`NAVER_API_KEY_ID`, `NAVER_API_KEY`, `ODSAY_API_KEY`, `TAGO_SERVICE_KEY`는
각 API를 연동할 때 입력하고, `TAGO_CITY_CODE`는 실제 원주시 코드를 확인한 뒤 입력한다.
서버의 `SERVICE_REGION` 기본값도 `wonju`이다.
기존 `core/config.py`가 `.env`를 읽으며, 프로세스 환경변수가 있으면 해당 값이 우선한다.
향후 서버 서비스에서는 기존 `from core import config` 방식으로
`config.ODSAY_API_KEY` 등을 참조하고, 키가 비어 있으면 해당 API를 호출하지 않도록 처리한다.
현재는 인증정보 설정만 준비하며 ODsay·TAGO 요청 기능을 추가하지 않는다.

실제 설정 파일은 Git에서 제외하고 예시 파일에는 인증정보를 넣지 않는다.
앱용 Client ID는 앱 빌드에 포함되므로 비밀정보 저장 수단으로 취급하지 않는다.
서버 비밀키는 앱 JSON이나 Flutter 빌드 옵션에 추가하지 않는다.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
