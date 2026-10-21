import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../core/config.dart';

class AppUser {
  const AppUser({required this.uid, this.email, this.displayName});
  final String uid;
  final String? email;
  final String? displayName;
}

class AuthCancelled implements Exception {}

abstract class AuthService {
  AppUser? get current;
  Stream<AppUser?> get changes;
  Future<String?> idToken({bool force = false});
  Future<AppUser> signInWithApple();
  Future<AppUser> signInWithGoogle();
  Future<AppUser> signInWithEmail(
    String email,
    String password, {
    required bool create,
  });
  Future<void> signOut();
  bool get appleAvailable;
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService(this._auth);

  final FirebaseAuth _auth;
  bool _googleReady = false;

  static AppUser? _map(User? u) => u == null
      ? null
      : AppUser(uid: u.uid, email: u.email, displayName: u.displayName);

  @override
  AppUser? get current => _map(_auth.currentUser);

  @override
  Stream<AppUser?> get changes => _auth.authStateChanges().map(_map);

  @override
  Future<String?> idToken({bool force = false}) async =>
      _auth.currentUser?.getIdToken(force);

  @override
  bool get appleAvailable => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<AppUser> signInWithApple() async {
    // Nonce protects against replay; Firebase checks the SHA-256 of it.
    final raw = _nonce();
    final cred =
        await SignInWithApple.getAppleIDCredential(
          scopes: [
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
          nonce: sha256.convert(utf8.encode(raw)).toString(),
        ).catchError((Object e) {
          if (e is SignInWithAppleAuthorizationException &&
              e.code == AuthorizationErrorCode.canceled) {
            throw AuthCancelled();
          }
          throw e;
        });
    final oauth = OAuthProvider('apple.com').credential(
      idToken: cred.identityToken,
      rawNonce: raw,
      accessToken: cred.authorizationCode,
    );
    final res = await _auth.signInWithCredential(oauth);
    final name = [
      cred.givenName,
      cred.familyName,
    ].whereType<String>().join(' ');
    if (name.isNotEmpty && (res.user?.displayName ?? '').isEmpty) {
      await res.user?.updateDisplayName(name);
    }
    return _map(_auth.currentUser)!;
  }

  @override
  Future<AppUser> signInWithGoogle() async {
    final g = GoogleSignIn.instance;
    if (!_googleReady) {
      await g.initialize(
        clientId: AppConfig.googleIosClientId.isEmpty
            ? null
            : AppConfig.googleIosClientId,
        serverClientId: AppConfig.googleServerClientId.isEmpty
            ? null
            : AppConfig.googleServerClientId,
      );
      _googleReady = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await g.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) throw AuthCancelled();
      rethrow;
    }
    final cred = GoogleAuthProvider.credential(
      idToken: account.authentication.idToken,
    );
    await _auth.signInWithCredential(cred);
    return _map(_auth.currentUser)!;
  }

  @override
  Future<AppUser> signInWithEmail(
    String email,
    String password, {
    required bool create,
  }) async {
    if (create) {
      await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } else {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
    }
    return _map(_auth.currentUser)!;
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    if (_googleReady) await GoogleSignIn.instance.signOut();
  }

  static String _nonce([int length = 32]) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final r = math.Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

/// Offline demo / tests: a local account with no network.
class DemoAuthService implements AuthService {
  AppUser? _user;
  final _ctrl = StreamController<AppUser?>.broadcast();

  @override
  AppUser? get current => _user;

  @override
  Stream<AppUser?> get changes => _ctrl.stream;

  @override
  Future<String?> idToken({bool force = false}) async =>
      _user == null ? null : 'demo:${_user!.uid}';

  @override
  bool get appleAvailable => true;

  Future<AppUser> _sign(String? email) async {
    _user = AppUser(uid: 'demo-user', email: email, displayName: 'Aarav');
    _ctrl.add(_user);
    return _user!;
  }

  @override
  Future<AppUser> signInWithApple() => _sign('demo@privaterelay.appleid.com');

  @override
  Future<AppUser> signInWithGoogle() => _sign('demo@gmail.com');

  @override
  Future<AppUser> signInWithEmail(
    String email,
    String password, {
    required bool create,
  }) => _sign(email);

  @override
  Future<void> signOut() async {
    _user = null;
    _ctrl.add(null);
  }
}
