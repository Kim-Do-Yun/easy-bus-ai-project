import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/bus_models.dart';

class ApiException implements Exception {
  final String message;
  // 서버 오류 코드이며 음성 재질문 대상인지 구분하는 데만 사용한다.
  final String? code;
  ApiException(this.message, [this.code]);
  @override
  String toString() => message;
}

// 선택된 서버와의 연결이 끊긴 경우만 구분하여 서버 재선택 여부를 판단한다.
class _ConnectionLost extends ApiException {
  _ConnectionLost(String message) : super(message, 'NETWORK_UNAVAILABLE');
}

class ApiService {
  // config/app.json에서 전달하며, 미설정 시 기존 에뮬레이터 주소를 유지한다.
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  // 쉼표로 구분한 복수 서버 주소이며, 적힌 순서를 연결 우선순위로 사용한다.
  static const _baseUrlsSetting = String.fromEnvironment('API_BASE_URLS');
  // 복수 주소가 없으면 기존 API_BASE_URL 하나만 사용한다.
  static final List<String> baseUrls = _parseBaseUrls();
  // 서버 확인은 연결 시도와 응답 수신을 합쳐 서버별 약 2초로 제한한다.
  static const _probeTimeout = Duration(seconds: 2);
  // 앱 실행 중 선택한 서버를 모든 요청이 함께 사용한다.
  static String? _selectedBaseUrl;
  // 서버 탐색 중 들어온 요청은 새로 탐색하지 않고 같은 결과를 기다린다.
  static Future<String?>? _selecting;
  // 꺼진 서버에 연결 대기가 길어지지 않도록 연결 단계만 제한하고 기존 150초 요청 제한은 유지한다.
  final http.Client _client = IOClient(
    HttpClient()..connectionTimeout = const Duration(seconds: 5),
  );
  final Set<Completer<void>> _pending = {};
  bool _disposed = false;
  ApiService() {
    // 실제 기기와 에뮬레이터의 연결 주소 차이를 확인하기 위해 서버 주소만 기록한다.
    debugPrint('[EASY_BUS_API] API_BASE_URLS=${baseUrls.join(',')}');
    // 첫 화면 준비와 동시에 서버를 미리 확인하며, 실패해도 첫 요청에서 다시 확인한다.
    unawaited(_resolveBaseUrl());
  }
  Uri _uri(String base, String path, [Map<String, String>? query]) =>
      Uri.parse('$base/api$path').replace(queryParameters: query);

  // 공백·빈 값·끝 슬래시·잘못된 주소를 정리하고 중복 주소는 처음 순서만 남긴다.
  static List<String> _parseBaseUrls() {
    final urls = <String>[];
    for (final raw in _baseUrlsSetting.split(',')) {
      final url = _normalizeBaseUrl(raw);
      if (url != null && !urls.contains(url)) urls.add(url);
    }
    if (urls.isEmpty) urls.add(_normalizeBaseUrl(baseUrl) ?? baseUrl);
    return urls;
  }

  static String? _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return null;
    }
    return url;
  }

  // 선택된 서버가 없을 때만 등록된 서버를 다시 확인한다.
  static Future<String?> _resolveBaseUrl() {
    final selected = _selectedBaseUrl;
    if (selected != null) return Future.value(selected);
    return _selecting ??= _selectBaseUrl().whenComplete(
      () => _selecting = null,
    );
  }

  // 모든 서버를 병렬로 확인하고, 응답한 서버 중 설정 순서가 가장 앞선 주소를 고른다.
  static Future<String?> _selectBaseUrl() async {
    final elapsed = Stopwatch()..start();
    final client = IOClient(HttpClient()..connectionTimeout = _probeTimeout);
    // Release APK에서도 adb logcat으로 확인할 수 있도록 탐색 대상과 결과를 기록한다.
    debugPrint(
      '[EASY_BUS_API] 서버 탐색 시작 대상=${baseUrls.length}개 '
      '(${baseUrls.join(',')})',
    );
    try {
      final results = await Future.wait(
        baseUrls.map((url) => _isEasyBusBackend(client, url)),
      );
      final index = results.indexOf(true);
      final selected = index < 0 ? null : baseUrls[index];
      _selectedBaseUrl = selected;
      debugPrint(
        '[EASY_BUS_API] 서버 선택=${selected ?? '없음'} '
        '응답=${results.where((ok) => ok).length}/${baseUrls.length} '
        '(${elapsed.elapsedMilliseconds}ms)',
      );
      if (selected == null) {
        debugPrint('[EASY_BUS_API] 서버 선택 실패 사유=정상 응답한 서버 없음 (서버별 확인 결과 참고)');
      }
      return selected;
    } finally {
      // 제한시간을 넘긴 확인 요청도 함께 중단한다.
      client.close();
    }
  }

  // 기존 상태 확인 API만 호출하며 Whisper·Qwen·TAGO 등 실제 처리나 외부 API는 실행하지 않는다.
  // 정상 응답은 서버 실행 여부만 뜻하며 Ollama·외부 API의 정상 동작까지 보장하지 않는다.
  static Future<bool> _isEasyBusBackend(http.Client client, String url) async {
    final elapsed = Stopwatch()..start();
    final healthUrl = '$url/api/health';
    debugPrint('[EASY_BUS_API] 서버 확인 요청 $healthUrl');
    try {
      final response = await client
          .get(Uri.parse(healthUrl))
          .timeout(_probeTimeout);
      final dynamic body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        debugPrint(
          '[EASY_BUS_API] 서버 확인 $url 상태=${response.statusCode} '
          '판정=제외(JSON 아님) (${elapsed.elapsedMilliseconds}ms)',
        );
        return false;
      }
      // 다른 프로그램의 응답과 구분하도록 기존 상태 확인 응답의 내용까지 확인한다.
      final message = body is Map ? body['message'] : null;
      final ok =
          response.statusCode == 200 &&
          body is Map &&
          body['status'] == 'ok' &&
          message is String &&
          message.contains('Easy AI Bus');
      // 응답 본문 원문은 기록하지 않고 판정에 쓴 항목의 일치 여부만 기록한다.
      debugPrint(
        '[EASY_BUS_API] 서버 확인 $url 상태=${response.statusCode} '
        '판정=${ok ? '정상' : '제외'} '
        'status일치=${body is Map && body['status'] == 'ok'} '
        'message일치=${message is String && message.contains('Easy AI Bus')} '
        '(${elapsed.elapsedMilliseconds}ms)',
      );
      return ok;
    } catch (error) {
      debugPrint(
        '[EASY_BUS_API] 서버 확인 실패 $url 유형=${error.runtimeType} '
        '내용=${_describeError(error)} (${elapsed.elapsedMilliseconds}ms)',
      );
      return false;
    }
  }

  // 연결 오류의 원인만 남기고, 검색어가 포함될 수 있는 요청 URL은 기록하지 않는다.
  static String _describeError(Object error) {
    if (error is SocketException) {
      final os = error.osError;
      return '${error.message}'
          '${os == null ? '' : ' (OS 오류=${os.message}, errno=${os.errorCode})'}';
    }
    if (error is http.ClientException) return error.message;
    if (error is TimeoutException) return '제한시간 ${_probeTimeout.inSeconds}초 초과';
    return error.runtimeType.toString();
  }

  // 다른 요청이 이미 새 서버를 골랐다면 그 선택은 유지한다.
  static void _forgetBaseUrl(String? url) {
    if (url != null && _selectedBaseUrl == url) _selectedBaseUrl = null;
  }

  // 요청 경로·상태 코드·소요 시간·오류 코드만 기록하고 검색어와 인증정보는 기록하지 않는다.
  // 연결이 끊긴 GET 조회만 서버를 다시 골라 한 번 재요청하고,
  // POST는 음성 중복 전송·중복 추론을 막기 위해 자동 재전송하지 않는다.
  Future<dynamic> _send(
    FutureOr<http.BaseRequest> Function(String base, Future<void> abort)
    build, {
    bool retryOnConnectionLost = false,
  }) async {
    final elapsed = Stopwatch()..start();
    var target = '';
    var retry = retryOnConnectionLost;
    while (true) {
      try {
        return await _sendRequest(build, (value) => target = value);
      } on ApiException catch (error) {
        if (retry && error is _ConnectionLost) {
          retry = false;
          debugPrint('[EASY_BUS_API] 연결 끊김 $target 서버 재선택 후 재요청');
          continue;
        }
        debugPrint(
          '[EASY_BUS_API] 실패 $target 코드=${error.code} '
          '(${elapsed.elapsedMilliseconds}ms)',
        );
        rethrow;
      }
    }
  }

  Future<dynamic> _sendRequest(
    FutureOr<http.BaseRequest> Function(String base, Future<void> abort) build,
    void Function(String target) started,
  ) async {
    if (_disposed) throw ApiException('요청이 취소되었습니다.', 'REQUEST_CANCELLED');
    final abort = Completer<void>();
    _pending.add(abort);
    final elapsed = Stopwatch()..start();
    String? base;
    try {
      // 업로드와 응답 본문 수신을 합친 전체 요청에 제한 시간을 둔다.
      final response = await (() async {
        final selected = await _resolveBaseUrl();
        if (abort.isCompleted || _disposed) {
          throw ApiException('요청이 취소되었습니다.', 'REQUEST_CANCELLED');
        }
        // 등록된 모든 서버에 연결할 수 없으면 기존 오류 안내로 전달하고 다음 요청에서 다시 확인한다.
        if (selected == null) {
          throw ApiException(
            '서버에 연결할 수 없습니다. 서버 실행 상태와 Wi-Fi 연결을 확인해 주세요.',
            'NETWORK_UNAVAILABLE',
          );
        }
        base = selected;
        final request = await build(selected, abort.future);
        final target = '${request.method} ${request.url.path}';
        started(target);
        debugPrint('[EASY_BUS_API] 요청 $target');
        if (abort.isCompleted) throw http.RequestAbortedException(request.url);
        return http.Response.fromStream(await _client.send(request));
      })().timeout(const Duration(seconds: 150));
      debugPrint(
        '[EASY_BUS_API] 응답 상태=${response.statusCode} '
        '크기=${response.bodyBytes.length}B (${elapsed.elapsedMilliseconds}ms)',
      );
      final dynamic body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        if (response.statusCode >= 500) {
          throw ApiException(
            '서버에서 요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.',
            'SERVER_ERROR',
          );
        }
        rethrow;
      }
      if (response.statusCode >= 400) {
        final detail = body is Map ? body['detail'] : null;
        throw ApiException(
          detail is Map && detail['message'] is String
              ? detail['message'] as String
              : '요청을 처리할 수 없습니다. (${response.statusCode})',
          detail is Map && detail['code'] is String
              ? detail['code'] as String
              : response.statusCode >= 500
              ? 'SERVER_ERROR'
              : 'REQUEST_REJECTED',
        );
      }
      return body;
    } on http.RequestAbortedException {
      throw ApiException('요청이 취소되었습니다.', 'REQUEST_CANCELLED');
    } on TimeoutException {
      throw ApiException('서버 응답이 늦습니다. 잠시 후 다시 시도해 주세요.', 'NETWORK_TIMEOUT');
    } on SocketException catch (error) {
      // 연결 실패만 선택을 해제하고, 서버의 정상 오류 응답·응답 지연은 서버를 바꾸지 않는다.
      debugPrint(
        '[EASY_BUS_API] 연결 실패 서버=$base 유형=${error.runtimeType} '
        '내용=${_describeError(error)}',
      );
      _forgetBaseUrl(base);
      throw _ConnectionLost('서버에 연결할 수 없습니다. 네트워크 연결을 확인해 주세요.');
    } on http.ClientException catch (error) {
      debugPrint(
        '[EASY_BUS_API] 연결 실패 서버=$base 유형=${error.runtimeType} '
        '내용=${_describeError(error)}',
      );
      _forgetBaseUrl(base);
      throw _ConnectionLost('서버 연결이 끊어졌습니다. 다시 시도해 주세요.');
    } on FormatException {
      throw ApiException('서버 응답 형식을 확인할 수 없습니다.', 'INVALID_SERVER_RESPONSE');
    } finally {
      // 타임아웃도 실제 업로드·응답 스트림을 중단해 파일 정리 경로로 돌려보낸다.
      _pending.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) => _send(
    (base, abort) => http.AbortableRequest(
      'GET',
      _uri(base, path, query),
      abortTrigger: abort,
    ),
    retryOnConnectionLost: true,
  );
  Future<dynamic> _post(String path, Object body) {
    return _send(
      (base, abort) =>
          http.AbortableRequest('POST', _uri(base, path), abortTrigger: abort)
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(body),
    );
  }

  Future<void> health() async {
    await _get('/health');
  }

  Future<String> speech(String path) async {
    final body = await _send((base, abort) async {
      // 최대 30초 WAV를 읽고 파일 핸들을 먼저 닫아 취소·타임아웃 후 삭제와 충돌하지 않게 한다.
      final file = File(path);
      final bytes = await file.readAsBytes();
      debugPrint('[EASY_BUS_API] 음성 파일 전송 크기=${bytes.length}B');
      return http.AbortableMultipartRequest(
          'POST',
          _uri(base, '/speech'),
          abortTrigger: abort,
        )
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: file.uri.pathSegments.last,
          ),
        );
    });
    if (body is! Map || body['text'] is! String) {
      throw ApiException('음성 인식 응답 형식을 확인할 수 없습니다.', 'INVALID_SERVER_RESPONSE');
    }
    final text = (body['text'] as String).trim();
    // 인식 문장은 디버그 실행에서만 기록하여 Whisper 결과와 앱 처리 결과를 비교한다.
    debugPrint(
      '[EASY_BUS_API] 음성 인식 결과 길이=${text.length}'
      '${kDebugMode ? ' 문장="$text"' : ''}',
    );
    if (text.isEmpty) throw ApiException('말소리를 찾지 못했습니다.', 'EMPTY_SPEECH');
    return text;
  }

  // 다중 턴 대화에서는 직전에 물은 항목(origin, destination)을 함께 전달한다.
  Future<Interpretation> interpret(String text, {String? expectedSlot}) async {
    try {
      return Interpretation.fromJson(
        await _post('/interpret', {
          'text': text,
          'expected_slot': ?expectedSlot,
        }),
      );
    } on TypeError {
      throw ApiException('문장 해석 응답 형식을 확인할 수 없습니다.', 'INVALID_SERVER_RESPONSE');
    }
  }

  Future<List<Place>> locations(String query) async =>
      ((await _get('/locations/search', {'q': query})) as List)
          .map((j) => Place.fromJson(j))
          .toList();
  Future<List<BusStop>> stops(Place p) async => ((await _get('/bus/stops', {
    'latitude': '${p.latitude}',
    'longitude': '${p.longitude}',
    'radius_m': '700',
  })) as List).map((j) => BusStop.fromJson(j)).toList();
  Future<List<BusRoute>> routes(Place origin, Place destination) async =>
      ((await _post('/bus/routes', {
        'origin': origin.coordinate,
        'destination': destination.coordinate,
      })) as List).map((j) => BusRoute.fromJson(j)).toList();
  void cancelRequests() {
    for (final abort in _pending.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  void dispose() {
    _disposed = true;
    cancelRequests();
    _client.close();
  }
}
