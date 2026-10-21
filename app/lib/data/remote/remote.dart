import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../../core/errors.dart';

/// Server persistence used by the outbox handlers and the pull-on-start merge.
abstract class Remote {
  /// Upsert users/{uid}/{collection}/{id} (or users/{uid} when collection is
  /// empty). Adds a server `updated_at` for last-write-wins (O3).
  Future<void> upsert(
    String uid,
    String collection,
    String id,
    Map<String, dynamic> data,
  );

  /// Upload a local JPEG to [storagePath]; re-running overwrites (idempotent).
  Future<void> upload(String localPath, String storagePath);

  /// Recent docs of a collection, newest first, with cursor paging (O4).
  Future<List<Map<String, dynamic>>> recent(
    String uid,
    String collection, {
    required String orderBy,
    int limit = 50,
  });

  /// users/{uid} document (entitlement, winback, ai_usage mirrors).
  Stream<Map<String, dynamic>?> userDoc(String uid);

  Future<void> deleteAccount();
}

class FirebaseRemote implements Remote {
  FirebaseRemote(this.db, this.storage, this.deleteAccountFn);

  final FirebaseFirestore db;
  final FirebaseStorage storage;
  final Future<void> Function() deleteAccountFn;

  DocumentReference<Map<String, dynamic>> _doc(
    String uid,
    String collection,
    String id,
  ) => collection.isEmpty
      ? db.collection('users').doc(uid)
      : db.collection('users').doc(uid).collection(collection).doc(id);

  @override
  Future<void> upsert(
    String uid,
    String collection,
    String id,
    Map<String, dynamic> data,
  ) => _guard(
    () => _doc(uid, collection, id).set({
      ...toFirestoreTypes(data),
      'server_updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)),
  );

  @override
  Future<void> upload(String localPath, String storagePath) => _guard(() async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw PermanentError(
        'local photo missing: $localPath',
        code: 'missing_file',
      );
    }
    await storage
        .ref(storagePath)
        .putFile(
          file,
          SettableMetadata(
            contentType: 'image/jpeg',
            cacheControl: 'private, max-age=86400',
          ),
        );
  });

  @override
  Future<List<Map<String, dynamic>>> recent(
    String uid,
    String collection, {
    required String orderBy,
    int limit = 50,
  }) => _guard(() async {
    final snap = await db
        .collection('users')
        .doc(uid)
        .collection(collection)
        .orderBy(orderBy, descending: true)
        .limit(limit)
        .get();
    return [
      for (final d in snap.docs)
        {
          ...d.data(),
          '_id': d.id,
          '_server_updated_at': _ts(d.data()['server_updated_at']),
        },
    ];
  });

  /// Outbox payloads are JSON; turn ISO date strings in `*_at` / `*_for`
  /// fields back into Firestore timestamps (the rules require them).
  static Map<String, dynamic> toFirestoreTypes(Map<String, dynamic> data) =>
      data.map((k, v) {
        if (v is String && (k.endsWith('_at') || k.endsWith('_for'))) {
          final d = DateTime.tryParse(v);
          if (d != null) return MapEntry(k, Timestamp.fromDate(d));
        }
        if (v is Map)
          return MapEntry(k, toFirestoreTypes(Map<String, dynamic>.from(v)));
        return MapEntry(k, v);
      });

  static String? _ts(Object? v) =>
      v is Timestamp ? v.toDate().toIso8601String() : null;

  @override
  Stream<Map<String, dynamic>?> userDoc(String uid) =>
      db.collection('users').doc(uid).snapshots().map((s) => s.data());

  @override
  Future<void> deleteAccount() => _guard(deleteAccountFn);

  static Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on FirebaseException catch (e) {
      switch (e.code) {
        case 'permission-denied':
        case 'invalid-argument':
        case 'unauthorized':
        case 'object-not-found':
          throw PermanentError(e.message ?? e.code, code: e.code);
        default:
          throw TransientError(e.message ?? e.code);
      }
    } on SocketException {
      throw const OfflineError();
    }
  }
}
