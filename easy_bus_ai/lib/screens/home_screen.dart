import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';

import '../models/bus_models.dart';
import '../services/api_service.dart';
import '../services/device_service.dart';
import 'bus_detail_screen.dart';
import 'splash_screen.dart';

// 디자인 시스템(Clear Voice Transit)의 색상 토큰을 화면 간에 공유한다.
class EasyColors {
  static const surface = Color(0xFFFAF8FF);
  static const white = Color(0xFFFFFFFF);
  static const surfaceContainer = Color(0xFFEAEDFF);
  static const surfaceContainerHigh = Color(0xFFE2E7FF);
  static const surfaceContainerHighest = Color(0xFFDAE2FD);
  static const onSurface = Color(0xFF131B2E);
  static const onSurfaceVariant = Color(0xFF434655);
  static const outline = Color(0xFF737686);
  static const outlineVariant = Color(0xFFC3C6D7);
  static const primary = Color(0xFF004AC6);
  static const primaryContainer = Color(0xFF2563EB);
  static const primaryFixed = Color(0xFFDBE1FF);
  static const onPrimaryFixed = Color(0xFF00174B);
  static const secondary = Color(0xFF006C49);
  static const secondaryContainer = Color(0xFF6CF8BB);
  static const onSecondaryFixed = Color(0xFF002113);
  static const tertiary = Color(0xFFAB0B1C);
  static const tertiaryContainer = Color(0xFFCF2C30);
  static const onTertiaryContainer = Color(0xFFFFECEA);
  static const recording = Color(0xFFEF4444);
  static const walk = Color(0xFF64748B);
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x1A000000),
      offset: Offset(0, 4),
      blurRadius: 6,
      spreadRadius: -1,
    ),
    BoxShadow(
      color: Color(0x1A000000),
      offset: Offset(0, 2),
      blurRadius: 4,
      spreadRadius: -2,
    ),
  ];
}

enum HomePhase { map, recording, processing, guidance, attention }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _api = ApiService();
  final _device = DeviceService();
  // 출발지가 비어 있으면 안내 문구를 표시하고 기존 GPS 분기를 사용한다.
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _originFocus = FocusNode(), _destinationFocus = FocusNode();
  String _status = '', _heard = '';
  String? _voiceProblem;
  bool _editingInputs = false;
  ModalBottomSheetRoute<Place>? _placeSheet;
  // 후보 목록에서 확정한 출발지·목적지와 선택 마커이며 입력 문구가 바뀌면 확정을 해제한다.
  Place? _originPlace, _destinationPlace;
  NMarker? _originMarker, _destinationMarker;
  NaverMapController? _map;
  HomePhase _phase = HomePhase.map;
  BusRoute? _route;
  // 최적 1·최적 2 선택지와 현재 선택 위치이며 재검색 없이 이미 받은 경로 사이에서 전환한다.
  List<BusRoute> _options = const [];
  int _selected = 0;
  String _originLabel = '', _destinationLabel = '';
  final Map<Color, NOverlayImage> _stopIcons = {};
  int _request = 0;
  bool _loading = false;
  bool _audioTransition = false;
  // 음성 대화 상태이며 출발지·목적지 값 자체는 기존 입력창과 확정 장소를 그대로 사용한다.
  // 인식 결과를 받은 시도를 단계별로 센다. 통신 오류·장치 오류·취소는 제외한다.
  bool _voiceActive = false;
  String? _awaitingSlot;
  int _voiceAttempts = 0;
  bool _voiceCurrentLocation = false;
  // 말소리를 인식하지 못한 오류만 실패 횟수에 포함한다.
  static const _speechRetryCodes = {
    'EMPTY_AUDIO',
    'EMPTY_SPEECH',
    'SPEECH_FAILED',
  };
  Timer? _loadingTimer;
  final List<NOverlayInfo> _routeOverlays = [];
  Future<void> _mapQueue = Future.value();
  // 화면 상태별 최초 빌드만 기록하여 재빌드 시 로그가 반복되지 않게 한다.
  final _initElapsed = Stopwatch();
  bool _initialBuildLogged = false;
  bool get _busy => _phase == HomePhase.processing;
  bool _valid(int id) => mounted && id == _request;

  @override
  void initState() {
    super.initState();
    _initElapsed.start();
    debugPrint(
      '[EASY_BUS_INIT] HomeScreen initState 진입 (화면=${_initElapsed.elapsedMilliseconds}ms)',
    );
    WidgetsBinding.instance.addObserver(this);
    _origin.addListener(() => _releaseSelection(true));
    _destination.addListener(() => _releaseSelection(false));
  }

  // 확정한 장소명과 입력 문구가 달라지면 이전 좌표와 선택 마커를 쓰지 않는다.
  void _releaseSelection(bool isOrigin) {
    final place = isOrigin ? _originPlace : _destinationPlace;
    final text = (isOrigin ? _origin : _destination).text.trim();
    if (place == null || place.name == text) return;
    if (isOrigin) {
      _originPlace = null;
    } else {
      _destinationPlace = null;
    }
    _removeSelectionMarker(isOrigin);
  }

  void _removeSelectionMarker(bool isOrigin) {
    final marker = isOrigin ? _originMarker : _destinationMarker;
    if (marker == null) return;
    if (isOrigin) {
      _originMarker = null;
    } else {
      _destinationMarker = null;
    }
    // 기존 지도 큐를 사용하여 경로 오버레이 변경과 순서가 섞이지 않게 한다.
    final task = _mapQueue.then((_) async {
      if (!mounted || _map == null) return;
      await _map!.deleteOverlay(marker.info);
    });
    _mapQueue = task.catchError((Object error) {});
  }

  // 경로를 표시하는 동안에는 경로의 출발·도착 마커와 겹치지 않도록 선택 마커를 숨긴다.
  void _showSelectionMarkers(bool visible) {
    _originMarker?.setIsVisible(visible);
    _destinationMarker?.setIsVisible(visible);
  }

  // 선택한 장소의 좌표를 확정하고, 입력창 문구·선택 마커·지도 카메라를 갱신한다. 경로 검색은 하지 않는다.
  Future<void> _confirmPlace(
    Place place,
    bool isOrigin, {
    bool moveCamera = true,
  }) async {
    if (isOrigin) {
      _originPlace = place;
    } else {
      _destinationPlace = place;
    }
    // 확정 장소를 먼저 저장해 두어 문구 변경 감지에서 해제되지 않게 한다.
    (isOrigin ? _origin : _destination).text = place.name;
    _removeSelectionMarker(isOrigin);
    final marker = NMarker(
      id: isOrigin ? 'select_origin' : 'select_destination',
      position: _latLng(place),
      iconTintColor: isOrigin
          ? EasyColors.primaryContainer
          : EasyColors.tertiaryContainer,
      caption: NOverlayCaption(
        text: isOrigin ? '출발지' : '도착지',
        textSize: 15,
        color: EasyColors.onSurface,
      ),
      subCaption: NOverlayCaption(
        text: place.name,
        textSize: 13,
        color: EasyColors.onSurfaceVariant,
      ),
    );
    if (isOrigin) {
      _originMarker = marker;
    } else {
      _destinationMarker = marker;
    }
    final task = _mapQueue.then((_) async {
      if (!mounted || _map == null) return;
      // 그 사이 다른 장소가 선택되었으면 오래된 마커를 추가하지 않는다.
      if (!identical(isOrigin ? _originMarker : _destinationMarker, marker))
        return;
      await _map!.addOverlay(marker);
      if (_route != null) marker.setIsVisible(false);
      if (!moveCamera) return;
      await _map!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: _latLng(place), zoom: 16),
      );
    });
    _mapQueue = task.catchError((Object error) {});
    await task;
  }

  // 입력창에서 검색 키를 누르면 후보를 찾아 선택만 하고, 경로 검색은 출발지·목적지 확정 후 수행한다.
  Future<void> _pickPlace(bool isOrigin) async {
    if (_busy || _audioTransition || _phase == HomePhase.recording) return;
    final text = (isOrigin ? _origin : _destination).text.trim();
    // 출발지를 비우면 기존 GPS 출발 분기를 그대로 사용한다.
    if (text.isEmpty) {
      if (!isOrigin) _notice('목적지를 입력해 주세요.');
      return;
    }
    final id = _begin('장소를 찾고 있어요.');
    try {
      final place = await _resolve(text, id, isOrigin ? '출발지' : '목적지');
      if (!_valid(id) || place == null) return;
      await _confirmPlace(place, isOrigin);
      if (!_valid(id)) return;
      setState(() {
        _voiceAttempts = 0;
        _voiceProblem = null;
      });
    } catch (error) {
      if (_valid(id)) _notice(error);
    } finally {
      if (_valid(id)) {
        _loadingTimer?.cancel();
        setState(() {
          _loading = false;
          _phase = _route == null ? HomePhase.map : HomePhase.guidance;
        });
      }
    }
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

  void _setStatus(String message) {
    if (mounted) setState(() => _status = message);
  }

  // 무발화·인식 실패도 한 번의 시도이다. 통신 오류·장치 오류·취소는 여기에 보내지 않는다.
  Future<void> _voiceFailure(String message) async {
    if (!mounted) return;
    _voiceAttempts++;
    final guidance = _voiceAttempts >= VoicePolicy.maxAttempts
        ? '$message 화면에서 장소를 고르거나 글자로 입력해 주세요.'
        : '$message 다시 말하거나 화면에서 고르거나 글자로 입력해 주세요.';
    setState(() => _voiceProblem = guidance);
    _notice(guidance);
    try {
      await _device.speak(guidance);
    } catch (_) {
      /* 화면 안내는 유지한다. */
    }
  }

  void _typeInstead() {
    if (_busy || _audioTransition) return;
    setState(() {
      _editingInputs = true;
      _voiceProblem = null;
    });
    final origin =
        _awaitingSlot == 'origin' ||
        (_origin.text.isEmpty && !_voiceCurrentLocation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (origin ? _originFocus : _destinationFocus).requestFocus();
    });
  }

  // 부분 인식 문자열을 수정해 기존 후보 검색으로 연결한다. 후보의 역할은 사용자가 지정한다.
  Future<void> _chooseInstead() async {
    if (_busy || _audioTransition) return;
    final generation = _request;
    var query = _awaitingSlot == 'origin'
        ? _origin.text
        : _awaitingSlot == 'destination'
        ? _destination.text
        : _heard;
    if (query.trim().isEmpty) query = _heard;
    final choice = await showModalBottomSheet<({bool origin, String query})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('찾을 장소를 확인해 주세요', style: TextStyle(fontSize: 22)),
                TextFormField(
                  initialValue: query,
                  onChanged: (value) => query = value,
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(hintText: '장소 이름 입력'),
                ),
                for (final origin in [true, false])
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        onPressed: () {
                          if (query.trim().isNotEmpty) {
                            Navigator.pop(sheetContext, (
                              origin: origin,
                              query: query.trim(),
                            ));
                          }
                        },
                        child: Text(
                          origin ? '출발지 후보 보기' : '목적지 후보 보기',
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!_valid(generation) || choice == null) return;
    (choice.origin ? _origin : _destination).text = choice.query;
    _awaitingSlot = choice.origin ? 'origin' : 'destination';
    _editingInputs = true;
    final id = _begin('장소를 찾고 있어요.');
    var confirmed = false;
    try {
      final place = await _resolve(
        choice.query,
        id,
        choice.origin ? '출발지' : '목적지',
      );
      if (!_valid(id) || place == null) return;
      await _confirmPlace(place, choice.origin);
      if (!_valid(id)) return;
      confirmed = true;
      setState(() {
        _editingInputs = true;
        _voiceProblem = null;
        _voiceAttempts = 0;
        if (choice.origin) _voiceCurrentLocation = false;
        _awaitingSlot = _origin.text.isEmpty && !_voiceCurrentLocation
            ? 'origin'
            : _destination.text.isEmpty
            ? 'destination'
            : null;
      });
    } catch (error) {
      if (_valid(id)) {
        _notice(error);
        setState(() => _voiceProblem = error.toString());
      }
    } finally {
      if (_valid(id)) {
        _loadingTimer?.cancel();
        setState(() {
          _loading = false;
          _phase = HomePhase.map;
        });
      }
    }
    if (confirmed &&
        _valid(id) &&
        _destination.text.isNotEmpty &&
        (_origin.text.isNotEmpty || _voiceCurrentLocation))
      await _search();
  }

  Future<void> _prepareMap(NaverMapController controller) async {
    debugPrint(
      '[EASY_BUS_INIT] onMapReady 호출 (화면=${_initElapsed.elapsedMilliseconds}ms)',
    );
    _map = controller;
    final generation = _request;
    final stageElapsed = Stopwatch()..start();
    var stage = 'GPS 조회';
    try {
      debugPrint('[EASY_BUS_INIT] $stage 시작');
      final position = await _device.currentPosition();
      debugPrint(
        '[EASY_BUS_INIT] $stage 완료 (단계=${stageElapsed.elapsedMilliseconds}ms)',
      );
      if (!mounted) return;
      stage = '현재 위치 지도 반영';
      stageElapsed.reset();
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
      stage = '정류장 조회';
      stageElapsed.reset();
      debugPrint(
        '[EASY_BUS_INIT] $stage 시작 (화면=${_initElapsed.elapsedMilliseconds}ms)',
      );
      final stops = await _api.stops(position);
      debugPrint(
        '[EASY_BUS_INIT] $stage 완료 (단계=${stageElapsed.elapsedMilliseconds}ms)',
      );
      if (!mounted) return;
      stage = '정류장 지도 반영';
      stageElapsed.reset();
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
      // 위치와 응답 원문은 제외하고 실패 단계의 유형과 소요 시간만 기록한다.
      debugPrint(
        '[EASY_BUS_INIT] $stage 예외 유형=${error.runtimeType} '
        '(단계=${stageElapsed.elapsedMilliseconds}ms)',
      );
      if (_valid(generation)) _notice(error);
    }
  }

  NLatLng _latLng(Place p) => NLatLng(p.latitude, p.longitude);

  int _begin([String message = '장소를 확인하고 있어요.']) {
    final id = ++_request;
    _loadingTimer?.cancel();
    setState(() {
      _phase = HomePhase.processing;
      _loading = false;
      _status = message;
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
    if (!mounted || !_valid(id)) return null;
    if (candidates.isEmpty)
      throw ApiException(
        '$label 장소를 찾지 못했습니다. 이름을 자세히 입력해 주세요.',
        'LOCATION_NOT_FOUND',
      );
    // 한 후보여도 부분 명칭·다른 지역일 수 있으므로 주소를 보고 직접 확정한다.
    // 동명이인 장소는 자동 선택하지 않고 사용자에게 후보를 보여 준다.
    final navigator = Navigator.of(context);
    final sheet = ModalBottomSheetRoute<Place>(
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
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
                          title: Text(
                            p.name,
                            style: const TextStyle(fontSize: 20),
                          ),
                          // 장소 구분과 주소(정류장은 정류장 번호)를 표시하고, 둘 다 없으면 기존처럼 좌표를 보여 준다.
                          subtitle: Text(
                            p.tagoId != null || p.kind == 'STOP'
                                ? '버스 정류장${p.arsId != null ? ' · 정류장 번호 ${p.arsId}' : ''}'
                                : p.address != null
                                ? '${p.kind == 'PLACE' ? '장소' : '주소'} · ${p.address}'
                                : '${p.latitude}, ${p.longitude}',
                          ),
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
    _placeSheet = sheet;
    try {
      return await navigator.push(sheet);
    } finally {
      if (identical(_placeSheet, sheet)) _placeSheet = null;
    }
  }

  Future<void> _search({String? audioPath}) async {
    if (_busy || _audioTransition || _phase == HomePhase.recording) return;
    final attemptsBefore = _voiceAttempts;
    final id = _begin();
    try {
      var originName = _origin.text.trim();
      var destinationName = _destination.text.trim();
      if (audioPath != null) {
        _setStatus('음성을 전송하고 말씀을 확인하고 있어요.');
        // 출발지·목적지가 모두 확인될 때까지는 재질문만 하고 경로 검색으로 넘어가지 않는다.
        if (!await _voiceTurn(audioPath, id) || !_valid(id)) return;
        originName = _origin.text.trim();
        destinationName = _destination.text.trim();
      }
      if (destinationName.isEmpty) throw Exception('목적지를 입력해 주세요.');
      // 후보 목록에서 이미 확정한 장소는 다시 검색하지 않고 저장한 좌표를 그대로 사용한다.
      final originPlace = _originPlace, destinationPlace = _destinationPlace;
      final voice = audioPath != null;
      _setStatus(
        originName.isEmpty || originName == '현재 위치'
            ? '현재 위치를 확인하고 있어요.'
            : '출발지를 확인하고 있어요.',
      );
      final origin = originName.isEmpty || originName == '현재 위치'
          ? await _currentOrigin(id, voice)
          : originPlace != null && originPlace.name == originName
          ? originPlace
          : await _resolvePlace(originName, id, true, voice);
      if (!_valid(id) || origin == null) return;
      try {
        if (origin.id != 'current' && !identical(origin, _originPlace)) {
          await _confirmPlace(origin, true, moveCamera: false);
        }
      } catch (_) {
        /* 좌표 확정 후 지도 마커 실패는 경로 검색을 막지 않는다. */
      }
      if (!_valid(id)) return;
      _setStatus('목적지를 확인하고 있어요.');
      final destination =
          destinationPlace != null && destinationPlace.name == destinationName
          ? destinationPlace
          : await _resolvePlace(destinationName, id, false, voice);
      if (!_valid(id) || destination == null) return;
      try {
        if (!identical(destination, _destinationPlace)) {
          await _confirmPlace(destination, false, moveCamera: false);
        }
      } catch (_) {
        /* 좌표 확정 후 지도 마커 실패는 경로 검색을 막지 않는다. */
      }
      if (!_valid(id)) return;
      _setStatus('버스 경로를 찾고 있어요.');
      if (voice) {
        try {
          await _device.speak('버스 경로를 찾고 있습니다.');
        } catch (_) {
          /* 시작 안내 실패는 경로 검색을 막지 않는다. */
        }
      }
      if (!_valid(id)) return;
      final routes = await _api.routes(origin, destination);
      if (!_valid(id)) return;
      if (routes.isEmpty || routes.first.segments.isEmpty)
        throw Exception('이용 가능한 버스 경로가 없습니다.');
      // 서버가 구분한 최적 1·최적 2만 선택지로 쓰고, 구분이 없으면 기존처럼 첫 후보를 사용한다.
      final recommended = routes
          .where((r) => r.recommendation != null && r.segments.isNotEmpty)
          .take(2)
          .toList();
      final options = recommended.isEmpty ? [routes.first] : recommended;
      final result = options.first;
      await _replaceRoute(
        result,
        id,
        accent: _accent(0),
        commit: () {
          _options = options;
          _selected = 0;
          _originLabel = origin.name;
          _destinationLabel = destination.name;
        },
      );
      if (!_valid(id)) return;
      // 경로를 받으면 음성 대화를 마치고 다음 음성 입력은 새 경로 요청으로 본다.
      _resetVoice();
      setState(() {
        _editingInputs = false;
        _status = '경로를 찾았습니다.';
      });
      // 검색 버튼에서 바로 고른 장소도 확정해 두어 뒤로 가기 후 다시 검색할 때 재조회하지 않는다.
      // 경로 화면 맞춤을 유지하도록 카메라는 움직이지 않으며 선택 마커는 경로를 지울 때 보인다.
      try {
        if (origin.id != 'current' && !identical(origin, _originPlace))
          await _confirmPlace(origin, true, moveCamera: false);
        if (!identical(destination, _destinationPlace))
          await _confirmPlace(destination, false, moveCamera: false);
      } catch (_) {
        /* 선택 마커 표시 실패는 경로 결과를 바꾸지 않는다. */
      }
      if (!_valid(id)) return;
      try {
        await _device.speak(result.guidance);
      } catch (error) {
        _notice('음성 안내를 재생하지 못했습니다.');
      }
    } catch (error) {
      if (_valid(id)) {
        // 장소·경로 서버 장애 때문에 음성 입력 한도가 소모되지는 않게 한다.
        if (audioPath != null &&
            error is ApiException &&
            _voiceAttempts > attemptsBefore) {
          _voiceAttempts = attemptsBefore;
        }
        _notice(error);
        setState(() => _phase = HomePhase.attention);
        if (audioPath != null)
          setState(
            () => _voiceProblem = error.toString().replaceFirst(
              'Exception: ',
              '',
            ),
          );
        // 음성으로 요청한 경우 실패 안내도 기존 TTS로 들려준다.
        if (audioPath != null) {
          try {
            await _device.speak(
              error.toString().replaceFirst('Exception: ', ''),
            );
          } catch (_) {
            /* 실패 안내 재생 오류는 화면 안내로 대신한다. */
          }
        }
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

  // 음성 한 번을 인식·해석하여 기존 출발지·목적지와 합치고, 빠진 장소가 있으면 재질문한 뒤 false를 반환한다.
  Future<bool> _voiceTurn(String audioPath, int id) async {
    final String text;
    try {
      text = await _api.speech(audioPath);
    } on ApiException catch (error) {
      if (!_valid(id) || !_speechRetryCodes.contains(error.code)) rethrow;
      await _voiceFailure(error.message);
      return false;
    }
    if (!_valid(id)) return false;
    _voiceAttempts++;
    _heard = text;
    _setStatus('말씀의 뜻을 확인하고 있어요.');
    final Interpretation result;
    try {
      result = await _api.interpret(
        text,
        expectedSlot: _awaitingSlot == 'both' ? null : _awaitingSlot,
      );
    } on ApiException catch (error) {
      if (!_valid(id)) rethrow;
      if (error.code != 'INVALID_AI_RESPONSE') {
        // 해석 서버·통신 문제로 중단된 시도는 사용자 입력 한도를 소모하지 않는다.
        _voiceAttempts--;
        rethrow;
      }
      await _askAgain('어디에서 어디로 가시는지 다시 말씀해 주세요.', heard: text);
      if (_valid(id)) setState(() => _voiceProblem = '들은 말씀을 장소로 확인하지 못했습니다.');
      return false;
    }
    if (!_valid(id)) return false;
    _voiceActive = true;
    if (result.origin == null &&
        result.destination == null &&
        !result.useCurrentLocation) {
      setState(() => _voiceProblem = '들은 말씀에서 장소를 골라 주세요.');
    }
    // 이번 발화에서 말한 항목만 갱신하고, 말하지 않은 항목과 확정 장소는 그대로 둔다.
    if (result.useCurrentLocation) {
      _origin.text = '';
      _voiceCurrentLocation = true;
    } else if (result.origin != null) {
      _origin.text = result.origin!;
      _voiceCurrentLocation = false;
    }
    if (result.destination != null) _destination.text = result.destination!;
    final hasOrigin = _voiceCurrentLocation || _origin.text.trim().isNotEmpty;
    final hasDestination = _destination.text.trim().isNotEmpty;
    if (hasOrigin && hasDestination) {
      _awaitingSlot = null;
      return true;
    }
    final slot = !hasOrigin && !hasDestination
        ? 'both'
        : !hasOrigin
        ? 'origin'
        : 'destination';
    // 한 항목을 얻고 다른 항목을 새로 묻는 경우만 다음 단계의 한도를 시작한다.
    if (slot != _awaitingSlot &&
        (result.origin != null ||
            result.destination != null ||
            result.useCurrentLocation)) {
      _voiceAttempts = 0;
    }
    await _askAgain(
      slot == 'both'
          ? '어디에서 어디로 가시는지 말씀해 주세요.'
          : slot == 'origin'
          ? '어디에서 출발하시나요?'
          : '어디로 가시나요?',
      slot: slot,
      heard: text,
    );
    return false;
  }

  // 누락 장소 재질문은 화면과 TTS로 전달하며 인식 실패 횟수에 포함하지 않는다.
  Future<void> _askAgain(String question, {String? slot, String? heard}) async {
    var message = question;
    if (slot != null) {
      _awaitingSlot = slot;
    }
    if (_voiceAttempts >= VoicePolicy.maxAttempts) {
      message = '$question 화면에서 고르거나 글자로 입력해 주세요.';
      setState(() => _voiceProblem = message);
    }
    _notice(heard == null ? message : '"$heard"\n$message');
    try {
      await _device.speak(message);
    } catch (_) {
      /* 재질문 음성 재생 실패는 화면 안내로 대신한다. */
    }
  }

  void _resetVoice() {
    _voiceActive = false;
    _awaitingSlot = null;
    _voiceAttempts = 0;
    _voiceCurrentLocation = false;
    _heard = '';
    _voiceProblem = null;
  }

  // 음성 대화에서 현재 위치를 확인하지 못하면 임의 좌표 없이 출발지를 다시 묻는다.
  Future<Place?> _currentOrigin(int id, bool voice) async {
    try {
      return await _device.currentPosition();
    } catch (error) {
      if (!_valid(id)) return null;
      _voiceCurrentLocation = false;
      setState(() {
        _voiceProblem = error.toString();
        _editingInputs = true;
      });
      await _askAgain('현재 위치를 확인하지 못했습니다. 어디에서 출발하시나요?', slot: 'origin');
      return null;
    }
  }

  // 장소를 찾지 못하면 문자열과 다른 항목을 보존하여 화면 검색에도 재사용한다.
  Future<Place?> _resolvePlace(
    String name,
    int id,
    bool isOrigin,
    bool voice,
  ) async {
    final label = isOrigin ? '출발지' : '목적지';
    if (!voice) return _resolve(name, id, label);
    try {
      return await _resolve(name, id, label);
    } on ApiException catch (error) {
      if (error.code != 'LOCATION_NOT_FOUND') rethrow;
      if (!_valid(id)) return null;
      // 인식된 문자열과 다른 쪽의 확정 장소를 남겨 화면 검색에 재사용한다.
      setState(() => _voiceProblem = '$name 장소를 찾지 못했습니다.');
      await _askAgain(
        '$name 장소를 찾지 못했습니다. $label 이름을 다시 말씀해 주세요.',
        slot: isOrigin ? 'origin' : 'destination',
      );
      return null;
    }
  }

  // 최적 1은 기본 파란색, 최적 2는 디자인의 녹색으로 경로와 카드를 구분한다.
  Color _accent(int index) =>
      index == 1 ? EasyColors.secondary : EasyColors.primaryContainer;

  Future<NOverlayImage?> _stopIcon(Color color) async {
    final cached = _stopIcons[color];
    if (cached != null || !mounted) return cached;
    try {
      // 경유 정류장은 디자인의 흰 원과 색 테두리 표시를 지도 아이콘으로 만든다.
      final icon = await NOverlayImage.fromWidget(
        widget: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: EasyColors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 3),
          ),
        ),
        size: const Size(16, 16),
        context: context,
      );
      return _stopIcons[color] = icon;
    } catch (_) {
      // 아이콘 생성에 실패하면 기본 마커를 작게 표시한다.
      return null;
    }
  }

  Future<void> _replaceRoute(
    BusRoute route,
    int id, {
    Color accent = EasyColors.primaryContainer,
    VoidCallback? commit,
  }) {
    // 지도 변경을 순서대로 실행하여 취소된 응답이 새 경로를 덮어쓰지 않게 한다.
    final task = _mapQueue.then((_) async {
      if (!_valid(id)) return;
      if (_map == null) throw Exception('지도가 준비된 뒤 다시 검색해 주세요.');
      final added = <NOverlayInfo>[];
      final points = <NLatLng>[];
      try {
        final stopIcon = await _stopIcon(accent);
        Future<void> add(NAddableOverlay overlay) async {
          added.add(overlay.info);
          await _map!.addOverlay(overlay);
        }

        Future<void> marker(
          String key,
          Place place,
          String text,
          Color color, [
          String? sub,
        ]) async {
          points.add(_latLng(place));
          await add(
            NMarker(
              id: 'route_${id}_$key',
              position: _latLng(place),
              iconTintColor: color,
              caption: NOverlayCaption(
                text: text,
                textSize: 15,
                color: EasyColors.onSurface,
              ),
              subCaption: sub == null
                  ? null
                  : NOverlayCaption(
                      text: sub,
                      textSize: 13,
                      color: EasyColors.onSurfaceVariant,
                    ),
            ),
          );
        }

        final segments = route.segments;
        // 도보 구간의 끝점은 버스 승하차 정류장과 같으므로 출발지·목적지만 따로 표시한다.
        if (segments.first.type == 'WALK')
          await marker(
            'origin',
            segments.first.start,
            '출발',
            EasyColors.primaryContainer,
          );
        if (segments.last.type == 'WALK')
          await marker(
            'destination',
            segments.last.end,
            '도착',
            EasyColors.tertiaryContainer,
          );
        // 환승 지점은 첫 승차·마지막 하차와 구분되도록 표시 문구만 바꾼다.
        final busIndexes = [
          for (var i = 0; i < segments.length; i++)
            if (segments[i].type == 'BUS') i,
        ];
        for (var i = 0; i < segments.length; i++) {
          final segment = segments[i];
          if (segment.type == 'BUS') {
            final transferIn = i != busIndexes.first;
            final transferOut = i != busIndexes.last;
            await marker(
              '${i}_start',
              segment.start,
              transferIn
                  ? '환승 ${segment.bus?.number ?? ''}번 승차'
                  : '${segment.bus?.number ?? ''}번 승차',
              accent,
              segment.start.name,
            );
            await marker(
              '${i}_end',
              segment.end,
              transferOut ? '하차 후 환승' : '하차',
              EasyColors.tertiary,
              segment.end.name,
            );
            // 경유 정류장은 실제 노선 순서 목록이 제공된 경우에만 작은 원으로 표시한다.
            for (var k = 1; k < segment.stops.length - 1; k++) {
              final stop = segment.stops[k];
              points.add(_latLng(stop));
              await add(
                NMarker(
                  id: 'route_${id}_${i}_stop_$k',
                  position: _latLng(stop),
                  icon: stopIcon,
                  iconTintColor: stopIcon == null ? accent : Colors.transparent,
                  size: stopIcon == null
                      ? const Size(14, 18)
                      : const Size(16, 16),
                  anchor: stopIcon == null
                      ? NMarker.defaultAnchor
                      : const NPoint(0.5, 0.5),
                  caption: NOverlayCaption(
                    text: stop.name,
                    textSize: 12,
                    color: EasyColors.onSurfaceVariant,
                    minZoom: 15,
                  ),
                  isHideCollidedCaptions: true,
                ),
              );
            }
          }
          // 정류장을 연결한 직선은 그리지 않고 실제 형상만 표시한다.
          if (segment.geometryStatus == 'available' &&
              segment.coordinates.length >= 2) {
            final coords = segment.coordinates.map(_latLng).toList();
            points.addAll(coords);
            await add(
              segment.type == 'BUS'
                  ? NPathOverlay(
                      id: 'route_${id}_${i}_line',
                      coords: coords,
                      color: accent,
                      width: 6,
                      outlineWidth: 2,
                      outlineColor: EasyColors.white,
                    )
                  : NPolylineOverlay(
                      id: 'route_${id}_${i}_line',
                      coords: coords,
                      color: EasyColors.walk,
                      width: 4,
                      pattern: const [8, 8],
                    ),
            );
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
        setState(() {
          _route = route;
          commit?.call();
        });
        _showSelectionMarkers(false);
        for (final info in previous) {
          try {
            await _map!.deleteOverlay(info);
          } catch (error) {
            _routeOverlays.add(info);
            _notice('이전 지도 표시 일부를 지우지 못했습니다. 뒤로 가기를 눌러 주세요.');
          }
        }
        // 선택한 경로 전체가 상단 안내와 마이크 버튼에 가리지 않도록 화면을 맞춘다.
        if (mounted && _valid(id) && points.length >= 2) {
          final inset = MediaQuery.paddingOf(context);
          try {
            await _map!.updateCamera(
              NCameraUpdate.fitBounds(
                NLatLngBounds.from(points),
                padding: EdgeInsets.fromLTRB(
                  40,
                  inset.top + 250,
                  40,
                  inset.bottom + 130,
                ),
              ),
            );
          } catch (_) {
            /* 화면 맞춤 실패는 표시된 경로 결과를 바꾸지 않는다. */
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

  Future<void> _selectOption(int index) async {
    if (_busy ||
        _phase == HomePhase.recording ||
        index == _selected ||
        index >= _options.length)
      return;
    // 경로 API를 다시 호출하지 않고 이미 받은 추천 경로로 지도와 카드를 교체한다.
    final id = ++_request;
    final route = _options[index];
    try {
      await _replaceRoute(
        route,
        id,
        accent: _accent(index),
        commit: () => _selected = index,
      );
      if (!_valid(id)) return;
      try {
        await _device.speak(route.guidance);
      } catch (error) {
        _notice('음성 안내를 재생하지 못했습니다.');
      }
    } catch (error) {
      if (_valid(id)) _notice(error);
    }
  }

  Future<void> _openDetail() async {
    final route = _route;
    if (route == null ||
        route.busSegments.isEmpty ||
        _busy ||
        _phase == HomePhase.recording)
      return;
    // 상세 화면은 위에 쌓아 열어 돌아왔을 때 선택한 최적 경로 상태를 유지한다.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BusDetailScreen(
          route: route,
          device: _device,
          accent: _accent(_selected),
        ),
      ),
    );
  }

  Future<void> _microphone() async {
    if (_busy || _audioTransition) return;
    if (_phase == HomePhase.recording) {
      // 녹음 종료 중에도 중복 탭을 막는다.
      final id = _begin('녹음을 완료하고 있어요.');
      setState(() => _audioTransition = true);
      String? recordedPath;
      try {
        if (!_device.heardSpeech) {
          final unavailable = _device.detectionUnavailable;
          await _device.cancelRecording();
          if (!_valid(id)) return;
          if (unavailable) {
            setState(
              () => _voiceProblem =
                  '마이크 음량을 확인하지 못했습니다. 다시 말하거나 다른 입력 방법을 선택해 주세요.',
            );
            _notice(_voiceProblem!);
          } else {
            await _voiceFailure('말소리가 감지되지 않았습니다.');
          }
          if (_valid(id)) {
            _loadingTimer?.cancel();
            setState(() {
              _loading = false;
              _phase = HomePhase.attention;
            });
          }
          return;
        }
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
      if (_voiceAttempts >= VoicePolicy.maxAttempts) {
        setState(() => _voiceProblem = '화면에서 장소를 고르거나 글자로 입력해 주세요.');
        return;
      }
      // 기존 결과는 지도에 유지하되 새 음성 대화에 이전 장소를 섞지 않는다.
      if (!_voiceActive && _route != null && !_editingInputs) {
        _origin.clear();
        _destination.clear();
        _resetVoice();
        // 취소 후 다시 입력해도 이번 검색에서 확보한 장소를 이전 결과로 오인해 비우지 않는다.
        _editingInputs = true;
      }
      _voiceActive = true;
      _voiceProblem = null;
      final id = _begin('마이크를 준비하고 있어요.');
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
          _status = '말씀해 주세요.';
        });
        _device.monitorRecording(
          () {
            if (_valid(id)) _setStatus('말씀을 듣고 있어요.');
          },
          () {
            if (_valid(id) && _phase == HomePhase.recording)
              unawaited(_microphone());
          },
        );
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
    _api.cancelRequests();
    // 취소된 요청의 후보 창만 닫으며 다른 화면을 잘못 pop하지 않는다.
    final sheet = _placeSheet;
    _placeSheet = null;
    if (sheet != null && sheet.isActive) sheet.navigator?.removeRoute(sheet);
    _loadingTimer?.cancel();
    setState(() {
      _loading = false;
      _phase = _route == null ? HomePhase.map : HomePhase.guidance;
      _status = '요청을 취소했습니다.';
      _resetVoice();
    });
    unawaited(_device.stopSpeaking().catchError((Object _) {}));
  }

  Future<void> _back() async {
    if (_busy) {
      _cancelRequest();
      return;
    }
    if (_phase == HomePhase.recording) {
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
    _resetVoice();
    setState(() {
      _route = null;
      _options = const [];
      _selected = 0;
      _phase = HomePhase.map;
    });
    // TTS 종료를 기다리는 동안 새 경로가 먼저 큐에 들어가지 않도록 지도 정리를 예약한다.
    final task = _mapQueue.then((_) async {
      if (!mounted || _map == null) return;
      for (final info in _routeOverlays) {
        await _map!.deleteOverlay(info);
      }
      _routeOverlays.clear();
      // 경로를 지운 뒤에는 확정해 둔 출발지·목적지 선택 마커를 다시 보여 준다.
      _showSelectionMarkers(true);
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
    _api.dispose();
    unawaited(_device.dispose().catchError((Object error) {}));
    _origin.dispose();
    _destination.dispose();
    _originFocus.dispose();
    _destinationFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialBuildLogged) {
      _initialBuildLogged = true;
      debugPrint(
        '[EASY_BUS_INIT] HomeScreen build 최초 진입 (화면=${_initElapsed.elapsedMilliseconds}ms)',
      );
      debugPrint(
        '[EASY_BUS_INIT] NaverMap 위젯 생성 직전 (화면=${_initElapsed.elapsedMilliseconds}ms)',
      );
    }
    return PopScope(
      canPop: !_busy && _phase != HomePhase.recording && _route == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: EasyColors.surface,
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _route == null || _editingInputs
                      ? _inputPanel()
                      : _resultPanel(),
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
                  // 디자인의 반투명 화면 가림과 원형 진행 표시를 사용하고 기존 취소 기능은 유지한다.
                  color: EasyColors.onSurface.withValues(alpha: 0.3),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 5,
                            color: EasyColors.primaryContainer,
                            backgroundColor: Color(0x332563EB),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 22,
                            color: EasyColors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Material(
                          color: EasyColors.white,
                          shape: const StadiumBorder(),
                          elevation: 2,
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: _cancelRequest,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 14,
                              ),
                              child: Text(
                                '요청 취소',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: EasyColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 로딩과 경로 안내 중에도 마이크의 위치와 가시성을 유지한다.
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _micButton(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 입력창 공통 형태: 높이 58, 둥글기 14, 흰 배경과 그림자를 사용한다.
  Widget _inputBox({
    required TextEditingController controller,
    required Widget leading,
    required String hint,
    required Widget trailing,
    required TextInputAction action,
    ValueChanged<String>? onSubmitted,
  }) => Container(
    constraints: const BoxConstraints(minHeight: 58),
    padding: const EdgeInsets.only(left: 16, right: 4),
    decoration: BoxDecoration(
      color: EasyColors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: EasyColors.cardShadow,
    ),
    child: Row(
      children: [
        SizedBox(width: 26, child: Center(child: leading)),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: identical(controller, _origin)
                ? _originFocus
                : _destinationFocus,
            enabled: !_busy && _phase != HomePhase.recording,
            textInputAction: action,
            onSubmitted: onSubmitted,
            onChanged: (_) {
              // 입력 방법만 바꿔 한도를 우회하지 않고 실제로 글자를 고쳤을 때 새 입력으로 본다.
              setState(() {
                _voiceAttempts = 0;
                _voiceProblem = null;
                _voiceActive = true;
                if (identical(controller, _origin))
                  _voiceCurrentLocation = false;
                _awaitingSlot =
                    _origin.text.trim().isEmpty && !_voiceCurrentLocation
                    ? 'origin'
                    : _destination.text.trim().isEmpty
                    ? 'destination'
                    : null;
              });
            },
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: EasyColors.onSurface,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: EasyColors.onSurfaceVariant,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        trailing,
      ],
    ),
  );

  Widget _inputPanel() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          if (_busy || _phase == HomePhase.recording) ...[
            _circleButton(icon: Icons.arrow_back, label: '뒤로 가기', onTap: _back),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: _inputBox(
              controller: _origin,
              // 출발지를 비워 두면 기존 GPS 현재 위치 분기를 그대로 사용한다.
              leading: Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: EasyColors.primaryFixed,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: EasyColors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              hint: '출발지를 입력하세요',
              action: TextInputAction.next,
              // 출발지 입력을 마치면 후보를 골라 지도에서 위치를 확인한다.
              onSubmitted: (_) => _pickPlace(true),
              trailing: const Tooltip(
                message: '비워 두면 현재 위치에서 출발합니다',
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(
                    Icons.my_location,
                    size: 24,
                    color: EasyColors.outline,
                    semanticLabel: '비워 두면 현재 위치에서 출발',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _inputBox(
        controller: _destination,
        leading: const Icon(
          Icons.location_on,
          size: 26,
          color: EasyColors.tertiaryContainer,
        ),
        hint: '도착지를 입력하세요',
        action: TextInputAction.search,
        // 목적지가 확정되지 않았으면 먼저 후보를 골라 위치를 확인하고, 확정된 뒤에는 기존 경로 검색을 수행한다.
        onSubmitted: (_) =>
            _destinationPlace != null &&
                _destinationPlace!.name == _destination.text.trim()
            ? _search()
            : _pickPlace(false),
        trailing: IconButton(
          onPressed: _busy || _phase == HomePhase.recording
              ? null
              : () {
                  FocusScope.of(context).unfocus();
                  _search();
                },
          tooltip: '검색',
          iconSize: 28,
          color: EasyColors.primaryContainer,
          icon: const Icon(Icons.search),
        ),
      ),
    ],
  );

  Widget _circleButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    double size = 52,
  }) => Material(
    color: EasyColors.white,
    shape: const CircleBorder(),
    elevation: 3,
    shadowColor: const Color(0x40000000),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          icon,
          size: 28,
          color: EasyColors.primary,
          semanticLabel: label,
        ),
      ),
    ),
  );

  Widget _resultPanel() {
    final route = _route!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _circleButton(
              icon: Icons.arrow_back,
              label: '이전 화면으로 돌아가기',
              onTap: _back,
            ),
            const SizedBox(width: 12),
            Expanded(child: _routeSummaryCard()),
          ],
        ),
        // 추천 경로가 둘일 때만 선택 버튼을 두고, 하나면 영역 자체를 만들지 않는다.
        if (_options.length == 2) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _optionTab(0, '최적 1', '(도보 최소)')),
              const SizedBox(width: 8),
              Expanded(child: _optionTab(1, '최적 2', _secondReason())),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: _routeFacts(route),
              ),
            ),
            const SizedBox(width: 12),
            if (route.busSegments.isNotEmpty) _busCard(route),
          ],
        ),
      ],
    );
  }

  Widget _routeSummaryCard() {
    Widget line(String label, String name) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: EasyColors.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: EasyColors.onSurface,
            ),
          ),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: EasyColors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: EasyColors.cardShadow,
      ),
      child: Row(
        children: [
          Column(
            children: [
              _dot(EasyColors.primaryContainer),
              Container(
                width: 2,
                height: 16,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: EasyColors.surfaceContainerHighest,
              ),
              _dot(EasyColors.tertiaryContainer),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line('출발', _originLabel),
                const SizedBox(height: 2),
                line('도착', _destinationLabel),
              ],
            ),
          ),
          // 디자인의 원형 보조 버튼 자리에 기존 '안내 다시 듣기' 기능을 연결한다.
          Material(
            color: EasyColors.surfaceContainer,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _busy || _phase == HomePhase.recording
                  ? null
                  : () async {
                      try {
                        await _device.repeat();
                      } catch (error) {
                        _notice('음성 안내를 재생하지 못했습니다.');
                      }
                    },
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.volume_up,
                  size: 24,
                  color: EasyColors.primaryContainer,
                  semanticLabel: '안내 다시 듣기',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  String _secondReason() {
    final first = _options[0], second = _options[1];
    // 최적 2가 빠르지 않고 환승만 적은 경우에는 환승 이점을 표시한다.
    final faster =
        (second.durationMinutes ?? double.infinity) <
        (first.durationMinutes ?? 0);
    return !faster && second.transferCount < first.transferCount
        ? '(환승 적음)'
        : '(시간 단축)';
  }

  Widget _optionTab(int index, String title, String reason) {
    final active = index == _selected;
    return Material(
      color: active ? EasyColors.primaryContainer : EasyColors.white,
      elevation: active ? 3 : 1,
      shadowColor: const Color(0x40000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: active
            ? BorderSide.none
            : BorderSide(
                color: EasyColors.outlineVariant.withValues(alpha: 0.6),
              ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _selectOption(index),
        child: Semantics(
          button: true,
          selected: active,
          label: '$title $reason',
          excludeSemantics: true,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? EasyColors.white
                          : EasyColors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    reason,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: active
                          ? EasyColors.white.withValues(alpha: 0.9)
                          : EasyColors.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _meters(double value) => value >= 1000
      ? '${(value / 1000).toStringAsFixed(1)}km'
      : '${value.round()}m';

  // 선택한 경로의 소요시간·도보·환승은 서버가 제공한 값만 표시한다.
  Widget _routeFacts(BusRoute route) {
    final facts = [
      if (route.durationMinutes != null) '약 ${route.durationMinutes!.round()}분',
      if (route.totalWalkM != null) '도보 ${_meters(route.totalWalkM!)}',
      route.transferCount == 0 ? '환승 없음' : '환승 ${route.transferCount}회',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: EasyColors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: EasyColors.cardShadow,
      ),
      child: Text(
        facts.join(' · '),
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: EasyColors.onSurface,
        ),
      ),
    );
  }

  // 우측 버스 카드는 선택한 경로의 첫 승차 버스만 표시하고 누르면 상세 화면으로 이동한다.
  Widget _busCard(BusRoute route) {
    final segment = route.busSegments.first;
    final arrival = segment.arrival;
    final accent = _accent(_selected);
    final number = segment.bus?.number ?? '';
    final stopsText = arrival.available && arrival.remainingStops != null
        ? '${arrival.remainingStops}정류장 전'
        : arrival.available
        ? '도착 예정'
        : '실시간';
    final timeText = arrival.available ? '약 ${arrival.minutes}분 후' : '도착정보 없음';
    return Semantics(
      button: true,
      label: '$number번 버스 $stopsText $timeText, 상세 보기',
      excludeSemantics: true,
      child: Material(
        color: EasyColors.white,
        elevation: 3,
        shadowColor: const Color(0x40000000),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openDetail,
          child: SizedBox(
            width: 150,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 36,
                  color: accent,
                  alignment: Alignment.center,
                  child: Text(
                    number,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: EasyColors.white,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
                  child: Column(
                    children: [
                      Text(
                        stopsText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: EasyColors.onSurface,
                        ),
                      ),
                      Text(
                        timeText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: arrival.available ? 22 : 18,
                          fontWeight: FontWeight.w700,
                          color: arrival.available
                              ? accent
                              : EasyColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 마이크 버튼: 대기 76px 파란 원, 녹음 중 80px 빨간 원과 후광을 사용한다.
  Widget _micButton() {
    final recording = _phase == HomePhase.recording;
    final enabled = !_busy && !_audioTransition;
    final size = recording ? 80.0 : 76.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_voiceProblem != null && !_busy && !recording)
          Container(
            constraints: BoxConstraints(
              maxWidth: 340,
              maxHeight: MediaQuery.sizeOf(context).height * 0.42,
            ),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: EasyColors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_voiceProblem!, style: const TextStyle(fontSize: 18)),
                  if (_heard.isNotEmpty)
                    Text(
                      '들은 말씀: $_heard',
                      style: const TextStyle(fontSize: 18),
                    ),
                  for (final item in <({String label, VoidCallback? action})>[
                    (
                      label: _voiceAttempts >= VoicePolicy.maxAttempts
                          ? '다시 말하기 (시도 완료)'
                          : '다시 말하기',
                      action: _voiceAttempts >= VoicePolicy.maxAttempts
                          ? null
                          : () {
                              unawaited(_microphone());
                            },
                    ),
                    (
                      label: '화면에서 고르기',
                      action: () {
                        unawaited(_chooseInstead());
                      },
                    ),
                    (label: '글자로 입력', action: _typeInstead),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: OutlinedButton(
                          onPressed: _audioTransition ? null : item.action,
                          child: Text(
                            item.label,
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (recording)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: EasyColors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: EasyColors.cardShadow,
            ),
            child: Text(
              '$_status\n말씀이 끝나면 자동으로 완료해요.\n버튼을 눌러 직접 끝낼 수도 있어요.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: EasyColors.onSurface,
              ),
            ),
          ),
        Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: recording
                  ? EasyColors.recording
                  : EasyColors.primaryContainer,
              boxShadow: recording
                  ? const [
                      BoxShadow(color: Color(0x33EF4444), spreadRadius: 8),
                      BoxShadow(
                        color: Color(0x66EF4444),
                        offset: Offset(0, 8),
                        blurRadius: 28,
                      ),
                    ]
                  : const [
                      BoxShadow(
                        color: Color(0x592563EB),
                        offset: Offset(0, 8),
                        blurRadius: 24,
                      ),
                    ],
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: enabled ? _microphone : null,
                child: Icon(
                  recording ? Icons.stop : Icons.mic,
                  size: 36,
                  color: EasyColors.white,
                  semanticLabel: recording ? '녹음 끝내기' : '음성으로 목적지 찾기',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
