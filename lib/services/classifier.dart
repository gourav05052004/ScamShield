import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class FraudClassifier {
  Interpreter? _interpreter;

  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/fraud_model.tflite');
      debugPrint('Model loaded successfully');
    } catch (e) {
      debugPrint('Model load FAILED: $e');
      rethrow;
    }
  }

  double classify(List<int> tokenIds) {
    assert(_interpreter != null, 'Model must be loaded before classification');

    // Convert int tokens to doubles and wrap in 2D array [1, 60]
    final input = [tokenIds.map((e) => e.toDouble()).toList()];
    final output = [<double>[0.0]];

    // Run the model
    _interpreter!.run(input, output);

    // Extract the raw confidence score
    double confidenceScore = output[0][0];
    
    // Determine the label based on your 0.5 threshold
    String label = confidenceScore >= 0.5 ? '🔴 FRAUD DETECTED' : '🟢 LEGITIMATE CALL';

    // LOG TO CONSOLE
    debugPrint('🧠 MODEL PREDICTION: $label | Score: $confidenceScore');

    return confidenceScore;
  }

  void dispose() {
    _interpreter?.close();
  }

  bool get isLoaded => _interpreter != null;
}

Future<void> testClassifier() async {
  final classifier = FraudClassifier();
  await classifier.loadModel();

  // CHANGED: 100 -> 60 so your dummy test doesn't crash the model
  final dummyInput = List<int>.filled(60, 1);
  final score = classifier.classify(dummyInput);

  debugPrint('Raw score: $score');
  debugPrint(score >= 0.5 ? 'FRAUD' : 'LEGITIMATE');
}
