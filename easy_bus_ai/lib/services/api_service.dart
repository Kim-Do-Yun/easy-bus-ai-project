import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/bus_models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
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
  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/api$path').replace(queryParameters: query);

  Future<dynamic> _send(http.BaseRequest request) async {
    try {
      // 업로드와 응답 본문 수신을 합친 전체 요청에 제한 시간을 둔다.
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(const Duration(seconds: 150));
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode >= 400) {
        final detail = body is Map ? body['detail'] : null;
        throw ApiException(
          detail is Map
              ? detail['message'].toString()
              : '요청을 처리할 수 없습니다. (${response.statusCode})',
        );
      }
      return body;
    } on TimeoutException {
      throw ApiException('서버 응답이 늦습니다. 잠시 후 다시 시도해 주세요.');
    } on SocketException {
      throw ApiException('서버에 연결할 수 없습니다. 네트워크와 서버 주소를 확인해 주세요.');
    } on http.ClientException {
      throw ApiException('서버 연결이 끊어졌습니다. 다시 시도해 주세요.');
    } on FormatException {
      throw ApiException('서버 응답 형식을 확인할 수 없습니다.');
    }
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) =>
      _send(http.Request('GET', _uri(path, query)));
  Future<dynamic> _post(String path, Object body) {
    final request = http.Request('POST', _uri(path))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    return _send(request);
  }

  Future<void> health() async {
    await _get('/health');
  }

  Future<String> speech(String path) async {
    final request = http.MultipartRequest('POST', _uri('/speech'))
      ..files.add(await http.MultipartFile.fromPath('file', path));
    return (await _send(request))['text'] as String;
  }

  Future<Interpretation> interpret(String text) async =>
      Interpretation.fromJson(await _post('/interpret', {'text': text}));
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
  void dispose() => _client.close();
}
