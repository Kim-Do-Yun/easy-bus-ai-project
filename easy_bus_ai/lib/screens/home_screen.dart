import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
  // 음성 대화에서 출발지를 다시 물은 상태이며, 이때 비어 있는 출발지는 현재 위치 출발로 보지 않는다.
  bool _originRequested = false;
  // 음량 기준으로 말소리를 감지하지 못한 녹음을 서버로 보냈는지 기록하여 Whisper 판단 결과 로그에 사용한다.
  bool _uploadWithoutSpeech = false;
  // 말소리를 인식하지 못한 오류만 실패 횟수에 포함한다.
  static const _speechRetryCodes = {
    'EMPTY_AUDIO',
    'EMPTY_SPEECH',
    'SPEECH_FAILED',
  };
  Timer? _loadingTimer;
  // 입력창 아래 장소 후보 목록 상태이다. true는 출발지, false는 목적지 아래에 표시하며 null이면 닫는다.
  // 사용자가 직접 입력하거나 입력창을 선택한 경우에만 열고, 코드에서 채운 글자로는 열지 않는다.
  bool? _suggestOrigin;
  List<Place> _suggestions = const [];
  bool _suggestLoading = false;
  String? _suggestMessage;
  Timer? _suggestTimer;
  // 늦게 도착한 이전 검색어의 응답이 최신 목록을 덮어쓰지 않도록 요청 번호를 비교한다.
  int _suggestRequest = 0;
  // 현재 후보 목록을 받은 검색어이며 입력창 글자와 같을 때만 후보를 선택할 수 있다.
  String? _suggestQuery;
  static const _suggestDelay = Duration(milliseconds: 400);
  // 앱의 현재 위치와 지도 마커이며 사용자가 지정한 출발지와 별도로 관리하여 경로 표시 중에도 유지한다.
  Place? _currentPlace;
  NMarker? _currentMarker;
  // 경로 결과 위에서 새 음성 입력을 시작할 때 비운 입력 상태이며 뒤로 가기로 결과 화면에 돌아갈 때 복원한다.
  ({
    String origin,
    String destination,
    Place? originPlace,
    Place? destinationPlace,
  })?
  _resultInputs;
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
    _originFocus.addListener(() => _focusChanged(true));
    _destinationFocus.addListener(() => _focusChanged(false));
  }

  bool get _inputLocked =>
      _busy || _audioTransition || _phase == HomePhase.recording;

  // 출발지 입력창에 표시하는 현재 위치 문구이며 경로 검색 시 기존 현재 위치 조회(_currentOrigin)를 사용한다.
  static const _currentLabel = '현재 위치';

  // 입력창 문구와 같은 이름의 장소가 후보 목록에서 확정되어 좌표가 있는 상태이다.
  // 출발지 입력창의 '현재 위치'는 후보 선택 없이 기존 현재 위치 조회로 좌표를 얻으므로 확정으로 본다.
  bool _confirmed(bool isOrigin) {
    if (isOrigin && _origin.text.trim() == _currentLabel) return true;
    final place = isOrigin ? _originPlace : _destinationPlace;
    return place != null &&
        place.name == (isOrigin ? _origin : _destination).text.trim();
  }

  // 출발지는 장소 확정 외에 음성으로 '여기서'처럼 현재 위치 출발을 말한 경우도 확정으로 본다.
  // 출발지 입력창을 비워 둔 경우도 기존 정책대로 현재 위치 출발로 본다.
  // 단, 출발지에 글자(조합 중 자음·모음 포함)가 있거나 음성 대화에서 출발지를 다시 물은 상태는 제외한다.
  bool get _originReady =>
      _confirmed(true) ||
      (_origin.text.trim().isEmpty &&
          (_voiceCurrentLocation || !_originRequested));
  bool get _destinationReady => _confirmed(false);

  // 자음·모음만 입력된 조합 중 글자로는 장소 검색을 하지 않는다.
  static bool _onlyJamo(String text) =>
      text.runes.every((r) => r >= 0x3131 && r <= 0x318E || r == 0x20);

  // 사용자가 입력창을 선택하면 이미 있는 글자로 바로 후보를 찾고, 포커스가 빠지면 해당 목록만 닫는다.
  void _focusChanged(bool isOrigin) {
    if (!mounted) return;
    // 입력창 포커스에 따라 좌측 상단 뒤로 가기 버튼 표시가 바뀌므로 화면을 다시 그린다.
    setState(() {});
    final focus = isOrigin ? _originFocus : _destinationFocus;
    if (focus.hasFocus) {
      final text = (isOrigin ? _origin : _destination).text.trim();
      if (!_inputLocked && text.isNotEmpty && !_confirmed(isOrigin)) {
        _scheduleSuggestions(isOrigin, immediate: true);
      } else if (_suggestOrigin != null && _suggestOrigin != isOrigin) {
        _hideSuggestions();
      }
    } else if (_suggestOrigin == isOrigin) {
      _hideSuggestions();
    }
  }

  // 글자 입력마다 바로 호출하지 않고 입력이 멈춘 뒤 기존 장소 검색 API로 후보를 찾는다.
  void _scheduleSuggestions(bool isOrigin, {bool immediate = false}) {
    _suggestTimer?.cancel();
    final query = (isOrigin ? _origin : _destination).text.trim();
    final request = ++_suggestRequest;
    if (query.isNotEmpty && _onlyJamo(query)) {
      // 조합 중에는 검색하지 않으며, 이전 검색어의 후보를 고르지 않도록 목록 내용만 비운다.
      if (_suggestOrigin != null &&
          (_suggestions.isNotEmpty || _suggestLoading)) {
        setState(() {
          _suggestions = const [];
          _suggestQuery = null;
          _suggestLoading = false;
          _suggestMessage = '글자를 마저 입력해 주세요.';
        });
      }
      return;
    }
    if (_inputLocked || query.isEmpty || _confirmed(isOrigin)) {
      _hideSuggestions();
      return;
    }
    setState(() {
      // 새 검색어의 결과가 도착하기 전에는 이전 검색어의 후보를 보여 주지 않는다.
      _suggestions = const [];
      _suggestQuery = null;
      _suggestOrigin = isOrigin;
      _suggestLoading = true;
      _suggestMessage = null;
    });
    _suggestTimer = Timer(
      immediate ? Duration.zero : _suggestDelay,
      () => unawaited(_loadSuggestions(isOrigin, query, request)),
    );
  }

  Future<void> _loadSuggestions(
    bool isOrigin,
    String query,
    int request,
  ) async {
    // 그 사이 글자가 바뀌었거나 목록을 닫았거나 다른 작업이 시작되었으면 응답을 버린다.
    bool current() =>
        mounted &&
        request == _suggestRequest &&
        _suggestOrigin == isOrigin &&
        (isOrigin ? _origin : _destination).text.trim() == query &&
        !_inputLocked;
    if (!current()) return;
    try {
      final places = await _api.locations(query);
      if (!current()) return;
      setState(() {
        _suggestions = places;
        _suggestQuery = query;
        _suggestLoading = false;
        _suggestMessage = places.isEmpty ? '검색 결과가 없습니다.' : null;
      });
    } catch (error) {
      if (!current()) return;
      // 실패해도 입력한 글자와 확정 장소는 그대로 두고 목록 안에서만 안내한다.
      setState(() {
        _suggestions = const [];
        _suggestLoading = false;
        _suggestMessage =
            error is ApiException && error.code == 'LOCATION_NOT_FOUND'
            ? '검색 결과가 없습니다. 이름을 자세히 입력해 주세요.'
            : '장소 후보를 불러오지 못했습니다. 잠시 후 다시 입력해 주세요.';
      });
    }
  }

  void _hideSuggestions() {
    _suggestTimer?.cancel();
    ++_suggestRequest;
    if (_suggestOrigin == null && !_suggestLoading) return;
    if (!mounted) return;
    setState(() {
      _suggestOrigin = null;
      _suggestions = const [];
      _suggestQuery = null;
      _suggestLoading = false;
      _suggestMessage = null;
    });
  }

  // 입력창 아래 후보에서 장소를 고르면 좌표를 확정하고, 두 장소가 모두 확정되면 경로를 한 번 검색한다.
  Future<void> _selectSuggestion(Place place, bool isOrigin) async {
    if (_inputLocked) return;
    // 현재 입력창 글자와 같은 검색어로 받은 최신 목록의 후보만 선택한다.
    final text = (isOrigin ? _origin : _destination).text.trim();
    if (_suggestOrigin != isOrigin ||
        _suggestQuery != text ||
        !_suggestions.contains(place)) {
      debugPrint('[EASY_BUS_SUGGEST] 이전 검색어의 후보 선택을 무시');
      return;
    }
    _hideSuggestions();
    final generation = _request;
    try {
      await _confirmPlace(place, isOrigin);
    } catch (_) {
      /* 지도 마커 표시 실패는 좌표 확정을 막지 않는다. */
    }
    if (!mounted || generation != _request) return;
    // 출발지 입력창을 비워 둔 채 목적지 후보를 고르면 현재 위치를 출발지로 정하고 바로 경로를 검색한다.
    // 출발지에 글자가 있거나(후보 미선택 포함) 음성 대화에서 출발지를 다시 물은 상태는 제외한다.
    if (!isOrigin && _origin.text.trim().isEmpty && !_originRequested) {
      _useCurrentOrigin();
    }
    setState(() {
      _voiceAttempts = 0;
      _voiceProblem = null;
      if (isOrigin) _voiceCurrentLocation = false;
      _awaitingSlot = !_originReady
          ? 'origin'
          : !_destinationReady
          ? 'destination'
          : null;
    });
    if (_originReady && _destinationReady) {
      FocusScope.of(context).unfocus();
      await _search();
      return;
    }
    // 아직 확정하지 않은 다른 입력창으로 이동하며, 글자가 있으면 그 글자로 후보를 바로 보여 준다.
    (_originReady ? _destinationFocus : _originFocus).requestFocus();
  }

  // 확정되지 않은 입력창의 후보 목록을 연다. 이미 포커스가 있으면 바로 검색한다.
  void _openSuggestionsFor(bool isOrigin) {
    final focus = isOrigin ? _originFocus : _destinationFocus;
    if (focus.hasFocus) {
      _scheduleSuggestions(isOrigin, immediate: true);
    } else {
      focus.requestFocus();
    }
  }

  // 검색 버튼은 확정되지 않은 장소만 후보에서 고르게 하고, 모두 확정되었으면 다시 고르지 않고 바로 검색한다.
  void _manualSearch() {
    if (_inputLocked) return;
    if (_origin.text.trim().isNotEmpty && !_confirmed(true)) {
      _openSuggestionsFor(true);
      return;
    }
    if (_destination.text.trim().isNotEmpty && !_confirmed(false)) {
      _openSuggestionsFor(false);
      return;
    }
    _hideSuggestions();
    FocusScope.of(context).unfocus();
    unawaited(_search());
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

  // 입력창에서 키보드의 다음·검색 키를 누르면 확정되지 않은 장소의 후보 목록을 바로 보여 준다.
  void _submitInput(bool isOrigin) {
    if (_inputLocked) return;
    final text = (isOrigin ? _origin : _destination).text.trim();
    if (text.isNotEmpty && !_confirmed(isOrigin)) {
      _scheduleSuggestions(isOrigin, immediate: true);
    } else if (isOrigin) {
      // 출발지를 비우거나 이미 확정했으면 목적지 입력으로 넘어간다.
      _destinationFocus.requestFocus();
    } else if (text.isEmpty) {
      _notice('목적지를 입력해 주세요.');
    } else {
      _manualSearch();
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
    debugPrint(
      '[EASY_BUS_VOICE] 음성 입력 실패 $_voiceAttempts/${VoicePolicy.maxAttempts}회 '
      '단계=${_awaitingSlot ?? '처음'}',
    );
    final guidance = _voiceAttempts >= VoicePolicy.maxAttempts
        ? '$message 음성 입력 횟수를 모두 사용했습니다. 글자로 입력해 주세요.'
        : '$message 다시 말하거나 글자로 입력해 주세요.';
    setState(() => _voiceProblem = guidance);
    _notice(guidance);
    try {
      await _device.speak(guidance);
    } catch (_) {
      /* 화면 안내는 유지한다. */
    }
  }

  // 음성으로 일부 인식한 글자는 그대로 두고 글자 입력으로 전환한다.
  // 확정되지 않은 입력창부터 선택하며, 글자가 있으면 선택 시점에 그 글자로 후보 목록을 보여 준다.
  void _typeInstead() {
    if (_busy || _audioTransition) return;
    setState(() {
      _editingInputs = true;
      _voiceProblem = null;
    });
    // 글자 입력 전환 시에는 기존처럼 비어 있는 출발지부터 선택하게 한다.
    final origin =
        !_confirmed(true) &&
        !(_voiceCurrentLocation && _origin.text.trim().isEmpty);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (origin ? _originFocus : _destinationFocus).requestFocus();
    });
  }

  Future<void> _prepareMap(NaverMapController controller) async {
    debugPrint(
      '[EASY_BUS_INIT] onMapReady 호출 (화면=${_initElapsed.elapsedMilliseconds}ms)',
    );
    _map = controller;
    final generation = _request;
    final stageElapsed = Stopwatch()..start();
    var stage = LocationPolicy.useFixed ? '고정 현재 위치 조회' : 'GPS 조회';
    try {
      debugPrint('[EASY_BUS_INIT] $stage 시작');
      final position = await _device.currentPosition();
      debugPrint(
        '[EASY_BUS_INIT] $stage 완료 (단계=${stageElapsed.elapsedMilliseconds}ms)',
      );
      if (!mounted) return;
      stage = '현재 위치 지도 반영';
      stageElapsed.reset();
      _currentPlace = position;
      await _showCurrentMarker(position);
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

  // 기존 현재 위치 마커 모양을 그대로 쓰되, 경로 마커보다 아래에 그리고 겹치는 글자는 숨긴다.
  NMarker _currentMarkerFor(Place place) => NMarker(
    id: 'current',
    position: _latLng(place),
    caption: const NOverlayCaption(text: '현재 위치'),
    isHideCollidedCaptions: true,
  )..setGlobalZIndex(190000);

  // 현재 위치 마커는 경로 오버레이 목록과 별도로 관리하여 경로 교체·삭제 시 함께 지워지지 않는다.
  Future<void> _showCurrentMarker(Place place) {
    final task = _mapQueue.then((_) async {
      if (!mounted || _map == null) return;
      final marker = _currentMarkerFor(place);
      // 같은 id의 오버레이를 추가하면 지도 SDK가 이전 현재 위치 마커를 교체한다.
      await _map!.addOverlay(marker);
      _currentMarker = marker;
    });
    _mapQueue = task.catchError((Object error) {});
    return task;
  }

  // 현재 위치 버튼: 고정 위치 모드에서는 원주시 중앙 좌표로 이동하고 경로 화면 맞춤과 별개로 동작한다.
  Future<void> _moveToCurrent() async {
    try {
      final place = await _device.currentPosition();
      if (!mounted) return;
      _currentPlace = place;
      await _showCurrentMarker(place);
      final task = _mapQueue.then((_) async {
        if (!mounted || _map == null) return;
        await _map!.updateCamera(
          NCameraUpdate.scrollAndZoomTo(target: _latLng(place), zoom: 16),
        );
      });
      _mapQueue = task.catchError((Object error) {});
      await task;
    } catch (error) {
      _notice(error);
    }
  }

  // 약 15m 이내이면 같은 지점으로 보고 경로 출발 마커에 현재 위치임을 함께 표시한다.
  bool _samePoint(Place a, Place b) =>
      (a.latitude - b.latitude).abs() < 0.00014 &&
      (a.longitude - b.longitude).abs() < 0.00017;

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
                          subtitle: Text(_placeSubtitle(p)),
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
      _resultInputs = null;
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
    final withoutSpeech = _uploadWithoutSpeech;
    _uploadWithoutSpeech = false;
    try {
      text = await _api.speech(audioPath);
    } on ApiException catch (error) {
      if (withoutSpeech) {
        debugPrint(
          '[EASY_BUS_VOICE] 음량 미감지 녹음의 Whisper 판단=인식 실패 코드=${error.code}',
        );
      }
      if (!_valid(id) || !_speechRetryCodes.contains(error.code)) rethrow;
      // 서버에서 말소리를 찾지 못한 경우에만 한 번의 실패로 센다.
      await _voiceFailure(error.message);
      return false;
    }
    if (withoutSpeech) {
      debugPrint(
        '[EASY_BUS_VOICE] 음량 미감지 녹음의 Whisper 판단=문장 인식 길이=${text.length}',
      );
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
      // 장소를 구분할 근거가 분명한 부분만 입력창에 남기고 재질문 단계는 그대로 둔다.
      final kept = _keepPartialPlaces(text);
      await _askAgain('어디에서 어디로 가시는지 다시 말씀해 주세요.', heard: text);
      if (_valid(id)) {
        setState(
          () => _voiceProblem = kept
              ? '들은 말씀을 장소로 확인하지 못했습니다. 알아들은 장소는 입력창에 남겨 두었습니다.'
              : '들은 말씀을 장소로 확인하지 못했습니다.',
        );
      }
      return false;
    }
    if (!_valid(id)) return false;
    _voiceActive = true;
    debugPrint(
      '[EASY_BUS_VOICE] 해석 결과 시도=$_voiceAttempts/${VoicePolicy.maxAttempts} '
      '출발지=${result.origin != null} 목적지=${result.destination != null} '
      '현재위치=${result.useCurrentLocation}'
      '${kDebugMode ? ' (출발="${result.origin ?? ''}", 도착="${result.destination ?? ''}")' : ''}',
    );
    var origin = result.origin;
    var destination = result.destination;
    // 해석 결과가 한 항목만 비었을 때 원문의 '~에서', '~로/까지' 같은 분명한 표현으로만 빠진 항목을 보완한다.
    final marked = _partialPlaces(text, markedOnly: true);
    bool same(String? a, String? b) =>
        a != null &&
        b != null &&
        a.replaceAll(RegExp(r'\s+'), '') == b.replaceAll(RegExp(r'\s+'), '');
    // 원문 표현과 해석 결과의 출발·도착이 뒤바뀌면 어느 쪽도 쓰지 않고 해당 항목만 다시 묻는다.
    final conflict =
        same(marked.origin, destination) || same(marked.destination, origin);
    if (conflict) {
      if (same(marked.origin, destination)) destination = null;
      if (same(marked.destination, origin)) origin = null;
    }
    final fillOrigin = !conflict && origin == null && !result.useCurrentLocation
        ? marked.origin
        : null;
    final fillDestination = !conflict && destination == null
        ? marked.destination
        : null;
    if (conflict || fillOrigin != null || fillDestination != null) {
      debugPrint(
        '[EASY_BUS_VOICE] 원문 보완 충돌=$conflict 출발지보완=${fillOrigin != null} '
        '목적지보완=${fillDestination != null}'
        '${kDebugMode ? ' (출발="${fillOrigin ?? ''}", 도착="${fillDestination ?? ''}")' : ''}',
      );
    }
    if (origin == null &&
        destination == null &&
        !result.useCurrentLocation &&
        fillOrigin == null &&
        fillDestination == null &&
        !conflict) {
      // 해석 결과가 비어 있어도 장소를 구분할 근거가 분명한 부분은 입력창에 남긴다.
      // 남긴 글자는 확정되지 않은 부분 인식이므로 경로 검색으로 넘어가지 않고 기존 단계로 다시 묻는다.
      final slot =
          _awaitingSlot ??
          (_origin.text.trim().isEmpty && !_voiceCurrentLocation
              ? (_destination.text.trim().isEmpty ? 'both' : 'origin')
              : 'destination');
      final kept = _keepPartialPlaces(text);
      setState(
        () => _voiceProblem = kept
            ? '들은 말씀에서 출발지와 목적지를 확인하지 못했습니다. 알아들은 장소는 입력창에 남겨 두었습니다.'
            : '들은 말씀에서 출발지와 목적지를 찾지 못했습니다.',
      );
      if (kept) {
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
    }
    // 이번 발화에서 말한 항목만 갱신하고, 말하지 않은 항목과 확정 장소는 그대로 둔다.
    // 코드에서 글자를 채우므로 입력창의 onChanged가 실행되지 않아 후보 목록과 자동 검색이 열리지 않는다.
    if (result.useCurrentLocation) {
      _origin.text = '';
      _voiceCurrentLocation = true;
    } else if (origin != null) {
      _origin.text = origin;
      _voiceCurrentLocation = false;
    }
    if (destination != null) _destination.text = destination;
    // 원문으로 보완한 장소는 비어 있는 입력창에만 넣고, 이미 입력·확정된 장소는 덮어쓰지 않는다.
    if (fillOrigin != null &&
        _origin.text.trim().isEmpty &&
        !_voiceCurrentLocation) {
      _origin.text = fillOrigin;
    }
    if (fillDestination != null && _destination.text.trim().isEmpty) {
      _destination.text = fillDestination;
    }
    var hasOrigin = _voiceCurrentLocation || _origin.text.trim().isNotEmpty;
    final hasDestination = _destination.text.trim().isNotEmpty;
    // 목적지만 말하고 출발지를 따로 지정하지 않았으면 출발지를 다시 묻지 않고 현재 위치를 출발지로 사용한다.
    // 출발지를 다시 물은 상태, '~에서'·'~부터' 같은 출발 표현을 말했지만 추출하지 못한 경우,
    // 출발·도착이 뒤바뀐 경우는 출발지 미지정으로 보지 않고 기존처럼 다시 묻는다.
    if (!hasOrigin &&
        hasDestination &&
        !conflict &&
        !_originRequested &&
        !_mentionsOrigin(text)) {
      _useCurrentOrigin();
      hasOrigin = true;
      debugPrint('[EASY_BUS_VOICE] 출발지 미지정: 현재 위치를 출발지로 사용');
    }
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
        (origin != null ||
            destination != null ||
            fillOrigin != null ||
            fillDestination != null ||
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

  // 문장 해석에 실패했을 때 인식 문장에서 장소를 구분할 근거가 분명한 문자열만 꺼낸다.
  // '~에서 ~로/까지' 같은 출발·도착 표현이 있거나, 한 항목만 물은 단계의 짧은 대답인 경우만 사용한다.
  // markedOnly는 해석 결과를 보완할 때 사용하며 출발·도착 표현이 있는 경우만 꺼낸다.
  ({String? origin, String? destination}) _partialPlaces(
    String text, {
    bool markedOnly = false,
  }) {
    // 문장 끝의 부탁·어미 표현과 문장부호를 지워 장소 이름만 남긴다.
    String clean(String value) {
      var result = value.replaceAll(RegExp(r'[.,!?~…]'), ' ').trim();
      // '~에서 출발해서 ~로'처럼 이어진 출발 표현은 목적지 이름에서 뺀다.
      result = result.replaceFirst(RegExp(r'^(출발해서|출발하여|떠나서)\s*'), '');
      result = result.replaceFirst(
        RegExp(
          r'\s*(가\s*주세요|가\s*줘|가고\s*싶어요?|가려고\s*해요?|가려고요|갈게요|갈래요|가요|가자|갑니다|출발할게요|출발해요|출발합니다|출발|이요|예요|이에요|입니다|요)$',
        ),
        '',
      );
      return result.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    // 장소로 보기 어려운 대답이나 지나치게 긴 문장은 버린다.
    String? place(String value) {
      final name = clean(value);
      if (name.isEmpty ||
          name.length > 20 ||
          name.split(' ').length > 4 ||
          RegExp(r'모르|몰라|아니|글쎄|뭐라|다시|취소|그만').hasMatch(name) ||
          // 현재 위치를 뜻하는 말은 장소 이름으로 넣지 않는다.
          RegExp(r'^(여기|거기|저기|이곳|지금\s?위치|현재\s?위치|내\s?위치)$').hasMatch(name)) {
        return null;
      }
      return name;
    }

    final sentence = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // '~에서/~부터 ~로/까지', '~에서 출발해서 ~에 가고'처럼 출발·도착이 함께 있는 표현이다.
    final both = RegExp(
      r'^(.+?)\s*(?:에서부터|에서|부터)\s*(.+?)\s*(?:(?:으로|로|까지)(?:\s|$)|에\s*(?:가|갈|도착))',
    ).firstMatch(sentence);
    if (both != null) {
      return (origin: place(both[1]!), destination: place(both[2]!));
    }
    final from = RegExp(
      r'^(.+?)\s*(?:에서부터|에서|부터)\s*(?:출발|떠나)',
    ).firstMatch(sentence);
    if (from != null) return (origin: place(from[1]!), destination: null);
    final to = RegExp(
      r'^(.+?)\s*(?:으로|로|까지)\s*(?:가|갈|데려|이동)',
    ).firstMatch(sentence);
    if (to != null) return (origin: null, destination: place(to[1]!));
    if (markedOnly) return (origin: null, destination: null);
    // 구분 표현이 없으면 출발지 또는 목적지 하나만 물은 단계의 대답으로만 사용한다.
    if (_awaitingSlot == 'origin') {
      return (origin: place(sentence), destination: null);
    }
    if (_awaitingSlot == 'destination') {
      return (origin: null, destination: place(sentence));
    }
    return (origin: null, destination: null);
  }

  // 해석 실패 시 꺼낸 장소 문자열을 비어 있는 입력창에만 넣는다. 확정 장소와 기존 글자는 덮어쓰지 않는다.
  // 코드에서 채우므로 onChanged가 실행되지 않아 후보 목록·키보드·자동 경로 검색이 열리지 않는다.
  bool _keepPartialPlaces(String text) {
    final partial = _partialPlaces(text);
    var kept = false;
    if (partial.origin != null &&
        _origin.text.trim().isEmpty &&
        !_voiceCurrentLocation) {
      _origin.text = partial.origin!;
      kept = true;
    }
    if (partial.destination != null && _destination.text.trim().isEmpty) {
      _destination.text = partial.destination!;
      kept = true;
    }
    debugPrint(
      '[EASY_BUS_VOICE] 부분 인식 보존=$kept 출발지=${partial.origin != null} '
      '목적지=${partial.destination != null} 단계=${_awaitingSlot ?? '처음'}',
    );
    return kept;
  }

  // 누락 장소 재질문은 화면과 TTS로 전달하며 인식 실패 횟수에 포함하지 않는다.
  Future<void> _askAgain(String question, {String? slot, String? heard}) async {
    var message = question;
    if (slot != null) {
      _awaitingSlot = slot;
      // 출발지를 물은 경우 비어 있는 출발지로 자동 경로 검색을 하지 않는다.
      // 출발지·목적지를 함께 물은 경우는 들은 말씀에 출발 표현이 있었을 때만 출발지를 물은 것으로 본다.
      _originRequested =
          slot == 'origin' ||
          (slot == 'both' && heard != null && _mentionsOrigin(heard));
    }
    if (_voiceAttempts >= VoicePolicy.maxAttempts) {
      message = '$question 음성 입력 횟수를 모두 사용했습니다. 글자로 입력해 주세요.';
      setState(() => _voiceProblem = message);
    }
    _notice(heard == null ? message : '"$heard"\n$message');
    try {
      await _device.speak(message);
    } catch (_) {
      /* 재질문 음성 재생 실패는 화면 안내로 대신한다. */
    }
  }

  // 발화에 '~에서', '~부터' 같은 출발 표현이 있는지 확인한다. '여기에서'처럼 현재 위치를 뜻하는 표현은 제외한다.
  static bool _mentionsOrigin(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '').replaceAll(
      RegExp(r'(여기|이곳|현재위치|지금위치|내위치|제위치|현위치)(에서부터|에서|부터)?'),
      '',
    );
    return RegExp(r'에서|부터').hasMatch(compact);
  }

  // 출발지를 따로 지정하지 않았을 때 출발지 입력창을 '현재 위치'로 정한다. 음성·글자 입력이 같은 처리를 사용한다.
  // 좌표는 경로 검색 시 기존 _currentOrigin()으로 조회하므로 고정 위치·GPS 설정을 그대로 따른다.
  // 문구 변경 감지에서 이전 출발지 확정 장소와 선택 마커는 해제되어 새 검색에 섞이지 않는다.
  void _useCurrentOrigin() {
    _originRequested = false;
    _origin.text = _currentLabel;
  }

  void _resetVoice() {
    _voiceActive = false;
    _awaitingSlot = null;
    _voiceAttempts = 0;
    _voiceCurrentLocation = false;
    _originRequested = false;
    _uploadWithoutSpeech = false;
    _heard = '';
    _voiceProblem = null;
  }

  // 음성 대화에서 현재 위치를 확인하지 못하면 임의 좌표 없이 출발지를 다시 묻는다.
  Future<Place?> _currentOrigin(int id, bool voice) async {
    try {
      // 고정 위치 모드에서는 원주시 중앙 좌표가 반환되며 현재 위치 마커와 같은 값을 사용한다.
      final place = await _device.currentPosition();
      if (_valid(id) && _currentPlace == null) {
        _currentPlace = place;
        unawaited(_showCurrentMarker(place));
      }
      return place;
    } catch (error) {
      if (!_valid(id)) return null;
      _voiceCurrentLocation = false;
      // 자동으로 채운 '현재 위치' 문구는 비워 다음 입력에서 현재 위치를 다시 출발지로 쓰지 않게 한다.
      if (_origin.text.trim() == _currentLabel) _origin.clear();
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
            // 출발지가 현재 위치와 같으면 겹친 현재 위치 마커 대신 출발 마커에 함께 표시한다.
            _currentPlace != null &&
                    _samePoint(segments.first.start, _currentPlace!)
                ? '현재 위치'
                : null,
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
        // 경로를 교체한 뒤에도 현재 위치 마커가 지도에 남아 있도록 확인하고, 없으면 다시 표시한다.
        final current = _currentPlace;
        if (current != null &&
            (_currentMarker == null || !_currentMarker!.isAdded)) {
          try {
            final marker = _currentMarkerFor(current);
            await _map!.addOverlay(marker);
            _currentMarker = marker;
          } catch (_) {
            /* 현재 위치 마커 표시 실패는 경로 결과를 바꾸지 않는다. */
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
    // 상세 화면에서 재생하던 안내는 결과 화면으로 돌아오면 멈춘다.
    unawaited(_device.stopSpeaking().catchError((Object _) {}));
  }

  Future<void> _microphone() async {
    if (_busy || _audioTransition) return;
    if (_phase == HomePhase.recording) {
      // 녹음 종료 중에도 중복 탭을 막는다.
      final id = _begin('녹음을 완료하고 있어요.');
      setState(() => _audioTransition = true);
      String? recordedPath;
      try {
        // 음량 기반 감지는 녹음 시작·종료 시점 판단에만 사용한다.
        // 감지하지 못했더라도 작은 목소리가 기록되었을 수 있으므로 완전 무음이 아니면 서버 음성 인식으로 확인한다.
        // 자동 종료와 직접 종료가 모두 이 경로를 거치므로 같은 정책이 적용된다.
        final unavailable = _device.detectionUnavailable;
        final silent = !_device.heardSpeech && _device.silentInput;
        _uploadWithoutSpeech = !_device.heardSpeech && !silent;
        if (_uploadWithoutSpeech) {
          debugPrint(
            '[EASY_BUS_VOICE] 음량 기준 말소리 미감지: 녹음 파일을 서버 인식으로 확인 '
            '(사유=${unavailable ? '음량 관측 불가' : '음량 기준 미달'})',
          );
        }
        if (silent) {
          await _device.cancelRecording();
          if (!_valid(id)) return;
          // 장치에서 소리가 전혀 들어오지 않은 경우는 사용자의 발화 실패로 세지 않는다.
          debugPrint('[EASY_BUS_VOICE] 마이크 입력이 완전 무음: 서버 전송 없이 녹음 폐기, 기기 마이크 접근 설정 확인 필요');
          setState(
            () => _voiceProblem = '마이크에 소리가 전혀 들어오지 않습니다. 휴대전화 설정에서 마이크 사용이 켜져 있는지 확인한 뒤 다시 말하거나 글자로 입력해 주세요.',
          );
          _notice(_voiceProblem!);
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
        setState(() => _voiceProblem = '음성 입력 횟수를 모두 사용했습니다. 글자로 입력해 주세요.');
        return;
      }
      // 녹음 중 키보드와 후보 목록이 열려 있지 않도록 닫는다.
      _hideSuggestions();
      FocusScope.of(context).unfocus();
      debugPrint(
        '[EASY_BUS_VOICE] 음성 입력 시작 시도=${_voiceAttempts + 1}/${VoicePolicy.maxAttempts} '
        '단계=${_awaitingSlot ?? '처음'}',
      );
      // 기존 결과는 지도에 유지하되 새 음성 대화에 이전 장소를 섞지 않는다.
      if (!_voiceActive && _route != null && !_editingInputs) {
        // 비우기 전 입력 상태를 보관해 뒤로 가기로 결과 화면에 돌아갈 때 복원한다.
        _resultInputs = (
          origin: _origin.text,
          destination: _destination.text,
          originPlace: _originPlace,
          destinationPlace: _destinationPlace,
        );
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
    _hideSuggestions();
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
    _hideSuggestions();
    FocusScope.of(context).unfocus();
    // 경로 결과 위에서 입력 중이면 경로를 지우지 않고 결과 화면으로 돌아간다.
    if (_route != null && _editingInputs) {
      _returnToResult();
      return;
    }
    // 경로가 없는 입력·음성 단계에서는 기본 지도 화면으로 돌아가며 입력한 글자와 확정 장소는 유지한다.
    if (_route == null) {
      _leaveInput();
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

  // 입력·음성 단계에서 돌아갈 이전 화면이 있을 때만 좌측 상단 뒤로 가기 버튼을 표시한다.
  // 최초 기본 화면에서도 입력창을 선택해 글자를 입력하는 중이거나 후보 목록이 열려 있으면 표시한다.
  // 입력창 포커스가 없고 진행 중인 단계도 없는 기본 화면에서는 남아 있는 글자만으로 표시하지 않는다.
  bool get _inputBackVisible =>
      _busy ||
      _phase == HomePhase.recording ||
      _phase == HomePhase.attention ||
      _route != null ||
      _editingInputs ||
      _voiceProblem != null ||
      _heard.isNotEmpty ||
      _suggestOrigin != null ||
      _originFocus.hasFocus ||
      _destinationFocus.hasFocus;

  // 경로 결과 위의 새 입력을 마치고 기존 결과 화면으로 돌아가며, 비웠던 입력 상태를 복원한다.
  void _returnToResult() {
    ++_request;
    final saved = _resultInputs;
    _resultInputs = null;
    setState(() {
      _resetVoice();
      _editingInputs = false;
      _phase = HomePhase.guidance;
    });
    if (saved != null) {
      for (final isOrigin in [true, false]) {
        final place = isOrigin ? saved.originPlace : saved.destinationPlace;
        final text = isOrigin ? saved.origin : saved.destination;
        if (place != null && place.name == text.trim()) {
          // 경로 표시 중에는 선택 마커를 숨긴 상태로 다시 확정하고 지도 화면은 움직이지 않는다.
          unawaited(
            _confirmPlace(
              place,
              isOrigin,
              moveCamera: false,
            ).catchError((Object _) {}),
          );
        } else {
          (isOrigin ? _origin : _destination).text = text;
        }
      }
    }
    unawaited(_device.stopSpeaking().catchError((Object _) {}));
  }

  // 음성 대화·글자 입력 단계를 마치고 기본 지도 화면으로 돌아간다.
  void _leaveInput() {
    ++_request;
    setState(() {
      _resetVoice();
      _editingInputs = false;
      _phase = HomePhase.map;
    });
    unawaited(_device.stopSpeaking().catchError((Object _) {}));
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
    _suggestTimer?.cancel();
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
      // 후보 목록·입력 단계·경로 결과가 있으면 앱을 닫지 않고 화면의 뒤로 가기와 같은 동작을 한다.
      canPop: !_inputBackVisible && _suggestOrigin == null,
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
              // 고정 위치 모드에서는 최초 지도 중심을 기본값(서울) 대신 원주시 중앙 좌표로 시작한다.
              options: LocationPolicy.useFixed
                  ? NaverMapViewOptions(
                      initialCameraPosition: NCameraPosition(
                        target: _latLng(LocationPolicy.fixedPlace),
                        zoom: 15,
                      ),
                    )
                  : const NaverMapViewOptions(),
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
            // 현재 위치 이동 버튼은 마이크 버튼과 같은 높이의 우측에 두어 입력창·안내 카드와 겹치지 않게 한다.
            SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 36),
                  child: _circleButton(
                    icon: Icons.my_location,
                    label: '현재 위치로 이동',
                    onTap: () => unawaited(_moveToCurrent()),
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
            // 키보드 완료 키가 포커스를 옮기지 않게 하고 후보 목록 표시는 onSubmitted에서 처리한다.
            onEditingComplete: () {},
            // 포커스가 남은 입력창을 다시 눌러도 닫힌 후보 목록을 기존 글자로 다시 보여 준다.
            onTap: () {
              final isOrigin = identical(controller, _origin);
              if (_suggestOrigin != isOrigin &&
                  controller.text.trim().isNotEmpty &&
                  !_confirmed(isOrigin)) {
                _scheduleSuggestions(isOrigin, immediate: true);
              }
            },
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
              // 사용자가 직접 고친 글자에만 후보 검색을 예약한다. 코드에서 채운 글자는 이 콜백을 거치지 않는다.
              _scheduleSuggestions(identical(controller, _origin));
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
          if (_inputBackVisible) ...[
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
              // 출발지 입력을 마치면 입력창 아래 후보를 골라 지도에서 위치를 확인한다.
              onSubmitted: (_) => _submitInput(true),
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
      if (_suggestOrigin == true) _suggestionList(true),
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
        // 목적지가 확정되지 않았으면 입력창 아래 후보를 보여 주고, 확정된 뒤에는 기존 경로 검색을 수행한다.
        onSubmitted: (_) => _submitInput(false),
        trailing: IconButton(
          onPressed: _busy || _phase == HomePhase.recording
              ? null
              : _manualSearch,
          tooltip: '검색',
          iconSize: 28,
          color: EasyColors.primaryContainer,
          icon: const Icon(Icons.search),
        ),
      ),
      if (_suggestOrigin == false) _suggestionList(false),
    ],
  );

  // 후보의 장소 구분과 주소(정류장은 정류장 번호)를 표시하고, 둘 다 없으면 기존처럼 좌표를 보여 준다.
  String _placeSubtitle(Place p) => p.tagoId != null || p.kind == 'STOP'
      ? '버스 정류장${p.arsId != null ? ' · 정류장 번호 ${p.arsId}' : ''}'
      : p.address != null
      ? '${p.kind == 'PLACE' ? '장소' : '주소'} · ${p.address}'
      : '${p.latitude}, ${p.longitude}';

  // 입력창 바로 아래의 장소 후보 목록이며 키보드 위 남은 화면 안에서만 펼쳐 다른 입력창을 가리지 않는다.
  Widget _suggestionList(bool isOrigin) {
    final media = MediaQuery.of(context);
    // 상단 여백, 입력창 두 개와 간격을 뺀 키보드 위 영역을 최대 높이로 사용한다.
    final available =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.top -
        12 -
        58 * 2 -
        8 -
        24;
    final maxHeight = math.max(
      120.0,
      math.min(available, media.size.height * 0.45),
    );
    final Widget content;
    if (_suggestions.isEmpty) {
      content = Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_suggestLoading) ...[
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: EasyColors.primaryContainer,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                _suggestLoading
                    ? '장소를 찾고 있어요.'
                    : _suggestMessage ?? '검색 결과가 없습니다.',
                style: const TextStyle(
                  fontSize: 18,
                  color: EasyColors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      content = ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _suggestions.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: EasyColors.surfaceContainerHigh),
        itemBuilder: (_, index) {
          final place = _suggestions[index];
          return ListTile(
            minVerticalPadding: 12,
            title: Text(
              place.name,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: EasyColors.onSurface,
              ),
            ),
            subtitle: Text(
              _placeSubtitle(place),
              style: const TextStyle(
                fontSize: 15,
                color: EasyColors.onSurfaceVariant,
              ),
            ),
            onTap: () => unawaited(_selectSuggestion(place, isOrigin)),
          );
        },
      );
    }
    // 목록을 누를 때 입력창 바깥 탭으로 처리되어 키보드가 닫히지 않도록 같은 입력 영역으로 묶는다.
    return TextFieldTapRegion(
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: EasyColors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: EasyColors.cardShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(type: MaterialType.transparency, child: content),
      ),
    );
  }

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
          // 마지막으로 재생한 임의 문장(오류·재질문) 대신 현재 선택한 추천 경로의 안내를 실시간 도착정보와 함께 다시 들려준다.
          // speak()가 이전 재생을 멈춘 뒤 재생하므로 여러 번 눌러도 겹쳐 들리지 않는다.
          Material(
            color: EasyColors.surfaceContainer,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _busy || _phase == HomePhase.recording
                  ? null
                  : () async {
                      final route = _route;
                      if (route == null) return;
                      try {
                        await _device.speak(route.guidance);
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
                  // 최대 횟수(3회)를 모두 실패하면 다시 말하기는 제공하지 않고 글자 입력만 안내한다.
                  for (final item in <({String label, VoidCallback? action})>[
                    if (_voiceAttempts < VoicePolicy.maxAttempts)
                      (
                        label: '다시 말하기',
                        action: () {
                          unawaited(_microphone());
                        },
                      ),
                    (label: '글자로 입력하기', action: _typeInstead),
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
