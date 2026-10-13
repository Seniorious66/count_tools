import 'package:sqflite/sqflite.dart';

/// A child writer can use this transaction but cannot open or commit another one.
class OwnedTransactionDatabase implements Database {
  OwnedTransactionDatabase(this.tx);
  final Transaction tx;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => action(tx);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Only owned transaction available');
}
