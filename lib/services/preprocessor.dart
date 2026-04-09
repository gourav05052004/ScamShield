import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TextPreprocessor {
  // CHANGED: 100 -> 60 to match the Conv1D model's expected input shape
  static const int maxSequenceLength = 60;

  Map<String, int> _vocab = {};

  Future<void> loadVocab() async {
    try {
      final vocabString = await rootBundle.loadString('assets/models/vocab.json');
      final decoded = jsonDecode(vocabString);

      _vocab = {};

      if (decoded is Map) {
        // If it's a standard dictionary {"word": 1}
        decoded.forEach((key, value) {
          // Safely parse the value no matter what type it is
          _vocab[key.toString()] = int.tryParse(value.toString()) ?? 0;
        });
        debugPrint('✅ VOCAB LOADED: ${_vocab.length} words found (Map format)');
      } 
      else if (decoded is List) {
        // If Python exported it as a flat list ["word1", "word2"]
        for (int i = 0; i < decoded.length; i++) {
          _vocab[decoded[i].toString()] = i + 1; // Keras is usually 1-indexed
        }
        debugPrint('✅ VOCAB LOADED: ${_vocab.length} words found (List format)');
      } 
      else {
        debugPrint('❌ ERROR: Unrecognized vocab.json format.');
      }
    } catch (e) {
      debugPrint('❌ CRITICAL ERROR loading vocab.json: $e');
    }
  }

  List<int> preprocess(String text) {
    final normalizedText = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '');

    final tokens = normalizedText
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();

    final tokenIds = tokens.map((token) {
      // If word isn't in vocab, log it so we know!
      if (!_vocab.containsKey(token)) {
        debugPrint('⚠️ VOCAB MISS: $token');
      }
      
      final id = _vocab[token] ?? 0;
      // Removed the >= 1000 limit just in case your vocab is larger than 1000
      return id; 
    }).toList();

    List<int> finalSequence;

    // FIX: Match Python's default PRE-PADDING
    if (tokenIds.length > maxSequenceLength) {
      // Truncate from the beginning (Python default)
      finalSequence = tokenIds.sublist(tokenIds.length - maxSequenceLength);
    } else if (tokenIds.length < maxSequenceLength) {
      // Pad with zeros at the BEGINNING
      int paddingNeeded = maxSequenceLength - tokenIds.length;
      finalSequence = List<int>.filled(paddingNeeded, 0) + tokenIds;
    } else {
      finalSequence = tokenIds;
    }

    // LOG THE ACTUAL ARRAY GOING INTO THE MODEL
    debugPrint('🔢 TOKEN ARRAY: $finalSequence');

    return finalSequence;
  }

  bool get isLoaded => _vocab.isNotEmpty;
}

Future<void> testPreprocessor() async {
  final preprocessor = TextPreprocessor();
  await preprocessor.loadVocab();
  final tokens = preprocessor.preprocess(
    'your account has been compromised please verify your details immediately',
  );
  debugPrint(tokens.toString());
}
