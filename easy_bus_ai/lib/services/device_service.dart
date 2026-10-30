import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../models/bus_models.dart';

class DeviceService {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  String? _path;
  String? _lastGuidance;

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
    return Place('current', '현재 위치', position.latitude, position.longitude);
  }

  Future<void> startRecording() async {
    await stopSpeaking();
    if (!await _recorder.hasPermission())
      throw Exception('음성 입력을 사용하려면 마이크 권한을 허용해 주세요.');
    final directory = await getTemporaryDirectory();
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
  }

  Future<String> stopRecording() async {
    final path = await _recorder.stop();
    if (path == null) throw Exception('녹음 파일을 찾을 수 없습니다.');
    return path;
  }

  Future<void> deleteRecording(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
    if (_path == path) _path = null;
  }

  Future<void> cancelRecording() async {
    await _recorder.cancel();
    if (_path != null) await deleteRecording(_path!);
  }

  Future<void> speak(String text) async {
    _lastGuidance = text;
    await _tts.stop();
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.4);
    await _tts.speak(text);
  }

  Future<void> repeat() async {
    if (_lastGuidance != null) await speak(_lastGuidance!);
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  Future<void> dispose() async {
    await stopSpeaking();
    await cancelRecording();
    await _recorder.dispose();
  }
}
