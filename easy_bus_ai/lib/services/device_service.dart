import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../models/bus_models.dart';

// 사용성 시험에서 시간과 음량 기준을 함께 조정한다. 음량 감지는 실제 VAD가 아니다.
class VoicePolicy {
  static const startWait = Duration(seconds: 7);
  static const silence = Duration(seconds: 2);
  static const maximum = Duration(seconds: 30);
  static const sample = Duration(milliseconds: 100);
  static const minimumSpeech = Duration(milliseconds: 300);
  // 최근 관측 창 안의 말소리 표본 수로 판단하여 음절 사이의 짧은 끊김에 후보가 초기화되지 않게 한다.
  static const minimumSamples = 4;
  static const speechWindowSamples = 6;
  static const observationGap = Duration(milliseconds: 500);
  // 음량은 녹음 버퍼의 최대값(dBFS, 0이 최대)이며 기기마다 기본 음량이 달라 주변 소음 기준에 여유를 더한다.
  static const minimumDb = -50.0;
  static const maximumThresholdDb = -20.0;
  static const noiseMarginDb = 10.0;
  // 말소리 감지 후에는 더 낮은 기준으로 말끝을 판단하여 작은 목소리에서 녹음이 끊기지 않게 한다.
  static const releaseMarginDb = 6.0;
  // 발화 전 최근 1.5초 음량의 하위값을 주변 소음으로 추정한다.
  static const noiseWindowSamples = 15;
  // 최초 발화와 다시 말하기 2회를 합한 한 입력 단계의 최대 발화 횟수이다.
  static const maxAttempts = 3;
  static const maxLocationAccuracyMeters = 100.0;
}

// 개발·시험 단계에서는 GPS 수신 여부와 관계없이 원주시 중앙 좌표를 현재 위치로 사용한다.
// config/app.json의 USE_FIXED_LOCATION을 false로 바꾸면 기존 GPS 조회를 그대로 사용한다.
class LocationPolicy {
  static const useFixed = bool.fromEnvironment(
    'USE_FIXED_LOCATION',
    defaultValue: true,
  );
  // 기본값은 원주시청 인근(원주시 중앙 생활권) 좌표이며 설정 파일 값이 있으면 그 값을 사용한다.
  static const _defaultLatitude = 37.3422;
  static const _defaultLongitude = 127.9202;
  static final double latitude = _coordinate(
    const String.fromEnvironment('FIXED_LOCATION_LATITUDE'),
    _defaultLatitude,
    90,
  );
  static final double longitude = _coordinate(
    const String.fromEnvironment('FIXED_LOCATION_LONGITUDE'),
    _defaultLongitude,
    180,
  );
  static double _coordinate(String raw, double fallback, double limit) {
    final value = double.tryParse(raw.trim());
    return value != null && value.isFinite && value.abs() <= limit
        ? value
        : fallback;
  }

  static Place get fixedPlace => Place('current', '현재 위치', latitude, longitude);
}

class DeviceService {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  String? _path;
  String? _lastGuidance;
  int _speechRequest = 0;
  bool _recording = false, _disposed = false;
  Future<void>? _starting;
  StreamSubscription<Amplitude>? _amplitude;
  Timer? _limit, _watch;
  final _elapsed = Stopwatch();
  bool heardSpeech = false;
  bool _endpoint = false;
  Duration? _candidate, _lastSound;
  Duration? _lastObservation;
  bool _observationError = false;
  double _noiseDb = VoicePolicy.minimumDb - VoicePolicy.noiseMarginDb;
  // 최근 관측 창의 말소리 여부와 발화 전 소음 추정용 음량 기록이다.
  final List<bool> _recentSpeech = [];
  final List<double> _noiseSamples = [];
  // 실제 기기 진단용 음량 통계이며 녹음 내용은 기록하지 않는다.
  int _observations = 0;
  double _peakDb = -160;
  bool get detectionUnavailable =>
      _observationError ||
      _lastObservation == null ||
      _elapsed.elapsed - _lastObservation! > VoicePolicy.observationGap;
  // 음량은 관측되지만 모든 값이 완전 무음(-160dB)이면 기기 마이크 접근이 차단된 상태일 수 있다.
  bool get silentInput => _observations > 0 && _peakDb <= -159;

  // 발화 전에는 최근 음량의 하위 20% 값을 소음으로 보고, 발화 감지 후에는 기준을 고정한다.
  void _updateNoise(double value) {
    _noiseSamples.add(math.max(value, -100));
    if (_noiseSamples.length > VoicePolicy.noiseWindowSamples) {
      _noiseSamples.removeAt(0);
    }
    final sorted = List<double>.of(_noiseSamples)..sort();
    _noiseDb = sorted[(sorted.length - 1) ~/ 5];
  }

  double get _startThreshold => (_noiseDb + VoicePolicy.noiseMarginDb).clamp(
    VoicePolicy.minimumDb,
    VoicePolicy.maximumThresholdDb,
  );
  double get _releaseThreshold => (_noiseDb + VoicePolicy.releaseMarginDb)
      .clamp(VoicePolicy.minimumDb - 4, VoicePolicy.maximumThresholdDb - 4);

  void _log(String message) => debugPrint('[EASY_BUS_VOICE] $message');

  void _clearDetection() {
    _limit?.cancel();
    _watch?.cancel();
    _elapsed.stop();
  }

  // 종료 콜백은 한 번만 보내고 실제 완료·취소는 화면의 공통 경로에서 처리한다.
  void monitorRecording(void Function() onSpeech, void Function() onEnd) {
    if (!_recording || _disposed) return;
    void finish(String reason) {
      if (_endpoint || !_recording || _disposed) return;
      _endpoint = true;
      _clearDetection();
      _log(
        '자동 종료 사유=$reason 경과=${_elapsed.elapsedMilliseconds}ms '
        '말소리감지=$heardSpeech 관측수=$_observations '
        '최대음량=${_peakDb.toStringAsFixed(1)}dB '
        '소음추정=${_noiseDb.toStringAsFixed(1)}dB 관측오류=$_observationError',
      );
      onEnd();
    }

    _elapsed
      ..reset()
      ..start();
    _log(
      '음량 감지 시작 (발화대기=${VoicePolicy.startWait.inSeconds}초, '
      '무음=${VoicePolicy.silence.inSeconds}초, 최대=${VoicePolicy.maximum.inSeconds}초)',
    );
    _limit = Timer(VoicePolicy.maximum, () => finish('최대 녹음 시간'));
    _amplitude = _recorder
        .onAmplitudeChanged(VoicePolicy.sample)
        .listen(
          (value) {
            if (_endpoint || !_recording || !value.current.isFinite) return;
            final now = _elapsed.elapsed;
            if (_lastObservation == null ||
                now - _lastObservation! > VoicePolicy.observationGap) {
              _candidate = null;
              _recentSpeech.clear();
            }
            _lastObservation = now;
            _observationError = false;
            _observations++;
            _peakDb = math.max(_peakDb, value.current);
            // 발화 감지 전에는 소음 추정과 시작 기준을, 감지 후에는 고정된 소음 기준의 종료 기준을 사용한다.
            final threshold = heardSpeech ? _releaseThreshold : _startThreshold;
            final loud = value.current >= threshold;
            if (!heardSpeech) _updateNoise(value.current);
            _recentSpeech.add(loud);
            if (_recentSpeech.length > VoicePolicy.speechWindowSamples) {
              _recentSpeech.removeAt(0);
            }
            if (loud) {
              _candidate ??= now;
              _lastSound = now;
            }
            final voiced = _recentSpeech.where((v) => v).length;
            if (voiced == 0) _candidate = null;
            if (!heardSpeech &&
                _candidate != null &&
                voiced >= VoicePolicy.minimumSamples &&
                now - _candidate! >= VoicePolicy.minimumSpeech) {
              heardSpeech = true;
              _log(
                '말소리 감지 경과=${now.inMilliseconds}ms '
                '음량=${value.current.toStringAsFixed(1)}dB '
                '기준=${threshold.toStringAsFixed(1)}dB '
                '소음추정=${_noiseDb.toStringAsFixed(1)}dB',
              );
              onSpeech();
            }
            // 1초마다 음량과 기준값을 기록해 실제 기기 마이크 특성을 확인한다.
            if (_observations % 10 == 0) {
              _log(
                '음량 경과=${now.inMilliseconds}ms '
                '현재=${value.current.toStringAsFixed(1)}dB '
                '소음추정=${_noiseDb.toStringAsFixed(1)}dB '
                '기준=${threshold.toStringAsFixed(1)}dB '
                '최근말소리=$voiced/${_recentSpeech.length} 말소리감지=$heardSpeech',
              );
            }
          },
          onError: (Object error) {
            _observationError = true;
            _log('음량 관측 오류 유형=${error.runtimeType}');
            // 관측 오류에도 최대 시간은 유지하며 녹음 파일은 서버 음성 인식으로 판단한다.
          },
        );
    _watch = Timer.periodic(VoicePolicy.sample, (_) {
      final now = _elapsed.elapsed;
      // 대기 마감 직전 시작한 짧은 음성 후보에는 최소 관측 시간만 추가 허용한다.
      final waitingEnded =
          now >= VoicePolicy.startWait &&
          (_candidate == null ||
              now >=
                  VoicePolicy.startWait +
                      VoicePolicy.minimumSpeech +
                      VoicePolicy.sample);
      // 음량을 전혀 관측하지 못하는 기기에서는 무발화로 단정하지 않고 직접 종료 또는 최대 시간까지 녹음한다.
      if (!heardSpeech && waitingEnded && !detectionUnavailable) {
        finish('발화 대기 시간 초과');
      } else if (heardSpeech &&
          !detectionUnavailable &&
          _lastSound != null &&
          now - _lastSound! >= VoicePolicy.silence) {
        finish('발화 후 무음');
      }
    });
  }

  Future<void> _stopDetection() async {
    _endpoint = true;
    _clearDetection();
    final subscription = _amplitude;
    _amplitude = null;
    await subscription?.cancel();
  }

  // 현재 위치 관련 기능은 모두 이 함수를 사용하며, 고정 위치 모드에서는 GPS 결과가 덮어쓰지 않는다.
  Future<Place> currentPosition() async {
    if (LocationPolicy.useFixed) {
      debugPrint('[EASY_BUS_LOCATION] 고정 위치 모드: 원주시 중앙 좌표 사용');
      return LocationPolicy.fixedPlace;
    }
    return _gpsPosition();
  }

  Future<Place> _gpsPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('휴대전화의 위치 기능을 켜 주세요.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('위치 권한을 허용하거나 출발지를 직접 입력해 주세요.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    if (!position.accuracy.isFinite ||
        position.accuracy > VoicePolicy.maxLocationAccuracyMeters) {
      throw Exception('현재 위치가 정확하지 않습니다. 출발지를 직접 선택해 주세요.');
    }
    return Place('current', '현재 위치', position.latitude, position.longitude);
  }

  Future<void> startRecording() {
    final task = _startRecording();
    _starting = task;
    return task;
  }

  Future<void> _startRecording() async {
    if (_recording || _disposed) throw StateError('녹음을 시작할 수 없습니다.');
    _recording = true;
    heardSpeech = false;
    _endpoint = false;
    _candidate = _lastSound = null;
    _lastObservation = null;
    _observationError = false;
    _noiseDb = VoicePolicy.minimumDb - VoicePolicy.noiseMarginDb;
    _recentSpeech.clear();
    _noiseSamples.clear();
    _observations = 0;
    _peakDb = -160;
    try {
      await stopSpeaking();
      final permitted = await _recorder.hasPermission();
      _log('마이크 권한=${permitted ? '허용' : '거부'}');
      if (!permitted) throw Exception('음성 입력을 사용하려면 마이크 권한을 허용해 주세요.');
      final directory = await getTemporaryDirectory();
      if (_disposed) throw StateError('화면이 닫혀 녹음을 취소했습니다.');
      _path =
          '${directory.path}/easy_bus_${DateTime.now().microsecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _path!,
      );
      _log('녹음 시작 (WAV PCM 16bit, 16000Hz, 모노)');
    } catch (error) {
      _log('녹음 시작 실패 유형=${error.runtimeType}');
      await cancelRecording();
      rethrow;
    }
  }

  Future<String> stopRecording() async {
    await _stopDetection();
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception('녹음 파일을 찾을 수 없습니다.');
      // 파일 크기로 실제 음성 데이터가 기록되었는지 확인한다. 44바이트는 WAV 머리글이다.
      final file = File(path);
      final size = await file.exists() ? await file.length() : -1;
      final seconds = size > 44 ? (size - 44) / (16000 * 2) : 0;
      _log(
        '녹음 종료 파일크기=${size}B 추정길이=${seconds.toStringAsFixed(1)}초 '
        '말소리감지=$heardSpeech',
      );
      if (size <= 44) throw Exception('녹음된 소리가 없습니다. 다시 말씀해 주세요.');
      return path;
    } catch (_) {
      await cancelRecording();
      rethrow;
    } finally {
      _recording = false;
    }
  }

  Future<void> deleteRecording(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
    if (_path == path) _path = null;
  }

  Future<void> cancelRecording() async {
    if (_recording) _log('녹음 취소');
    await _stopDetection();
    try {
      await _recorder.cancel();
    } finally {
      _recording = false;
      if (_path != null) await deleteRecording(_path!);
    }
  }

  Future<void> speak(String text) async {
    if (_recording || _disposed) return;
    final request = ++_speechRequest;
    _lastGuidance = text;
    await _tts.stop();
    // 중지 또는 새 안내 요청 이후에는 이전 비동기 설정의 재생을 무효화한다.
    if (request != _speechRequest) return;
    await _tts.setLanguage('ko-KR');
    if (request != _speechRequest) return;
    await _tts.setSpeechRate(0.4);
    if (request != _speechRequest) return;
    await _tts.speak(text);
  }

  Future<void> repeat() async {
    if (_lastGuidance != null) await speak(_lastGuidance!);
  }

  Future<void> stopSpeaking() async {
    ++_speechRequest;
    await _tts.stop();
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _starting;
    } catch (_) {
      /* 시작 실패 후에도 자원 해제를 계속한다. */
    }
    // 한 장치의 정리 실패가 다른 장치 자원 해제를 건너뛰지 않게 한다.
    try {
      await stopSpeaking();
    } finally {
      try {
        await cancelRecording();
      } finally {
        await _recorder.dispose();
      }
    }
  }
}
