import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/bus_models.dart';

class ApiException implements Exception {
  final String message;
  // 서버 오류 코드이며 음성 재질문 대상인지 구분하는 데만 사용한다.
  final String? code;
  ApiException(this.message, [this.code]);
  @override
  String toString() => message;
}

class ApiService {
  // config/app.json에서 전달하며, 미설정 시 기존 에뮬레이터 주소를 유지한다.
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  final http.Client _client = http.Client();
  final Set<Completer<void>> _pending = {};
  bool _disposed = false;
  ApiService() {
    // 실제 기기와 에뮬레이터의 연결 주소 차이를 확인하기 위해 서버 주소만 기록한다.
    debugPrint('[EASY_BUS_API] API_BASE_URL=$baseUrl');
  }
  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/api$path').replace(queryParameters: query);

  // 요청 경로·상태 코드·소요 시간·오류 코드만 기록하고 검색어와 인증정보는 기록하지 않는다.
  Future<dynamic> _send(
    FutureOr<http.BaseRequest> Function(Future<void> abort) build,
  ) async {
    final elapsed = Stopwatch()..start();
    var target = '';
    try {
      return await _sendRequest(build, (value) => target = value);
    } on ApiException catch (error) {
      debugPrint(
        '[EASY_BUS_API] 실패 $target 코드=${error.code} '
        '(${elapsed.elapsedMilliseconds}ms)',
      );
      rethrow;
    }
  }

  Future<dynamic> _sendRequest(
    FutureOr<http.BaseRequest> Function(Future<void> abort) build,
    void Function(String target) started,
  ) async {
    if (_disposed) throw ApiException('요청이 취소되었습니다.', 'REQUEST_CANCELLED');
    final abort = Completer<void>();
    _pending.add(abort);
    final elapsed = Stopwatch()..start();
    try {
      // 업로드와 응답 본문 수신을 합친 전체 요청에 제한 시간을 둔다.
      final response = await (() async {
        final request = await build(abort.future);
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
    } on SocketException {
      throw ApiException(
        '서버에 연결할 수 없습니다. 네트워크 연결을 확인해 주세요.',
        'NETWORK_UNAVAILABLE',
      );
    } on http.ClientException {
      throw ApiException('서버 연결이 끊어졌습니다. 다시 시도해 주세요.', 'NETWORK_UNAVAILABLE');
    } on FormatException {
      throw ApiException('서버 응답 형식을 확인할 수 없습니다.', 'INVALID_SERVER_RESPONSE');
    } finally {
      // 타임아웃도 실제 업로드·응답 스트림을 중단해 파일 정리 경로로 돌려보낸다.
      _pending.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) => _send(
    (abort) =>
        http.AbortableRequest('GET', _uri(path, query), abortTrigger: abort),
  );
  Future<dynamic> _post(String path, Object body) {
    return _send(
      (abort) => http.AbortableRequest('POST', _uri(path), abortTrigger: abort)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body),
    );
  }

  Future<void> health() async {
    await _get('/health');
  }

  Future<String> speech(String path) async {
    final body = await _send((abort) async {
      // 최대 30초 WAV를 읽고 파일 핸들을 먼저 닫아 취소·타임아웃 후 삭제와 충돌하지 않게 한다.
      final file = File(path);
      final bytes = await file.readAsBytes();
      debugPrint('[EASY_BUS_API] 음성 파일 전송 크기=${bytes.length}B');
      return http.AbortableMultipartRequest(
          'POST',
          _uri('/speech'),
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
