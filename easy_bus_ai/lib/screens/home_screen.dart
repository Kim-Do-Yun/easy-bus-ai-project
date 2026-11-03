import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';

import '../models/bus_models.dart';
import '../services/api_service.dart';
import '../services/device_service.dart';
import 'splash_screen.dart';

enum HomePhase { map, recording, processing, guidance, attention }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _api = ApiService();
  final _device = DeviceService();
  final _origin = TextEditingController(text: '현재 위치');
  final _destination = TextEditingController();
  NaverMapController? _map;
  HomePhase _phase = HomePhase.map;
  BusRoute? _route;
  int _request = 0;
  bool _loading = false;
  bool _audioTransition = false;
  Timer? _loadingTimer, _recordTimer;
  final List<NOverlayInfo> _routeOverlays = [];
  Future<void> _mapQueue = Future.value();
  bool get _busy => _phase == HomePhase.processing;
  bool _valid(int id) => mounted && id == _request;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _notice(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.toString().replaceFirst('Exception: ', '')),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _prepareMap(NaverMapController controller) async {
    _map = controller;
    final generation = _request;
    try {
      final position = await _device.currentPosition();
      if (!mounted) return;
      await controller.addOverlay(
        NMarker(
          id: 'current',
          position: _latLng(position),
          caption: const NOverlayCaption(text: '현재 위치'),
        ),
      );
      if (generation == _request)
        await controller.updateCamera(
          NCameraUpdate.scrollAndZoomTo(target: _latLng(position), zoom: 15),
        );
      final stops = await _api.stops(position);
      if (!mounted) return;
      for (final stop in stops) {
        await controller.addOverlay(
          NMarker(
            id: 'stop_${stop.id}',
            position: _latLng(stop),
            caption: NOverlayCaption(text: stop.name),
          ),
        );
      }
    } catch (error) {
      _notice(error);
    }
  }

  NLatLng _latLng(Place p) => NLatLng(p.latitude, p.longitude);

  int _begin() {
    final id = ++_request;
    _loadingTimer?.cancel();
    setState(() {
      _phase = HomePhase.processing;
      _loading = false;
    });
    // 빠른 응답에는 로딩 화면을 띄우지 않아 깜빡임을 줄인다.
    _loadingTimer = Timer(const Duration(milliseconds: 300), () {
      if (_valid(id) && _busy) setState(() => _loading = true);
    });
    return id;
  }

  Future<Place?> _resolve(String name, int id, String label) async {
    if (name.trim().isEmpty) throw Exception('$label 장소를 입력해 주세요.');
    final candidates = await _api.locations(name.trim());
    if (!_valid(id)) return null;
    if (candidates.isEmpty)
      throw Exception('$label 장소를 찾지 못했습니다. 이름을 자세히 입력해 주세요.');
    if (candidates.length == 1) return candidates.first;
    // 동명이인 장소는 자동 선택하지 않고 사용자에게 후보를 보여 준다.
    return showModalBottomSheet<Place>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '$label 장소를 선택해 주세요',
                  style: const TextStyle(fontSize: 22),
                ),
              ),
              Expanded(
                child: ListView(
                  children: candidates
                      .map(
                        (p) => ListTile(
                          minVerticalPadding: 16,
                          title: Text(p.name),
                          subtitle: Text('${p.latitude}, ${p.longitude}'),
                          onTap: () => Navigator.pop(context, p),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _search({String? audioPath}) async {
    if (_busy || _phase == HomePhase.recording) return;
    final id = _begin();
    try {
      var originName = _origin.text.trim();
      var destinationName = _destination.text.trim();
      if (audioPath != null) {
        final text = await _api.speech(audioPath);
        if (!_valid(id)) return;
        final interpretation = await _api.interpret(text);
        if (!_valid(id)) return;
        if (interpretation.needsClarification)
          throw Exception(
            interpretation.clarificationMessage ?? '목적지를 자세히 말씀해 주세요.',
          );
        originName = interpretation.useCurrentLocation
            ? '현재 위치'
            : interpretation.origin ?? '';
        destinationName = interpretation.destination ?? '';
        _origin.text = originName;
        _destination.text = destinationName;
      }
      if (destinationName.isEmpty) throw Exception('목적지를 입력해 주세요.');
      final origin = originName.isEmpty || originName == '현재 위치'
          ? await _device.currentPosition()
          : await _resolve(originName, id, '출발지');
      if (!_valid(id) || origin == null) return;
      final destination = await _resolve(destinationName, id, '목적지');
      if (!_valid(id) || destination == null) return;
      final routes = await _api.routes(origin, destination);
      if (!_valid(id)) return;
      if (routes.isEmpty || routes.first.segments.isEmpty)
        throw Exception('이용 가능한 버스 경로가 없습니다.');
      final result = routes.first;
      await _replaceRoute(result, id);
      if (!_valid(id)) return;
      try {
        await _device.speak(result.guidance);
      } catch (error) {
        _notice('음성 안내를 재생하지 못했습니다.');
      }
    } catch (error) {
      if (_valid(id)) {
        _notice(error);
        setState(() => _phase = HomePhase.attention);
      }
    } finally {
      if (audioPath != null) {
        try {
          await _device.deleteRecording(audioPath);
        } catch (_) {
          /* 임시 파일 정리 오류는 경로 결과를 바꾸지 않는다. */
        }
      }
      if (_valid(id)) {
        _loadingTimer?.cancel();
        setState(() {
          _loading = false;
          if (_phase != HomePhase.attention)
            _phase = _route == null ? HomePhase.map : HomePhase.guidance;
        });
      }
    }
  }

  Future<void> _replaceRoute(BusRoute route, int id) {
    // 지도 변경을 순서대로 실행하여 취소된 응답이 새 경로를 덮어쓰지 않게 한다.
    final task = _mapQueue.then((_) async {
      if (!_valid(id)) return;
      if (_map == null) throw Exception('지도가 준비된 뒤 다시 검색해 주세요.');
      final added = <NOverlayInfo>[];
      try {
        for (var i = 0; i < route.segments.length; i++) {
          final segment = route.segments[i];
          for (final entry in [
            MapEntry('start', segment.start),
            MapEntry('end', segment.end),
          ]) {
            final marker = NMarker(
              id: 'route_${id}_${i}_${entry.key}',
              position: _latLng(entry.value),
              caption: NOverlayCaption(
                text:
                    '${segment.type == 'BUS' ? (entry.key == 'start' ? '승차' : '하차') : (i == 0 && entry.key == 'start' ? '출발' : '도보')} ${entry.value.name}',
              ),
            );
            added.add(marker.info);
            await _map!.addOverlay(marker);
          }
          // 정류장을 연결한 직선은 그리지 않고 실제 형상만 표시한다.
          if (segment.geometryStatus == 'available' &&
              segment.coordinates.length >= 2) {
            final line = NPolylineOverlay(
              id: 'route_${id}_${i}_line',
              coords: segment.coordinates.map(_latLng).toList(),
              color: segment.type == 'BUS' ? Colors.blue : Colors.green,
              width: 6,
            );
            added.add(line.info);
            await _map!.addOverlay(line);
          }
        }
        if (!_valid(id)) {
          for (final info in added) {
            await _map!.deleteOverlay(info);
          }
          return;
        }
        // 유효성 확인 직후 UI와 소유 목록을 함께 확정한다.
        final previous = List<NOverlayInfo>.of(_routeOverlays);
        _routeOverlays
          ..clear()
          ..addAll(added);
        setState(() => _route = route);
        for (final info in previous) {
          try {
            await _map!.deleteOverlay(info);
          } catch (error) {
            _routeOverlays.add(info);
            _notice('이전 지도 표시 일부를 지우지 못했습니다. 뒤로 가기를 눌러 주세요.');
          }
        }
      } catch (_) {
        for (final info in added) {
          try {
            await _map!.deleteOverlay(info);
          } catch (_) {}
        }
        rethrow;
      }
    });
    _mapQueue = task.catchError((Object error) {});
    return task;
  }

  Future<void> _microphone() async {
    if (_busy || _audioTransition) return;
    if (_phase == HomePhase.recording) {
      _recordTimer?.cancel();
      // 녹음 종료 중에도 중복 탭을 막는다.
      final id = _begin();
      setState(() => _audioTransition = true);
      String? recordedPath;
      try {
        final path = await _device.stopRecording();
        if (!_valid(id)) {
          await _device.deleteRecording(path);
          return;
        }
        recordedPath = path;
      } catch (error) {
        if (_valid(id)) {
          _cancelRequest();
          _notice(error);
        }
      } finally {
        if (mounted) setState(() => _audioTransition = false);
      }
      // 녹음 장치 전환을 끝낸 뒤 서버 요청을 시작한다.
      if (_valid(id) && recordedPath != null) {
        setState(() => _phase = HomePhase.map);
        await _search(audioPath: recordedPath);
      }
    } else {
      final id = _begin();
      // 권한 창이 열린 동안 취소해도 이전 시작 작업이 끝나기 전에는 재녹음을 막는다.
      setState(() => _audioTransition = true);
      try {
        await _device.startRecording();
        if (!_valid(id)) {
          await _device.cancelRecording();
          return;
        }
        _loadingTimer?.cancel();
        setState(() {
          _loading = false;
          _phase = HomePhase.recording;
        });
        _recordTimer = Timer(const Duration(seconds: 55), _microphone);
      } catch (error) {
        if (_valid(id)) {
          _cancelRequest();
          _notice(error);
        }
      } finally {
        if (mounted) setState(() => _audioTransition = false);
      }
    }
  }

  void _cancelRequest() {
    ++_request;
    _loadingTimer?.cancel();
    setState(() {
      _loading = false;
      _phase = _route == null ? HomePhase.map : HomePhase.guidance;
    });
  }

  Future<void> _back() async {
    if (_busy) {
      _cancelRequest();
      return;
    }
    if (_phase == HomePhase.recording) {
      _recordTimer?.cancel();
      _cancelRequest();
      setState(() => _audioTransition = true);
      try {
        await _device.cancelRecording();
      } catch (error) {
        _notice(error);
      } finally {
        if (mounted) setState(() => _audioTransition = false);
      }
      return;
    }
    ++_request;
    setState(() {
      _route = null;
      _phase = HomePhase.map;
    });
    // TTS 종료를 기다리는 동안 새 경로가 먼저 큐에 들어가지 않도록 지도 정리를 예약한다.
    final task = _mapQueue.then((_) async {
      if (!mounted || _map == null) return;
      for (final info in _routeOverlays) {
        await _map!.deleteOverlay(info);
      }
      _routeOverlays.clear();
    });
    _mapQueue = task.catchError((Object error) {
      _notice(error);
    });
    try {
      await _device.stopSpeaking();
    } catch (error) {
      _notice('음성 안내를 중지하지 못했습니다.');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        (_busy || _phase == HomePhase.recording)) {
      final wasRecording = _phase == HomePhase.recording;
      _recordTimer?.cancel();
      _cancelRequest();
      // 업로드 중인 파일은 검색 작업이 정리하고 진행 중 녹음만 여기서 취소한다.
      if (wasRecording && !_audioTransition) {
        setState(() => _audioTransition = true);
        unawaited(
          _device
              .cancelRecording()
              .catchError((Object error) {
                _notice(error);
              })
              .whenComplete(() {
                if (mounted) setState(() => _audioTransition = false);
              }),
        );
      }
    }
  }

  @override
  void dispose() {
    ++_request;
    WidgetsBinding.instance.removeObserver(this);
    _loadingTimer?.cancel();
    _recordTimer?.cancel();
    _api.dispose();
    unawaited(_device.dispose().catchError((Object error) {}));
    _origin.dispose();
    _destination.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && _phase != HomePhase.recording && _route == null,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _back();
    },
    child: Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          NaverMap(
            key: const ValueKey('persistent-map'),
            onMapReady: _prepareMap,
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (_route != null ||
                                _busy ||
                                _phase == HomePhase.recording)
                              IconButton(
                                onPressed: _back,
                                tooltip: '뒤로 가기',
                                icon: const Icon(Icons.arrow_back),
                                iconSize: 30,
                              ),
                            Expanded(
                              child: TextField(
                                controller: _origin,
                                enabled:
                                    !_busy && _phase != HomePhase.recording,
                                style: const TextStyle(fontSize: 20),
                                decoration: const InputDecoration(
                                  labelText: '출발지',
                                  hintText: '현재 위치',
                                ),
                              ),
                            ),
                          ],
                        ),
                        TextField(
                          controller: _destination,
                          enabled: !_busy && _phase != HomePhase.recording,
                          style: const TextStyle(fontSize: 20),
                          decoration: const InputDecoration(
                            labelText: '목적지',
                            hintText: '어디로 가시나요?',
                          ),
                          onSubmitted: (_) => _search(),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton(
                            onPressed: _busy || _phase == HomePhase.recording
                                ? null
                                : () {
                                    FocusScope.of(context).unfocus();
                                    _search();
                                  },
                            child: const Text(
                              '버스 찾기',
                              style: TextStyle(fontSize: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_route != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 245,
              right: 12,
              bottom: 125,
              width: MediaQuery.sizeOf(context).width * 0.56,
              child: Card(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '환승 ${_route!.transferCount}회',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      for (final s in _route!.segments)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.type == 'BUS'
                                    ? '${s.bus?.number ?? ''}번 버스'
                                    : '도보',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '${s.start.name} → ${s.end.name}',
                                style: const TextStyle(fontSize: 18),
                              ),
                              if (s.type == 'BUS') Text(s.arrival.label),
                              if (s.geometryStatus != 'available')
                                const Text('상세 이동 경로 미제공'),
                            ],
                          ),
                        ),
                      TextButton(
                        onPressed: _busy || _phase == HomePhase.recording
                            ? null
                            : () async {
                                try {
                                  await _device.repeat();
                                } catch (error) {
                                  _notice('음성 안내를 재생하지 못했습니다.');
                                }
                              },
                        child: const Text('안내 다시 듣기'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ValueListenableBuilder<String?>(
            valueListenable: mapAuthError,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(error),
                      ),
                    ),
                  ),
          ),
          if (_loading)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: _cancelRequest,
                            child: const Text('요청 취소'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // 로딩과 경로 안내 중에도 마이크의 위치와 가시성을 유지한다.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: SizedBox(
                  height: 80,
                  width: 180,
                  child: FilledButton.icon(
                    onPressed: _busy || _audioTransition ? null : _microphone,
                    style: FilledButton.styleFrom(
                      backgroundColor: _phase == HomePhase.recording
                          ? Colors.red
                          : null,
                    ),
                    icon: Icon(
                      _phase == HomePhase.recording ? Icons.stop : Icons.mic,
                      size: 36,
                    ),
                    label: Text(
                      _phase == HomePhase.recording ? '녹음 끝내기' : '말로 찾기',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
