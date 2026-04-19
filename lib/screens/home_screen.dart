import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fraud_detector/services/classifier.dart';
import 'package:fraud_detector/services/preprocessor.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

enum AppState { idle, recording, processing }

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppState _appState = AppState.idle;
  final TextPreprocessor _preprocessor = TextPreprocessor();
  final FraudClassifier _classifier = FraudClassifier();
  final SpeechToText _speechToText = SpeechToText();
  Whisper? _whisper;
  String _liveTranscript = '';
  bool _fraudDetected = false;
  String? _uploadedFileName;
  String? _recordedFilePath;
  String? _resultLabel;
  double? _confidenceScore;

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _initWhisper();
  }

  Future<void> _initializeServices() async {
    try {
      await Future.wait([
        _preprocessor.loadVocab(),
        _classifier.loadModel(),
      ]);
    } catch (error) {
      debugPrint('Initialization error: $error');
    }
  }

  Future<void> _initWhisper() async {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final modelDir = appSupportDir.path;
      final modelFile = File('$modelDir/ggml-tiny.bin');

      if (!modelFile.existsSync()) {
        final modelData = await rootBundle.load('assets/models/ggml-tiny.en.bin');
        final bytes = modelData.buffer.asUint8List();
        await modelFile.writeAsBytes(bytes, flush: true);
      }

      _whisper = Whisper(
        model: WhisperModel.tiny,
        modelDir: modelDir,
      );

      await _whisper!.getVersion();
      debugPrint('Whisper STT engine loaded');
    } catch (error) {
      debugPrint('Whisper init error: $error');
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _appState = AppState.recording;
      _liveTranscript = '';
      _fraudDetected = false;
      _resultLabel = null;
      _confidenceScore = null;
    });

    final available = await _speechToText.initialize();
    if (!available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition unavailable')),
        );
        setState(() {
          _appState = AppState.idle;
        });
      }
      return;
    }

    await _speechToText.listen(
      onResult: _onSpeechResult,
      localeId: 'en_IN',
      partialResults: true,
      pauseFor: const Duration(seconds: 5),
      listenFor: const Duration(minutes: 5),
      onSoundLevelChange: null,
    );
  }

  Future<void> _stopRecording() async {
    await _speechToText.stop();

    if (_liveTranscript.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No speech detected')),
        );
        setState(() {
          _appState = AppState.idle;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _appState = AppState.processing;
      });
    }

    _analyzeRecording(_liveTranscript);
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) {
      return;
    }

    setState(() {
      _liveTranscript = result.recognizedWords;
    });

    print('🎤 LIVE TRANSCRIPT: $_liveTranscript');

    if (result.recognizedWords.trim().isEmpty) {
      return;
    }

    if (_fraudDetected) {
      return;
    }
  }

  Future<void> _uploadRecording() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
      );

      if (result == null || result.files.single.path == null) {
        return;
      }

      setState(() {
        _appState = AppState.processing;
        _uploadedFileName = result.files.single.name;
        _recordedFilePath = result.files.single.path;
        _fraudDetected = false;
        _liveTranscript = 'Extracting audio...';
        _resultLabel = null;
        _confidenceScore = null;
      });

      final extractedText = await _transcribeAudioFile(_recordedFilePath!);

      if (!mounted) {
        return;
      }

      setState(() {
        _liveTranscript = extractedText;
      });

      _analyzeRecording(extractedText);
    } catch (error) {
      debugPrint('Upload error: $error');
      if (mounted) {
        setState(() {
          _appState = AppState.idle;
        });
      }
    }
  }

  Future<String> _transcribeAudioFile(String filePath) async {
    if (_whisper == null) {
      return 'Error: Transcription engine not loaded.';
    }

    try {
      final response = await _whisper!.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: filePath,
          language: 'en',
          isTranslate: false,
          isNoTimestamps: true,
          splitOnWord: true,
        ),
      );

      final text = response.text.trim();
      return text.isEmpty ? 'No speech detected in file.' : text;
    } catch (error) {
      debugPrint('Transcription error: $error');
      return 'Transcription failed.';
    }
  }

  void _analyzeRecording(String transcript) {
    if (transcript.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _appState = AppState.idle;
          _resultLabel = 'No speech detected';
        });
      }
      return;
    }

    if (!_classifier.isLoaded) {
      if (mounted) {
        setState(() {
          _appState = AppState.idle;
          _resultLabel = 'Model not loaded';
        });
      }
      return;
    }

    try {
      final tokens = _preprocessor.preprocess(transcript);
      final score = _classifier.classify(tokens);

      if (!mounted) {
        return;
      }

      setState(() {
        _fraudDetected = score >= 0.5;
        _confidenceScore = score;
        _resultLabel = score >= 0.5 ? 'FRAUD DETECTED' : 'LEGITIMATE CALL';
        _appState = AppState.idle;
      });
    } catch (error) {
      debugPrint('Analysis error: $error');
      if (mounted) {
        setState(() {
          _appState = AppState.idle;
          _resultLabel = 'Analysis failed';
        });
      }
    }
  }

  @override
  void dispose() {
    _classifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.indigo[800],
        title: const Text(
          'ScamShield AI',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildResultCard(),
              const SizedBox(height: 24),
              const Text(
                'Live Transcript',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 150,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey[300]!),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _liveTranscript.isEmpty
                        ? 'Your conversation transcript will appear here...'
                        : _liveTranscript,
                    style: TextStyle(
                      fontSize: 15,
                      color: _liveTranscript.isEmpty
                          ? Colors.grey
                          : Colors.black87,
                      fontStyle: _liveTranscript.isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: _buildControls(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    bool isFraud = _resultLabel?.contains('FRAUD') ?? false;
    bool hasResult = _resultLabel != null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: hasResult
              ? (isFraud
                  ? [Colors.red[700]!, Colors.red[500]!]
                  : [Colors.green[700]!, Colors.green[500]!])
              : [Colors.indigo[50]!, Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: hasResult
                ? (isFraud
                    ? Colors.red.withOpacity(0.3)
                    : Colors.green.withOpacity(0.3))
                : Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            hasResult
                ? (isFraud
                    ? Icons.warning_rounded
                    : Icons.verified_user_rounded)
                : Icons.shield_rounded,
            size: 64,
            color: hasResult ? Colors.white : Colors.indigo[300],
          ),
          const SizedBox(height: 16),
          Text(
            _resultLabel ?? 'Awaiting Analysis',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: hasResult ? Colors.white : Colors.indigo[900],
            ),
            textAlign: TextAlign.center,
          ),
          if (_confidenceScore != null) ...[
            const SizedBox(height: 12),
            Text(
              'Confidence: ${(_confidenceScore! * 100).toStringAsFixed(1)}%',
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (_uploadedFileName != null && !hasResult) ...[
            const SizedBox(height: 12),
            Text(
              'File: $_uploadedFileName',
              style: TextStyle(fontSize: 14, color: Colors.indigo[400]),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControls() {
    if (_appState == AppState.processing) {
      return Column(
        children: [
          const CircularProgressIndicator(color: Colors.indigo),
          const SizedBox(height: 16),
          Text(
            'Running AI Model...',
            style: TextStyle(color: Colors.grey[700], fontWeight: FontWeight.w500),
          ),
        ],
      );
    }

    if (_appState == AppState.recording) {
      return FloatingActionButton.extended(
        onPressed: _stopRecording,
        backgroundColor: Colors.redAccent,
        icon: const Icon(Icons.stop_rounded, color: Colors.white),
        label: const Text(
          'Stop Recording',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        ElevatedButton.icon(
          onPressed: _startRecording,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo[600],
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          icon: const Icon(Icons.mic, color: Colors.white),
          label: const Text(
            'Record Call',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _uploadRecording,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.indigo[600],
            side: BorderSide(color: Colors.indigo[600]!, width: 2),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          icon: const Icon(Icons.upload_file),
          label: const Text('Upload', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}
