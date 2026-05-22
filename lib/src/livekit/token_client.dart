import 'dart:convert';

import 'package:http/http.dart' as http;

/// Talks to the user-deployed token-mint endpoint.
///
/// The endpoint is expected to accept JSON
/// `{ "room": "...", "identity": "...", "name": "<role:code>" }`
/// and return JSON `{ "token": "<jwt>" }` (extra fields are ignored).
///
/// The LiveKit API key and secret live ONLY on that server.
class TokenClient {
  TokenClient(this.endpoint);

  final String endpoint;

  Future<String> fetchToken({
    required String room,
    required String identity,
    required String role, // 'host' or 'controller'
    required String pairingCode,
  }) async {
    final res = await http.post(
      Uri.parse(endpoint),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'room': room,
        'identity': identity,
        // Encoded into the participant `name` so it shows up server-side
        // for any future authorization / pairing-code enforcement.
        'name': '$role:$pairingCode',
      }),
    );
    if (res.statusCode != 200) {
      throw TokenException(
        'Token endpoint returned ${res.statusCode}: ${res.body}',
      );
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw TokenException('Token endpoint returned no token');
    }
    return token;
  }
}

class TokenException implements Exception {
  TokenException(this.message);
  final String message;
  @override
  String toString() => 'TokenException: $message';
}
