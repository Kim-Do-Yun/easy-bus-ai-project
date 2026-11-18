import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  static const minimumSamples = 4;
  static const observationGap = Duration(milliseconds: 500);
  static const minimumDb = -45.0;
  static const noiseMarginDb = 8.0;
  static const maxAttempts = 2;
  static const maxLocationAccuracyMeters = 100.0;
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
  int _soundSamples = 0;
  bool _observationError = false;
  double _noiseDb = -60;
  bool get detectionUnavailable =>
      _observationError ||
      _lastObservation == null ||
      _elapsed.elapsed - _lastObservation! > VoicePolicy.observationGap;

  void _clearDetection() {
    _limit?.cancel();
    _watch?.cancel();
    _elapsed.stop();
  }

  // 종료 콜백은 한 번만 보내고 실제 완료·취소는 화면의 공통 경로에서 처리한다.
  void monitorRecording(void Function() onSpeech, void Function() onEnd) {
    if (!_recording || _disposed) return;
    void finish() {
      if (_endpoint || !_recording || _disposed) return;
      _endpoint = true;
      _clearDetection();
      onEnd();
    }

    _elapsed
      ..reset()
      ..start();
    _limit = Timer(VoicePolicy.maximum, finish);
    _amplitude = _recorder
        .onAmplitudeChanged(VoicePolicy.sample)
        .listen(
          (value) {
            if (_endpoint || !_recording || !value.current.isFinite) return;
            final now = _elapsed.elapsed;
            if (_lastObservation == null ||
                now - _lastObservation! > VoicePolicy.observationGap) {
              _candidate = null;
              _soundSamples = 0;
            }
            _lastObservation = now;
            _observationError = false;
            final threshold = math.max(
              VoicePolicy.minimumDb,
              _noiseDb + VoicePolicy.noiseMarginDb,
            );
            if (value.current >= threshold) {
              _candidate ??= now;
              _soundSamples++;
              _lastSound = now;
              if (!heardSpeech &&
                  _soundSamples >= VoicePolicy.minimumSamples &&
                  now - _candidate! >= VoicePolicy.minimumSpeech) {
                heardSpeech = true;
                onSpeech();
              }
            } else {
              _candidate = null;
              _soundSamples = 0;
              // 말소리 후보를 소음 기준에 섞지 않고 낮은 음량 구간만 천천히 반영한다.
              _noiseDb = (_noiseDb * 0.95 + value.current * 0.05).clamp(
                -80.0,
                -30.0,
              );
            }
          },
          onError: (Object _) {
            _observationError = true;
            // 관측 오류에도 최대 시간은 유지하며 감지하지 못한 파일은 전송하지 않는다.
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
      if (!heardSpeech && waitingEnded ||
          heardSpeech &&
              !detectionUnavailable &&
              _lastSound != null &&
              now - _lastSound! >= VoicePolicy.silence) {
        finish();
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

  Future<Place> currentPosition() async {
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
    _soundSamples = 0;
    _observationError = false;
    _noiseDb = -60;
    try {
      await stopSpeaking();
      if (!await _recorder.hasPermission())
        throw Exception('음성 입력을 사용하려면 마이크 권한을 허용해 주세요.');
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
    } catch (_) {
      await cancelRecording();
      rethrow;
    }
  }

  Future<String> stopRecording() async {
    await _stopDetection();
    try {
      final path = await _recorder.stop();
      if (path == null) throw Exception('녹음 파일을 찾을 수 없습니다.');
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
